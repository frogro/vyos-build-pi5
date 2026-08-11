#!/bin/bash
set -euo pipefail

# Build a flashable Raspberry Pi 5 VyOS image from:
#   1) the pinned Armbian Pi hardware-base image
#   2) a merged VyOS rootfs produced by merge-vyos-pi5.sh
#
# The original MBR and p1 Raspberry Pi firmware partition are preserved
# byte-for-byte. Only p2 is extended and its filesystem contents are replaced.
#
# Usage:
#   sudo ./scripts/pi5/build-vyos-pi5-image.sh \
#     /path/to/armbian-pi5.img.xz \
#     /path/to/vyos-rootfs-pi5-merged.tar.gz \
#     /path/to/vyos-pi5-fresh.img
#
# Optional:
#   IMAGE_SIZE_GIB=6   Final image size in GiB (default: 6)

ARMBIAN_IMAGE="${1:?Armbian .img.xz or .img is missing}"
MERGED_TAR="${2:?Merged Pi 5 VyOS rootfs tar is missing}"
OUT_IMG="${3:?Output image path is missing}"
IMAGE_SIZE_GIB="${IMAGE_SIZE_GIB:-6}"

[[ $EUID -eq 0 ]] || {
    echo "ERROR: run this script as root." >&2
    exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BASE_ENV="${PI5_BASE_ENV:-${REPO_ROOT}/config/pi5-armbian-base.env}"

for cmd in xz truncate stat losetup lsblk blkid parted e2fsck resize2fs \
           mount umount mountpoint tar sha256sum grep awk readlink sync; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: required command is missing: $cmd" >&2
        exit 1
    }
done

[[ -f "$ARMBIAN_IMAGE" ]] || {
    echo "ERROR: Armbian image not found: $ARMBIAN_IMAGE" >&2
    exit 1
}
[[ -f "$MERGED_TAR" ]] || {
    echo "ERROR: merged rootfs not found: $MERGED_TAR" >&2
    exit 1
}
[[ -f "$BASE_ENV" ]] || {
    echo "ERROR: Pi 5 base config not found: $BASE_ENV" >&2
    exit 1
}
[[ "$IMAGE_SIZE_GIB" =~ ^[0-9]+$ ]] || {
    echo "ERROR: IMAGE_SIZE_GIB must be an integer." >&2
    exit 1
}
(( IMAGE_SIZE_GIB >= 3 )) || {
    echo "ERROR: IMAGE_SIZE_GIB must be at least 3 GiB." >&2
    exit 1
}

if [[ -e "$OUT_IMG" && "${FORCE:-0}" != "1" ]]; then
    echo "ERROR: output already exists: $OUT_IMG" >&2
    echo "       Remove it first or use FORCE=1." >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$BASE_ENV"

WORK="$(mktemp -d)"
IMG="${WORK}/pi5.img"
ROOT_MNT="${WORK}/root"
BOOT_MNT="${WORK}/boot"
LOOPDEV=""
P1_SHA_BEFORE=""

cleanup() {
    set +e
    mountpoint -q "$BOOT_MNT" && umount "$BOOT_MNT"
    mountpoint -q "$ROOT_MNT" && umount "$ROOT_MNT"
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

sha256_blockdev() {
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
            echo "==> Extracting pinned Armbian base"
            xz -dc -- "$ARMBIAN_IMAGE" > "$IMG"
            ;;
        *.img)
            echo "==> Copying pinned Armbian base"
            cp --reflink=auto --sparse=always -- "$ARMBIAN_IMAGE" "$IMG"
            ;;
        *)
            fail "unsupported Armbian image format (use .img.xz or .img)"
            ;;
    esac
}

attach_rw() {
    LOOPDEV="$(losetup --find --show --partscan "$IMG")"
    command -v udevadm >/dev/null 2>&1 && udevadm settle || true
    sleep 1
}

detach_loop() {
    [[ -n "$LOOPDEV" ]] || return 0
    losetup -d "$LOOPDEV"
    LOOPDEV=""
}

validate_layout() {
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
}

run_e2fsck() {
    local dev="$1" rc
    set +e
    e2fsck -f -p "$dev"
    rc=$?
    set -e

    case "$rc" in
        0|1) ;;
        *) fail "e2fsck failed on $dev with exit code $rc" ;;
    esac
}

verify_final_image() {
    local image_target kver dtb_target
    local boot_kernel root_kernel boot_initrd root_initrd boot_dtb root_dtb
    local p1_sha_after

    validate_layout

    mkdir -p "$ROOT_MNT" "$BOOT_MNT"
    mount -o ro,noload "${LOOPDEV}p2" "$ROOT_MNT"
    mount -o ro "${LOOPDEV}p1" "$BOOT_MNT"

    grep -Eq '^[[:space:]]*kernel=vmlinuz[[:space:]]*$' "$BOOT_MNT/config.txt" \
        || fail "final config.txt does not select kernel=vmlinuz"
    grep -Eq '^[[:space:]]*initramfs[[:space:]]+initrd\.img[[:space:]]+followkernel[[:space:]]*$' "$BOOT_MNT/config.txt" \
        || fail "final config.txt does not select initrd.img"
    grep -Eq '(^|[[:space:]])root=LABEL=armbi_root([[:space:]]|$)' "$BOOT_MNT/cmdline.txt" \
        || fail "final cmdline.txt lost root=LABEL=armbi_root"

    grep -Eq '[[:space:]]/boot/firmware[[:space:]]+vfat[[:space:]]' "$ROOT_MNT/etc/fstab" \
        || fail "final fstab does not mount RPICFG on /boot/firmware"

    image_target="$(readlink "$ROOT_MNT/boot/Image" 2>/dev/null || true)"
    [[ "$image_target" == vmlinuz-* ]] || fail "final /boot/Image symlink is invalid"
    kver="${image_target#vmlinuz-}"

    [[ -d "$ROOT_MNT/usr/lib/modules/$kver" ]] || fail "final kernel modules missing for $kver"

    boot_kernel="$BOOT_MNT/vmlinuz"
    root_kernel="$ROOT_MNT/boot/vmlinuz-$kver"
    boot_initrd="$BOOT_MNT/initrd.img"
    root_initrd="$ROOT_MNT/boot/initrd.img-$kver"
    boot_dtb="$BOOT_MNT/bcm2712-rpi-5-b.dtb"

    dtb_target="$(readlink "$ROOT_MNT/boot/dtb" 2>/dev/null || true)"
    [[ -n "$dtb_target" ]] || fail "final /boot/dtb symlink missing"
    root_dtb="$ROOT_MNT/boot/$dtb_target/broadcom/bcm2712-rpi-5-b.dtb"

    for f in "$boot_kernel" "$root_kernel" "$boot_initrd" "$root_initrd" "$boot_dtb" "$root_dtb"; do
        [[ -f "$f" ]] || fail "required final boot file missing: $f"
    done

    [[ "$(sha256_file "$boot_kernel")" == "$(sha256_file "$root_kernel")" ]] \
        || fail "final FAT/root kernel mismatch"
    [[ "$(sha256_file "$boot_initrd")" == "$(sha256_file "$root_initrd")" ]] \
        || fail "final FAT/root initrd mismatch"
    [[ "$(sha256_file "$boot_dtb")" == "$(sha256_file "$root_dtb")" ]] \
        || fail "final FAT/root Pi 5 DTB mismatch"

    [[ -f "$ROOT_MNT/config/config.boot" ]] || fail "final VyOS config.boot missing"
    [[ -L "$ROOT_MNT/etc/systemd/system/timers.target.wants/pi5-dhcp-wan-firstboot.timer" ]] \
        || fail "final Pi 5 first-boot timer is not enabled"
    [[ -x "$ROOT_MNT/home/vyos/ap-dhcp-wan-setup.sh" ]] \
        || fail "final AP setup helper missing"

    # Verify critical supplemental firmware that the merge step is expected to add.
    for rel in \
        mediatek/WIFI_RAM_CODE_MT7922_1.bin \
        mediatek/WIFI_MT7922_patch_mcu_1_1_hdr.bin \
        rtw89/rtw8852b_fw-2.bin \
        rtl_nic/rtl8125b-2.fw; do
        [[ -e "$ROOT_MNT/usr/lib/firmware/$rel" || -L "$ROOT_MNT/usr/lib/firmware/$rel" ]] \
            || fail "critical final network firmware missing: $rel"
    done

    p1_sha_after="$(sha256_blockdev "${LOOPDEV}p1")"
    [[ "$p1_sha_after" == "$P1_SHA_BEFORE" ]] || {
        echo "Before: $P1_SHA_BEFORE" >&2
        echo "After:  $p1_sha_after" >&2
        fail "RPICFG partition changed during image build"
    }

    echo "==> Final image validation OK"
    echo "    Kernel: $kver"
    echo "    RPICFG SHA-256 unchanged: $p1_sha_after"

    sync
    umount "$BOOT_MNT"
    umount "$ROOT_MNT"
}

verify_pinned_base
extract_base_image

original_bytes="$(stat -c '%s' "$IMG")"
target_bytes=$(( IMAGE_SIZE_GIB * 1024 * 1024 * 1024 ))

if (( original_bytes < target_bytes )); then
    echo "==> Growing image to ${IMAGE_SIZE_GIB} GiB"
    truncate -s "$target_bytes" "$IMG"
else
    echo "==> Base image is already >= ${IMAGE_SIZE_GIB} GiB; keeping current size"
fi

attach_rw
validate_layout
P1_SHA_BEFORE="$(sha256_blockdev "${LOOPDEV}p1")"
echo "==> Original RPICFG partition SHA-256: $P1_SHA_BEFORE"

echo "==> Extending p2 (armbi_root) to the end of the MBR image"
parted -s "$LOOPDEV" resizepart 2 100%

# Reattach so the kernel sees the new p2 end reliably.
detach_loop
attach_rw
validate_layout

ROOTPART="${LOOPDEV}p2"
echo "==> Checking and growing ext4 filesystem: $ROOTPART"
run_e2fsck "$ROOTPART"
resize2fs "$ROOTPART"

mkdir -p "$ROOT_MNT"
mount "$ROOTPART" "$ROOT_MNT"

echo "==> Replacing Armbian root filesystem contents with merged VyOS rootfs"
find "$ROOT_MNT" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +

tar \
    --numeric-owner \
    --acls \
    --xattrs \
    --xattrs-include='*' \
    -xpf "$MERGED_TAR" \
    -C "$ROOT_MNT"

sync
umount "$ROOT_MNT"

echo "==> Running final Pi 5 image validation"
verify_final_image

detach_loop

mkdir -p "$(dirname "$OUT_IMG")"
if [[ -e "$OUT_IMG" ]]; then
    rm -f "$OUT_IMG"
fi
mv "$IMG" "$OUT_IMG"

FINAL_SHA="$(sha256_file "$OUT_IMG")"

echo
echo "==> Raspberry Pi 5 VyOS image complete"
echo "    Image:  $OUT_IMG"
echo "    Size:   $(stat -c '%s' "$OUT_IMG") bytes"
echo "    SHA256: $FINAL_SHA"
