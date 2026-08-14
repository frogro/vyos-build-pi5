#!/usr/bin/env python3
"""
Commit the currently running Raspberry Pi VyOS tryboot slot.

The command only commits when all of the following agree:
  * runtime root filesystem label
  * runtime /boot/firmware label
  * Raspberry Pi device-tree boot partition
  * device-tree tryboot=1
  * autoboot.txt currently lists the running slot as [tryboot]

The only persistent change is an atomic replacement of VYOS_AB/autoboot.txt.
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
    return source.split("[", 1)[0]


def device_for_label(label: str) -> str:
    result = run("blkid", "-L", label, check=False)
    device = result.stdout.strip()
    if result.returncode != 0 or not device:
        raise ABError(f"filesystem label {label!r} was not found")
    return os.path.realpath(device)


def device_label(device: str) -> str | None:
    result = run("blkid", "-s", "LABEL", "-o", "value", device, check=False)
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value or None


def read_dt_u32(name: str) -> int:
    path = DT_BASE / name
    try:
        data = path.read_bytes()
    except FileNotFoundError as exc:
        raise ABError(f"missing Raspberry Pi bootloader device-tree property: {path}") from exc
    if len(data) < 4:
        raise ABError(f"{path} is shorter than one 32-bit cell")
    return int.from_bytes(data[:4], byteorder="big", signed=False)


def parse_autoboot_text(text: str) -> dict[str, int | bool | None]:
    try:
        encoded = text.encode("ascii")
    except UnicodeEncodeError as exc:
        raise ABError("autoboot.txt is not ASCII") from exc

    if len(encoded) >= 512:
        raise ABError(f"autoboot.txt is {len(encoded)} bytes; must be < 512 bytes")

    section: str | None = None
    default_partition: int | None = None
    tryboot_partition: int | None = None
    tryboot_ab = False

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
                raise ABError(f"invalid boot_partition value {value!r}") from exc

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


def detect_running_slot() -> tuple[str, str, str, int, int]:
    root_source = normalize_source(findmnt_source("/"))
    boot_source = normalize_source(findmnt_source("/boot/firmware"))
    if not root_source or not boot_source:
        raise ABError("cannot determine / and /boot/firmware source devices")

    root_label = device_label(root_source)
    boot_label = device_label(boot_source)

    root_slot = next((slot for slot, label in ROOT_LABELS.items() if label == root_label), None)
    boot_slot = next((slot for slot, label in BOOT_LABELS.items() if label == boot_label), None)

    if root_slot is None:
        raise ABError(f"root filesystem {root_source} has unexpected label {root_label!r}")
    if boot_slot is None:
        raise ABError(f"/boot/firmware {boot_source} has unexpected label {boot_label!r}")
    if root_slot != boot_slot:
        raise ABError(
            f"runtime slot mismatch: root is slot {root_slot}, boot is slot {boot_slot}"
        )

    dt_partition = read_dt_u32("partition")
    dt_tryboot = read_dt_u32("tryboot")
    expected_partition = BOOT_PARTITIONS[root_slot]

    if dt_partition != expected_partition:
        raise ABError(
            f"device-tree partition={dt_partition}, but runtime slot {root_slot} "
            f"requires partition={expected_partition}"
        )

    return root_slot, root_source, boot_source, dt_partition, dt_tryboot


@contextlib.contextmanager
def control_mount_rw() -> Iterator[Path]:
    device = device_for_label(CONTROL_LABEL)

    existing = run("findmnt", "-rn", "-S", device, "-o", "TARGET,OPTIONS", check=False)
    if existing.returncode == 0 and existing.stdout.strip():
        first = existing.stdout.splitlines()[0].strip()
        fields = first.split(None, 1)
        target = fields[0]
        options = fields[1] if len(fields) > 1 else ""
        if "rw" not in options.split(","):
            raise ABError(
                f"{CONTROL_LABEL} is already mounted read-only at {target}; "
                "unmount it before committing"
            )
        yield Path(target)
        return

    with tempfile.TemporaryDirectory(prefix="vyos-pi-ab-control-", dir="/run") as temp_dir:
        mountpoint = Path(temp_dir)
        run("mount", "-o", "rw", device, str(mountpoint))
        try:
            yield mountpoint
        finally:
            run("umount", str(mountpoint), check=False)


def build_autoboot(default_slot: str) -> str:
    if default_slot not in ("A", "B"):
        raise ABError(f"invalid slot {default_slot!r}")
    tryboot_slot = "B" if default_slot == "A" else "A"
    text = (
        "[all]\n"
        "tryboot_a_b=1\n"
        f"boot_partition={BOOT_PARTITIONS[default_slot]}\n"
        "\n"
        "[tryboot]\n"
        f"boot_partition={BOOT_PARTITIONS[tryboot_slot]}\n"
    )
    if len(text.encode("ascii")) >= 512:
        raise ABError("generated autoboot.txt unexpectedly exceeds 511 bytes")
    return text


def atomic_replace_autoboot(path: Path, content: str) -> None:
    temp_path = path.with_name(path.name + ".new")

    try:
        with open(temp_path, "w", encoding="ascii", newline="\n") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())

        # Read back before rename so a short/failed write cannot become active.
        verify = temp_path.read_text(encoding="ascii")
        if verify != content:
            raise ABError("verification of temporary autoboot.txt failed")

        os.replace(temp_path, path)

        # Best effort directory fsync plus full system sync for the FAT control
        # partition. Some filesystems may reject directory fsync.
        try:
            dir_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
        except OSError:
            pass

        os.sync()

        final = path.read_text(encoding="ascii")
        if final != content:
            raise ABError("verification of committed autoboot.txt failed")
    finally:
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Commit the currently running VyOS Raspberry Pi A/B tryboot slot"
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        help="commit without the interactive confirmation prompt",
    )
    args = parser.parse_args()

    if os.geteuid() != 0:
        raise ABError("this command must be run as root")

    running_slot, root_source, boot_source, dt_partition, dt_tryboot = detect_running_slot()

    if dt_tryboot != 1:
        raise ABError(
            f"slot {running_slot} is not a tryboot boot (device-tree tryboot={dt_tryboot}); "
            "refusing to change the default slot"
        )

    with control_mount_rw() as control:
        autoboot_path = control / "autoboot.txt"
        try:
            old_text = autoboot_path.read_text(encoding="ascii")
        except OSError as exc:
            raise ABError(f"cannot read {autoboot_path}: {exc}") from exc

        state = parse_autoboot_text(old_text)

        if not state["tryboot_a_b"]:
            raise ABError("autoboot.txt does not contain tryboot_a_b=1 in [all]")

        default_partition = state["default_partition"]
        tryboot_partition = state["tryboot_partition"]
        default_slot = slot_for_boot_partition(
            default_partition if isinstance(default_partition, int) else None
        )
        configured_tryboot_slot = slot_for_boot_partition(
            tryboot_partition if isinstance(tryboot_partition, int) else None
        )

        if default_slot is None or configured_tryboot_slot is None:
            raise ABError("autoboot.txt must use boot partitions 2 and 3")
        if default_slot == configured_tryboot_slot:
            raise ABError("autoboot.txt default and tryboot slots are identical")
        if configured_tryboot_slot != running_slot:
            raise ABError(
                f"running slot is {running_slot}, but autoboot.txt tryboot slot is "
                f"{configured_tryboot_slot}; refusing to commit"
            )
        if default_slot == running_slot:
            raise ABError(
                f"running slot {running_slot} is already the configured default; "
                "refusing inconsistent tryboot commit"
            )

        new_text = build_autoboot(running_slot)

        print("VyOS Raspberry Pi A/B commit")
        print()
        print(f"Running slot : {running_slot}")
        print(f"Root         : {root_source}")
        print(f"Boot         : {boot_source}")
        print(f"DT partition : {dt_partition}")
        print(f"DT tryboot   : {dt_tryboot}")
        print(f"Old default  : {default_slot}")
        print(f"New default  : {running_slot}")
        print()

        if not args.yes:
            answer = input(f"Commit slot {running_slot} as the new default? [y/N] ").strip().lower()
            if answer not in ("y", "yes"):
                print("No changes made.")
                return 0

        atomic_replace_autoboot(autoboot_path, new_text)

        final_state = parse_autoboot_text(autoboot_path.read_text(encoding="ascii"))
        if final_state["default_partition"] != BOOT_PARTITIONS[running_slot]:
            raise ABError("post-commit validation failed: wrong default partition")

        other_slot = "B" if running_slot == "A" else "A"
        if final_state["tryboot_partition"] != BOOT_PARTITIONS[other_slot]:
            raise ABError("post-commit validation failed: wrong tryboot partition")

        print()
        print(f"OK: slot {running_slot} is now the default boot slot.")
        print(f"    slot {other_slot} remains available as the tryboot/rollback slot.")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ABError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
