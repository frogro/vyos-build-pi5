#!/bin/bash
set -euo pipefail

# Build a VyOS Raspberry Pi A/B update bundle.
#
# Bundle format v1:
#   manifest.json
#   SHA256SUMS
#   payload/rootfs.tar.gz
#   payload/boot.tar
#
# The rootfs payload is the merged VyOS Raspberry Pi rootfs produced by
# merge-vyos-pi5.sh. The boot payload is copied read-only from the same pinned
# Armbian Raspberry Pi hardware base used by the full-image builder.
#
# Usage:
#   sudo ./scripts/pi5/build-vyos-pi-ab-update.sh \
#     /path/to/armbian.img.xz \
#     /path/to/vyos-rootfs-pi5-merged.tar.gz \
#     /path/to/vyos-<version>-rpi-arm64-update.tar.zst
#
# Optional:
#   FORCE=1
#   ZSTD_LEVEL=10
#   SOURCE_DATE_EPOCH=<unix timestamp>

ARMBIAN_IMAGE="${1:?Armbian .img.xz or .img is missing}"
MERGED_TAR="${2:?Merged Raspberry Pi VyOS rootfs .tar.gz is missing}"
OUT_BUNDLE="${3:?Output update bundle path is missing}"

FORCE="${FORCE:-0}"
ZSTD_LEVEL="${ZSTD_LEVEL:-10}"

[[ $EUID -eq 0 ]] || {
    echo "ERROR: run this script as root." >&2
    exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BASE_ENV="${PI5_BASE_ENV:-${REPO_ROOT}/config/pi5-armbian-base.env}"

for cmd in xz cp stat losetup blkid mount umount mountpoint tar zstd \
           sha256sum python3 sync mkdir rm mv awk grep mktemp date dirname sleep; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: required command is missing: $cmd" >&2
        exit 1
    }
done

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

[[ -f "$ARMBIAN_IMAGE" ]] || fail "Armbian image not found: $ARMBIAN_IMAGE"
[[ -f "$MERGED_TAR" ]] || fail "merged rootfs not found: $MERGED_TAR"
[[ -f "$BASE_ENV" ]] || fail "Pi base config not found: $BASE_ENV"
[[ ! -b "$OUT_BUNDLE" ]] || fail "output must be a regular file, never a block device"

case "$MERGED_TAR" in
    *.tar.gz|*.tgz) ;;
    *) fail "v1 update builder currently requires a gzip-compressed rootfs tar (.tar.gz/.tgz)" ;;
esac

[[ "$ZSTD_LEVEL" =~ ^[0-9]+$ ]] || fail "ZSTD_LEVEL must be an integer"
(( ZSTD_LEVEL >= 1 && ZSTD_LEVEL <= 19 )) || fail "ZSTD_LEVEL must be between 1 and 19"

if [[ -e "$OUT_BUNDLE" && "$FORCE" != "1" ]]; then
    fail "output already exists: $OUT_BUNDLE (remove it or use FORCE=1)"
fi

# shellcheck disable=SC1090
source "$BASE_ENV"

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

verify_pinned_base() {
    local actual expected=""
    actual="$(sha256_file "$ARMBIAN_IMAGE")"

    case "$ARMBIAN_IMAGE" in
        *.xz) expected="${ARMBIAN_BASE_SHA256:-}" ;;
        *.img) expected="${ARMBIAN_ORIGINAL_SHA256:-}" ;;
        *) fail "unsupported Armbian image format (use .img.xz or .img)" ;;
    esac

    [[ -n "$expected" ]] || fail "no pinned SHA-256 available for input type: $ARMBIAN_IMAGE"

    if [[ "$actual" != "$expected" ]]; then
        echo "Expected: $expected" >&2
        echo "Actual:   $actual" >&2
        fail "Armbian base SHA-256 mismatch"
    fi

    ARMBIAN_SHA="$actual"
    echo "==> Pinned Armbian base SHA-256 OK: $actual"
}

OUT_DIR="$(dirname "$OUT_BUNDLE")"
mkdir -p "$OUT_DIR"
WORK="$(mktemp -d "${OUT_DIR%/}/.vyos-pi-ab-update.XXXXXX")"
SRC_IMG="${WORK}/armbian-source.img"
SRC_BOOT_MNT="${WORK}/source-boot"
STAGE="${WORK}/stage"
PAYLOAD="${STAGE}/payload"
BOOT_TAR="${PAYLOAD}/boot.tar"
ROOTFS_PAYLOAD="${PAYLOAD}/rootfs.tar.gz"
SRC_LOOP=""

mkdir -p "$SRC_BOOT_MNT" "$PAYLOAD"

cleanup() {
    set +e
    mountpoint -q "$SRC_BOOT_MNT" && umount "$SRC_BOOT_MNT"
    [[ -n "$SRC_LOOP" ]] && losetup -d "$SRC_LOOP" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

settle_partitions() {
    command -v udevadm >/dev/null 2>&1 && udevadm settle || true
    sleep 1
}

extract_source_base() {
    case "$ARMBIAN_IMAGE" in
        *.xz)
            echo "==> Extracting pinned Armbian base read-only source"
            xz -dc -- "$ARMBIAN_IMAGE" > "$SRC_IMG"
            ;;
        *.img)
            echo "==> Copying pinned Armbian base read-only source"
            cp --reflink=auto --sparse=always -- "$ARMBIAN_IMAGE" "$SRC_IMG"
            ;;
    esac

    SRC_LOOP="$(losetup --find --show --read-only --partscan "$SRC_IMG")"
    settle_partitions
}

mount_validate_boot_source() {
    local p1="${SRC_LOOP}p1"
    local pttype p1type p1label

    [[ -b "$p1" ]] || fail "pinned base is missing partition 1"

    pttype="$(blkid -s PTTYPE -o value "$SRC_LOOP" 2>/dev/null || true)"
    p1type="$(blkid -s TYPE -o value "$p1" 2>/dev/null || true)"
    p1label="$(blkid -s LABEL -o value "$p1" 2>/dev/null || true)"

    [[ "$pttype" == "dos" ]] || fail "pinned base must use DOS/MBR, got: ${pttype:-unknown}"
    [[ "$p1type" == "vfat" ]] || fail "pinned base p1 must be vfat, got: ${p1type:-unknown}"
    [[ "$p1label" == "RPICFG" ]] || fail "pinned base p1 must be labeled RPICFG, got: ${p1label:-none}"

    mount -o ro "$p1" "$SRC_BOOT_MNT"

    for f in config.txt cmdline.txt vmlinuz initrd.img bcm2712-rpi-5-b.dtb; do
        [[ -f "$SRC_BOOT_MNT/$f" ]] || fail "pinned base boot partition is missing $f"
    done
    [[ -f "$SRC_BOOT_MNT/overlays/pcie-32bit-dma-pi5.dtbo" ]] \
        || fail "pinned base is missing overlays/pcie-32bit-dma-pi5.dtbo"
}

validate_rootfs_and_boot_parity() {
    echo "==> Validating merged rootfs metadata and boot parity"

    ROOTFS_META="${WORK}/rootfs-meta.json"

    python3 - "$MERGED_TAR" "$SRC_BOOT_MNT" "$ROOTFS_META" <<'PY'
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import tarfile
import sys

archive = Path(sys.argv[1])
boot_root = Path(sys.argv[2])
out = Path(sys.argv[3])

def norm(name: str) -> str:
    while name.startswith("./"):
        name = name[2:]
    return name.lstrip("/")

def sha_stream(handle) -> str:
    h = hashlib.sha256()
    while True:
        chunk = handle.read(1024 * 1024)
        if not chunk:
            break
        h.update(chunk)
    return h.hexdigest()

with tarfile.open(archive, "r:*") as tf:
    members = {norm(m.name): m for m in tf.getmembers()}

    def member(name: str):
        try:
            return members[name]
        except KeyError:
            raise SystemExit(f"ERROR: merged rootfs is missing {name}")

    version_member = member("usr/share/vyos/version.json")
    vf = tf.extractfile(version_member)
    if vf is None:
        raise SystemExit("ERROR: cannot read usr/share/vyos/version.json")
    version_data = json.load(vf)

    version = str(version_data.get("version", "")).strip()
    architecture = str(version_data.get("architecture", "")).strip()
    flavor = str(version_data.get("flavor", "")).strip()

    if not version:
        raise SystemExit("ERROR: rootfs version.json has no version")
    if architecture != "arm64":
        raise SystemExit(f"ERROR: rootfs architecture is {architecture!r}, expected 'arm64'")
    if not flavor:
        raise SystemExit("ERROR: rootfs version.json has no flavor")

    image_member = member("boot/Image")
    if not (image_member.issym() or image_member.islnk()):
        raise SystemExit("ERROR: rootfs boot/Image is not a symlink/hardlink")
    kernel_name = Path(image_member.linkname).name
    if not kernel_name.startswith("vmlinuz-"):
        raise SystemExit(f"ERROR: rootfs boot/Image target is unexpected: {image_member.linkname}")
    kernel_version = kernel_name.removeprefix("vmlinuz-")

    kernel_member = member(f"boot/{kernel_name}")
    initrd_member = member(f"boot/initrd.img-{kernel_version}")

    kf = tf.extractfile(kernel_member)
    inf = tf.extractfile(initrd_member)
    if kf is None or inf is None:
        raise SystemExit("ERROR: cannot read rootfs kernel/initrd")

    root_kernel_sha = sha_stream(kf)
    root_initrd_sha = sha_stream(inf)

    def sha_file(path: Path) -> str:
        h = hashlib.sha256()
        with path.open("rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
        return h.hexdigest()

    boot_kernel_sha = sha_file(boot_root / "vmlinuz")
    boot_initrd_sha = sha_file(boot_root / "initrd.img")

    if root_kernel_sha != boot_kernel_sha:
        raise SystemExit("ERROR: pinned boot vmlinuz does not match merged rootfs kernel")
    if root_initrd_sha != boot_initrd_sha:
        raise SystemExit("ERROR: pinned boot initrd.img does not match merged rootfs initrd")

    # Check Pi 5 DTB parity when the rootfs exposes the conventional boot/dtb link.
    dtb_link = members.get("boot/dtb")
    if dtb_link is not None and (dtb_link.issym() or dtb_link.islnk()):
        dtb_dir = dtb_link.linkname.rstrip("/")
        dtb_name = norm(f"boot/{dtb_dir}/broadcom/bcm2712-rpi-5-b.dtb")
        dtb_member = member(dtb_name)
        df = tf.extractfile(dtb_member)
        if df is None:
            raise SystemExit("ERROR: cannot read rootfs Pi 5 DTB")
        if sha_stream(df) != sha_file(boot_root / "bcm2712-rpi-5-b.dtb"):
            raise SystemExit("ERROR: pinned boot Pi 5 DTB does not match merged rootfs DTB")

    required_members = (
        "config/config.boot",
        "home/vyos/ap-dhcp-wan-setup.sh",
        "usr/lib/firmware/brcm/brcmfmac43455-sdio.bin",
    )
    for required in required_members:
        if required not in members:
            raise SystemExit(f"ERROR: merged rootfs is missing required member {required}")

    regular_bytes = sum(m.size for m in tf.getmembers() if m.isfile())
    file_count = sum(1 for m in tf.getmembers() if m.isfile())

meta = {
    "version": version,
    "architecture": architecture,
    "flavor": flavor,
    "kernel_version": kernel_version,
    "rootfs_regular_bytes": regular_bytes,
    "rootfs_regular_files": file_count,
}
out.write_text(json.dumps(meta, sort_keys=True) + "\n", encoding="utf-8")
print(f"    Version : {version}")
print(f"    Arch    : {architecture}")
print(f"    Flavor  : {flavor}")
print(f"    Kernel  : {kernel_version}")
PY
}

create_payloads() {
    echo "==> Copying merged rootfs payload"
    cp --reflink=auto -- "$MERGED_TAR" "$ROOTFS_PAYLOAD"

    echo "==> Creating boot payload"
    tar -C "$SRC_BOOT_MNT" \
        --numeric-owner \
        -cf "$BOOT_TAR" .

    sync
}

create_manifest() {
    local root_sha boot_sha root_size boot_size source_epoch
    root_sha="$(sha256_file "$ROOTFS_PAYLOAD")"
    boot_sha="$(sha256_file "$BOOT_TAR")"
    root_size="$(stat -c '%s' "$ROOTFS_PAYLOAD")"
    boot_size="$(stat -c '%s' "$BOOT_TAR")"

    if [[ -n "${SOURCE_DATE_EPOCH:-}" ]]; then
        source_epoch="$SOURCE_DATE_EPOCH"
    else
        source_epoch="$(date +%s)"
    fi

    python3 - \
        "$ROOTFS_META" \
        "$STAGE/manifest.json" \
        "$root_sha" "$root_size" \
        "$boot_sha" "$boot_size" \
        "$ARMBIAN_SHA" "$(sha256_file "$MERGED_TAR")" \
        "$source_epoch" <<'PY'
from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
import sys

rootfs_meta_path = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])
root_sha = sys.argv[3]
root_size = int(sys.argv[4])
boot_sha = sys.argv[5]
boot_size = int(sys.argv[6])
armbian_sha = sys.argv[7]
merged_sha = sys.argv[8]
epoch = int(sys.argv[9])

meta = json.loads(rootfs_meta_path.read_text(encoding="utf-8"))

manifest = {
    "format": "vyos-rpi-ab-update",
    "format_version": 1,
    "platform": "raspberry-pi",
    "architecture": meta["architecture"],
    "flavor": meta["flavor"],
    "version": meta["version"],
    "kernel_version": meta["kernel_version"],
    "created_utc": datetime.fromtimestamp(epoch, tz=timezone.utc).isoformat().replace("+00:00", "Z"),
    "payload": {
        "rootfs": {
            "path": "payload/rootfs.tar.gz",
            "archive": "tar.gz",
            "sha256": root_sha,
            "size": root_size,
            "regular_bytes": meta["rootfs_regular_bytes"],
            "regular_files": meta["rootfs_regular_files"],
        },
        "boot": {
            "path": "payload/boot.tar",
            "archive": "tar",
            "sha256": boot_sha,
            "size": boot_size,
        },
    },
    "required_layout": {
        "control_label": "VYOS_AB",
        "boot_labels": {"A": "VYOS_BOOT_A", "B": "VYOS_BOOT_B"},
        "root_labels": {"A": "VYOS_ROOT_A", "B": "VYOS_ROOT_B"},
        "boot_partitions": {"A": 2, "B": 3},
        "root_partitions": {"A": 5, "B": 6},
    },
    "source": {
        "armbian_sha256": armbian_sha,
        "merged_rootfs_sha256": merged_sha,
    },
}

manifest_path.write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

    (
        cd "$STAGE"
        sha256sum manifest.json payload/rootfs.tar.gz payload/boot.tar > SHA256SUMS
    )
}

create_bundle() {
    local tmp_bundle="${WORK}/update.tar.zst"
    local epoch="${SOURCE_DATE_EPOCH:-$(date +%s)}"

    echo "==> Creating update bundle (zstd level ${ZSTD_LEVEL})"

    # Explicit file list keeps the top-level format intentionally small.
    tar -C "$STAGE" \
        --sort=name \
        --owner=0 --group=0 --numeric-owner \
        --mtime="@${epoch}" \
        -cf - \
        manifest.json SHA256SUMS payload/rootfs.tar.gz payload/boot.tar \
      | zstd -q -T0 "-${ZSTD_LEVEL}" -o "$tmp_bundle"

    zstd -q -t "$tmp_bundle"

    if [[ -e "$OUT_BUNDLE" ]]; then
        rm -f "$OUT_BUNDLE"
    fi
    mv "$tmp_bundle" "$OUT_BUNDLE"
}

show_result() {
    local version bundle_sha
    version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$STAGE/manifest.json")"
    bundle_sha="$(sha256_file "$OUT_BUNDLE")"

    echo
    echo "==> Raspberry Pi VyOS A/B update bundle complete"
    echo "    Version : $version"
    echo "    Bundle  : $OUT_BUNDLE"
    echo "    Size    : $(stat -c '%s' "$OUT_BUNDLE") bytes"
    echo "    SHA256  : $bundle_sha"
    echo
    echo "    Bundle format:"
    echo "      manifest.json"
    echo "      SHA256SUMS"
    echo "      payload/rootfs.tar.gz"
    echo "      payload/boot.tar"
}

echo "==> VyOS Raspberry Pi A/B update bundle builder v0.1"
echo "    Armbian base : $ARMBIAN_IMAGE"
echo "    Merged rootfs: $MERGED_TAR"
echo "    Output       : $OUT_BUNDLE"

verify_pinned_base
extract_source_base
mount_validate_boot_source
validate_rootfs_and_boot_parity
create_payloads
create_manifest
create_bundle
show_result
