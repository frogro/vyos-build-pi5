#!/usr/bin/env python3
"""
Dispatch `add system image` on VyOS Raspberry Pi A/B systems.

Local, HTTP(S), or `latest` Raspberry Pi A/B update bundles (*.tar.zst) are
handed to install-vyos-pi-ab-update.py. For `latest`, the dispatcher reuses
VyOS' existing latest-image-url.py resolver and configured `system update-check
url`; no repository URL is hard-coded here. Everything else is exec'd unchanged
into the original VyOS op-mode image_installer.py.

The dispatcher performs only lightweight identification. Full bundle integrity,
layout, architecture/flavor and A/B safety validation remains the job of
install-vyos-pi-ab-update.py.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
from urllib.parse import urlparse
from uuid import uuid4

DISPATCHER_REBOOT_PROMPT = "Reboot and test the new image now? [Y/n] "

from vyos.remote import download

ORIGINAL_INSTALLER = Path("/usr/libexec/vyos/op_mode/image_installer.py")
AB_INSTALLER = Path("/usr/libexec/vyos/install-vyos-pi-ab-update.py")
SIMPLE_DOWNLOAD = Path("/usr/libexec/vyos/simple-download.py")
LATEST_IMAGE_URL = Path("/usr/libexec/vyos/latest-image-url.py")
DT_BASE = Path("/proc/device-tree/chosen/bootloader")
SUPPORTED_REMOTE_SCHEMES = {"http", "https"}

AB_LABELS = (
    "VYOS_AB",
    "VYOS_BOOT_A",
    "VYOS_BOOT_B",
    "VYOS_ROOT_A",
    "VYOS_ROOT_B",
)


class DispatchError(RuntimeError):
    pass


def run(
    *args: str,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        args,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise DispatchError(f"command failed: {' '.join(args)}: {detail}")
    return result


def blkid_label_device(label: str) -> str | None:
    result = run("blkid", "-L", label, check=False)
    value = result.stdout.strip()
    if result.returncode != 0 or not value:
        return None
    return os.path.realpath(value)


def findmnt_source(target: str) -> str | None:
    result = run("findmnt", "-rn", "-o", "SOURCE", "--target", target, check=False)
    value = result.stdout.strip()
    if result.returncode != 0 or not value:
        return None
    return os.path.realpath(value.split("[", 1)[0])


def blkid_value(device: str, field: str) -> str | None:
    result = run("blkid", "-s", field, "-o", "value", device, check=False)
    value = result.stdout.strip()
    if result.returncode != 0 or not value:
        return None
    return value


def is_raspberry_pi_ab_system() -> bool:
    if not DT_BASE.is_dir():
        return False

    devices = {label: blkid_label_device(label) for label in AB_LABELS}
    if any(device is None for device in devices.values()):
        return False

    root = findmnt_source("/")
    boot = findmnt_source("/boot/firmware")
    if root is None or boot is None:
        return False

    root_label = blkid_value(root, "LABEL")
    boot_label = blkid_value(boot, "LABEL")

    valid_pairs = {
        ("VYOS_ROOT_A", "VYOS_BOOT_A"),
        ("VYOS_ROOT_B", "VYOS_BOOT_B"),
    }
    return (root_label, boot_label) in valid_pairs


def is_remote_ab_candidate(image_path: str) -> bool:
    parsed = urlparse(image_path)
    return (
        parsed.scheme.lower() in SUPPORTED_REMOTE_SCHEMES
        and parsed.path.lower().endswith(".tar.zst")
    )


def configure_remote_credentials(username: str, password: str) -> None:
    # Match upstream image_installer.py semantics: vyos.remote.download and
    # simple-download.py consume these environment variables implicitly.
    os.environ["REMOTE_USERNAME"] = username
    os.environ["REMOTE_PASSWORD"] = password


def resolve_latest_image_url(
    vrf: str | None,
    username: str,
    password: str,
) -> str:
    """Resolve `latest` using VyOS' configured system update-check URL."""
    if not LATEST_IMAGE_URL.is_file():
        raise DispatchError(
            f"VyOS latest-image resolver is missing: {LATEST_IMAGE_URL}"
        )

    configure_remote_credentials(username, password)

    command = [str(LATEST_IMAGE_URL)]
    if vrf is not None:
        command = ["ip", "vrf", "exec", vrf, *command]

    result = subprocess.run(
        command,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=os.environ.copy(),
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise DispatchError(
            "could not resolve `latest` from system update-check URL"
            + (f": {detail}" if detail else "")
        )

    resolved = result.stdout.strip()
    if not resolved:
        raise DispatchError(
            "VyOS latest-image resolver returned an empty image URL"
        )

    parsed = urlparse(resolved)
    if parsed.scheme.lower() not in SUPPORTED_REMOTE_SCHEMES:
        raise DispatchError(
            f"VyOS latest-image resolver returned unsupported URL: {resolved}"
        )

    return resolved


def download_remote_bundle(
    remote_path: str,
    vrf: str | None,
    username: str,
    password: str,
) -> Path:
    configure_remote_credentials(username, password)

    local_path = Path.home() / f".vyos-rpi-ab-{uuid4()}.tar.zst"
    try:
        print(f"Downloading Raspberry Pi A/B bundle: {remote_path}")
        if vrf is None:
            download(
                str(local_path),
                remote_path,
                progressbar=True,
                check_space=True,
                raise_error=True,
            )
        else:
            if not SIMPLE_DOWNLOAD.is_file():
                raise DispatchError(
                    f"VyOS VRF download helper is missing: {SIMPLE_DOWNLOAD}"
                )
            result = subprocess.run(
                [
                    "ip",
                    "vrf",
                    "exec",
                    vrf,
                    str(SIMPLE_DOWNLOAD),
                    "--local-file",
                    str(local_path),
                    "--remote-path",
                    remote_path,
                ],
                check=False,
                env=os.environ.copy(),
            )
            if result.returncode != 0:
                raise DispatchError(
                    f"VRF download failed with exit code {result.returncode}"
                )

        if not local_path.is_file() or local_path.stat().st_size == 0:
            raise DispatchError("download completed without a usable bundle file")

        print(
            f"Downloaded bundle : {local_path} "
            f"({local_path.stat().st_size} bytes)"
        )
        return local_path
    except Exception:
        try:
            local_path.unlink()
        except FileNotFoundError:
            pass
        raise


def read_ab_manifest(path: Path) -> dict[str, object] | None:
    result = run(
        "tar",
        "--zstd",
        "-xOf",
        str(path),
        "manifest.json",
        check=False,
    )
    if result.returncode != 0:
        return None

    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def validate_ab_bundle(path: Path) -> None:
    manifest = read_ab_manifest(path)
    if manifest is None:
        raise DispatchError(
            f"{path} does not contain a readable Raspberry Pi A/B manifest.json"
        )

    if manifest.get("format") != "vyos-rpi-ab-update":
        raise DispatchError(
            f"{path} is not a VyOS Raspberry Pi A/B update bundle "
            f"(format={manifest.get('format')!r})"
        )
    if manifest.get("platform") != "raspberry-pi":
        raise DispatchError(
            f"{path} has unsupported A/B platform "
            f"{manifest.get('platform')!r}"
        )


def ask_yes_no(prompt: str, *, default: bool = True) -> bool:
    suffix_default = "y" if default else "n"
    while True:
        answer = input(prompt).strip().lower()
        if not answer:
            return default
        if answer in {"y", "yes"}:
            return True
        if answer in {"n", "no"}:
            return False
        print(f"Please answer y or n (default {suffix_default}).")


def request_tryboot_reboot(*, no_prompt: bool) -> int:
    # Never reboot implicitly for non-interactive callers.  Interactive VyOS
    # users get a simple final question while the Pi-specific tryboot detail
    # stays behind the normal `add system image` command.
    if no_prompt:
        print("Update installed. Reboot was not requested in --no-prompt mode.")
        print("To test the new slot later, run: sudo reboot '0 tryboot'")
        return 0

    print()
    print("The new image is installed in the inactive A/B slot.")
    print("It will be booted once in test mode and validated automatically.")
    print("If validation succeeds, the new slot is committed and the system performs")
    print("one final normal reboot automatically. If validation fails or the test boot")
    print("hangs, the previous working slot is restored automatically.")
    try:
        reboot_now = ask_yes_no(DISPATCHER_REBOOT_PROMPT, default=True)
    except KeyboardInterrupt:
        print("\nReboot cancelled; the update remains installed in the inactive slot.")
        print("To test the new slot later, run: sudo reboot '0 tryboot'")
        return 0
    if not reboot_now:
        print("Reboot deferred. To test the new slot later, run: sudo reboot '0 tryboot'")
        return 0

    print("Rebooting into the new image for automatic A/B validation...")
    print("This session will disconnect. The test boot will report PASS/FAIL on the")
    print("system console, and the next normal login will show the final update result.")
    try:
        os.sync()
    except OSError:
        pass
    result = subprocess.run(["/sbin/reboot", "0 tryboot"], check=False)
    if result.returncode != 0:
        raise DispatchError(
            f"update installed, but tryboot reboot failed with exit code {result.returncode}; "
            "run sudo reboot '0 tryboot' manually"
        )
    return 0


def run_ab_installer(
    local_path: Path,
    *,
    source: str,
    no_prompt: bool,
) -> int:
    if not AB_INSTALLER.is_file():
        raise DispatchError(f"Raspberry Pi A/B installer is missing: {AB_INSTALLER}")

    command = [
        sys.executable,
        str(AB_INSTALLER),
        "--install",
    ]

    # Upstream image_installer.py copies configuration and SSH host keys in
    # --no-prompt mode. Preserve that semantic for the A/B path.
    if no_prompt:
        command += ["--yes-config", "--yes-ssh-keys"]

    command.append(str(local_path))

    print("VyOS Raspberry Pi A/B image dispatcher")
    print(f"Source          : {source}")
    print(f"Detected bundle : {local_path}")
    print("Backend         : native Raspberry Pi A/B installer")
    print()

    result = subprocess.run(command, check=False)
    return result.returncode


def exec_original() -> None:
    if not ORIGINAL_INSTALLER.is_file():
        raise DispatchError(f"original VyOS image installer is missing: {ORIGINAL_INSTALLER}")
    os.execv(
        sys.executable,
        [sys.executable, str(ORIGINAL_INSTALLER), *sys.argv[1:]],
    )


def parse_dispatch_args() -> tuple[argparse.Namespace, list[str]]:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--action")
    parser.add_argument("--image-path")
    parser.add_argument("--vrf")
    parser.add_argument("--username", default="")
    parser.add_argument("--password", default="")
    parser.add_argument("--no-prompt", action="store_true")
    parser.add_argument("--force", action="store_true")
    return parser.parse_known_args()


def main() -> int:
    args, unknown = parse_dispatch_args()

    # Only intercept the op-mode `add` action. Malformed invocations retain
    # upstream VyOS behavior.
    if args.action != "add" or not args.image_path:
        exec_original()

    # Never change standard VyOS behavior outside our exact Raspberry Pi A/B
    # layout.
    if not is_raspberry_pi_ab_system():
        exec_original()

    image_path = args.image_path
    source_description = image_path

    # Reuse the native VyOS "latest" resolver. If it points at our .tar.zst,
    # continue through the A/B backend; if it points at a normal ISO, hand the
    # original `latest` invocation back to upstream image_installer.py.
    if image_path == "latest":
        resolved = resolve_latest_image_url(
            args.vrf,
            args.username,
            args.password,
        )
        if not is_remote_ab_candidate(resolved):
            exec_original()
        image_path = resolved
        source_description = f"latest -> {resolved}"

    parsed = urlparse(image_path)
    remote_candidate = is_remote_ab_candidate(image_path)
    local_candidate = (
        not parsed.scheme
        and image_path.lower().endswith(".tar.zst")
    )

    # Non-A/B-looking paths retain upstream VyOS behavior, including normal
    # local/remote ISO images.
    if not remote_candidate and not local_candidate:
        exec_original()

    if unknown:
        raise DispatchError(
            "unsupported arguments for Raspberry Pi A/B update path: "
            + " ".join(unknown)
        )
    if args.force:
        raise DispatchError(
            "--force is not supported for Raspberry Pi A/B update bundles"
        )

    downloaded_path: Path | None = None
    if remote_candidate:
        try:
            downloaded_path = download_remote_bundle(
                image_path,
                args.vrf,
                args.username,
                args.password,
            )
            validate_ab_bundle(downloaded_path)
            install_rc = run_ab_installer(
                downloaded_path,
                source=source_description,
                no_prompt=args.no_prompt,
            )
        except DispatchError:
            raise
        except Exception as exc:
            raise DispatchError(
                f"could not download/install Raspberry Pi A/B bundle: {exc}"
            ) from exc
        finally:
            if downloaded_path is not None:
                try:
                    downloaded_path.unlink()
                    print(f"Removed download  : {downloaded_path}")
                except FileNotFoundError:
                    pass

        if install_rc != 0:
            return install_rc
        return request_tryboot_reboot(no_prompt=args.no_prompt)

    local_path = Path(image_path).expanduser()
    if not local_path.is_file():
        raise DispatchError(
            f"Raspberry Pi A/B update bundle not found: {local_path}"
        )

    validate_ab_bundle(local_path)
    install_rc = run_ab_installer(
        local_path,
        source=source_description,
        no_prompt=args.no_prompt,
    )
    if install_rc != 0:
        return install_rc
    return request_tryboot_reboot(no_prompt=args.no_prompt)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nUpdate cancelled by user.", file=sys.stderr)
        raise SystemExit(130)
    except DispatchError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
