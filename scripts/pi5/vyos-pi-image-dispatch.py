#!/usr/bin/env python3
"""
Dispatch `add system image` on VyOS Raspberry Pi A/B systems.

Local Raspberry Pi A/B update bundles (*.tar.zst) are handed to
install-vyos-pi-ab-update.py. Everything else is exec'd unchanged into the
original VyOS op-mode image_installer.py, preserving normal ISO/URL/latest
behavior.

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

ORIGINAL_INSTALLER = Path("/usr/libexec/vyos/op_mode/image_installer.py")
AB_INSTALLER = Path("/usr/libexec/vyos/install-vyos-pi-ab-update.py")
DT_BASE = Path("/proc/device-tree/chosen/bootloader")

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


def is_remote_or_latest(image_path: str) -> bool:
    if image_path == "latest":
        return True
    parsed = urlparse(image_path)
    return bool(parsed.scheme)


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

    # Only intercept the op-mode `add` action. `install`, malformed invocations,
    # URLs and `latest` retain upstream VyOS behavior.
    if args.action != "add" or not args.image_path:
        exec_original()

    if is_remote_or_latest(args.image_path):
        exec_original()

    local_path = Path(args.image_path).expanduser()
    if not local_path.is_file():
        # Preserve upstream local-path error handling for normal ISO paths.
        exec_original()

    if not is_raspberry_pi_ab_system():
        exec_original()

    # A .tar.zst on an A/B Pi is reserved for our native A/B update format.
    # Do not let an invalid bundle fall through to ISO mounting, which would
    # produce a misleading iso9660 error.
    if not local_path.name.endswith(".tar.zst"):
        exec_original()

    manifest = read_ab_manifest(local_path)
    if manifest is None:
        raise DispatchError(
            f"{local_path} is a .tar.zst file but does not contain a readable "
            "Raspberry Pi A/B manifest.json"
        )

    if manifest.get("format") != "vyos-rpi-ab-update":
        raise DispatchError(
            f"{local_path} is not a VyOS Raspberry Pi A/B update bundle "
            f"(format={manifest.get('format')!r})"
        )
    if manifest.get("platform") != "raspberry-pi":
        raise DispatchError(
            f"{local_path} has unsupported A/B platform "
            f"{manifest.get('platform')!r}"
        )

    if unknown:
        raise DispatchError(
            "unsupported arguments for Raspberry Pi A/B update path: "
            + " ".join(unknown)
        )
    if args.force:
        raise DispatchError(
            "--force is not supported for Raspberry Pi A/B update bundles"
        )
    if not AB_INSTALLER.is_file():
        raise DispatchError(f"Raspberry Pi A/B installer is missing: {AB_INSTALLER}")

    command = [
        sys.executable,
        str(AB_INSTALLER),
        "--install",
    ]

    # Upstream image_installer.py copies configuration and SSH host keys in
    # --no-prompt mode. Preserve that semantic for the A/B path.
    if args.no_prompt:
        command += ["--yes-config", "--yes-ssh-keys"]

    command.append(str(local_path))

    print("VyOS Raspberry Pi A/B image dispatcher")
    print(f"Detected bundle : {local_path}")
    print("Backend         : native Raspberry Pi A/B installer")
    print()

    result = subprocess.run(command, check=False)
    return result.returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except DispatchError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
