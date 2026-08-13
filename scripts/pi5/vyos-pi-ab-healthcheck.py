#!/usr/bin/env python3
"""
Health-check the currently running Raspberry Pi VyOS A/B slot.

The check is intentionally local: it verifies A/B slot consistency, mounts,
cmdline/fstab, core VyOS startup state and config.boot.  Network reachability is
not a mandatory health criterion.

By default this command is read-only.  With --commit, a healthy tryboot slot is
committed by invoking the sibling vyos-pi-ab-commit.py with --yes.
"""

from __future__ import annotations

import argparse
import contextlib
import os
from pathlib import Path
import shlex
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

REQUIRED_UNITS = (
    "vyos-router.service",
    "vyos-configd.service",
    "vyos-commitd.service",
)


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


def ok(message: str) -> None:
    print(f"OK: {message}")


def findmnt_field(target: str, field: str) -> str | None:
    result = run("findmnt", "-rn", "-o", field, "--target", target, check=False)
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return value or None


def normalize_source(source: str | None) -> str | None:
    if not source:
        return None
    return source.split("[", 1)[0]


def mount_is_rw(target: str) -> bool:
    options = findmnt_field(target, "OPTIONS")
    if not options:
        return False
    return "rw" in options.split(",")


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


def detect_runtime() -> tuple[str, str, str, str, int, int]:
    root_source = normalize_source(findmnt_field("/", "SOURCE"))
    config_source = normalize_source(findmnt_field("/config", "SOURCE"))
    boot_source = normalize_source(findmnt_field("/boot/firmware", "SOURCE"))

    if not root_source or not config_source or not boot_source:
        raise ABError("cannot determine /, /config and /boot/firmware source devices")

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
    if os.path.realpath(config_source) != os.path.realpath(root_source):
        raise ABError(
            f"/config comes from {config_source}, but root filesystem is {root_source}"
        )

    dt_partition = read_dt_u32("partition")
    dt_tryboot = read_dt_u32("tryboot")
    expected_partition = BOOT_PARTITIONS[root_slot]

    if dt_partition != expected_partition:
        raise ABError(
            f"device-tree partition={dt_partition}, but runtime slot {root_slot} "
            f"requires partition={expected_partition}"
        )
    if dt_tryboot not in (0, 1):
        raise ABError(f"unexpected device-tree tryboot value {dt_tryboot}")

    return root_slot, root_source, config_source, boot_source, dt_partition, dt_tryboot


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


def read_autoboot_state() -> tuple[dict[str, int | bool | None], str, str]:
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

    return state, default_slot, tryboot_slot


def check_cmdline_root(root_source: str) -> None:
    try:
        cmdline = Path("/proc/cmdline").read_text(encoding="ascii").strip()
    except OSError as exc:
        raise ABError(f"cannot read /proc/cmdline: {exc}") from exc

    root_tokens = [token for token in shlex.split(cmdline) if token.startswith("root=")]
    if len(root_tokens) != 1:
        raise ABError(f"expected exactly one root= token in /proc/cmdline, found {len(root_tokens)}")

    root_value = root_tokens[0].split("=", 1)[1]
    partuuid = blkid_value(root_source, "PARTUUID")
    if not partuuid:
        raise ABError(f"cannot determine PARTUUID for {root_source}")

    expected = f"PARTUUID={partuuid}"
    if root_value.lower() != expected.lower():
        raise ABError(f"kernel root={root_value}, expected {expected}")


def parse_fstab() -> dict[str, str]:
    try:
        lines = Path("/etc/fstab").read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as exc:
        raise ABError(f"cannot read /etc/fstab: {exc}") from exc

    entries: dict[str, str] = {}
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) < 2:
            continue
        source, target = fields[0], fields[1]
        entries[target] = source
    return entries


def source_matches_device(spec: str, device: str) -> bool:
    uuid = blkid_value(device, "UUID")
    partuuid = blkid_value(device, "PARTUUID")
    candidates = {device, os.path.realpath(device)}
    if uuid:
        candidates.add(f"UUID={uuid}")
    if partuuid:
        candidates.add(f"PARTUUID={partuuid}")
    return spec in candidates


def check_fstab(root_source: str, boot_source: str) -> None:
    entries = parse_fstab()
    root_spec = entries.get("/")
    boot_spec = entries.get("/boot/firmware")

    if root_spec is None:
        raise ABError("/etc/fstab has no root (/) entry")
    if boot_spec is None:
        raise ABError("/etc/fstab has no /boot/firmware entry")
    if not source_matches_device(root_spec, root_source):
        raise ABError(f"fstab root source {root_spec!r} does not match {root_source}")
    if not source_matches_device(boot_spec, boot_source):
        raise ABError(f"fstab boot source {boot_spec!r} does not match {boot_source}")


def system_state() -> str:
    result = run("systemctl", "is-system-running", check=False)
    return (result.stdout.strip() or result.stderr.strip() or "unknown").splitlines()[0]


def unit_state(unit: str) -> str:
    result = run("systemctl", "is-active", unit, check=False)
    return (result.stdout.strip() or "unknown").splitlines()[0]


def wait_for_vyos(timeout: int, interval: float) -> None:
    deadline = time.monotonic() + timeout
    last_state = "unknown"
    last_units: dict[str, str] = {}

    while True:
        last_state = system_state()
        last_units = {unit: unit_state(unit) for unit in REQUIRED_UNITS}

        if last_state == "running" and all(state == "active" for state in last_units.values()):
            return

        if time.monotonic() >= deadline:
            unit_text = ", ".join(f"{unit}={state}" for unit, state in last_units.items())
            raise ABError(
                f"VyOS did not reach healthy systemd state within {timeout}s: "
                f"system={last_state}; {unit_text}"
            )

        time.sleep(interval)


def find_commit_command() -> Path:
    candidates = (
        Path(__file__).resolve().with_name("vyos-pi-ab-commit.py"),
        Path("/usr/libexec/vyos/vyos-pi-ab-commit.py"),
        Path("/usr/local/libexec/vyos/vyos-pi-ab-commit.py"),
    )
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise ABError("cannot find vyos-pi-ab-commit.py next to healthcheck or in /usr/libexec/vyos")


def commit_running_slot() -> None:
    command = find_commit_command()
    result = subprocess.run(
        [sys.executable, str(command), "--yes"],
        text=True,
    )
    if result.returncode != 0:
        raise ABError(f"commit helper failed with return code {result.returncode}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Health-check VyOS Raspberry Pi A/B slot")
    parser.add_argument(
        "--commit",
        action="store_true",
        help="commit a healthy tryboot slot as the new default",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=90,
        help="seconds to wait for systemd/VyOS core services (default: 90)",
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=2.0,
        help="poll interval while waiting for VyOS startup (default: 2.0)",
    )
    args = parser.parse_args()

    if os.geteuid() != 0:
        raise ABError("this command must be run as root")
    if args.timeout < 0:
        raise ABError("--timeout must be >= 0")
    if args.interval <= 0:
        raise ABError("--interval must be > 0")

    print("VyOS Raspberry Pi A/B healthcheck")
    print()

    running_slot, root_source, config_source, boot_source, dt_partition, dt_tryboot = detect_runtime()
    ok(
        f"runtime slot {running_slot} is consistent "
        f"(root={root_source}, boot={boot_source}, DT partition={dt_partition})"
    )

    if not mount_is_rw("/"):
        raise ABError("root filesystem is not mounted read-write")
    if not mount_is_rw("/config"):
        raise ABError("/config is not mounted read-write")
    if not mount_is_rw("/boot/firmware"):
        raise ABError("/boot/firmware is not mounted read-write")
    ok(f"/, /config and /boot/firmware are read-write; /config comes from {config_source}")

    check_cmdline_root(root_source)
    ok("kernel root=PARTUUID matches the running root slot")

    check_fstab(root_source, boot_source)
    ok("/etc/fstab points to the running root and boot filesystems")

    config_boot = Path("/config/config.boot")
    try:
        config_size = config_boot.stat().st_size
    except OSError as exc:
        raise ABError(f"cannot stat {config_boot}: {exc}") from exc
    if config_size <= 0:
        raise ABError("/config/config.boot is empty")
    ok(f"/config/config.boot exists and is non-empty ({config_size} bytes)")

    wait_for_vyos(args.timeout, args.interval)
    ok("systemd is running and core VyOS units are active")

    _state, default_slot, tryboot_slot = read_autoboot_state()
    if dt_tryboot == 1:
        if tryboot_slot != running_slot:
            raise ABError(
                f"running slot {running_slot} is a tryboot boot, but autoboot.txt tryboot slot is "
                f"{tryboot_slot}"
            )
        if default_slot == running_slot:
            raise ABError(
                f"running slot {running_slot} is marked tryboot but is also configured as default"
            )
        ok(f"tryboot state is consistent: running={running_slot}, default={default_slot}")
    else:
        if default_slot != running_slot:
            raise ABError(
                f"normal boot is running slot {running_slot}, but autoboot.txt default is {default_slot}"
            )
        ok(f"normal boot state is consistent: running/default={running_slot}")

    print()
    print(f"HEALTHY: slot {running_slot}")
    print(f"Tryboot : {'yes' if dt_tryboot else 'no'}")
    print(f"Default : {default_slot}")

    if args.commit:
        if dt_tryboot == 1:
            print()
            print(f"Committing healthy tryboot slot {running_slot}...")
            commit_running_slot()
            _new_state, new_default_slot, new_tryboot_slot = read_autoboot_state()
            if new_default_slot != running_slot:
                raise ABError(
                    f"post-commit validation failed: default is {new_default_slot}, "
                    f"expected {running_slot}"
                )
            other_slot = "B" if running_slot == "A" else "A"
            if new_tryboot_slot != other_slot:
                raise ABError(
                    f"post-commit validation failed: tryboot slot is {new_tryboot_slot}, "
                    f"expected {other_slot}"
                )
            print(f"HEALTHY+COMMITTED: slot {running_slot} is now the default")
        else:
            print("No commit needed: this is a normal (non-tryboot) boot.")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ABError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
