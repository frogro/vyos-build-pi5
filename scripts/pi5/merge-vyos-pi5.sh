#!/bin/bash
set -euo pipefail

# Merge a pinned Armbian Raspberry Pi hardware base into a VyOS Rolling ARM64
# root filesystem.
#
# The Raspberry Pi firmware partition itself is NOT modified here. This script
# only produces a merged rootfs tarball for build-vyos-pi5-image.sh.
#
# Usage:
#   sudo ./scripts/pi5/merge-vyos-pi5.sh \
#     /path/to/armbian-pi5.img.xz \
#     /path/to/vyos-rootfs.tar.gz \
#     /path/to/output-dir

ARMBIAN_IMAGE="${1:?Armbian .img.xz or .img is missing}"
VYOS_TAR="${2:?VyOS rootfs tar is missing}"
OUTDIR="${3:?Output directory is missing}"

[[ $EUID -eq 0 ]] || {
    echo "ERROR: run this script as root." >&2
    exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FIRSTBOOT_DIR="${SCRIPT_DIR}/first-boot"
BASE_ENV="${PI5_BASE_ENV:-${REPO_ROOT}/config/pi5-armbian-base.env}"
NETWORK_FW_SCRIPT="${SCRIPT_DIR}/install-network-firmware.sh"
INJECT_SCRIPT="${SCRIPT_DIR}/inject-defaults.sh"
BRCM_FW_CHECK="${SCRIPT_DIR}/validate-brcm43455-firmware.py"

for cmd in xz losetup lsblk blkid mount umount mountpoint tar rsync sha256sum \
           grep awk find install readlink git python3; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: required command is missing: $cmd" >&2
        exit 1
    }
done

[[ -f "$ARMBIAN_IMAGE" ]] || {
    echo "ERROR: Armbian image not found: $ARMBIAN_IMAGE" >&2
    exit 1
}
[[ -f "$VYOS_TAR" ]] || {
    echo "ERROR: VyOS rootfs tar not found: $VYOS_TAR" >&2
    exit 1
}
[[ -f "$BASE_ENV" ]] || {
    echo "ERROR: Pi 5 base config not found: $BASE_ENV" >&2
    exit 1
}
[[ -x "$NETWORK_FW_SCRIPT" ]] || {
    echo "ERROR: network firmware installer is missing/not executable: $NETWORK_FW_SCRIPT" >&2
    exit 1
}
[[ -x "$INJECT_SCRIPT" ]] || {
    echo "ERROR: defaults injector is missing/not executable: $INJECT_SCRIPT" >&2
    exit 1
}
[[ -x "$BRCM_FW_CHECK" ]] || {
    echo "ERROR: BCM43455 firmware validator is missing/not executable: $BRCM_FW_CHECK" >&2
    exit 1
}
[[ -d "$FIRSTBOOT_DIR" ]] || {
    echo "ERROR: first-boot directory not found: $FIRSTBOOT_DIR" >&2
    exit 1
}

# shellcheck disable=SC1090
source "$BASE_ENV"

WORK="$(mktemp -d)"
BASE_IMG="${WORK}/armbian-base.img"
BASE_ROOT="${WORK}/armbian-root"
BASE_BOOT="${WORK}/armbian-boot"
VYOS_ROOT="${WORK}/vyos-root"
LOOPDEV=""

cleanup() {
    set +e
    mountpoint -q "$BASE_BOOT" && umount "$BASE_BOOT"
    mountpoint -q "$BASE_ROOT" && umount "$BASE_ROOT"
    [[ -n "$LOOPDEV" ]] && losetup -d "$LOOPDEV" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

verify_pinned_base() {
    local actual expected=""
    actual="$(sha256_file "$ARMBIAN_IMAGE")"

    case "$ARMBIAN_IMAGE" in
        *.xz)
            expected="${ARMBIAN_BASE_SHA256:-}"
            ;;
        *.img)
            expected="${ARMBIAN_ORIGINAL_SHA256:-}"
            ;;
    esac

    [[ -n "$expected" ]] || fail "no pinned SHA-256 available for input type: $ARMBIAN_IMAGE"
    [[ "$actual" == "$expected" ]] || {
        echo "Expected: $expected" >&2
        echo "Actual:   $actual" >&2
        fail "Armbian base SHA-256 mismatch"
    }

    echo "==> Pinned Armbian base SHA-256 OK: $actual"
}

extract_base_image() {
    case "$ARMBIAN_IMAGE" in
        *.xz)
            echo "==> Extracting pinned Armbian base image"
            xz -dc -- "$ARMBIAN_IMAGE" > "$BASE_IMG"
            ;;
        *.img)
            echo "==> Copying pinned Armbian base image"
            cp --reflink=auto --sparse=always -- "$ARMBIAN_IMAGE" "$BASE_IMG"
            ;;
        *)
            fail "unsupported Armbian image format (use .img.xz or .img)"
            ;;
    esac
}

attach_base_read_only() {
    LOOPDEV="$(losetup --find --show --partscan --read-only "$BASE_IMG")"
    command -v udevadm >/dev/null 2>&1 && udevadm settle || true
    sleep 1
}

validate_partition_layout() {
    local pttype count p1type p1label p2type p2label
    pttype="$(blkid -s PTTYPE -o value "$LOOPDEV" 2>/dev/null || true)"
    count="$(lsblk -ln -o TYPE "$LOOPDEV" | awk '$1=="part"{n++} END{print n+0}')"

    [[ "$pttype" == "dos" ]] || fail "expected DOS/MBR partition table, got: ${pttype:-unknown}"
    [[ "$count" -eq 2 ]] || fail "expected exactly 2 partitions, got: $count"
    [[ -b "${LOOPDEV}p1" ]] || fail "missing partition 1"
    [[ -b "${LOOPDEV}p2" ]] || fail "missing partition 2"

    p1type="$(blkid -s TYPE -o value "${LOOPDEV}p1" 2>/dev/null || true)"
    p1label="$(blkid -s LABEL -o value "${LOOPDEV}p1" 2>/dev/null || true)"
    p2type="$(blkid -s TYPE -o value "${LOOPDEV}p2" 2>/dev/null || true)"
    p2label="$(blkid -s LABEL -o value "${LOOPDEV}p2" 2>/dev/null || true)"

    [[ "$p1type" == "vfat" ]] || fail "partition 1 must be vfat, got: ${p1type:-unknown}"
    [[ "$p1label" == "RPICFG" ]] || fail "partition 1 must be labeled RPICFG, got: ${p1label:-none}"
    [[ "$p2type" == "ext4" ]] || fail "partition 2 must be ext4, got: ${p2type:-unknown}"
    [[ "$p2label" == "armbi_root" ]] || fail "partition 2 must be labeled armbi_root, got: ${p2label:-none}"

    echo "==> Base layout OK: MBR, p1=vfat/RPICFG, p2=ext4/armbi_root"
}

verify_base_boot_sync() {
    local image_target kver dtb_target
    local boot_kernel root_kernel boot_initrd root_initrd boot_dtb root_dtb

    image_target="$(readlink "$BASE_ROOT/boot/Image" 2>/dev/null || true)"
    [[ "$image_target" == vmlinuz-* ]] || fail "unexpected /boot/Image symlink: ${image_target:-missing}"
    kver="${image_target#vmlinuz-}"

    [[ -d "$BASE_ROOT/usr/lib/modules/$kver" ]] || fail "kernel modules missing for $kver"

    boot_kernel="$BASE_BOOT/vmlinuz"
    root_kernel="$BASE_ROOT/boot/vmlinuz-$kver"
    boot_initrd="$BASE_BOOT/initrd.img"
    root_initrd="$BASE_ROOT/boot/initrd.img-$kver"
    boot_dtb="$BASE_BOOT/bcm2712-rpi-5-b.dtb"

    dtb_target="$(readlink "$BASE_ROOT/boot/dtb" 2>/dev/null || true)"
    [[ -n "$dtb_target" ]] || fail "missing /boot/dtb symlink"
    root_dtb="$BASE_ROOT/boot/$dtb_target/broadcom/bcm2712-rpi-5-b.dtb"

    for f in "$boot_kernel" "$root_kernel" "$boot_initrd" "$root_initrd" "$boot_dtb" "$root_dtb"; do
        [[ -f "$f" ]] || fail "required Pi 5 boot file missing: $f"
    done

    [[ "$(sha256_file "$boot_kernel")" == "$(sha256_file "$root_kernel")" ]] \
        || fail "FAT/root kernel mismatch"
    [[ "$(sha256_file "$boot_initrd")" == "$(sha256_file "$root_initrd")" ]] \
        || fail "FAT/root initrd mismatch"
    [[ "$(sha256_file "$boot_dtb")" == "$(sha256_file "$root_dtb")" ]] \
        || fail "FAT/root Pi 5 DTB mismatch"

    grep -Eq '^[[:space:]]*kernel=vmlinuz[[:space:]]*$' "$BASE_BOOT/config.txt" \
        || fail "config.txt does not select kernel=vmlinuz"
    grep -Eq '^[[:space:]]*initramfs[[:space:]]+initrd\.img[[:space:]]+followkernel[[:space:]]*$' "$BASE_BOOT/config.txt" \
        || fail "config.txt does not select initrd.img"
    grep -Eq '(^|[[:space:]])root=LABEL=armbi_root([[:space:]]|$)' "$BASE_BOOT/cmdline.txt" \
        || fail "cmdline.txt does not use root=LABEL=armbi_root"
    grep -Eq '[[:space:]]/boot/firmware[[:space:]]+vfat[[:space:]]' "$BASE_ROOT/etc/fstab" \
        || fail "Armbian fstab does not mount the firmware partition on /boot/firmware"

    KVER="$kver"
    export KVER
    echo "==> Pi 5 boot/root synchronization OK; kernel: $KVER"
}

verify_pinned_base
extract_base_image
attach_base_read_only
validate_partition_layout

mkdir -p "$BASE_ROOT" "$BASE_BOOT"
mount -o ro,noload "${LOOPDEV}p2" "$BASE_ROOT"
mount -o ro "${LOOPDEV}p1" "$BASE_BOOT"

verify_base_boot_sync

echo "==> Extracting VyOS root filesystem"
mkdir -p "$VYOS_ROOT"
tar \
    --numeric-owner \
    --acls \
    --xattrs \
    --xattrs-include='*' \
    -xpf "$VYOS_TAR" \
    -C "$VYOS_ROOT"

# The current VyOS/Armbian roots use usrmerge. Failing here is safer than
# silently placing kernel modules where the running kernel will not find them.
[[ -L "$VYOS_ROOT/lib" ]] || fail "VyOS rootfs is not usrmerge: /lib is not a symlink"
[[ "$(readlink "$VYOS_ROOT/lib")" == "usr/lib" ]] \
    || fail "unexpected VyOS /lib symlink target: $(readlink "$VYOS_ROOT/lib")"

echo "==> Replacing VyOS kernel modules with Armbian Pi 5 kernel modules"
rm -rf "$VYOS_ROOT/usr/lib/modules"
mkdir -p "$VYOS_ROOT/usr/lib/modules"
rsync -aHAX "$BASE_ROOT/usr/lib/modules/$KVER/" "$VYOS_ROOT/usr/lib/modules/$KVER/"

echo "==> Replacing VyOS firmware with the Armbian firmware tree"
rm -rf "$VYOS_ROOT/usr/lib/firmware"
mkdir -p "$VYOS_ROOT/usr/lib/firmware"
rsync -aHAX "$BASE_ROOT/usr/lib/firmware/" "$VYOS_ROOT/usr/lib/firmware/"

echo "==> Adding pinned missing-only network firmware"
"$NETWORK_FW_SCRIPT" "$VYOS_ROOT"

echo "==> Repairing/validating Raspberry Pi BCM43455 firmware links"
python3 "$BRCM_FW_CHECK" "$VYOS_ROOT" --repair

echo "==> Preserving Armbian /boot tree"
rm -rf "$VYOS_ROOT/boot"
mkdir -p "$VYOS_ROOT/boot"
rsync -aHAX "$BASE_ROOT/boot/" "$VYOS_ROOT/boot/"
mkdir -p "$VYOS_ROOT/boot/firmware"

echo "==> Preserving Armbian fstab"
install -D -m 0644 "$BASE_ROOT/etc/fstab" "$VYOS_ROOT/etc/fstab"

echo "==> Removing VyOS live-image persistence marker"
rm -f "$VYOS_ROOT/persistence.conf" 2>/dev/null || true

echo "==> Injecting Raspberry Pi 5 defaults and first-boot services"
"$INJECT_SCRIPT" "$VYOS_ROOT" "$FIRSTBOOT_DIR"

# Final rootfs sanity checks before packing.
[[ -d "$VYOS_ROOT/usr/lib/modules/$KVER" ]] || fail "final kernel module tree missing"
[[ -f "$VYOS_ROOT/boot/vmlinuz-$KVER" ]] || fail "final root /boot kernel missing"
[[ -f "$VYOS_ROOT/boot/initrd.img-$KVER" ]] || fail "final root /boot initrd missing"
[[ -f "$VYOS_ROOT/boot/dtb-$KVER/broadcom/bcm2712-rpi-5-b.dtb" ]] \
    || fail "final Pi 5 DTB missing"
[[ -f "$VYOS_ROOT/config/config.boot" ]] || fail "VyOS config.boot missing after injection"
[[ -L "$VYOS_ROOT/etc/systemd/system/timers.target.wants/pi5-dhcp-wan-firstboot.timer" ]] \
    || fail "Pi 5 first-boot timer is not enabled"
grep -Eq '[[:space:]]/boot/firmware[[:space:]]+vfat[[:space:]]' "$VYOS_ROOT/etc/fstab" \
    || fail "final fstab lost the Raspberry Pi firmware mount"

echo "==> Final BCM43455 firmware validation"
python3 "$BRCM_FW_CHECK" "$VYOS_ROOT" --check-only

mkdir -p "$OUTDIR"
OUT_TAR="${OUTDIR}/vyos-rootfs-pi5-merged.tar.gz"
TMP_TAR="${OUT_TAR}.tmp"

echo "==> Packing merged Raspberry Pi 5 VyOS root filesystem"
rm -f "$TMP_TAR"
tar \
    --numeric-owner \
    --acls \
    --xattrs \
    --xattrs-include='*' \
    -czpf "$TMP_TAR" \
    -C "$VYOS_ROOT" .
mv -f "$TMP_TAR" "$OUT_TAR"

MANIFEST="${OUTDIR}/pi5-base-manifest.txt"
{
    echo "ARMBIAN_VERSION=${ARMBIAN_VERSION:-unknown}"
    echo "ARMBIAN_RELEASE=${ARMBIAN_RELEASE:-unknown}"
    echo "ARMBIAN_BRANCH=${ARMBIAN_BRANCH:-unknown}"
    echo "ARMBIAN_KERNEL_CONFIG=${ARMBIAN_KERNEL:-unknown}"
    echo "ARMBIAN_BUILD_BOARD=${ARMBIAN_BUILD_BOARD:-unknown}"
    echo "KERNEL_VERSION=$KVER"
    echo "PARTITION_TABLE=dos"
    echo "BOOT_LABEL=RPICFG"
    echo "ROOT_LABEL=armbi_root"
    echo "BOOT_KERNEL_SHA256=$(sha256_file "$BASE_BOOT/vmlinuz")"
    echo "BOOT_INITRD_SHA256=$(sha256_file "$BASE_BOOT/initrd.img")"
    echo "PI5_DTB_SHA256=$(sha256_file "$BASE_BOOT/bcm2712-rpi-5-b.dtb")"
    echo "MERGED_ROOTFS_SHA256=$(sha256_file "$OUT_TAR")"
} > "$MANIFEST"

echo
echo "==> Merge complete"
echo "    Rootfs:   $OUT_TAR"
echo "    Manifest: $MANIFEST"
