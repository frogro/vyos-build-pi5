#!/usr/bin/env python3
"""
Show Raspberry Pi VyOS A/B slot state.

This is an experimental helper for the VyOS Raspberry Pi A/B layout:
  p1  VYOS_AB
  p2  VYOS_BOOT_A
  p3  VYOS_BOOT_B
  p5  VYOS_ROOT_A
  p6  VYOS_ROOT_B

It is intentionally read-only.
"""

from __future__ import annotations

import argparse
import contextlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Iterator


CONTROL_LABEL = "VYOS_AB"
BOOT_LABELS = {"A": "VYOS_BOOT_A", "B": "VYOS_BOOT_B"}
ROOT_LABELS = {"A": "VYOS_ROOT_A", "B": "VYOS_ROOT_B"}
BOOT_PARTITIONS = {"A": 2, "B": 3}
ROOT_PARTITIONS = {"A": 5, "B": 6}

DT_BASE = Path("/proc/device-tree/chosen/bootloader")


class ABError(RuntimeError):
    pass


def run(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def findmnt_source(target: str) -> str | None:
    result = run("findmnt", "-rn", "-o", "SOURCE", "--target", target, check=False)
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value or None


def normalize_source(source: str | None) -> str | None:
    if not source:
        return None
    # findmnt may report a bind source as /dev/mmcblk0p5[/path].
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


def device_partuuid(device: str) -> str | None:
    return blkid_value(device, "PARTUUID")


def read_dt_u32(name: str) -> int | None:
    path = DT_BASE / name
    try:
        data = path.read_bytes()
    except FileNotFoundError:
        return None

    if len(data) < 4:
        raise ABError(f"{path} is shorter than one 32-bit cell")
    return int.from_bytes(data[:4], byteorder="big", signed=False)


def parse_autoboot(path: Path) -> dict[str, int | bool | None]:
    section: str | None = None
    default_partition: int | None = None
    tryboot_partition: int | None = None
    tryboot_ab = False

    try:
        text = path.read_text(encoding="ascii")
    except OSError as exc:
        raise ABError(f"cannot read {path}: {exc}") from exc

    if len(text.encode("ascii")) >= 512:
        raise ABError(f"{path} is {len(text.encode('ascii'))} bytes; must be < 512 bytes")

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
        key = key.lower()
        if section == "all" and key == "tryboot_a_b":
            tryboot_ab = value == "1"
        elif key == "boot_partition":
            try:
                number = int(value, 10)
            except ValueError as exc:
                raise ABError(f"invalid boot_partition value {value!r} in {path}") from exc
            if section == "all":
                default_partition = number
            elif section == "tryboot":
                tryboot_partition = number

    return {
        "tryboot_a_b": tryboot_ab,
        "default_partition": default_partition,
        "tryboot_partition": tryboot_partition,
    }


def slot_for_boot_partition(partition: int | None) -> str | None:
    if partition == BOOT_PARTITIONS["A"]:
        return "A"
    if partition == BOOT_PARTITIONS["B"]:
        return "B"
    return None


def slot_from_runtime(root_source: str | None, boot_source: str | None) -> str | None:
    root_source = normalize_source(root_source)
    boot_source = normalize_source(boot_source)

    root_label = device_label(root_source) if root_source else None
    boot_label = device_label(boot_source) if boot_source else None

    root_slot = next((slot for slot, label in ROOT_LABELS.items() if label == root_label), None)
    boot_slot = next((slot for slot, label in BOOT_LABELS.items() if label == boot_label), None)

    if root_slot and boot_slot and root_slot != boot_slot:
        raise ABError(
            f"runtime slot mismatch: root is slot {root_slot} ({root_source}), "
            f"boot is slot {boot_slot} ({boot_source})"
        )
    return root_slot or boot_slot


@contextlib.contextmanager
def mounted_readonly(device: str, tag: str) -> Iterator[Path]:
    # Reuse an existing mount of the device if there is one.
    result = run("findmnt", "-rn", "-S", device, "-o", "TARGET", check=False)
    if result.returncode == 0 and result.stdout.strip():
        yield Path(result.stdout.splitlines()[0].strip())
        return

    if os.geteuid() != 0:
        raise ABError(f"root privileges are required to inspect inactive slot device {device}")

    with tempfile.TemporaryDirectory(prefix=f"vyos-pi-ab-{tag}-", dir="/run") as temp_dir:
        mountpoint = Path(temp_dir)
        run("mount", "-o", "ro", device, str(mountpoint))
        try:
            yield mountpoint
        finally:
            run("umount", str(mountpoint), check=False)


def read_slot_version(slot: str, running_slot: str | None) -> str:
    device = device_for_label(ROOT_LABELS[slot])

    if slot == running_slot:
        root = Path("/")
        return read_version_from_root(root)

    with mounted_readonly(device, f"root-{slot.lower()}") as root:
        return read_version_from_root(root)


def read_version_from_root(root: Path) -> str:
    candidates = (
        root / "opt/vyatta/etc/version",
        root / "etc/version",
    )
    for path in candidates:
        try:
            text = path.read_text(encoding="utf-8", errors="replace").strip()
        except FileNotFoundError:
            continue
        if text:
            if text.lower().startswith("version:"):
                return text.split(":", 1)[1].strip()
            return text.splitlines()[0].strip()
    return "unknown"


@contextlib.contextmanager
def control_mount_readonly() -> Iterator[Path]:
    device = device_for_label(CONTROL_LABEL)

    result = run("findmnt", "-rn", "-S", device, "-o", "TARGET", check=False)
    if result.returncode == 0 and result.stdout.strip():
        yield Path(result.stdout.splitlines()[0].strip())
        return

    if os.geteuid() != 0:
        raise ABError("root privileges are required to read the unmounted VYOS_AB partition")

    with tempfile.TemporaryDirectory(prefix="vyos-pi-ab-control-", dir="/run") as temp_dir:
        mountpoint = Path(temp_dir)
        run("mount", "-o", "ro", device, str(mountpoint))
        try:
            yield mountpoint
        finally:
            run("umount", str(mountpoint), check=False)


def main() -> int:
    parser = argparse.ArgumentParser(description="Show VyOS Raspberry Pi A/B slot status")
    parser.parse_args()

    root_source = normalize_source(findmnt_source("/"))
    boot_source = normalize_source(findmnt_source("/boot/firmware"))
    running_slot = slot_from_runtime(root_source, boot_source)

    dt_partition = read_dt_u32("partition")
    dt_tryboot = read_dt_u32("tryboot")

    if running_slot:
        expected_partition = BOOT_PARTITIONS[running_slot]
        if dt_partition is not None and dt_partition != expected_partition:
            raise ABError(
                f"device-tree boot partition is {dt_partition}, but runtime mounts indicate "
                f"slot {running_slot} (partition {expected_partition})"
            )

    with control_mount_readonly() as control:
        autoboot_path = control / "autoboot.txt"
        autoboot = parse_autoboot(autoboot_path)

    if not autoboot["tryboot_a_b"]:
        raise ABError("autoboot.txt does not contain tryboot_a_b=1 in [all]")

    default_partition = autoboot["default_partition"]
    tryboot_partition = autoboot["tryboot_partition"]
    default_slot = slot_for_boot_partition(default_partition if isinstance(default_partition, int) else None)
    tryboot_slot = slot_for_boot_partition(tryboot_partition if isinstance(tryboot_partition, int) else None)

    if default_slot is None or tryboot_slot is None or default_slot == tryboot_slot:
        raise ABError(
            "autoboot.txt must map [all] and [tryboot] to different boot partitions 2 and 3"
        )

    slot_versions: dict[str, str] = {}
    for slot in ("A", "B"):
        try:
            slot_versions[slot] = read_slot_version(slot, running_slot)
        except ABError as exc:
            slot_versions[slot] = f"unavailable ({exc})"

    print("Raspberry Pi VyOS A/B status")
    print()
    print(f"Running slot : {running_slot or 'unknown'}")
    print(f"Root         : {root_source or 'unknown'}")
    print(f"Boot         : {boot_source or 'unknown'}")
    print(f"Default slot : {default_slot} (boot p{default_partition})")
    print(f"Tryboot slot : {tryboot_slot} (boot p{tryboot_partition})")
    if dt_tryboot is None:
        print("Tryboot boot : unknown")
    else:
        print(f"Tryboot boot : {'yes' if dt_tryboot else 'no'}")
    print(f"DT partition : {dt_partition if dt_partition is not None else 'unknown'}")
    print()
    for slot in ("A", "B"):
        root_device = device_for_label(ROOT_LABELS[slot])
        boot_device = device_for_label(BOOT_LABELS[slot])
        print(f"Slot {slot}:")
        print(
            f"  boot    : {boot_device} "
            f"(p{BOOT_PARTITIONS[slot]}, PARTUUID={device_partuuid(boot_device) or 'unknown'})"
        )
        print(
            f"  root    : {root_device} "
            f"(p{ROOT_PARTITIONS[slot]}, PARTUUID={device_partuuid(root_device) or 'unknown'})"
        )
        print(f"  version : {slot_versions[slot]}")
        if slot == "A":
            print()

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ABError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
