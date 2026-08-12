#!/usr/bin/env python3
"""Validate Raspberry Pi BCM43455 firmware links inside an offline rootfs.

Absolute symlinks are resolved relative to ROOTFS (not the build host).
With --repair, a known dangling Debian alternatives link for
cyfmac43455-sdio.bin is repaired to the packaged standard firmware when that
file is available.  No firmware version is downloaded or forced here.
"""
from pathlib import Path, PurePosixPath
import argparse
import os
import posixpath
import sys

parser = argparse.ArgumentParser()
parser.add_argument("rootfs")
mode = parser.add_mutually_exclusive_group()
mode.add_argument("--repair", action="store_true")
mode.add_argument("--check-only", action="store_true")
args = parser.parse_args()
root = Path(args.rootfs).resolve()

if not root.is_dir():
    raise SystemExit(f"ERROR: rootfs not found: {root}")


def host_path(rel: str) -> Path:
    return root / rel.lstrip("/")


def resolve_in_rootfs(rel: str, max_hops: int = 40) -> Path:
    cur = PurePosixPath("/" + rel.lstrip("/"))
    seen = set()
    for _ in range(max_hops):
        key = str(cur)
        if key in seen:
            raise RuntimeError(f"symlink loop at {cur}")
        seen.add(key)
        hp = host_path(str(cur))
        if not os.path.lexists(hp):
            raise FileNotFoundError(str(cur))
        if not hp.is_symlink():
            return hp
        target = os.readlink(hp)
        if target.startswith("/"):
            cur = PurePosixPath(posixpath.normpath(target))
        else:
            cur = PurePosixPath(posixpath.normpath(str(cur.parent / target)))
    raise RuntimeError(f"too many symlink hops resolving {rel}")


def good(rel: str) -> bool:
    try:
        resolve_in_rootfs(rel)
        return True
    except (FileNotFoundError, RuntimeError):
        return False


def repair_generic_bin():
    generic = "/usr/lib/firmware/cypress/cyfmac43455-sdio.bin"
    if good(generic):
        return
    standard = "/usr/lib/firmware/cypress/cyfmac43455-sdio-standard.bin"
    if not good(standard):
        raise RuntimeError(
            "generic BCM43455 firmware is broken and standard fallback is unavailable"
        )
    alt = host_path("/etc/alternatives/cyfmac43455-sdio.bin")
    alt.parent.mkdir(parents=True, exist_ok=True)
    if os.path.lexists(alt):
        alt.unlink()
    alt.symlink_to(standard)
    print(f"REPAIR /etc/alternatives/cyfmac43455-sdio.bin -> {standard}")


if args.repair:
    try:
        repair_generic_bin()
    except RuntimeError as exc:
        raise SystemExit(f"ERROR: {exc}")

required = [
    "/usr/lib/firmware/brcm/brcmfmac43455-sdio.bin",
    "/usr/lib/firmware/brcm/brcmfmac43455-sdio.clm_blob",
    "/usr/lib/firmware/brcm/brcmfmac43455-sdio.txt",
    "/usr/lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi,4-model-b.bin",
    "/usr/lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi,4-model-b.clm_blob",
    "/usr/lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi,4-model-b.txt",
    "/usr/lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi,5-model-b.bin",
    "/usr/lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi,5-model-b.clm_blob",
    "/usr/lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi,5-model-b.txt",
]

failed = False
for rel in required:
    try:
        resolved = resolve_in_rootfs(rel)
        print(f"OK     {rel} -> /{resolved.relative_to(root)}")
    except Exception as exc:
        print(f"BROKEN {rel}: {exc}", file=sys.stderr)
        failed = True

if failed:
    raise SystemExit("ERROR: BCM43455 firmware/NVRAM/CLM validation failed")
print("OK: BCM43455 Pi 4/Pi 5 firmware links are resolvable inside the rootfs")
