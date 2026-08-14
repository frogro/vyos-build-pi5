#!/usr/bin/env bash
set -Eeuo pipefail

# Convert an existing single-slot VyOS Raspberry Pi .img.xz into BOTH:
#   1) a bootable Raspberry Pi A/B full image (.img.xz)
#   2) a matching VyOS Raspberry Pi A/B update bundle (.tar.zst)
#
# The converter deliberately uses the SAME extracted rootfs, boot payload and
# A/B runtime for both outputs. This keeps the full image and update bundle in
# lock-step even when the original Armbian build inputs are no longer present.
#
# Default A/B disk layout (DOS/MBR):
#   p1  FAT32  VYOS_AB       64 MiB     control/autoboot.txt
#   p2  FAT32  VYOS_BOOT_A  512 MiB
#   p3  FAT32  VYOS_BOOT_B  512 MiB
#   p4  extended
#   p5  ext4   VYOS_ROOT_A    5.5 GiB
#   p6  ext4   VYOS_ROOT_B    5.5 GiB
#
# Usage:
#   sudo ./convert-vyos-rpi-image-to-ab.sh \
#     vyos-2026.08.13-0024-rolling-rpi-arm64.img.xz
#
# Optional:
#   --repo DIR        vyos-build-pi5 A/B worktree containing scripts/pi5/
#   --output-dir DIR  output directory (default: source image directory)
#   --force           overwrite existing output artifacts
#   --keep-work       keep temporary work directory for debugging
#
# Environment knobs:
#   AB_IMAGE_SIZE_MIB=12360
#   XZ_LEVEL=6
#   ZSTD_LEVEL=10
#   GZIP_LEVEL=6
#   SOURCE_DATE_EPOCH=<unix epoch>
#   WORKDIR_BASE=<directory for temporary files>
#
# This is intentionally an offline converter: it never downloads build inputs.

SCRIPT_VERSION="0.1"
AB_IMAGE_SIZE_MIB="${AB_IMAGE_SIZE_MIB:-12360}"
XZ_LEVEL="${XZ_LEVEL:-6}"
ZSTD_LEVEL="${ZSTD_LEVEL:-10}"
GZIP_LEVEL="${GZIP_LEVEL:-6}"
DEFAULT_REPO="/mnt/datenplatte/pi5vyos/vyos-build-pi5-ab"
REPO="${VYOS_PI5_AB_REPO:-$DEFAULT_REPO}"
OUT_DIR=""
FORCE=0
KEEP_WORK=0
SRC_XZ=""
WORK=""
SRC_RAW=""
SRC_LOOP=""
AB_RAW=""
AB_LOOP=""

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

info() {
    echo "==> $*"
}

usage() {
    cat <<'USAGE'
Usage:
  sudo ./convert-vyos-rpi-image-to-ab.sh [options] SOURCE.img.xz

Options:
  --repo DIR        A/B repository/worktree (default: /mnt/datenplatte/pi5vyos/vyos-build-pi5-ab)
  --output-dir DIR  write outputs here (default: directory containing SOURCE)
  --force           overwrite existing output files
  --keep-work       keep temporary work directory for debugging
  -h, --help        show this help

Outputs for SOURCE=vyos-VERSION-rpi-arm64.img.xz:
  vyos-VERSION-rpi-arm64-ab.img.xz
  vyos-VERSION-rpi-arm64-update.tar.zst
USAGE
}

while (($#)); do
    case "$1" in
        --repo)
            (($# >= 2)) || fail "--repo requires a directory"
            REPO="$2"
            shift 2
            ;;
        --output-dir)
            (($# >= 2)) || fail "--output-dir requires a directory"
            OUT_DIR="$2"
            shift 2
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --keep-work)
            KEEP_WORK=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            fail "unknown option: $1"
            ;;
        *)
            [[ -z "$SRC_XZ" ]] || fail "only one source image may be specified"
            SRC_XZ="$1"
            shift
            ;;
    esac
done

[[ -n "$SRC_XZ" ]] || { usage; exit 2; }
[[ $EUID -eq 0 ]] || fail "run this converter with sudo/root"
SRC_XZ="$(readlink -f -- "$SRC_XZ")"
[[ -f "$SRC_XZ" ]] || fail "source image not found: $SRC_XZ"
[[ "$SRC_XZ" == *.img.xz ]] || fail "source must end in .img.xz"

REPO="$(readlink -f -- "$REPO")"
SCRIPT_DIR="${REPO}/scripts/pi5"
[[ -d "$SCRIPT_DIR" ]] || fail "A/B scripts directory not found: $SCRIPT_DIR"

if [[ -z "$OUT_DIR" ]]; then
    OUT_DIR="$(dirname -- "$SRC_XZ")"
else
    mkdir -p -- "$OUT_DIR"
    OUT_DIR="$(readlink -f -- "$OUT_DIR")"
fi

SRC_NAME="$(basename -- "$SRC_XZ")"
BASE_NAME="${SRC_NAME%.img.xz}"
[[ "$BASE_NAME" != *-ab ]] || fail "source filename already looks like an A/B image: $SRC_NAME"
OUT_AB_XZ="${OUT_DIR}/${BASE_NAME}-ab.img.xz"
OUT_UPDATE="${OUT_DIR}/${BASE_NAME}-update.tar.zst"

if (( ! FORCE )); then
    [[ ! -e "$OUT_AB_XZ" ]] || fail "output already exists: $OUT_AB_XZ (use --force)"
    [[ ! -e "$OUT_UPDATE" ]] || fail "output already exists: $OUT_UPDATE (use --force)"
fi

for cmd in \
    awk blkid cp date df find findmnt grep gzip install ln losetup lsblk \
    mkdir mkfs.ext4 mkfs.vfat mount mountpoint mv parted python3 readlink \
    rm sha256sum stat sync tar truncate umount xz zstd; do
    command -v "$cmd" >/dev/null 2>&1 || fail "required command is missing: $cmd"
done

[[ "$AB_IMAGE_SIZE_MIB" =~ ^[0-9]+$ ]] || fail "AB_IMAGE_SIZE_MIB must be an integer"
[[ "$XZ_LEVEL" =~ ^[0-9]+$ ]] || fail "XZ_LEVEL must be an integer"
[[ "$ZSTD_LEVEL" =~ ^[0-9]+$ ]] || fail "ZSTD_LEVEL must be an integer"
[[ "$GZIP_LEVEL" =~ ^[0-9]+$ ]] || fail "GZIP_LEVEL must be an integer"
(( AB_IMAGE_SIZE_MIB >= 12360 )) || fail "AB_IMAGE_SIZE_MIB must be at least 12360 MiB"

for runtime_script in \
    vyos-pi-ab-status.py \
    vyos-pi-ab-commit.py \
    vyos-pi-ab-healthcheck.py \
    vyos-pi-ab-auto-guard.py \
    install-vyos-pi-ab-update.py \
    vyos-pi-image-dispatch.py; do
    [[ -f "${SCRIPT_DIR}/${runtime_script}" ]] \
        || fail "required runtime source is missing: ${SCRIPT_DIR}/${runtime_script}"
done

WORK_PARENT="${WORKDIR_BASE:-$OUT_DIR}"
mkdir -p -- "$WORK_PARENT"
WORK="$(mktemp -d -p "$WORK_PARENT" .vyos-pi-ab-convert.XXXXXX)"
SRC_RAW="${WORK}/source.img"
AB_RAW="${WORK}/ab.img"
SRC_BOOT_MNT="${WORK}/src-boot"
SRC_ROOT_MNT="${WORK}/src-root"
AB_CTL_MNT="${WORK}/ab-control"
AB_BOOT_A_MNT="${WORK}/ab-boot-a"
AB_BOOT_B_MNT="${WORK}/ab-boot-b"
AB_ROOT_A_MNT="${WORK}/ab-root-a"
AB_ROOT_B_MNT="${WORK}/ab-root-b"
STAGE="${WORK}/update-stage"
PAYLOAD="${STAGE}/payload"
ROOTFS_PAYLOAD="${PAYLOAD}/rootfs.tar.gz"
BOOT_PAYLOAD="${PAYLOAD}/boot.tar"
RUNTIME_PAYLOAD="${PAYLOAD}/ab-runtime.tar"
RUNTIME_ROOT="${WORK}/runtime-root"
META_JSON="${WORK}/rootfs-meta.json"

mkdir -p \
    "$SRC_BOOT_MNT" "$SRC_ROOT_MNT" \
    "$AB_CTL_MNT" "$AB_BOOT_A_MNT" "$AB_BOOT_B_MNT" \
    "$AB_ROOT_A_MNT" "$AB_ROOT_B_MNT" \
    "$PAYLOAD" "$RUNTIME_ROOT"

cleanup() {
    set +e
    sync >/dev/null 2>&1 || true
    for m in \
        "$AB_ROOT_B_MNT" "$AB_ROOT_A_MNT" \
        "$AB_BOOT_B_MNT" "$AB_BOOT_A_MNT" "$AB_CTL_MNT" \
        "$SRC_ROOT_MNT" "$SRC_BOOT_MNT"; do
        if mountpoint -q "$m" 2>/dev/null; then
            umount "$m" >/dev/null 2>&1 || umount -l "$m" >/dev/null 2>&1 || true
        fi
    done
    if [[ -n "$AB_LOOP" ]]; then
        losetup -d "$AB_LOOP" >/dev/null 2>&1 || true
    fi
    if [[ -n "$SRC_LOOP" ]]; then
        losetup -d "$SRC_LOOP" >/dev/null 2>&1 || true
    fi
    if (( KEEP_WORK )); then
        echo "NOTE: keeping work directory: $WORK"
    else
        rm -rf -- "$WORK"
    fi
}
trap cleanup EXIT INT TERM

# A 6 GiB source + ~12.1 GiB raw A/B image + payloads/compressed outputs needs
# substantial temporary headroom. This is a conservative early warning only.
FREE_BYTES="$(df -PB1 "$WORK_PARENT" | awk 'NR==2 {print $4}')"
MIN_FREE_BYTES=$((22 * 1024 * 1024 * 1024))
if [[ "$FREE_BYTES" =~ ^[0-9]+$ ]] && (( FREE_BYTES < MIN_FREE_BYTES )); then
    fail "less than 22 GiB free in $WORK_PARENT; choose WORKDIR_BASE on a larger filesystem"
fi

SOURCE_SHA="$(sha256sum "$SRC_XZ" | awk '{print $1}')"

info "VyOS Raspberry Pi existing-image -> A/B converter v${SCRIPT_VERSION}"
echo "    Source        : $SRC_XZ"
echo "    Source SHA256 : $SOURCE_SHA"
echo "    A/B image     : $OUT_AB_XZ"
echo "    Update bundle : $OUT_UPDATE"
echo "    A/B repo      : $REPO"
echo

info "Decompressing source image read-only working copy"
xz -dc -- "$SRC_XZ" > "$SRC_RAW"

info "Attaching source image read-only"
SRC_LOOP="$(losetup --find --show --partscan --read-only "$SRC_RAW")"
sleep 1

# Refuse a source that is already our A/B layout.
if lsblk -lnpo NAME,TYPE "$SRC_LOOP" | awk '$2 == "part" {print $1}' | while read -r p; do
    [[ "$(blkid -s LABEL -o value "$p" 2>/dev/null || true)" == "VYOS_AB" ]] && exit 42
    true
done; then
    :
else
    rc=$?
    (( rc == 42 )) && fail "source image already contains VYOS_AB; refusing double conversion"
    exit "$rc"
fi

info "Discovering source boot and root partitions"
SRC_BOOT_DEV=""
SRC_ROOT_DEV=""
while read -r dev kind; do
    [[ "$kind" == "part" ]] || continue
    fstype="$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)"
    case "$fstype" in
        vfat|fat|fat16|fat32)
            if ! mountpoint -q "$SRC_BOOT_MNT"; then
                if mount -o ro "$dev" "$SRC_BOOT_MNT" 2>/dev/null; then
                    if [[ -f "$SRC_BOOT_MNT/config.txt" \
                       && -f "$SRC_BOOT_MNT/cmdline.txt" \
                       && -f "$SRC_BOOT_MNT/vmlinuz" \
                       && -f "$SRC_BOOT_MNT/initrd.img" ]]; then
                        [[ -z "$SRC_BOOT_DEV" ]] || fail "multiple candidate source boot partitions found"
                        SRC_BOOT_DEV="$dev"
                    fi
                    umount "$SRC_BOOT_MNT"
                fi
            fi
            ;;
        ext4)
            if ! mountpoint -q "$SRC_ROOT_MNT"; then
                if mount -o ro,noload "$dev" "$SRC_ROOT_MNT" 2>/dev/null; then
                    if [[ -f "$SRC_ROOT_MNT/usr/share/vyos/version.json" \
                       && -d "$SRC_ROOT_MNT/etc" \
                       && -d "$SRC_ROOT_MNT/config" ]]; then
                        [[ -z "$SRC_ROOT_DEV" ]] || fail "multiple candidate source VyOS root partitions found"
                        SRC_ROOT_DEV="$dev"
                    fi
                    umount "$SRC_ROOT_MNT"
                fi
            fi
            ;;
    esac
done < <(lsblk -lnpo NAME,TYPE "$SRC_LOOP")

[[ -n "$SRC_BOOT_DEV" ]] || fail "could not identify source Raspberry Pi boot partition"
[[ -n "$SRC_ROOT_DEV" ]] || fail "could not identify source VyOS root partition"

echo "    Source boot   : $SRC_BOOT_DEV ($(blkid -s LABEL -o value "$SRC_BOOT_DEV" 2>/dev/null || echo no-label))"
echo "    Source root   : $SRC_ROOT_DEV ($(blkid -s LABEL -o value "$SRC_ROOT_DEV" 2>/dev/null || echo no-label))"

mount -o ro "$SRC_BOOT_DEV" "$SRC_BOOT_MNT"
mount -o ro,noload "$SRC_ROOT_DEV" "$SRC_ROOT_MNT"

for f in config.txt cmdline.txt vmlinuz initrd.img bcm2712-rpi-5-b.dtb; do
    [[ -f "$SRC_BOOT_MNT/$f" ]] || fail "source boot partition is missing required file: $f"
done
[[ -f "$SRC_BOOT_MNT/overlays/pcie-32bit-dma-pi5.dtbo" ]] \
    || fail "source boot partition is missing overlays/pcie-32bit-dma-pi5.dtbo"

info "Creating rootfs payload from the existing release image"
if command -v pigz >/dev/null 2>&1; then
    tar -C "$SRC_ROOT_MNT" \
        --sort=name \
        --numeric-owner \
        --acls --xattrs --xattrs-include='*' \
        --one-file-system \
        -cf - . \
      | pigz -"$GZIP_LEVEL" > "$ROOTFS_PAYLOAD"
else
    tar -C "$SRC_ROOT_MNT" \
        --sort=name \
        --numeric-owner \
        --acls --xattrs --xattrs-include='*' \
        --one-file-system \
        -cf - . \
      | gzip -"$GZIP_LEVEL" > "$ROOTFS_PAYLOAD"
fi

gzip -t "$ROOTFS_PAYLOAD"

info "Creating boot payload from the existing release image"
tar -C "$SRC_BOOT_MNT" --sort=name --numeric-owner -cf "$BOOT_PAYLOAD" .

create_runtime_payload() {
    local libexec="${RUNTIME_ROOT}/usr/libexec/vyos"
    local op_mode="${libexec}/op_mode"
    local systemd_dir="${RUNTIME_ROOT}/etc/systemd/system"
    local wants_dir="${systemd_dir}/multi-user.target.wants"

    info "Creating A/B runtime payload from the current feature worktree"
    mkdir -p "$libexec" "$op_mode" "$wants_dir"

    for script in \
        vyos-pi-ab-status.py \
        vyos-pi-ab-commit.py \
        vyos-pi-ab-healthcheck.py \
        vyos-pi-ab-auto-guard.py \
        install-vyos-pi-ab-update.py; do
        install -m 0755 "${SCRIPT_DIR}/${script}" "${libexec}/${script}"
    done

    install -m 0755 "${SCRIPT_DIR}/vyos-pi-image-dispatch.py" \
        "${op_mode}/vyos_pi_image_dispatch.py"

    cat > "${systemd_dir}/vyos-pi-ab-auto-guard.service" <<'UNIT'
[Unit]
Description=VyOS Raspberry Pi A/B automatic tryboot watchdog guard
After=local-fs.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/libexec/vyos/vyos-pi-ab-auto-guard.py
Environment=PYTHONUNBUFFERED=1
Restart=no
TimeoutStopSec=5s

[Install]
WantedBy=multi-user.target
UNIT

    ln -s ../vyos-pi-ab-auto-guard.service \
        "${wants_dir}/vyos-pi-ab-auto-guard.service"

    tar -C "$RUNTIME_ROOT" --sort=name --numeric-owner -cf "$RUNTIME_PAYLOAD" .

    python3 - "$SCRIPT_DIR" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for name in (
    "vyos-pi-ab-status.py",
    "vyos-pi-ab-commit.py",
    "vyos-pi-ab-healthcheck.py",
    "vyos-pi-ab-auto-guard.py",
    "install-vyos-pi-ab-update.py",
    "vyos-pi-image-dispatch.py",
):
    path = root / name
    compile(path.read_text(encoding="utf-8"), str(path), "exec")
PY
}
create_runtime_payload

info "Validating source version metadata and kernel/boot parity"
python3 - "$ROOTFS_PAYLOAD" "$SRC_BOOT_MNT" "$META_JSON" <<'PY'
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
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        h.update(chunk)
    return h.hexdigest()

def sha_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

with tarfile.open(archive, "r:gz") as tf:
    all_members = tf.getmembers()
    members = {norm(m.name): m for m in all_members}

    def member(name: str):
        try:
            return members[name]
        except KeyError:
            raise SystemExit(f"ERROR: converted rootfs is missing {name}")

    vf = tf.extractfile(member("usr/share/vyos/version.json"))
    if vf is None:
        raise SystemExit("ERROR: cannot read usr/share/vyos/version.json")
    version_data = json.load(vf)
    version = str(version_data.get("version", "")).strip()
    architecture = str(version_data.get("architecture", "")).strip()
    flavor = str(version_data.get("flavor", "")).strip()
    if not version:
        raise SystemExit("ERROR: source image version.json has no version")
    if architecture != "arm64":
        raise SystemExit(f"ERROR: source architecture is {architecture!r}, expected 'arm64'")
    if not flavor:
        raise SystemExit("ERROR: source image version.json has no flavor")

    image_member = member("boot/Image")
    if not (image_member.issym() or image_member.islnk()):
        raise SystemExit("ERROR: rootfs boot/Image is not a symlink/hardlink")
    kernel_name = Path(image_member.linkname).name
    if not kernel_name.startswith("vmlinuz-"):
        raise SystemExit(f"ERROR: rootfs boot/Image target is unexpected: {image_member.linkname}")
    kernel_version = kernel_name.removeprefix("vmlinuz-")

    kf = tf.extractfile(member(f"boot/{kernel_name}"))
    inf = tf.extractfile(member(f"boot/initrd.img-{kernel_version}"))
    if kf is None or inf is None:
        raise SystemExit("ERROR: cannot read source rootfs kernel/initrd")

    if sha_stream(kf) != sha_file(boot_root / "vmlinuz"):
        raise SystemExit("ERROR: source boot vmlinuz does not match rootfs kernel")
    if sha_stream(inf) != sha_file(boot_root / "initrd.img"):
        raise SystemExit("ERROR: source boot initrd.img does not match rootfs initrd")

    required = (
        "config/config.boot",
        "usr/lib/firmware/brcm/brcmfmac43455-sdio.bin",
    )
    for name in required:
        if name not in members:
            raise SystemExit(f"ERROR: source rootfs is missing required member {name}")

    regular_bytes = sum(m.size for m in all_members if m.isfile())
    regular_files = sum(1 for m in all_members if m.isfile())

meta = {
    "version": version,
    "architecture": architecture,
    "flavor": flavor,
    "kernel_version": kernel_version,
    "rootfs_regular_bytes": regular_bytes,
    "rootfs_regular_files": regular_files,
}
out.write_text(json.dumps(meta, sort_keys=True) + "\n", encoding="utf-8")
print(f"    Version : {version}")
print(f"    Arch    : {architecture}")
print(f"    Flavor  : {flavor}")
print(f"    Kernel  : {kernel_version}")
print(f"    Files   : {regular_files}")
print(f"    Bytes   : {regular_bytes}")
PY

VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$META_JSON")"

info "Building matching A/B update bundle"
ROOT_SHA="$(sha256sum "$ROOTFS_PAYLOAD" | awk '{print $1}')"
BOOT_SHA="$(sha256sum "$BOOT_PAYLOAD" | awk '{print $1}')"
RUNTIME_SHA="$(sha256sum "$RUNTIME_PAYLOAD" | awk '{print $1}')"
ROOT_SIZE="$(stat -c '%s' "$ROOTFS_PAYLOAD")"
BOOT_SIZE="$(stat -c '%s' "$BOOT_PAYLOAD")"
RUNTIME_SIZE="$(stat -c '%s' "$RUNTIME_PAYLOAD")"
EPOCH="${SOURCE_DATE_EPOCH:-$(date +%s)}"

python3 - \
    "$META_JSON" "$STAGE/manifest.json" \
    "$ROOT_SHA" "$ROOT_SIZE" \
    "$BOOT_SHA" "$BOOT_SIZE" \
    "$RUNTIME_SHA" "$RUNTIME_SIZE" \
    "$SRC_NAME" "$SOURCE_SHA" "$EPOCH" <<'PY'
from datetime import datetime, timezone
import json
from pathlib import Path
import sys

meta = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
manifest_path = Path(sys.argv[2])
root_sha, root_size = sys.argv[3], int(sys.argv[4])
boot_sha, boot_size = sys.argv[5], int(sys.argv[6])
runtime_sha, runtime_size = sys.argv[7], int(sys.argv[8])
source_name, source_sha = sys.argv[9], sys.argv[10]
epoch = int(sys.argv[11])

manifest = {
    "format": "vyos-rpi-ab-update",
    "format_version": 2,
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
        "runtime": {
            "path": "payload/ab-runtime.tar",
            "archive": "tar",
            "sha256": runtime_sha,
            "size": runtime_size,
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
        "converted_from": source_name,
        "source_image_sha256": source_sha,
    },
}
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

(
    cd "$STAGE"
    sha256sum manifest.json payload/rootfs.tar.gz payload/boot.tar payload/ab-runtime.tar > SHA256SUMS
)

TMP_UPDATE="${OUT_UPDATE}.tmp.$$"
rm -f -- "$TMP_UPDATE"
tar -C "$STAGE" \
    --sort=name \
    --owner=0 --group=0 --numeric-owner \
    --mtime="@${EPOCH}" \
    -cf - \
    manifest.json SHA256SUMS payload/rootfs.tar.gz payload/boot.tar payload/ab-runtime.tar \
  | zstd -q -T0 "-${ZSTD_LEVEL}" -o "$TMP_UPDATE"
zstd -q -t "$TMP_UPDATE"

info "Creating empty A/B full-image disk (${AB_IMAGE_SIZE_MIB} MiB)"
truncate -s "${AB_IMAGE_SIZE_MIB}MiB" "$AB_RAW"
parted -s "$AB_RAW" mklabel msdos
parted -s "$AB_RAW" unit MiB mkpart primary fat32 1 65
parted -s "$AB_RAW" unit MiB mkpart primary fat32 65 577
parted -s "$AB_RAW" unit MiB mkpart primary fat32 577 1089
parted -s "$AB_RAW" unit MiB mkpart extended 1089 100%
parted -s "$AB_RAW" unit MiB mkpart logical ext4 1090 6722
parted -s "$AB_RAW" unit MiB mkpart logical ext4 6723 12355
parted -s "$AB_RAW" set 1 boot on
parted -s "$AB_RAW" set 1 lba on
parted -s "$AB_RAW" set 2 lba on
parted -s "$AB_RAW" set 3 lba on

AB_LOOP="$(losetup --find --show --partscan "$AB_RAW")"
sleep 1
for n in 1 2 3 5 6; do
    for _ in $(seq 1 20); do
        [[ -b "${AB_LOOP}p${n}" ]] && break
        sleep 0.2
    done
    [[ -b "${AB_LOOP}p${n}" ]] || fail "partition ${AB_LOOP}p${n} did not appear"
done

P1="${AB_LOOP}p1"
P2="${AB_LOOP}p2"
P3="${AB_LOOP}p3"
P5="${AB_LOOP}p5"
P6="${AB_LOOP}p6"

info "Formatting A/B filesystems"
mkfs.vfat -F 32 -n VYOS_AB "$P1" >/dev/null
mkfs.vfat -F 32 -n VYOS_BOOT_A "$P2" >/dev/null
mkfs.vfat -F 32 -n VYOS_BOOT_B "$P3" >/dev/null
mkfs.ext4 -F -q -m 0 -L VYOS_ROOT_A "$P5"
mkfs.ext4 -F -q -m 0 -L VYOS_ROOT_B "$P6"

ROOT_A_UUID="$(blkid -s UUID -o value "$P5")"
ROOT_B_UUID="$(blkid -s UUID -o value "$P6")"
BOOT_A_UUID="$(blkid -s UUID -o value "$P2")"
BOOT_B_UUID="$(blkid -s UUID -o value "$P3")"
ROOT_A_PARTUUID="$(blkid -s PARTUUID -o value "$P5")"
ROOT_B_PARTUUID="$(blkid -s PARTUUID -o value "$P6")"

[[ -n "$ROOT_A_UUID" && -n "$ROOT_B_UUID" && -n "$BOOT_A_UUID" && -n "$BOOT_B_UUID" ]] \
    || fail "could not determine newly created filesystem UUIDs"
[[ -n "$ROOT_A_PARTUUID" && -n "$ROOT_B_PARTUUID" ]] \
    || fail "could not determine newly created root PARTUUIDs"

mount "$P1" "$AB_CTL_MNT"
mount "$P2" "$AB_BOOT_A_MNT"
mount "$P3" "$AB_BOOT_B_MNT"
mount "$P5" "$AB_ROOT_A_MNT"
mount "$P6" "$AB_ROOT_B_MNT"

info "Populating ROOT-A and ROOT-B from the same source rootfs payload"
for root in "$AB_ROOT_A_MNT" "$AB_ROOT_B_MNT"; do
    rm -rf -- "$root/lost+found"
    tar -xzf "$ROOTFS_PAYLOAD" -C "$root" --numeric-owner --acls --xattrs
    tar -xf "$RUNTIME_PAYLOAD" -C "$root" --numeric-owner
    mkdir -p "$root/boot/firmware"
done

info "Populating BOOT-A and BOOT-B from the same source boot payload"
for boot in "$AB_BOOT_A_MNT" "$AB_BOOT_B_MNT"; do
    tar -xf "$BOOT_PAYLOAD" -C "$boot" --no-same-owner --no-same-permissions
 done

patch_root_slot() {
    local root="$1" slot="$2" root_uuid="$3" boot_uuid="$4"
    cat > "$root/etc/fstab" <<EOF_FSTAB
# VyOS Raspberry Pi A/B slot ${slot}
UUID=${root_uuid} / ext4 defaults,commit=120,errors=remount-ro 0 1
UUID=${boot_uuid} /boot/firmware vfat defaults 0 2
tmpfs /tmp tmpfs defaults,nosuid 0 0
EOF_FSTAB
    chmod 0644 "$root/etc/fstab"
    printf '%s\n' "$slot" > "$root/etc/vyos-pi-ab-slot"
    chmod 0644 "$root/etc/vyos-pi-ab-slot"

    local templates="$root/opt/vyatta/share/vyatta-op/templates/add/system/image"
    [[ -d "$templates" ]] || fail "slot $slot is missing add/system/image op-mode templates"
    python3 - "$templates" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
old = "${vyos_op_scripts_dir}/image_installer.py --action add"
new = "${vyos_op_scripts_dir}/vyos_pi_image_dispatch.py --action add"
count = 0
for path in sorted(root.rglob("node.def")):
    text = path.read_text(encoding="utf-8")
    n = text.count(old)
    if n:
        path.write_text(text.replace(old, new), encoding="utf-8")
        count += n
if count == 0:
    # A pre-patched source is acceptable only if every add leaf already goes
    # through our dispatcher.
    existing = 0
    for path in sorted(root.rglob("node.def")):
        existing += path.read_text(encoding="utf-8", errors="replace").count(new)
    if existing == 0:
        raise SystemExit("ERROR: no add system image route could be patched")
    count = existing
for path in sorted(root.rglob("node.def")):
    if old in path.read_text(encoding="utf-8", errors="replace"):
        raise SystemExit(f"ERROR: direct image_installer route remains: {path}")
print(count)
PY
}

patch_boot_slot() {
    local boot="$1" root_partuuid="$2"
    python3 - "$boot/cmdline.txt" "$root_partuuid" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
partuuid = sys.argv[2]
tokens = path.read_text(encoding="utf-8").replace("\r", " ").replace("\n", " ").split()
out = []
seen = False
for token in tokens:
    if token.startswith("root="):
        if not seen:
            out.append(f"root=PARTUUID={partuuid}")
            seen = True
        continue
    out.append(token)
if not seen:
    raise SystemExit(f"ERROR: no root= token in {path}")
for required in ("net.ifnames=0", "modprobe.blacklist=btusb,btmtk"):
    if required not in out:
        out.append(required)
path.write_text(" ".join(out) + "\n", encoding="utf-8")
PY

    python3 - "$boot/config.txt" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")
lines = [line.strip() for line in text.splitlines()]
if "dtparam=pciex1_gen=3" in lines:
    raise SystemExit("ERROR: boot config unexpectedly enables pciex1_gen=3")
required = ("dtparam=pciex1", "dtoverlay=pcie-32bit-dma-pi5")
missing = [line for line in required if line not in lines]
if missing:
    with path.open("a", encoding="utf-8") as f:
        f.write("\n[all]\n# Enable Raspberry Pi 5 external PCIe x1\n")
        for line in missing:
            f.write(line + "\n")
PY
}

info "Patching slot identities, fstab, CLI dispatcher and boot root=PARTUUID"
ROUTES_A="$(patch_root_slot "$AB_ROOT_A_MNT" A "$ROOT_A_UUID" "$BOOT_A_UUID")"
ROUTES_B="$(patch_root_slot "$AB_ROOT_B_MNT" B "$ROOT_B_UUID" "$BOOT_B_UUID")"
patch_boot_slot "$AB_BOOT_A_MNT" "$ROOT_A_PARTUUID"
patch_boot_slot "$AB_BOOT_B_MNT" "$ROOT_B_PARTUUID"

echo "    CLI routes A : $ROUTES_A"
echo "    CLI routes B : $ROUTES_B"

cat > "$AB_CTL_MNT/autoboot.txt" <<'AUTOBOOT'
[all]
tryboot_a_b=1
boot_partition=2

[tryboot]
boot_partition=3
AUTOBOOT

sync

info "Validating completed A/B image before compression"
python3 - \
    "$AB_CTL_MNT" "$AB_BOOT_A_MNT" "$AB_BOOT_B_MNT" \
    "$AB_ROOT_A_MNT" "$AB_ROOT_B_MNT" \
    "$ROOT_A_UUID" "$ROOT_B_UUID" "$BOOT_A_UUID" "$BOOT_B_UUID" \
    "$ROOT_A_PARTUUID" "$ROOT_B_PARTUUID" "$VERSION" <<'PY'
from pathlib import Path
import json
import os
import sys

ctl, ba, bb, ra, rb = map(Path, sys.argv[1:6])
root_a_uuid, root_b_uuid, boot_a_uuid, boot_b_uuid = sys.argv[6:10]
root_a_partuuid, root_b_partuuid, version = sys.argv[10:13]

expected_autoboot = "[all]\ntryboot_a_b=1\nboot_partition=2\n\n[tryboot]\nboot_partition=3\n"
if (ctl / "autoboot.txt").read_text(encoding="ascii") != expected_autoboot:
    raise SystemExit("ERROR: autoboot.txt validation failed")

for slot, root, boot, ruuid, buuid, rpart in (
    ("A", ra, ba, root_a_uuid, boot_a_uuid, root_a_partuuid),
    ("B", rb, bb, root_b_uuid, boot_b_uuid, root_b_partuuid),
):
    version_data = json.loads((root / "usr/share/vyos/version.json").read_text(encoding="utf-8"))
    if str(version_data.get("version", "")).strip() != version:
        raise SystemExit(f"ERROR: ROOT-{slot} version mismatch")
    if (root / "etc/vyos-pi-ab-slot").read_text(encoding="ascii").strip() != slot:
        raise SystemExit(f"ERROR: ROOT-{slot} slot marker mismatch")
    fstab = (root / "etc/fstab").read_text(encoding="utf-8")
    if f"UUID={ruuid} / ext4" not in fstab or f"UUID={buuid} /boot/firmware vfat" not in fstab:
        raise SystemExit(f"ERROR: ROOT-{slot} fstab mismatch")
    cmdline = (boot / "cmdline.txt").read_text(encoding="utf-8")
    if f"root=PARTUUID={rpart}" not in cmdline:
        raise SystemExit(f"ERROR: BOOT-{slot} root PARTUUID mismatch")
    for rel in (
        "usr/libexec/vyos/vyos-pi-ab-status.py",
        "usr/libexec/vyos/vyos-pi-ab-commit.py",
        "usr/libexec/vyos/vyos-pi-ab-healthcheck.py",
        "usr/libexec/vyos/vyos-pi-ab-auto-guard.py",
        "usr/libexec/vyos/install-vyos-pi-ab-update.py",
        "usr/libexec/vyos/op_mode/vyos_pi_image_dispatch.py",
    ):
        p = root / rel
        if not p.is_file() or not os.access(p, os.X_OK):
            raise SystemExit(f"ERROR: ROOT-{slot} missing/non-executable {rel}")
    unit = root / "etc/systemd/system/vyos-pi-ab-auto-guard.service"
    link = root / "etc/systemd/system/multi-user.target.wants/vyos-pi-ab-auto-guard.service"
    if not unit.is_file() or not link.is_symlink():
        raise SystemExit(f"ERROR: ROOT-{slot} auto-guard service is not installed/enabled")
    templates = root / "opt/vyatta/share/vyatta-op/templates/add/system/image"
    dispatcher = "${vyos_op_scripts_dir}/vyos_pi_image_dispatch.py --action add"
    upstream = "${vyos_op_scripts_dir}/image_installer.py --action add"
    routes = 0
    for node in templates.rglob("node.def"):
        text = node.read_text(encoding="utf-8", errors="replace")
        routes += text.count(dispatcher)
        if upstream in text:
            raise SystemExit(f"ERROR: ROOT-{slot} still has a direct upstream add-image route")
    if routes == 0:
        raise SystemExit(f"ERROR: ROOT-{slot} has no Pi A/B add-image dispatcher routes")

print("OK: A/B full-image offline validation passed")
PY

# Unmount before filesystem/image checks and compression.
for m in "$AB_ROOT_B_MNT" "$AB_ROOT_A_MNT" "$AB_BOOT_B_MNT" "$AB_BOOT_A_MNT" "$AB_CTL_MNT"; do
    sync
    umount "$m"
done

if command -v e2fsck >/dev/null 2>&1; then
    e2fsck -fn "$P5" >/dev/null || fail "ROOT-A e2fsck validation failed"
    e2fsck -fn "$P6" >/dev/null || fail "ROOT-B e2fsck validation failed"
fi
if command -v fsck.vfat >/dev/null 2>&1; then
    fsck.vfat -n "$P1" >/dev/null || fail "VYOS_AB FAT validation failed"
    fsck.vfat -n "$P2" >/dev/null || fail "BOOT-A FAT validation failed"
    fsck.vfat -n "$P3" >/dev/null || fail "BOOT-B FAT validation failed"
fi

losetup -d "$AB_LOOP"
AB_LOOP=""

info "Compressing A/B full image with xz level ${XZ_LEVEL}"
TMP_AB_XZ="${OUT_AB_XZ}.tmp.$$"
rm -f -- "$TMP_AB_XZ"
xz -T0 -"$XZ_LEVEL" -c -- "$AB_RAW" > "$TMP_AB_XZ"
xz -t "$TMP_AB_XZ"

if (( FORCE )); then
    rm -f -- "$OUT_AB_XZ" "$OUT_UPDATE"
fi
mv -- "$TMP_AB_XZ" "$OUT_AB_XZ"
mv -- "$TMP_UPDATE" "$OUT_UPDATE"

AB_SHA="$(sha256sum "$OUT_AB_XZ" | awk '{print $1}')"
UPDATE_SHA="$(sha256sum "$OUT_UPDATE" | awk '{print $1}')"

echo
info "Conversion complete"
echo "    VyOS version  : $VERSION"
echo "    Source image  : $SRC_NAME"
echo "    Source SHA256 : $SOURCE_SHA"
echo
echo "    A/B full image: $OUT_AB_XZ"
echo "    Size          : $(stat -c '%s' "$OUT_AB_XZ") bytes"
echo "    SHA256        : $AB_SHA"
echo
echo "    Update bundle : $OUT_UPDATE"
echo "    Size          : $(stat -c '%s' "$OUT_UPDATE") bytes"
echo "    SHA256        : $UPDATE_SHA"
echo
echo "    Layout        : p1 VYOS_AB, p2/p3 BOOT_A/B, p5/p6 ROOT_A/B"
echo "    Initial boot  : slot A default, slot B one-shot tryboot target"
echo
