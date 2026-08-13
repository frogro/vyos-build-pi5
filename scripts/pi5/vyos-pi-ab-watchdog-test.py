#!/usr/bin/env python3
"""
Controlled hardware-watchdog rollback test for VyOS Raspberry Pi A/B.

SAFETY DESIGN
-------------
This test refuses to arm the watchdog unless all of these are true:
  * the running root and /boot/firmware belong to the same A/B slot
  * the Raspberry Pi device-tree boot partition matches that slot
  * device-tree tryboot == 1
  * autoboot.txt says the running slot is the configured [tryboot] slot
  * the configured default is the opposite slot
  * watchdog0 identifies as the Broadcom BCM2835 watchdog
  * watchdog timeout is exactly 15 seconds
  * nowayout == 0

The watchdog is armed only after --arm plus an explicit confirmation.
After arming, the process deliberately sends NO keepalive.  The expected
result is a hardware reset after about 15 seconds.  Because Raspberry Pi
tryboot is one-shot, the next boot should return to the old default slot.

Ctrl-C/SIGTERM before expiry attempts a Magic Close ('V') to disarm the
watchdog.  SIGHUP is ignored so an SSH disconnect does not accidentally
terminate the process while the test is armed.

This is a hardware test helper, not the production watchdog service.
"""

from __future__ import annotations

import argparse
import contextlib
import errno
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
from typing import Iterator

CONTROL_LABEL = "VYOS_AB"
BOOT_LABELS = {"A": "VYOS_BOOT_A", "B": "VYOS_BOOT_B"}
ROOT_LABELS = {"A": "VYOS_ROOT_A", "B": "VYOS_ROOT_B"}
BOOT_PARTITIONS = {"A": 2, "B": 3}
DT_BASE = Path("/proc/device-tree/chosen/bootloader")

WATCHDOG_DEVICE = Path("/dev/watchdog0")
WATCHDOG_SYSFS = Path("/sys/class/watchdog/watchdog0")
EXPECTED_IDENTITY = "Broadcom BCM2835 Watchdog timer"
EXPECTED_TIMEOUT = 15

_watchdog_fd: int | None = None


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


def blkid_value(device: str, field: str) -> str | None:
    result = run("blkid", "-s", field, "-o", "value", device, check=False)
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value or None


def device_label(device: str) -> str | None:
    return blkid_value(device, "LABEL")


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


@contextlib.contextmanager
def control_mount_readonly() -> Iterator[Path]:
    device = device_for_label(CONTROL_LABEL)

    existing = run("findmnt", "-rn", "-S", device, "-o", "TARGET", check=False)
    if existing.returncode == 0 and existing.stdout.strip():
        yield Path(existing.stdout.splitlines()[0].strip())
        return

    with tempfile.TemporaryDirectory(prefix="vyos-pi-ab-control-", dir="/run") as temp_dir:
        mountpoint = Path(temp_dir)
        run("mount", "-o", "ro", device, str(mountpoint))
        try:
            yield mountpoint
        finally:
            run("umount", str(mountpoint), check=False)


def read_autoboot_slots() -> tuple[str, str]:
    with control_mount_readonly() as control:
        path = control / "autoboot.txt"
        try:
            text = path.read_text(encoding="ascii")
        except OSError as exc:
            raise ABError(f"cannot read {path}: {exc}") from exc

    state = parse_autoboot_text(text)
    if not state["tryboot_a_b"]:
        raise ABError("autoboot.txt does not contain tryboot_a_b=1 in [all]")

    default_partition = state["default_partition"]
    tryboot_partition = state["tryboot_partition"]
    default_slot = slot_for_boot_partition(
        default_partition if isinstance(default_partition, int) else None
    )
    tryboot_slot = slot_for_boot_partition(
        tryboot_partition if isinstance(tryboot_partition, int) else None
    )

    if default_slot is None or tryboot_slot is None:
        raise ABError("autoboot.txt must use boot partitions 2 and 3")
    if default_slot == tryboot_slot:
        raise ABError("autoboot.txt default and tryboot slots are identical")

    return default_slot, tryboot_slot


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
            f"device-tree partition={dt_partition}, but slot {root_slot} "
            f"requires partition={expected_partition}"
        )

    return root_slot, root_source, boot_source, dt_partition, dt_tryboot


def read_sysfs(name: str) -> str:
    path = WATCHDOG_SYSFS / name
    try:
        return path.read_text(encoding="ascii").strip()
    except OSError as exc:
        raise ABError(f"cannot read {path}: {exc}") from exc


def watchdog_preflight() -> tuple[str, int, int]:
    if not WATCHDOG_DEVICE.exists():
        raise ABError(f"{WATCHDOG_DEVICE} does not exist")

    identity = read_sysfs("identity")
    try:
        timeout = int(read_sysfs("timeout"), 10)
        nowayout = int(read_sysfs("nowayout"), 10)
    except ValueError as exc:
        raise ABError("invalid numeric watchdog sysfs value") from exc

    if identity != EXPECTED_IDENTITY:
        raise ABError(
            f"unexpected watchdog identity {identity!r}; expected {EXPECTED_IDENTITY!r}"
        )
    if timeout != EXPECTED_TIMEOUT:
        raise ABError(
            f"watchdog timeout is {timeout}s; this test requires exactly "
            f"{EXPECTED_TIMEOUT}s"
        )
    if nowayout != 0:
        raise ABError(
            "watchdog nowayout is enabled; refusing this test because Ctrl-C "
            "could not safely disarm it"
        )

    return identity, timeout, nowayout


def disarm_watchdog() -> None:
    global _watchdog_fd
    fd = _watchdog_fd
    if fd is None:
        return

    # BCM2835 advertises WDIOF_MAGICCLOSE.  Sending 'V' immediately before
    # close asks the watchdog core to stop a stoppable watchdog.
    try:
        os.write(fd, b"V")
    except OSError:
        pass
    try:
        os.close(fd)
    except OSError:
        pass
    _watchdog_fd = None


def abort_handler(signum: int, _frame: object) -> None:
    name = signal.Signals(signum).name
    print(f"\nABORT: received {name}; attempting Magic Close to disarm watchdog.", flush=True)
    disarm_watchdog()
    raise SystemExit(130)


def arm_and_wait(timeout: int) -> int:
    global _watchdog_fd

    # Set handlers before opening the device.  SIGHUP is ignored so an SSH
    # disconnect cannot terminate the test process after the watchdog is armed.
    signal.signal(signal.SIGINT, abort_handler)
    signal.signal(signal.SIGTERM, abort_handler)
    if hasattr(signal, "SIGHUP"):
        signal.signal(signal.SIGHUP, signal.SIG_IGN)

    try:
        _watchdog_fd = os.open(
            WATCHDOG_DEVICE,
            os.O_WRONLY | getattr(os, "O_CLOEXEC", 0),
        )
    except OSError as exc:
        if exc.errno in (errno.EBUSY, errno.EAGAIN):
            raise ABError(
                f"{WATCHDOG_DEVICE} is busy; another watchdog user may already be active"
            ) from exc
        raise ABError(f"cannot open {WATCHDOG_DEVICE}: {exc}") from exc

    print()
    print(f"ARMED: {WATCHDOG_DEVICE} opened; watchdog timeout is {timeout}s.", flush=True)
    print("NO keepalive will be sent.", flush=True)
    print(
        f"Expected: hardware reset in about {timeout}s, then rollback to the old default slot.",
        flush=True,
    )
    print("Press Ctrl-C before expiry to attempt a safe disarm.", flush=True)

    # Opening /dev/watchdog starts the watchdog.  Keep the descriptor open and
    # deliberately do not write/ping it.  If the platform behaves correctly,
    # execution never reaches the code below.
    time.sleep(timeout + 10)

    print(
        "\nERROR: system did not reset within the expected watchdog window; "
        "attempting to disarm.",
        file=sys.stderr,
        flush=True,
    )
    disarm_watchdog()
    return 2


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Controlled VyOS Raspberry Pi A/B hardware-watchdog rollback test"
    )
    parser.add_argument(
        "--arm",
        action="store_true",
        help="allow the test to arm /dev/watchdog0 after all safety checks pass",
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        help="skip the final interactive ARM confirmation (still requires --arm)",
    )
    args = parser.parse_args()

    if os.geteuid() != 0:
        raise ABError("this command must be run as root")

    running_slot, root_source, boot_source, dt_partition, dt_tryboot = detect_running_slot()
    default_slot, configured_tryboot_slot = read_autoboot_slots()
    identity, timeout, nowayout = watchdog_preflight()

    print("VyOS Raspberry Pi A/B watchdog rollback test")
    print()
    print(f"Running slot : {running_slot}")
    print(f"Root         : {root_source}")
    print(f"Boot         : {boot_source}")
    print(f"DT partition : {dt_partition}")
    print(f"DT tryboot   : {dt_tryboot}")
    print(f"Default slot : {default_slot}")
    print(f"Tryboot slot : {configured_tryboot_slot}")
    print(f"Watchdog     : {identity}")
    print(f"Timeout      : {timeout}s")
    print(f"Nowayout     : {nowayout}")
    print()

    # Hard safety boundary: NEVER arm on a normal/default boot.
    if dt_tryboot != 1:
        raise ABError(
            f"running slot {running_slot} is not a tryboot boot "
            f"(device-tree tryboot={dt_tryboot}); watchdog will NOT be armed"
        )
    if configured_tryboot_slot != running_slot:
        raise ABError(
            f"running slot is {running_slot}, but autoboot.txt tryboot slot is "
            f"{configured_tryboot_slot}; watchdog will NOT be armed"
        )
    if default_slot == running_slot:
        raise ABError(
            f"running slot {running_slot} is also the configured default; "
            "refusing watchdog rollback test"
        )

    print(
        f"SAFETY OK: slot {running_slot} is an uncommitted tryboot; "
        f"rollback target is slot {default_slot}."
    )

    if not args.arm:
        print()
        print("DRY RUN ONLY: watchdog was NOT armed.")
        print("Re-run with --arm when you intentionally want the hardware-reset test.")
        return 0

    if not args.yes:
        print()
        answer = input(
            f"Type ARM to start the {timeout}s watchdog reset test "
            f"(rollback target {default_slot}): "
        ).strip()
        if answer != "ARM":
            print("No changes made; watchdog was NOT armed.")
            return 0

    return arm_and_wait(timeout)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ABError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
