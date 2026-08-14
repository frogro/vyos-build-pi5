#!/usr/bin/env python3
"""
VyOS Raspberry Pi A/B update bundle validator and inactive-slot installer.

v0.7 supports two explicit modes:

  --dry-run   Validate the bundle and print the exact A/B update plan.
  --install   Erase and rewrite ONLY the inactive A/B slot, preserving its
              filesystem UUIDs. The currently running/default slot and the
              VYOS_AB control partition are never modified.

After a successful --install, the new slot is left as the existing one-shot
tryboot target. The image dispatcher offers an interactive reboot after a successful install.
That reboot uses Raspberry Pi tryboot internally; the new slot must pass the
separate healthcheck before it is committed as the new default. If it hangs
before commit, the hardware watchdog/tryboot design
allows the old default slot to return.

v0.7 installs the automatic tryboot watchdog guard and the `add system image`
dispatcher from the bundle runtime payload. The installer itself accepts local
bundles only; the dispatcher handles HTTP(S) and `latest` downloads before
calling it. Publisher signatures are not yet implemented.

For safety, an update may be written only from a normal/default boot. After a
successful one-shot tryboot is health-checked and committed, perform one normal
reboot before installing another update so the previous slot remains a known
rollback target until the new default has also completed a normal boot.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import subprocess
import sys
import tempfile
from typing import Iterator

INSTALLER_VERSION = "0.7"
DEFAULT_UPDATE_CHECK_URL = "https://raw.githubusercontent.com/frogro/vyos-build-pi5/rolling/version.json"

CONTROL_LABEL = "VYOS_AB"
BOOT_LABELS = {"A": "VYOS_BOOT_A", "B": "VYOS_BOOT_B"}
ROOT_LABELS = {"A": "VYOS_ROOT_A", "B": "VYOS_ROOT_B"}
BOOT_PARTITIONS = {"A": 2, "B": 3}
ROOT_PARTITIONS = {"A": 5, "B": 6}
DT_BASE = Path("/proc/device-tree/chosen/bootloader")

EXPECTED_BUNDLE_MEMBERS = (
    "manifest.json",
    "SHA256SUMS",
    "payload/rootfs.tar.gz",
    "payload/boot.tar",
    "payload/ab-runtime.tar",
)

EXPECTED_LAYOUT = {
    "control_label": CONTROL_LABEL,
    "boot_labels": BOOT_LABELS,
    "root_labels": ROOT_LABELS,
    "boot_partitions": BOOT_PARTITIONS,
    "root_partitions": ROOT_PARTITIONS,
}

REQUIRED_BRCM43455 = (
    "/usr/lib/firmware/brcm/brcmfmac43455-sdio.bin",
    "/usr/lib/firmware/brcm/brcmfmac43455-sdio.clm_blob",
    "/usr/lib/firmware/brcm/brcmfmac43455-sdio.txt",
    "/usr/lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi,4-model-b.bin",
    "/usr/lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi,4-model-b.clm_blob",
    "/usr/lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi,4-model-b.txt",
    "/usr/lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi,5-model-b.bin",
    "/usr/lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi,5-model-b.clm_blob",
    "/usr/lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi,5-model-b.txt",
)

MSG_INPUT_CONFIG_FOUND = (
    "An active configuration was found. Would you like to copy it to the new image?"
)
MSG_INPUT_SSH_KEYS = "Would you like to copy SSH host keys?"
MSG_ERR_UNSAVED_COMMITS = (
    "There are unsaved changes to the configuration. Either save or revert before upgrade."
)


class ABError(RuntimeError):
    pass


def run(
    *args: str,
    check: bool = True,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        args,
        check=False,
        text=True,
        input=input_text,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode != 0:
        command = " ".join(args)
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise ABError(f"command failed: {command}: {detail}")
    return result


def require_command(name: str) -> None:
    result = run("sh", "-c", f"command -v {name}", check=False)
    if result.returncode != 0:
        raise ABError(f"required command is missing: {name}")


def ask_yes_no(message: str, default: bool = True) -> bool:
    suffix = " [Y/n] " if default else " [y/N] "
    while True:
        try:
            answer = input(message + suffix).strip().lower()
        except EOFError as exc:
            raise ABError("interactive input ended unexpectedly") from exc
        if not answer:
            return default
        if answer in ("y", "yes"):
            return True
        if answer in ("n", "no"):
            return False
        print("Please answer yes or no.")


def findmnt_source(target: str) -> str | None:
    result = run("findmnt", "-rn", "-o", "SOURCE", "--target", target, check=False)
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value or None


def normalize_source(source: str | None) -> str | None:
    if not source:
        return None
    return source.split("[", 1)[0]


def device_for_label(label: str) -> str:
    result = run("blkid", "-L", label, check=False)
    device = result.stdout.strip()
    if result.returncode != 0 or not device:
        raise ABError(f"filesystem label {label!r} was not found")
    return os.path.realpath(device)


def blkid_value(device: str, field: str) -> str | None:
    result = run("blkid", "-s", field, "-o", "value", device, check=False)
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value or None


def device_label(device: str) -> str | None:
    return blkid_value(device, "LABEL")


def device_type(device: str) -> str | None:
    return blkid_value(device, "TYPE")


def device_partuuid(device: str) -> str:
    value = blkid_value(device, "PARTUUID")
    if not value:
        raise ABError(f"cannot determine PARTUUID for {device}")
    return value


def device_uuid(device: str) -> str:
    value = blkid_value(device, "UUID")
    if not value:
        raise ABError(f"cannot determine UUID for {device}")
    return value


def lsblk_scalar(device: str, field: str) -> str:
    result = run("lsblk", "-dn", "-o", field, device, check=False)
    value = result.stdout.strip()
    if result.returncode != 0 or not value:
        raise ABError(f"cannot determine lsblk {field} for {device}")
    return value


def device_partn(device: str) -> int:
    # PARTN is not exposed reliably by lsblk on all util-linux builds.
    # Linux sysfs provides the kernel partition number directly and is the
    # authoritative source for block partitions such as mmcblk0p5/p6.
    name = os.path.basename(os.path.realpath(device))
    path = Path("/sys/class/block") / name / "partition"
    try:
        value = path.read_text(encoding="ascii").strip()
    except OSError as exc:
        raise ABError(f"cannot determine partition number for {device} from {path}: {exc}") from exc
    try:
        return int(value, 10)
    except ValueError as exc:
        raise ABError(f"invalid partition number for {device}: {value!r}") from exc


def device_parent(device: str) -> str:
    # Resolve the sysfs class symlink.  For a partition the immediate parent
    # directory is the containing whole-disk block device (e.g. mmcblk0).
    name = os.path.basename(os.path.realpath(device))
    path = Path("/sys/class/block") / name
    try:
        resolved = path.resolve(strict=True)
    except OSError as exc:
        raise ABError(f"cannot resolve sysfs block device for {device}: {exc}") from exc

    partition_file = resolved / "partition"
    if not partition_file.exists():
        raise ABError(f"{device} is not a partition")

    parent_name = resolved.parent.name
    parent_device = Path("/dev") / parent_name
    if not parent_device.exists():
        raise ABError(f"cannot determine parent disk for {device}: {parent_device} does not exist")
    return os.path.realpath(parent_device)


def read_dt_u32(name: str) -> int:
    path = DT_BASE / name
    try:
        data = path.read_bytes()
    except FileNotFoundError as exc:
        raise ABError(f"missing Raspberry Pi bootloader device-tree property: {path}") from exc
    if len(data) < 4:
        raise ABError(f"{path} is shorter than one 32-bit cell")
    return int.from_bytes(data[:4], byteorder="big", signed=False)


def parse_autoboot_text(text: str) -> tuple[str, str]:
    try:
        encoded = text.encode("ascii")
    except UnicodeEncodeError as exc:
        raise ABError("autoboot.txt is not ASCII") from exc
    if len(encoded) >= 512:
        raise ABError("autoboot.txt must be smaller than 512 bytes")

    section: str | None = None
    tryboot_ab = False
    default_partition: int | None = None
    tryboot_partition: int | None = None

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip().lower()
            continue
        if "=" not in line:
            continue
        key, value = (part.strip() for part in line.split("=", 1))
        if section == "all" and key == "tryboot_a_b":
            tryboot_ab = value == "1"
        elif key == "boot_partition":
            try:
                number = int(value, 10)
            except ValueError as exc:
                raise ABError(f"invalid boot_partition value {value!r}") from exc
            if section == "all":
                default_partition = number
            elif section == "tryboot":
                tryboot_partition = number

    if not tryboot_ab:
        raise ABError("autoboot.txt does not contain tryboot_a_b=1")

    slot_by_boot = {2: "A", 3: "B"}
    default_slot = slot_by_boot.get(default_partition)
    tryboot_slot = slot_by_boot.get(tryboot_partition)

    if not default_slot or not tryboot_slot or default_slot == tryboot_slot:
        raise ABError("autoboot.txt must map default/tryboot to different boot partitions 2 and 3")

    return default_slot, tryboot_slot


@contextlib.contextmanager
def mounted_readonly(device: str, tag: str, fstype: str | None = None) -> Iterator[Path]:
    existing = run("findmnt", "-rn", "-S", device, "-o", "TARGET", check=False)
    if existing.returncode == 0 and existing.stdout.strip():
        yield Path(existing.stdout.splitlines()[0].strip())
        return

    with tempfile.TemporaryDirectory(prefix=f"vyos-pi-ab-{tag}-", dir="/run") as temp_dir:
        mountpoint = Path(temp_dir)
        options = "ro,noload" if fstype == "ext4" else "ro"
        run("mount", "-o", options, device, str(mountpoint))
        try:
            yield mountpoint
        finally:
            run("umount", str(mountpoint), check=False)


@contextlib.contextmanager
def mounted_writable(device: str, tag: str) -> Iterator[Path]:
    ensure_target_inactive(device)
    with tempfile.TemporaryDirectory(prefix=f"vyos-pi-ab-{tag}-", dir="/run") as temp_dir:
        mountpoint = Path(temp_dir)
        run("mount", device, str(mountpoint))
        try:
            yield mountpoint
        finally:
            run("sync", check=False)
            result = run("umount", str(mountpoint), check=False)
            if result.returncode != 0:
                print(
                    f"WARNING: failed to unmount {mountpoint}: "
                    f"{result.stderr.strip() or result.stdout.strip()}",
                    file=sys.stderr,
                )


def read_control_state() -> tuple[str, str]:
    device = device_for_label(CONTROL_LABEL)
    with mounted_readonly(device, "control", "vfat") as root:
        path = root / "autoboot.txt"
        try:
            text = path.read_text(encoding="ascii")
        except OSError as exc:
            raise ABError(f"cannot read {path}: {exc}") from exc
    return parse_autoboot_text(text)


def detect_runtime() -> tuple[str, str, str, int, int]:
    root_source = normalize_source(findmnt_source("/"))
    boot_source = normalize_source(findmnt_source("/boot/firmware"))
    config_source = normalize_source(findmnt_source("/config"))

    if not root_source or not boot_source or not config_source:
        raise ABError("cannot determine /, /config and /boot/firmware source devices")

    root_source = os.path.realpath(root_source)
    boot_source = os.path.realpath(boot_source)
    config_source = os.path.realpath(config_source)

    root_label = device_label(root_source)
    boot_label = device_label(boot_source)

    root_slot = next((s for s, label in ROOT_LABELS.items() if label == root_label), None)
    boot_slot = next((s for s, label in BOOT_LABELS.items() if label == boot_label), None)

    if not root_slot:
        raise ABError(f"running root {root_source} has unexpected label {root_label!r}")
    if not boot_slot:
        raise ABError(f"running boot {boot_source} has unexpected label {boot_label!r}")
    if root_slot != boot_slot:
        raise ABError(f"runtime root is slot {root_slot}, but boot is slot {boot_slot}")
    if config_source != root_source:
        raise ABError(f"/config comes from {config_source}, but / comes from {root_source}")

    if device_partn(root_source) != ROOT_PARTITIONS[root_slot]:
        raise ABError(
            f"running root {root_source} has wrong partition number; "
            f"slot {root_slot} requires p{ROOT_PARTITIONS[root_slot]}"
        )
    if device_partn(boot_source) != BOOT_PARTITIONS[root_slot]:
        raise ABError(
            f"running boot {boot_source} has wrong partition number; "
            f"slot {root_slot} requires p{BOOT_PARTITIONS[root_slot]}"
        )
    if device_parent(root_source) != device_parent(boot_source):
        raise ABError("running root and boot partitions are on different disks")

    dt_partition = read_dt_u32("partition")
    dt_tryboot = read_dt_u32("tryboot")

    if dt_partition != BOOT_PARTITIONS[root_slot]:
        raise ABError(
            f"device-tree partition={dt_partition}, runtime slot {root_slot} "
            f"requires partition={BOOT_PARTITIONS[root_slot]}"
        )
    if dt_tryboot not in (0, 1):
        raise ABError(f"unexpected device-tree tryboot value {dt_tryboot}")

    return root_slot, root_source, boot_source, dt_partition, dt_tryboot


def read_version_from_root(root: Path) -> str:
    version_json = root / "usr/share/vyos/version.json"
    try:
        data = json.loads(version_json.read_text(encoding="utf-8"))
        value = str(data.get("version", "")).strip()
        if value:
            return value
    except (OSError, json.JSONDecodeError):
        pass

    for rel in ("opt/vyatta/etc/version", "etc/version"):
        path = root / rel
        try:
            text = path.read_text(encoding="utf-8", errors="replace").strip()
        except OSError:
            continue
        if text.lower().startswith("version:"):
            return text.split(":", 1)[1].strip()
        if text:
            return text.splitlines()[0].strip()
    return "unknown"


def current_version_data() -> dict[str, object]:
    path = Path("/usr/share/vyos/version.json")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ABError(f"cannot read current VyOS version data from {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ABError("current version.json is not an object")
    return value


def check_unsaved_commits() -> None:
    try:
        from vyos.config_mgmt import unsaved_commits  # type: ignore
    except Exception as exc:
        raise ABError(f"cannot import VyOS configuration state helper: {exc}") from exc

    try:
        dirty = bool(unsaved_commits())
    except Exception as exc:
        raise ABError(
            f"cannot determine whether the VyOS configuration has unsaved changes: {exc}"
        ) from exc

    if dirty:
        raise ABError(MSG_ERR_UNSAVED_COMMITS)


def tar_members(bundle: Path) -> list[str]:
    result = run("tar", "--zstd", "-tf", str(bundle), check=False)
    if result.returncode != 0:
        raise ABError(f"cannot list update bundle: {result.stderr.strip()}")
    return [line.strip().lstrip("./") for line in result.stdout.splitlines() if line.strip()]


def tar_read_text(bundle: Path, member: str) -> str:
    result = run("tar", "--zstd", "-xOf", str(bundle), member, check=False)
    if result.returncode != 0:
        raise ABError(f"cannot read {member} from update bundle: {result.stderr.strip()}")
    return result.stdout


def hash_bundle_member(bundle: Path, member: str) -> tuple[str, int]:
    proc = subprocess.Popen(
        ["tar", "--zstd", "-xOf", str(bundle), member],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert proc.stdout is not None
    h = hashlib.sha256()
    size = 0
    while True:
        chunk = proc.stdout.read(1024 * 1024)
        if not chunk:
            break
        h.update(chunk)
        size += len(chunk)
    stderr = proc.stderr.read().decode("utf-8", errors="replace") if proc.stderr else ""
    rc = proc.wait()
    if rc != 0:
        raise ABError(f"cannot hash {member} from update bundle: {stderr.strip()}")
    return h.hexdigest(), size


def parse_sha256sums(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        parts = line.split(maxsplit=1)
        if len(parts) != 2:
            raise ABError(f"invalid SHA256SUMS line: {raw!r}")
        digest, path = parts
        path = path.lstrip("*")
        if len(digest) != 64 or any(c not in "0123456789abcdefABCDEF" for c in digest):
            raise ABError(f"invalid SHA-256 digest in SHA256SUMS: {digest!r}")
        values[path] = digest.lower()
    return values


def validate_required_layout(manifest: dict[str, object]) -> None:
    layout = manifest.get("required_layout")
    if layout != EXPECTED_LAYOUT:
        raise ABError(
            "manifest required_layout does not exactly match the supported "
            "Raspberry Pi A/B p1/p2/p3/p5/p6 layout"
        )


def validate_bundle(bundle: Path) -> dict[str, object]:
    members = tar_members(bundle)
    if tuple(members) != EXPECTED_BUNDLE_MEMBERS:
        raise ABError(
            "unexpected update bundle layout; expected exactly: "
            + ", ".join(EXPECTED_BUNDLE_MEMBERS)
            + f"; got: {', '.join(members)}"
        )

    manifest_text = tar_read_text(bundle, "manifest.json")
    sums_text = tar_read_text(bundle, "SHA256SUMS")

    try:
        manifest = json.loads(manifest_text)
    except json.JSONDecodeError as exc:
        raise ABError(f"manifest.json is invalid JSON: {exc}") from exc
    if not isinstance(manifest, dict):
        raise ABError("manifest.json is not a JSON object")

    expected = {
        "format": "vyos-rpi-ab-update",
        "format_version": 2,
        "platform": "raspberry-pi",
        "architecture": "arm64",
    }
    for key, value in expected.items():
        if manifest.get(key) != value:
            raise ABError(
                f"manifest {key!r} is {manifest.get(key)!r}, expected {value!r}"
            )

    validate_required_layout(manifest)

    version = str(manifest.get("version", "")).strip()
    flavor = str(manifest.get("flavor", "")).strip()
    kernel_version = str(manifest.get("kernel_version", "")).strip()
    if not version:
        raise ABError("manifest has no version")
    if not flavor:
        raise ABError("manifest has no flavor")
    if not kernel_version:
        raise ABError("manifest has no kernel_version")

    payload = manifest.get("payload")
    if not isinstance(payload, dict):
        raise ABError("manifest payload is missing or invalid")

    sums = parse_sha256sums(sums_text)

    manifest_digest = hashlib.sha256(manifest_text.encode("utf-8")).hexdigest()
    if sums.get("manifest.json") != manifest_digest:
        raise ABError("manifest.json SHA-256 does not match SHA256SUMS")

    for key, expected_path, expected_archive in (
        ("rootfs", "payload/rootfs.tar.gz", "tar.gz"),
        ("boot", "payload/boot.tar", "tar"),
        ("runtime", "payload/ab-runtime.tar", "tar"),
    ):
        item = payload.get(key)
        if not isinstance(item, dict):
            raise ABError(f"manifest payload.{key} is missing or invalid")
        if item.get("path") != expected_path:
            raise ABError(
                f"manifest payload.{key}.path is {item.get('path')!r}, expected {expected_path!r}"
            )
        if item.get("archive") != expected_archive:
            raise ABError(
                f"manifest payload.{key}.archive is {item.get('archive')!r}, "
                f"expected {expected_archive!r}"
            )

        expected_sha = str(item.get("sha256", "")).lower()
        expected_size = item.get("size")
        if len(expected_sha) != 64:
            raise ABError(f"manifest payload.{key}.sha256 is invalid")
        if not isinstance(expected_size, int) or expected_size <= 0:
            raise ABError(f"manifest payload.{key}.size is invalid")

        print(f"Verifying {expected_path} SHA256...", flush=True)
        actual_sha, actual_size = hash_bundle_member(bundle, expected_path)

        if actual_sha != expected_sha:
            raise ABError(
                f"{expected_path} SHA-256 mismatch: manifest={expected_sha}, actual={actual_sha}"
            )
        if sums.get(expected_path) != actual_sha:
            raise ABError(f"{expected_path} SHA-256 does not match SHA256SUMS")
        if actual_size != expected_size:
            raise ABError(
                f"{expected_path} size mismatch: manifest={expected_size}, actual={actual_size}"
            )

    return manifest


def device_size_bytes(device: str) -> int:
    result = run("lsblk", "-b", "-dn", "-o", "SIZE", device, check=False)
    raw = result.stdout.strip()
    if result.returncode != 0 or not raw.isdigit():
        raise ABError(f"cannot determine size of {device}")
    return int(raw)


def ensure_target_inactive(device: str) -> None:
    result = run("findmnt", "-rn", "-S", device, "-o", "TARGET", check=False)
    if result.returncode == 0 and result.stdout.strip():
        raise ABError(
            f"inactive target device {device} is unexpectedly mounted at "
            f"{result.stdout.strip()}"
        )


def validate_target_layout(
    target_slot: str,
    running_root: str,
    running_boot: str,
) -> dict[str, object]:
    rootdev = device_for_label(ROOT_LABELS[target_slot])
    bootdev = device_for_label(BOOT_LABELS[target_slot])
    controldev = device_for_label(CONTROL_LABEL)

    if device_type(rootdev) != "ext4":
        raise ABError(f"target root {rootdev} is not ext4")
    if device_type(bootdev) != "vfat":
        raise ABError(f"target boot {bootdev} is not vfat")
    if device_type(controldev) != "vfat":
        raise ABError(f"control partition {controldev} is not vfat")

    if device_partn(rootdev) != ROOT_PARTITIONS[target_slot]:
        raise ABError(
            f"target root {rootdev} is not p{ROOT_PARTITIONS[target_slot]}"
        )
    if device_partn(bootdev) != BOOT_PARTITIONS[target_slot]:
        raise ABError(
            f"target boot {bootdev} is not p{BOOT_PARTITIONS[target_slot]}"
        )
    if device_partn(controldev) != 1:
        raise ABError(f"control partition {controldev} is not p1")

    parent = device_parent(running_root)
    if device_parent(running_boot) != parent:
        raise ABError("running root/boot parent disk mismatch")
    for dev in (rootdev, bootdev, controldev):
        if device_parent(dev) != parent:
            raise ABError(
                f"A/B device {dev} is on {device_parent(dev)}, expected running disk {parent}"
            )

    ensure_target_inactive(rootdev)
    ensure_target_inactive(bootdev)

    with mounted_readonly(rootdev, f"root-{target_slot.lower()}", "ext4") as root:
        old_version = read_version_from_root(root)
        stat = os.statvfs(root)
        total_inodes = stat.f_files

    return {
        "rootdev": rootdev,
        "bootdev": bootdev,
        "controldev": controldev,
        "disk": parent,
        "root_uuid": device_uuid(rootdev),
        "boot_uuid": device_uuid(bootdev),
        "root_partuuid": device_partuuid(rootdev),
        "boot_partuuid": device_partuuid(bootdev),
        "root_size": device_size_bytes(rootdev),
        "boot_size": device_size_bytes(bootdev),
        "root_inodes": int(total_inodes),
        "old_version": old_version,
    }


def validate_capacity(manifest: dict[str, object], target: dict[str, object]) -> None:
    payload = manifest.get("payload")
    if not isinstance(payload, dict):
        raise ABError("manifest payload missing")

    root_payload = payload.get("rootfs")
    boot_payload = payload.get("boot")
    runtime_payload = payload.get("runtime")
    if (
        not isinstance(root_payload, dict)
        or not isinstance(boot_payload, dict)
        or not isinstance(runtime_payload, dict)
    ):
        raise ABError("manifest payload entries missing")

    regular_bytes = root_payload.get("regular_bytes")
    regular_files = root_payload.get("regular_files")
    boot_bytes = boot_payload.get("size")
    runtime_bytes = runtime_payload.get("size")

    if not isinstance(regular_bytes, int) or regular_bytes <= 0:
        raise ABError("manifest rootfs regular_bytes is invalid")
    if not isinstance(regular_files, int) or regular_files <= 0:
        raise ABError("manifest rootfs regular_files is invalid")
    if not isinstance(boot_bytes, int) or boot_bytes <= 0:
        raise ABError("manifest boot size is invalid")
    if not isinstance(runtime_bytes, int) or runtime_bytes <= 0:
        raise ABError("manifest runtime size is invalid")

    root_capacity = int(target["root_size"])
    boot_capacity = int(target["boot_size"])
    inode_capacity = int(target["root_inodes"])

    # Keep deliberate headroom for filesystem metadata, directories, symlinks,
    # logs and post-boot growth.
    if regular_bytes + runtime_bytes > int(root_capacity * 0.85):
        raise ABError(
            f"rootfs+runtime payload bytes "
            f"({format_bytes(regular_bytes + runtime_bytes)}) are too large for target "
            f"({format_bytes(root_capacity)})"
        )
    if regular_files > int(inode_capacity * 0.85):
        raise ABError(
            f"rootfs payload file count ({regular_files}) is too large for target "
            f"inode capacity ({inode_capacity})"
        )
    if boot_bytes > int(boot_capacity * 0.85):
        raise ABError(
            f"boot payload ({format_bytes(boot_bytes)}) is too large for target "
            f"({format_bytes(boot_capacity)})"
        )


def config_stats() -> tuple[bool, int]:
    config = Path("/config/config.boot")
    exists = config.is_file() and config.stat().st_size > 0

    total = 0
    for root, _dirs, files in os.walk("/config", followlinks=False):
        for name in files:
            path = Path(root) / name
            try:
                if path.is_file():
                    total += path.stat().st_size
            except OSError:
                pass
    return exists, total


def ssh_host_key_paths() -> list[Path]:
    return sorted(path for path in Path("/etc/ssh").glob("ssh_host_*") if path.is_file())


def ssh_host_key_stats() -> tuple[int, int]:
    paths = ssh_host_key_paths()
    total = sum(path.stat().st_size for path in paths)
    return len(paths), total


def format_bytes(value: int) -> str:
    units = ("B", "KiB", "MiB", "GiB", "TiB")
    n = float(value)
    for unit in units:
        if n < 1024.0 or unit == units[-1]:
            if unit == "B":
                return f"{int(n)} {unit}"
            return f"{n:.1f} {unit}"
        n /= 1024.0
    return f"{value} B"


def file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def remove_mount_contents(root: Path) -> None:
    run(
        "find",
        str(root),
        "-mindepth",
        "1",
        "-maxdepth",
        "1",
        "-exec",
        "rm",
        "-rf",
        "--",
        "{}",
        "+",
    )


def extract_nested_tar(
    bundle: Path,
    member: str,
    destination: Path,
    *,
    gzip_inner: bool,
    rootfs_metadata: bool,
) -> None:
    outer = subprocess.Popen(
        ["tar", "--zstd", "-xOf", str(bundle), member],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert outer.stdout is not None

    inner_cmd = ["tar"]
    if rootfs_metadata:
        inner_cmd += [
            "--numeric-owner",
            "--acls",
            "--xattrs",
            "--xattrs-include=*",
        ]
    else:
        inner_cmd += [
            "--no-same-owner",
            "--no-same-permissions",
        ]

    inner_cmd += ["-x"]
    if gzip_inner:
        inner_cmd += ["-z"]
    inner_cmd += ["-f", "-", "-C", str(destination)]

    inner = subprocess.Popen(
        inner_cmd,
        stdin=outer.stdout,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    outer.stdout.close()

    inner_stdout, inner_stderr = inner.communicate()
    outer_stderr = (
        outer.stderr.read().decode("utf-8", errors="replace") if outer.stderr else ""
    )
    outer_rc = outer.wait()

    if outer_rc != 0:
        raise ABError(
            f"failed reading {member} from update bundle: {outer_stderr.strip()}"
        )
    if inner.returncode != 0:
        detail = inner_stderr.decode("utf-8", errors="replace").strip()
        raise ABError(f"failed extracting {member}: {detail or f'exit {inner.returncode}'}")
    if inner_stdout:
        # Extraction should not produce stdout; ignore harmless output but keep
        # the branch explicit for diagnostics during development.
        pass


def patch_cmdline(path: Path, root_partuuid: str) -> None:
    try:
        tokens = (
            path.read_text(encoding="utf-8")
            .replace("\r", " ")
            .replace("\n", " ")
            .split()
        )
    except OSError as exc:
        raise ABError(f"cannot read {path}: {exc}") from exc

    out: list[str] = []
    root_seen = False
    for token in tokens:
        if token.startswith("root="):
            if not root_seen:
                out.append(f"root=PARTUUID={root_partuuid}")
                root_seen = True
            continue
        out.append(token)

    if not root_seen:
        raise ABError(f"no root= token found in {path}")

    for required in ("net.ifnames=0", "modprobe.blacklist=btusb,btmtk"):
        if required not in out:
            out.append(required)

    path.write_text(" ".join(out) + "\n", encoding="utf-8")


def patch_config_txt(path: Path) -> None:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise ABError(f"cannot read {path}: {exc}") from exc

    lines = [line.strip() for line in text.splitlines()]
    if "dtparam=pciex1_gen=3" in lines:
        raise ABError("boot config unexpectedly enables pciex1_gen=3")

    required = ("dtparam=pciex1", "dtoverlay=pcie-32bit-dma-pi5")
    missing = [line for line in required if line not in lines]
    if missing:
        with path.open("a", encoding="utf-8") as handle:
            handle.write("\n[all]\n# Enable Raspberry Pi 5 external PCIe x1\n")
            for line in missing:
                handle.write(line + "\n")


def patch_target_root(root: Path, slot: str, target: dict[str, object]) -> None:
    etc = root / "etc"
    etc.mkdir(parents=True, exist_ok=True)

    fstab = etc / "fstab"
    fstab.write_text(
        f"# VyOS Raspberry Pi A/B slot {slot}\n"
        f"UUID={target['root_uuid']} / ext4 defaults,commit=120,errors=remount-ro 0 1\n"
        f"UUID={target['boot_uuid']} /boot/firmware vfat defaults 0 2\n"
        "tmpfs /tmp tmpfs defaults,nosuid 0 0\n",
        encoding="utf-8",
    )
    os.chmod(fstab, 0o644)

    marker = etc / "vyos-pi-ab-slot"
    marker.write_text(slot + "\n", encoding="ascii")
    os.chmod(marker, 0o644)



def patch_target_add_system_image(root: Path) -> int:
    """Route `add system image` through the Pi A/B dispatcher in this slot.

    We patch only op-mode leaf node.def files that already invoke the upstream
    image_installer.py for `--action add`. All other content/help/completion and
    all upstream installer code remain untouched.
    """
    templates = (
        root
        / "opt/vyatta/share/vyatta-op/templates/add/system/image"
    )
    if not templates.is_dir():
        raise ABError(
            f"target root has no add/system/image op-mode templates: {templates}"
        )

    old = "${vyos_op_scripts_dir}/image_installer.py --action add"
    new = "${vyos_op_scripts_dir}/vyos_pi_image_dispatch.py --action add"

    replacements = 0
    for path in sorted(templates.rglob("node.def")):
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            raise ABError(f"cannot read op-mode template {path}: {exc}") from exc

        count = text.count(old)
        if not count:
            continue

        path.write_text(text.replace(old, new), encoding="utf-8")
        replacements += count

    if replacements == 0:
        raise ABError(
            "could not find any `add system image` image_installer.py leaf "
            "commands to patch"
        )

    # A mixed state would make CLI behavior dependent on argument path.
    leftovers: list[str] = []
    for path in sorted(templates.rglob("node.def")):
        text = path.read_text(encoding="utf-8", errors="replace")
        if old in text:
            leftovers.append(str(path.relative_to(root)))

    if leftovers:
        raise ABError(
            "some `add system image` commands still bypass the Pi dispatcher: "
            + ", ".join(leftovers)
        )

    return replacements

def patch_target_boot(boot: Path, target: dict[str, object]) -> None:
    config = boot / "config.txt"
    cmdline = boot / "cmdline.txt"

    for path in (config, cmdline, boot / "vmlinuz", boot / "initrd.img"):
        if not path.is_file():
            raise ABError(f"boot payload is missing required file: {path.name}")

    overlay = boot / "overlays/pcie-32bit-dma-pi5.dtbo"
    if not overlay.is_file():
        raise ABError("boot payload is missing overlays/pcie-32bit-dma-pi5.dtbo")

    patch_cmdline(cmdline, str(target["root_partuuid"]))
    patch_config_txt(config)


def copy_active_config(root: Path) -> None:
    destination = root / "config"
    destination.mkdir(parents=True, exist_ok=True)
    run(
        "rsync",
        "-aHAX",
        "--numeric-ids",
        "--delete",
        "/config/",
        str(destination) + "/",
    )


def _brace_delta(line: str) -> int:
    return line.count("{") - line.count("}")


def _find_config_block(
    lines: list[str],
    start_pattern: re.Pattern[str],
    start: int,
    end: int,
    wanted_depth: int,
) -> tuple[int, int] | None:
    depth = 0
    for index, line in enumerate(lines):
        if index < start:
            depth += _brace_delta(line)
            continue
        if index >= end:
            break
        if depth == wanted_depth and start_pattern.match(line):
            block_depth = depth + _brace_delta(line)
            for close in range(index + 1, end):
                block_depth += _brace_delta(lines[close])
                if block_depth == depth:
                    return index, close
            raise ABError(f"unterminated configuration block: {line.strip()}")
        depth += _brace_delta(line)
    return None


def read_update_check_url(path: Path) -> str | None:
    try:
        lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    except OSError as exc:
        raise ABError(f"cannot read {path}: {exc}") from exc

    system = _find_config_block(
        lines, re.compile(r"^\s*system\s*\{\s*$"), 0, len(lines), 0
    )
    if system is None:
        return None
    system_start, system_end = system
    system_inner_depth = 1 + sum(_brace_delta(line) for line in lines[:system_start])
    update = _find_config_block(
        lines,
        re.compile(r"^\s*update-check\s*\{\s*$"),
        system_start + 1,
        system_end,
        system_inner_depth,
    )
    if update is None:
        return None

    update_start, update_end = update
    url_pattern = re.compile(r'^\s*url\s+(?:"([^"]+)"|(\S+))\s*$')
    for line in lines[update_start + 1 : update_end]:
        match = url_pattern.match(line.rstrip("\n"))
        if match:
            value = match.group(1) or match.group(2)
            if value:
                return value
    return None


def ensure_update_check_url(path: Path) -> str:
    existing = read_update_check_url(path)
    if existing:
        return existing

    try:
        lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    except OSError as exc:
        raise ABError(f"cannot read {path}: {exc}") from exc

    system = _find_config_block(
        lines, re.compile(r"^\s*system\s*\{\s*$"), 0, len(lines), 0
    )
    if system is None:
        raise ABError(f"{path} has no top-level system block")
    system_start, system_end = system
    system_inner_depth = 1 + sum(_brace_delta(line) for line in lines[:system_start])
    update = _find_config_block(
        lines,
        re.compile(r"^\s*update-check\s*\{\s*$"),
        system_start + 1,
        system_end,
        system_inner_depth,
    )

    if update is None:
        system_indent = re.match(r"^(\s*)", lines[system_start]).group(1)
        child_indent = system_indent + "    "
        value_indent = child_indent + "    "
        lines[system_end:system_end] = [
            f"{child_indent}update-check {{\n",
            f'{value_indent}url "{DEFAULT_UPDATE_CHECK_URL}"\n',
            f"{child_indent}}}\n",
        ]
    else:
        update_start, update_end = update
        update_indent = re.match(r"^(\s*)", lines[update_start]).group(1)
        value_indent = update_indent + "    "
        lines[update_end:update_end] = [
            f'{value_indent}url "{DEFAULT_UPDATE_CHECK_URL}"\n'
        ]

    try:
        path.write_text("".join(lines), encoding="utf-8")
    except OSError as exc:
        raise ABError(f"cannot update {path}: {exc}") from exc

    final = read_update_check_url(path)
    if not final:
        raise ABError(f"failed to ensure system update-check URL in {path}")
    return final


def copy_active_ssh_keys(root: Path) -> None:
    keys = ssh_host_key_paths()
    if not keys:
        raise ABError("SSH host key copy was requested, but no ssh_host_* files exist")

    destination = root / "etc/ssh"
    destination.mkdir(parents=True, exist_ok=True)

    for existing in destination.glob("ssh_host_*"):
        if existing.is_file() or existing.is_symlink():
            existing.unlink()

    run("cp", "-a", "--", *(str(path) for path in keys), str(destination) + "/")


def resolve_in_rootfs(root: Path, rel: str, max_hops: int = 40) -> Path:
    cur = PurePosixPath("/" + rel.lstrip("/"))
    seen: set[str] = set()

    for _ in range(max_hops):
        key = str(cur)
        if key in seen:
            raise ABError(f"symlink loop at {cur}")
        seen.add(key)

        host = root / str(cur).lstrip("/")
        if not os.path.lexists(host):
            raise ABError(f"rootfs path is missing: {cur}")
        if not host.is_symlink():
            return host

        target = os.readlink(host)
        if target.startswith("/"):
            cur = PurePosixPath(posixpath.normpath(target))
        else:
            cur = PurePosixPath(posixpath.normpath(str(cur.parent / target)))

    raise ABError(f"too many symlink hops resolving {rel}")


def validate_config_copy(root: Path) -> None:
    result = run(
        "rsync",
        "-aHAXn",
        "--numeric-ids",
        "--delete",
        "--itemize-changes",
        "/config/",
        str(root / "config") + "/",
        check=False,
    )
    if result.returncode != 0:
        raise ABError(f"cannot verify copied /config: {result.stderr.strip()}")
    if result.stdout.strip():
        raise ABError(
            "copied /config differs from the active configuration after rsync"
        )


def validate_ssh_key_copy(root: Path) -> None:
    for source in ssh_host_key_paths():
        destination = root / "etc/ssh" / source.name
        if not destination.is_file():
            raise ABError(f"copied SSH host key is missing: {destination}")
        if file_sha256(source) != file_sha256(destination):
            raise ABError(f"copied SSH host key differs: {source.name}")


def validate_offline_slot(
    slot: str,
    target: dict[str, object],
    manifest: dict[str, object],
    *,
    copied_config: bool,
    copied_ssh: bool,
) -> None:
    rootdev = str(target["rootdev"])
    bootdev = str(target["bootdev"])

    with mounted_readonly(rootdev, f"validate-root-{slot.lower()}", "ext4") as root:
        with mounted_readonly(bootdev, f"validate-boot-{slot.lower()}", "vfat") as boot:
            version = read_version_from_root(root)
            expected_version = str(manifest.get("version", ""))
            if version != expected_version:
                raise ABError(
                    f"ROOT-{slot} version is {version!r}, expected {expected_version!r}"
                )

            marker = root / "etc/vyos-pi-ab-slot"
            if marker.read_text(encoding="ascii").strip() != slot:
                raise ABError(f"ROOT-{slot} slot marker is missing/wrong")

            fstab = (root / "etc/fstab").read_text(encoding="utf-8", errors="replace")
            if f"UUID={target['root_uuid']} / ext4" not in fstab:
                raise ABError(f"ROOT-{slot} fstab does not mount its own root UUID")
            if f"UUID={target['boot_uuid']} /boot/firmware vfat" not in fstab:
                raise ABError(f"ROOT-{slot} fstab does not mount BOOT-{slot}")

            cmdline_tokens = (
                (boot / "cmdline.txt")
                .read_text(encoding="utf-8", errors="replace")
                .replace("\r", " ")
                .replace("\n", " ")
                .split()
            )
            roots = [token for token in cmdline_tokens if token.startswith("root=")]
            expected_root = f"root=PARTUUID={target['root_partuuid']}"
            if roots != [expected_root]:
                raise ABError(
                    f"BOOT-{slot} cmdline root tokens are {roots!r}, expected {[expected_root]!r}"
                )
            for required in ("net.ifnames=0", "modprobe.blacklist=btusb,btmtk"):
                if required not in cmdline_tokens:
                    raise ABError(f"BOOT-{slot} cmdline lost {required}")

            config_lines = [
                line.strip()
                for line in (boot / "config.txt")
                .read_text(encoding="utf-8", errors="replace")
                .splitlines()
            ]
            for required in (
                "kernel=vmlinuz",
                "initramfs initrd.img followkernel",
                "dtparam=pciex1",
                "dtoverlay=pcie-32bit-dma-pi5",
            ):
                if required not in config_lines:
                    raise ABError(f"BOOT-{slot} config.txt lost {required}")
            if "dtparam=pciex1_gen=3" in config_lines:
                raise ABError(f"BOOT-{slot} unexpectedly enables pciex1_gen=3")

            image = root / "boot/Image"
            if not image.is_symlink():
                raise ABError(f"ROOT-{slot} /boot/Image symlink is invalid")
            image_target = os.readlink(image)
            kernel_name = Path(image_target).name
            if not kernel_name.startswith("vmlinuz-"):
                raise ABError(f"ROOT-{slot} /boot/Image target is unexpected: {image_target}")
            kver = kernel_name.removeprefix("vmlinuz-")

            if kver != str(manifest.get("kernel_version", "")):
                raise ABError(
                    f"ROOT-{slot} kernel is {kver}, manifest expects "
                    f"{manifest.get('kernel_version')}"
                )
            if not (root / "usr/lib/modules" / kver).is_dir():
                raise ABError(f"ROOT-{slot} kernel modules missing for {kver}")

            boot_kernel = boot / "vmlinuz"
            root_kernel = root / "boot" / f"vmlinuz-{kver}"
            boot_initrd = boot / "initrd.img"
            root_initrd = root / "boot" / f"initrd.img-{kver}"
            for path in (boot_kernel, root_kernel, boot_initrd, root_initrd):
                if not path.is_file():
                    raise ABError(f"required slot file missing: {path}")

            if file_sha256(boot_kernel) != file_sha256(root_kernel):
                raise ABError(f"slot {slot} FAT/root kernel mismatch")
            if file_sha256(boot_initrd) != file_sha256(root_initrd):
                raise ABError(f"slot {slot} FAT/root initrd mismatch")

            boot_dtb = boot / "bcm2712-rpi-5-b.dtb"
            if boot_dtb.is_file():
                dtb_link = root / "boot/dtb"
                if not dtb_link.is_symlink():
                    raise ABError(f"ROOT-{slot} /boot/dtb symlink is missing")
                dtb_target = os.readlink(dtb_link)
                if dtb_target.startswith("/"):
                    root_dtb = (
                        root
                        / dtb_target.lstrip("/")
                        / "broadcom/bcm2712-rpi-5-b.dtb"
                    )
                else:
                    root_dtb = (
                        root
                        / "boot"
                        / dtb_target
                        / "broadcom/bcm2712-rpi-5-b.dtb"
                    )
                if not root_dtb.is_file():
                    raise ABError(f"ROOT-{slot} Pi 5 DTB is missing")
                if file_sha256(boot_dtb) != file_sha256(root_dtb):
                    raise ABError(f"slot {slot} FAT/root Pi 5 DTB mismatch")

            runtime_helpers = (
                "vyos-pi-ab-status.py",
                "vyos-pi-ab-commit.py",
                "vyos-pi-ab-healthcheck.py",
                "vyos-pi-ab-auto-guard.py",
                "install-vyos-pi-ab-update.py",
            )
            for helper_name in runtime_helpers:
                helper = root / "usr/libexec/vyos" / helper_name
                if not helper.is_file() or not os.access(helper, os.X_OK):
                    raise ABError(
                        f"ROOT-{slot} A/B runtime helper is missing/not executable: "
                        f"{helper_name}"
                    )

            dispatcher = (
                root / "usr/libexec/vyos/op_mode/vyos_pi_image_dispatch.py"
            )
            if not dispatcher.is_file() or not os.access(dispatcher, os.X_OK):
                raise ABError(
                    f"ROOT-{slot} `add system image` Pi dispatcher is "
                    "missing/not executable"
                )

            cli_templates = (
                root
                / "opt/vyatta/share/vyatta-op/templates/add/system/image"
            )
            dispatch_ref = (
                "${vyos_op_scripts_dir}/vyos_pi_image_dispatch.py --action add"
            )
            upstream_ref = (
                "${vyos_op_scripts_dir}/image_installer.py --action add"
            )
            dispatch_count = 0
            bypasses: list[str] = []
            for node_def in sorted(cli_templates.rglob("node.def")):
                node_text = node_def.read_text(
                    encoding="utf-8",
                    errors="replace",
                )
                dispatch_count += node_text.count(dispatch_ref)
                if upstream_ref in node_text:
                    bypasses.append(str(node_def.relative_to(root)))

            if dispatch_count == 0:
                raise ABError(
                    f"ROOT-{slot} has no `add system image` command routed "
                    "through the Pi dispatcher"
                )
            if bypasses:
                raise ABError(
                    f"ROOT-{slot} still has `add system image` commands "
                    "bypassing the Pi dispatcher: "
                    + ", ".join(bypasses)
                )

            guard_unit = (
                root / "etc/systemd/system/vyos-pi-ab-auto-guard.service"
            )
            guard_link = (
                root
                / "etc/systemd/system/multi-user.target.wants/"
                "vyos-pi-ab-auto-guard.service"
            )
            if not guard_unit.is_file():
                raise ABError(f"ROOT-{slot} automatic watchdog guard unit is missing")
            if not guard_link.is_symlink():
                raise ABError(f"ROOT-{slot} automatic watchdog guard is not enabled")
            if os.readlink(guard_link) != "../vyos-pi-ab-auto-guard.service":
                raise ABError(
                    f"ROOT-{slot} automatic watchdog guard enable symlink is unexpected"
                )

            guard_text = guard_unit.read_text(encoding="utf-8", errors="replace")
            expected_exec = (
                "ExecStart=/usr/bin/python3 "
                "/usr/libexec/vyos/vyos-pi-ab-auto-guard.py"
            )
            if expected_exec not in guard_text:
                raise ABError(
                    f"ROOT-{slot} automatic watchdog guard unit has unexpected ExecStart"
                )

            config_boot = root / "config/config.boot"
            if not config_boot.is_file() or config_boot.stat().st_size <= 0:
                raise ABError(f"ROOT-{slot} /config/config.boot is missing/empty")
            update_url = read_update_check_url(config_boot)
            if not update_url:
                raise ABError(f"ROOT-{slot} system update-check URL is missing")

            timer = (
                root
                / "etc/systemd/system/timers.target.wants/pi5-dhcp-wan-firstboot.timer"
            )
            if not timer.is_symlink():
                raise ABError(f"ROOT-{slot} Pi first-boot timer is not enabled")

            helper = root / "home/vyos/ap-dhcp-wan-setup.sh"
            if not helper.is_file() or not os.access(helper, os.X_OK):
                raise ABError(f"ROOT-{slot} AP setup helper is missing/not executable")

            for rel in REQUIRED_BRCM43455:
                resolve_in_rootfs(root, rel)

            if copied_ssh:
                validate_ssh_key_copy(root)

            print(
                f"OK: offline slot {slot} validated "
                f"(version={version}, kernel={kver}, root PARTUUID={target['root_partuuid']})"
            )


def install_inactive_slot(
    bundle: Path,
    slot: str,
    target: dict[str, object],
    manifest: dict[str, object],
    *,
    copy_config: bool,
    copy_ssh: bool,
) -> None:
    rootdev = str(target["rootdev"])
    bootdev = str(target["bootdev"])

    print()
    print(f"==> Writing inactive ROOT-{slot}: {rootdev}")
    with mounted_writable(rootdev, f"install-root-{slot.lower()}") as root:
        remove_mount_contents(root)
        extract_nested_tar(
            bundle,
            "payload/rootfs.tar.gz",
            root,
            gzip_inner=True,
            rootfs_metadata=True,
        )

        print("==> Installing A/B runtime, watchdog guard and image dispatcher")
        extract_nested_tar(
            bundle,
            "payload/ab-runtime.tar",
            root,
            gzip_inner=False,
            rootfs_metadata=True,
        )

        patch_target_root(root, slot, target)
        patched_nodes = patch_target_add_system_image(root)
        print(
            f"==> Routed {patched_nodes} `add system image` op-mode command(s) "
            "through the Pi A/B dispatcher"
        )

        if copy_config:
            print("==> Copying active /config")
            copy_active_config(root)
            validate_config_copy(root)

        target_update_url = ensure_update_check_url(root / "config/config.boot")
        print(f"==> Target system update-check URL: {target_update_url}")

        if copy_ssh:
            print("==> Copying active SSH host keys")
            copy_active_ssh_keys(root)

        run("sync")

    print(f"==> Writing inactive BOOT-{slot}: {bootdev}")
    with mounted_writable(bootdev, f"install-boot-{slot.lower()}") as boot:
        remove_mount_contents(boot)
        extract_nested_tar(
            bundle,
            "payload/boot.tar",
            boot,
            gzip_inner=False,
            rootfs_metadata=False,
        )
        patch_target_boot(boot, target)
        run("sync")

    print("==> Validating written inactive slot read-only")
    validate_offline_slot(
        slot,
        target,
        manifest,
        copied_config=copy_config,
        copied_ssh=copy_ssh,
    )


def print_plan(
    *,
    running_slot: str,
    current: dict[str, object],
    target_slot: str,
    target: dict[str, object],
    manifest: dict[str, object],
    copy_config: bool,
    config_bytes: int,
    copy_ssh: bool,
    ssh_count: int,
    ssh_bytes: int,
) -> None:
    payload = manifest["payload"]
    assert isinstance(payload, dict)
    root_payload = payload["rootfs"]
    boot_payload = payload["boot"]
    runtime_payload = payload["runtime"]
    assert isinstance(root_payload, dict)
    assert isinstance(boot_payload, dict)
    assert isinstance(runtime_payload, dict)

    print()
    print("===== UPDATE PLAN =====")
    print(f"Current slot  : {running_slot}")
    print(f"Current image : {current.get('version', 'unknown')}")
    print(f"Target slot   : {target_slot}")
    print(f"Target old    : {target['old_version']}")
    print(f"New image     : {manifest.get('version')}")
    print(f"Architecture  : {manifest.get('architecture')}")
    print(f"Flavor        : {manifest.get('flavor')}")
    print(f"Kernel        : {manifest.get('kernel_version')}")
    print()
    print(f"Target disk   : {target['disk']}")
    print(f"Target root   : {target['rootdev']} ({ROOT_LABELS[target_slot]})")
    print(f"  UUID        : {target['root_uuid']}")
    print(f"  PARTUUID    : {target['root_partuuid']}")
    print(f"  Capacity    : {format_bytes(int(target['root_size']))}")
    print(f"Target boot   : {target['bootdev']} ({BOOT_LABELS[target_slot]})")
    print(f"  UUID        : {target['boot_uuid']}")
    print(f"  PARTUUID    : {target['boot_partuuid']}")
    print(f"  Capacity    : {format_bytes(int(target['boot_size']))}")
    print()
    print(
        f"Root payload  : {format_bytes(int(root_payload['size']))} compressed; "
        f"{format_bytes(int(root_payload.get('regular_bytes', 0)))} regular-file bytes"
    )
    print(f"Boot payload  : {format_bytes(int(boot_payload['size']))}")
    print(f"A/B runtime   : {format_bytes(int(runtime_payload['size']))}")
    print()
    print(f"Copy /config  : {'yes' if copy_config else 'no'} ({format_bytes(config_bytes)})")
    print(
        f"Copy SSH keys : {'yes' if copy_ssh else 'no'} "
        f"({ssh_count} files, {format_bytes(ssh_bytes)})"
    )
    print()
    print("Write sequence:")
    print(
        f"  1. Clean contents of {ROOT_LABELS[target_slot]} and "
        f"{BOOT_LABELS[target_slot]} (filesystem UUIDs preserved)"
    )
    print("  2. Extract rootfs payload into inactive root slot")
    print("  3. Install A/B runtime + watchdog guard + `add system image` dispatcher")
    print("  4. Extract boot payload into inactive boot slot")
    print(
        f"  5. Patch target /etc/fstab and cmdline.txt for slot {target_slot} "
        f"(root PARTUUID={target['root_partuuid']})"
    )
    print("  6. Copy /config if selected")
    print("  7. Copy SSH host keys if selected")
    print("  8. Validate inactive slot offline, including auto-guard and CLI dispatch")
    print(
        f"  9. Keep {running_slot} as default and {target_slot} as the existing "
        "one-shot tryboot target"
    )
    print(" 10. Test boot: reboot '0 tryboot'")
    print(" 11. Auto-guard arms watchdog, healthchecks, then commits only on success")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate or install a VyOS Raspberry Pi A/B update bundle"
    )
    parser.add_argument("bundle", help="local vyos-*-rpi-arm64-update.tar.zst bundle")

    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument(
        "--dry-run",
        action="store_true",
        help="validate bundle/layout and print plan without modifying any partition",
    )
    mode.add_argument(
        "--install",
        action="store_true",
        help="erase and rewrite ONLY the inactive slot, then validate it offline",
    )

    parser.add_argument(
        "--yes-config",
        action="store_true",
        help="assume yes to copying /config without prompting",
    )
    parser.add_argument(
        "--no-config",
        action="store_true",
        help="assume no to copying /config without prompting",
    )
    parser.add_argument(
        "--yes-ssh-keys",
        action="store_true",
        help="assume yes to copying SSH host keys without prompting",
    )
    parser.add_argument(
        "--no-ssh-keys",
        action="store_true",
        help="assume no to copying SSH host keys without prompting",
    )
    args = parser.parse_args()

    if os.geteuid() != 0:
        raise ABError("this command must be run as root")
    if args.yes_config and args.no_config:
        raise ABError("--yes-config and --no-config are mutually exclusive")
    if args.yes_ssh_keys and args.no_ssh_keys:
        raise ABError("--yes-ssh-keys and --no-ssh-keys are mutually exclusive")

    required = [
        "tar",
        "zstd",
        "blkid",
        "findmnt",
        "mount",
        "umount",
        "lsblk",
    ]
    if args.install:
        required += ["find", "rm", "rsync", "cp", "sync"]
    for command in required:
        require_command(command)

    bundle = Path(args.bundle).expanduser()
    if "://" in args.bundle:
        raise ABError(
            f"installer v{INSTALLER_VERSION} accepts local bundle files only; "
            "use the add system image dispatcher for HTTP(S) or latest updates"
        )
    if not bundle.is_file():
        raise ABError(f"update bundle not found: {bundle}")

    check_unsaved_commits()

    print(f"VyOS Raspberry Pi A/B update installer v{INSTALLER_VERSION}")
    print(f"Mode         : {'INSTALL inactive slot' if args.install else 'DRY RUN (read-only)'}")
    print(f"Bundle       : {bundle}")
    print()

    manifest = validate_bundle(bundle)
    print("OK: bundle layout, manifest and payload SHA-256 checks passed")
    print()

    running_slot, root_source, boot_source, _dt_partition, dt_tryboot = detect_runtime()
    default_slot, configured_tryboot_slot = read_control_state()

    if dt_tryboot != 0:
        raise ABError(
            f"updates may only be installed from a normal/default boot; "
            f"device-tree tryboot={dt_tryboot}. If the test slot was already "
            "committed, reboot normally once and retry"
        )
    if running_slot != default_slot:
        raise ABError(
            f"running slot is {running_slot}, but autoboot.txt default is {default_slot}"
        )

    target_slot = "B" if running_slot == "A" else "A"
    if configured_tryboot_slot != target_slot:
        raise ABError(
            f"inactive target should be slot {target_slot}, but autoboot.txt tryboot slot is "
            f"{configured_tryboot_slot}"
        )

    target = validate_target_layout(target_slot, root_source, boot_source)
    validate_capacity(manifest, target)
    current = current_version_data()

    current_arch = str(current.get("architecture", "")).strip()
    current_flavor = str(current.get("flavor", "")).strip()
    new_arch = str(manifest.get("architecture", "")).strip()
    new_flavor = str(manifest.get("flavor", "")).strip()

    if current_arch != new_arch:
        raise ABError(
            f'architecture mismatch: current="{current_arch}", new="{new_arch}"'
        )
    if current_flavor != new_flavor:
        raise ABError(
            f'flavor mismatch: current="{current_flavor}", new="{new_flavor}"'
        )

    config_found, config_bytes = config_stats()
    ssh_count, ssh_bytes = ssh_host_key_stats()

    if args.yes_config:
        copy_config = True
    elif args.no_config:
        copy_config = False
    elif config_found:
        copy_config = ask_yes_no(MSG_INPUT_CONFIG_FOUND, default=True)
    else:
        copy_config = False

    if args.yes_ssh_keys:
        copy_ssh = True
    elif args.no_ssh_keys:
        copy_ssh = False
    elif ssh_count:
        copy_ssh = ask_yes_no(MSG_INPUT_SSH_KEYS, default=True)
    else:
        copy_ssh = False

    print_plan(
        running_slot=running_slot,
        current=current,
        target_slot=target_slot,
        target=target,
        manifest=manifest,
        copy_config=copy_config,
        config_bytes=config_bytes,
        copy_ssh=copy_ssh,
        ssh_count=ssh_count,
        ssh_bytes=ssh_bytes,
    )

    if args.dry_run:
        print()
        print("DRY RUN OK: no partitions or boot-control files were modified.")
        print(
            f"NOTE: v{INSTALLER_VERSION} verifies SHA-256 integrity but does not yet provide a "
            "cryptographic publisher signature."
        )
        return 0

    print()
    print("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
    print(f"WARNING: this will ERASE ONLY inactive slot {target_slot}:")
    print(f"  {target['rootdev']}  {ROOT_LABELS[target_slot]}")
    print(f"  {target['bootdev']}  {BOOT_LABELS[target_slot]}")
    print(f"Running/default slot {running_slot} will NOT be modified.")
    print(f"{CONTROL_LABEL}/autoboot.txt will NOT be modified.")
    print("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
    print()

    expected_confirmation = f"INSTALL {target_slot}"
    try:
        confirmation = input(
            f"Type {expected_confirmation} to write the inactive slot: "
        ).strip()
    except EOFError as exc:
        raise ABError("interactive input ended before destructive confirmation") from exc

    if confirmation != expected_confirmation:
        print("Installation cancelled; inactive slot was NOT modified.")
        return 0

    # Re-check the safety-critical state immediately before destructive writes.
    running_slot2, root_source2, boot_source2, _dt_partition2, dt_tryboot2 = detect_runtime()
    default_slot2, configured_tryboot_slot2 = read_control_state()

    if (
        running_slot2 != running_slot
        or root_source2 != root_source
        or boot_source2 != boot_source
        or dt_tryboot2 != 0
        or default_slot2 != running_slot
        or configured_tryboot_slot2 != target_slot
    ):
        raise ABError("A/B state changed after planning; refusing destructive write")

    target2 = validate_target_layout(target_slot, root_source2, boot_source2)
    for key in (
        "rootdev",
        "bootdev",
        "root_uuid",
        "boot_uuid",
        "root_partuuid",
        "boot_partuuid",
        "disk",
    ):
        if target2[key] != target[key]:
            raise ABError(f"target identity changed before write ({key})")

    print()
    print(f"==> Installing {manifest.get('version')} into inactive slot {target_slot}")
    install_inactive_slot(
        bundle,
        target_slot,
        target,
        manifest,
        copy_config=copy_config,
        copy_ssh=copy_ssh,
    )

    # Confirm that installation did not touch boot-control semantics.
    default_after, tryboot_after = read_control_state()
    if default_after != running_slot or tryboot_after != target_slot:
        raise ABError(
            "offline slot validated, but boot-control state changed unexpectedly; "
            "do NOT reboot with tryboot until investigated"
        )

    print()
    print("INSTALL OK: inactive slot was written and validated.")
    print(f"Running/default slot : {running_slot}")
    print(f"Installed test slot  : {target_slot}")
    print(f"New image            : {manifest.get('version')}")
    print(f"Default remains      : {default_after}")
    print(f"Tryboot target       : {tryboot_after}")
    print()
    print(
        "The image dispatcher can now reboot into the test slot automatically. "
        "The installed guard will arm the hardware watchdog, run the healthcheck, "
        "commit only if healthy, and then request one final normal reboot."
    )
    print(
        "If the test boot fails or hangs before commit, the previous default slot "
        "remains the rollback target."
    )
    print(
        f"NOTE: v{INSTALLER_VERSION} verifies SHA-256 integrity but does not yet provide a "
        "cryptographic publisher signature."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nInstallation cancelled by user.", file=sys.stderr)
        print(
            "If cancellation happened after destructive confirmation, treat the "
            "inactive slot as untrusted until it is rewritten or validated.",
            file=sys.stderr,
        )
        raise SystemExit(130)
    except ABError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
