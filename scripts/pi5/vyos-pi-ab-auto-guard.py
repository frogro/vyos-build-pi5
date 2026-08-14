#!/usr/bin/env python3
"""
Automatic watchdog guard for VyOS Raspberry Pi A/B tryboot updates.

Normal/default boot:
  * exits without touching /dev/watchdog0

Tryboot:
  * validates that the running slot is exactly the configured tryboot slot
  * arms the BCM2835 hardware watchdog
  * keeps it alive while the read-only A/B healthcheck waits for VyOS startup
  * if healthcheck FAILS: stops pinging and leaves the watchdog open so the Pi
    resets after the watchdog timeout; the old default slot then boots
  * if healthcheck SUCCEEDS: disarms the watchdog first, commits the healthy
    running slot as the new default, then requests one final normal reboot

Disarming BEFORE commit deliberately removes the dangerous window where a
watchdog reset after changing autoboot.txt could reboot into a half-committed
new default.

This service is intended to be installed and enabled inside every update slot.
"""

from __future__ import annotations

import contextlib
import errno
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
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
PING_INTERVAL = 5.0
HEALTHCHECK_TIMEOUT = 90
WATCHDOG_FALLBACK_GRACE = 10

_watchdog_fd: int | None = None
_ping_thread: threading.Thread | None = None
_stop_ping = threading.Event()


class ABError(RuntimeError):
    pass


def log(message: str) -> None:
    print(message, flush=True)


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
        raise ABError(f"command failed: {' '.join(args)}: {detail}")
    return result


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

    slot_by_partition = {2: "A", 3: "B"}
    default_slot = slot_by_partition.get(default_partition)
    tryboot_slot = slot_by_partition.get(tryboot_partition)

    if default_slot is None or tryboot_slot is None or default_slot == tryboot_slot:
        raise ABError(
            "autoboot.txt must map default/tryboot to different boot partitions 2 and 3"
        )

    return default_slot, tryboot_slot


def read_control_state() -> tuple[str, str]:
    with control_mount_readonly() as control:
        path = control / "autoboot.txt"
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

    if root_slot is None:
        raise ABError(f"running root {root_source} has unexpected label {root_label!r}")
    if boot_slot is None:
        raise ABError(f"running boot {boot_source} has unexpected label {boot_label!r}")
    if root_slot != boot_slot:
        raise ABError(f"runtime root is slot {root_slot}, but boot is slot {boot_slot}")
    if config_source != root_source:
        raise ABError(f"/config comes from {config_source}, but / comes from {root_source}")

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


def read_watchdog_sysfs(name: str) -> str:
    path = WATCHDOG_SYSFS / name
    try:
        return path.read_text(encoding="ascii").strip()
    except OSError as exc:
        raise ABError(f"cannot read {path}: {exc}") from exc


def wait_for_watchdog_device(seconds: int = 10) -> None:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if WATCHDOG_DEVICE.exists() and WATCHDOG_SYSFS.exists():
            return
        time.sleep(0.25)
    raise ABError(f"{WATCHDOG_DEVICE} did not appear within {seconds}s")


def watchdog_preflight() -> tuple[str, int, int]:
    wait_for_watchdog_device()

    identity = read_watchdog_sysfs("identity")
    try:
        timeout = int(read_watchdog_sysfs("timeout"), 10)
        nowayout = int(read_watchdog_sysfs("nowayout"), 10)
    except ValueError as exc:
        raise ABError("invalid numeric watchdog sysfs value") from exc

    if identity != EXPECTED_IDENTITY:
        raise ABError(
            f"unexpected watchdog identity {identity!r}; expected {EXPECTED_IDENTITY!r}"
        )
    if timeout != EXPECTED_TIMEOUT:
        raise ABError(
            f"watchdog timeout is {timeout}s; automatic A/B guard requires "
            f"{EXPECTED_TIMEOUT}s"
        )
    if nowayout != 0:
        raise ABError(
            "watchdog nowayout is enabled; automatic A/B guard requires nowayout=0"
        )

    return identity, timeout, nowayout


def find_helper(name: str) -> Path:
    candidates = (
        Path(__file__).resolve().with_name(name),
        Path("/usr/libexec/vyos") / name,
        Path("/usr/local/libexec/vyos") / name,
    )
    for path in candidates:
        if path.is_file():
            return path
    raise ABError(f"cannot find required A/B helper {name}")


def keepalive_loop(fd: int) -> None:
    # Opening /dev/watchdog0 arms the hardware timer. Send one keepalive
    # immediately, then refresh it every five seconds while healthcheck runs.
    while not _stop_ping.is_set():
        try:
            os.write(fd, b"\0")
        except OSError as exc:
            log(f"ERROR: watchdog keepalive failed: {exc}")
            return
        if _stop_ping.wait(PING_INTERVAL):
            return


def open_watchdog() -> int:
    try:
        return os.open(
            WATCHDOG_DEVICE,
            os.O_WRONLY | getattr(os, "O_CLOEXEC", 0),
        )
    except OSError as exc:
        if exc.errno in (errno.EBUSY, errno.EAGAIN):
            raise ABError(
                f"{WATCHDOG_DEVICE} is busy; another watchdog user may already be active"
            ) from exc
        raise ABError(f"cannot open {WATCHDOG_DEVICE}: {exc}") from exc


def stop_keepalive_thread() -> None:
    _stop_ping.set()
    thread = _ping_thread
    if (
        thread is not None
        and thread.is_alive()
        and thread is not threading.current_thread()
    ):
        thread.join(timeout=2)


def disarm_watchdog() -> None:
    global _watchdog_fd

    # Ensure no ordinary keepalive write can race after the Magic Close byte.
    stop_keepalive_thread()

    fd = _watchdog_fd
    if fd is None:
        return

    try:
        os.write(fd, b"V")
    except OSError as exc:
        log(f"WARNING: Magic Close write failed: {exc}")
    try:
        os.close(fd)
    except OSError as exc:
        log(f"WARNING: watchdog close failed: {exc}")
    _watchdog_fd = None


def signal_handler(signum: int, _frame: object) -> None:
    name = signal.Signals(signum).name
    log(f"Received {name}; attempting to disarm watchdog before exit.")
    disarm_watchdog()
    raise SystemExit(128 + signum)


def run_streamed(command: list[str]) -> int:
    # Inherit stdout/stderr so healthcheck/commit diagnostics appear directly
    # in the systemd journal.
    result = subprocess.run(command, check=False)
    return result.returncode


def fail_into_watchdog_reset(timeout: int, old_default: str) -> int:
    # Stop keepalives but intentionally keep the fd open. With nowayout=0,
    # closing it could stop the watchdog; we explicitly want expiry here.
    stop_keepalive_thread()

    log("")
    log("HEALTHCHECK FAILED: watchdog keepalive stopped.")
    log(
        f"Expected: hardware reset in about {timeout}s, then rollback to "
        f"old default slot {old_default}."
    )

    deadline = time.monotonic() + timeout + WATCHDOG_FALLBACK_GRACE
    while time.monotonic() < deadline:
        time.sleep(1)

    # If the hardware watchdog did not reset the machine, force a reboot.
    # The default slot is still the old slot because commit has not happened.
    log("ERROR: hardware watchdog did not reset in time; forcing reboot fallback.")
    try:
        os.sync()
    except OSError:
        pass
    subprocess.run(["/sbin/reboot", "-f"], check=False)
    time.sleep(30)
    return 2


def main() -> int:
    global _watchdog_fd, _ping_thread

    if os.geteuid() != 0:
        raise ABError("this command must be run as root")

    running_slot, root_source, boot_source, dt_partition, dt_tryboot = detect_runtime()
    default_slot, tryboot_slot = read_control_state()

    log("VyOS Raspberry Pi A/B automatic tryboot guard")
    log(f"Running slot : {running_slot}")
    log(f"Root         : {root_source}")
    log(f"Boot         : {boot_source}")
    log(f"DT partition : {dt_partition}")
    log(f"DT tryboot   : {dt_tryboot}")
    log(f"Default slot : {default_slot}")
    log(f"Tryboot slot : {tryboot_slot}")

    if dt_tryboot == 0:
        if running_slot != default_slot:
            raise ABError(
                f"normal boot is running slot {running_slot}, but default is {default_slot}"
            )
        log("Normal/default boot detected; watchdog guard is not armed.")
        return 0

    if tryboot_slot != running_slot:
        raise ABError(
            f"running slot {running_slot} is a tryboot boot, but configured "
            f"tryboot slot is {tryboot_slot}"
        )
    if default_slot == running_slot:
        raise ABError(
            f"running slot {running_slot} is marked tryboot but is also the default"
        )

    identity, timeout, nowayout = watchdog_preflight()
    log(f"Watchdog     : {identity}")
    log(f"Timeout      : {timeout}s")
    log(f"Nowayout     : {nowayout}")
    log(f"Rollback     : slot {default_slot}")

    healthcheck = find_helper("vyos-pi-ab-healthcheck.py")
    commit = find_helper("vyos-pi-ab-commit.py")

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    if hasattr(signal, "SIGHUP"):
        signal.signal(signal.SIGHUP, signal.SIG_IGN)

    _watchdog_fd = open_watchdog()
    log("WATCHDOG ARMED: keepalive active while healthcheck runs.")

    _ping_thread = threading.Thread(
        target=keepalive_loop,
        args=(_watchdog_fd,),
        name="vyos-pi-ab-watchdog-keepalive",
        daemon=True,
    )
    _ping_thread.start()

    log("")
    log("Running read-only A/B healthcheck...")
    health_rc = run_streamed(
        [
            sys.executable,
            str(healthcheck),
            "--timeout",
            str(HEALTHCHECK_TIMEOUT),
        ]
    )

    if health_rc != 0:
        return fail_into_watchdog_reset(timeout, default_slot)

    log("")
    log("Healthcheck passed. Disarming watchdog BEFORE changing the default slot.")
    disarm_watchdog()

    log(f"Committing healthy tryboot slot {running_slot}...")
    commit_rc = run_streamed([sys.executable, str(commit), "--yes"])
    if commit_rc != 0:
        raise ABError(
            "healthcheck passed and watchdog was safely disarmed, but commit failed; "
            f"old default slot {default_slot} remains the safe fallback"
        )

    new_default, new_tryboot = read_control_state()
    other_slot = "B" if running_slot == "A" else "A"

    if new_default != running_slot or new_tryboot != other_slot:
        raise ABError(
            f"post-commit boot-control validation failed: default={new_default}, "
            f"tryboot={new_tryboot}"
        )

    log("")
    log(f"AUTO-GUARD SUCCESS: slot {running_slot} is healthy and now the default.")
    log(f"Rollback slot      : {other_slot}")
    log("Requesting one final normal reboot to leave Raspberry Pi tryboot mode.")
    try:
        os.sync()
    except OSError:
        pass
    reboot_result = run("/usr/bin/systemctl", "--no-block", "reboot", check=False)
    if reboot_result.returncode != 0:
        detail = reboot_result.stderr.strip() or reboot_result.stdout.strip()
        log(
            "WARNING: slot commit succeeded, but the final normal reboot request "
            f"failed{': ' + detail if detail else ''}. Run sudo reboot manually."
        )
        return 0
    log("Final normal reboot scheduled; the committed slot will boot with tryboot=0.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ABError as exc:
        print(f"ERROR: {exc}", file=sys.stderr, flush=True)
        raise SystemExit(1)
