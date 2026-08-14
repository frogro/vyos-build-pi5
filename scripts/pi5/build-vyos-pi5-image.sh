#!/bin/bash
set -euo pipefail

# Build the production Raspberry Pi VyOS A/B release image from:
#   1) the pinned Armbian Raspberry Pi hardware-base image (boot template)
#   2) a merged VyOS rootfs produced by merge-vyos-pi5.sh
#
# Disk layout (DOS/MBR):
#   p1  VYOS_AB       FAT32   control partition with autoboot.txt
#   p2  VYOS_BOOT_A   FAT32   boot files for slot A
#   p3  VYOS_BOOT_B   FAT32   boot files for slot B
#   p4                extended partition container
#   p5  VYOS_ROOT_A   ext4    VyOS root/config for slot A
#   p6  VYOS_ROOT_B   ext4    VyOS root/config for slot B
#
# Initial policy:
#   normal boot -> A (p2 + p5)
#   reboot '0 tryboot' -> B once (p3 + p6)
#   automatic watchdog guard commits a healthy tryboot slot and rolls back
#   automatically if the health check fails.
#
# This builder NEVER writes to a physical SD/eMMC/NVMe device. It only creates
# and modifies OUT_IMG and opens the Armbian source image read-only.
#
# Usage:
#   sudo ./scripts/pi5/build-vyos-pi5-image.sh \
#     /path/to/armbian.img.xz \
#     /path/to/vyos-rootfs-pi5-merged.tar.gz \
#     /path/to/vyos-VERSION-rpi-arm64.img
#
# Optional environment variables:
#   AB_IMAGE_SIZE_MIB=12360 final image size in MiB (default: 12360)
#   AB_CONTROL_MIB=64       p1 size (default: 64; FAT32-safe)
#   AB_BOOT_MIB=512         p2/p3 size each (default: 512)
#   AB_ROOT_MIB=5632        p5/p6 size each (default: 5632 = 5.5 GiB)
#   FORCE=1                 replace an existing OUT_IMG

ARMBIAN_IMAGE="${1:?Armbian .img.xz or .img is missing}"
MERGED_TAR="${2:?Merged Raspberry Pi VyOS rootfs tar is missing}"
OUT_IMG="${3:?Output image path is missing}"

AB_IMAGE_SIZE_MIB="${AB_IMAGE_SIZE_MIB:-12360}"
AB_CONTROL_MIB="${AB_CONTROL_MIB:-64}"
AB_BOOT_MIB="${AB_BOOT_MIB:-512}"
AB_ROOT_MIB="${AB_ROOT_MIB:-5632}"

[[ $EUID -eq 0 ]] || {
    echo "ERROR: run this script as root." >&2
    exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BASE_ENV="${PI5_BASE_ENV:-${REPO_ROOT}/config/pi5-armbian-base.env}"
BRCM_FW_CHECK="${SCRIPT_DIR}/validate-brcm43455-firmware.py"

for cmd in xz truncate stat losetup lsblk blkid parted mkfs.vfat mkfs.ext4 \
           mount umount mountpoint tar rsync sha256sum grep awk readlink \
           sync python3 find rm mkdir mv cp tr sed install ln chmod e2fsck fsck.vfat; do
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
[[ -x "$BRCM_FW_CHECK" ]] || fail "BCM43455 firmware validator missing/not executable: $BRCM_FW_CHECK"
[[ ! -b "$OUT_IMG" ]] || fail "OUT_IMG must be a regular image file, never a block device: $OUT_IMG"

for runtime_script in \
    vyos-pi-ab-status.py \
    vyos-pi-ab-commit.py \
    vyos-pi-ab-healthcheck.py \
    vyos-pi-ab-auto-guard.py \
    install-vyos-pi-ab-update.py \
    vyos-pi-image-dispatch.py; do
    [[ -f "${SCRIPT_DIR}/${runtime_script}" ]] \
        || fail "required A/B runtime source is missing: ${SCRIPT_DIR}/${runtime_script}"
done

python3 - "$SCRIPT_DIR" <<'PY_RUNTIME_SYNTAX'
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
PY_RUNTIME_SYNTAX

for n in "$AB_IMAGE_SIZE_MIB" "$AB_CONTROL_MIB" "$AB_BOOT_MIB" "$AB_ROOT_MIB"; do
    [[ "$n" =~ ^[0-9]+$ ]] || fail "image/partition sizes must be positive integers"
done

(( AB_IMAGE_SIZE_MIB >= 12360 )) || fail "AB_IMAGE_SIZE_MIB must be >= 12360"
(( AB_CONTROL_MIB >= 64 )) || fail "AB_CONTROL_MIB must be >= 64 for this FAT32 control partition"
(( AB_BOOT_MIB >= 256 )) || fail "AB_BOOT_MIB must be >= 256"
(( AB_ROOT_MIB >= 1024 )) || fail "AB_ROOT_MIB must be >= 1024"

if [[ -e "$OUT_IMG" && "${FORCE:-0}" != "1" ]]; then
    echo "ERROR: output already exists: $OUT_IMG" >&2
    echo "       Remove it first or use FORCE=1." >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$BASE_ENV"

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

partdev() {
    local loop="$1" number="$2"
    printf '%sp%s\n' "$loop" "$number"
}

fs_uuid() {
    blkid -s UUID -o value "$1"
}

part_uuid() {
    blkid -s PARTUUID -o value "$1"
}

# Geometry in MiB. Leave 1 MiB before p1 for the MBR/alignment. Logical
# partitions start 1 MiB inside/after their container boundaries.
P1_START=1
P1_END=$(( P1_START + AB_CONTROL_MIB ))
P2_START=$P1_END
P2_END=$(( P2_START + AB_BOOT_MIB ))
P3_START=$P2_END
P3_END=$(( P3_START + AB_BOOT_MIB ))
P4_START=$P3_END
P5_START=$(( P4_START + 1 ))
P5_END=$(( P5_START + AB_ROOT_MIB ))
P6_START=$(( P5_END + 1 ))
P6_END=$(( P6_START + AB_ROOT_MIB ))
TOTAL_MIB=$AB_IMAGE_SIZE_MIB
P4_END=$(( TOTAL_MIB - 1 ))

(( P6_END < P4_END )) || {
    fail "AB_IMAGE_SIZE_MIB=${AB_IMAGE_SIZE_MIB} is too small for the requested A/B slots (p6 ends at ${P6_END} MiB)"
}

OUT_DIR="$(dirname "$OUT_IMG")"
mkdir -p "$OUT_DIR"
WORK="$(mktemp -d "${OUT_DIR%/}/.vyos-pi-ab-build.XXXXXX")"
SRC_IMG="${WORK}/armbian-source.img"
IMG="${WORK}/vyos-pi-ab.img"
SRC_BOOT_MNT="${WORK}/source-boot"
CTRL_MNT="${WORK}/control"
BOOT_MNT="${WORK}/boot"
ROOT_MNT="${WORK}/root"
SRC_LOOP=""
OUT_LOOP=""

mkdir -p "$SRC_BOOT_MNT" "$CTRL_MNT" "$BOOT_MNT" "$ROOT_MNT"

cleanup() {
    set +e
    for m in "$ROOT_MNT" "$BOOT_MNT" "$CTRL_MNT" "$SRC_BOOT_MNT"; do
        mountpoint -q "$m" && umount "$m"
    done
    [[ -n "$OUT_LOOP" ]] && losetup -d "$OUT_LOOP" 2>/dev/null
    [[ -n "$SRC_LOOP" ]] && losetup -d "$SRC_LOOP" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

settle_partitions() {
    command -v udevadm >/dev/null 2>&1 && udevadm settle || true
    sleep 1
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
    echo "==> Pinned Armbian base SHA-256 OK: $actual"
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

validate_source_base() {
    local pttype p1type p1label
    local p1
    p1="$(partdev "$SRC_LOOP" 1)"

    pttype="$(blkid -s PTTYPE -o value "$SRC_LOOP" 2>/dev/null || true)"
    [[ "$pttype" == "dos" ]] || fail "pinned base must use DOS/MBR, got: ${pttype:-unknown}"
    [[ -b "$p1" ]] || fail "pinned base is missing partition 1"

    p1type="$(blkid -s TYPE -o value "$p1" 2>/dev/null || true)"
    p1label="$(blkid -s LABEL -o value "$p1" 2>/dev/null || true)"
    [[ "$p1type" == "vfat" ]] || fail "pinned base p1 must be vfat, got: ${p1type:-unknown}"
    [[ "$p1label" == "RPICFG" ]] || fail "pinned base p1 must be labeled RPICFG, got: ${p1label:-none}"

    mount -o ro "$p1" "$SRC_BOOT_MNT"
    [[ -f "$SRC_BOOT_MNT/config.txt" ]] || fail "pinned base boot partition has no config.txt"
    [[ -f "$SRC_BOOT_MNT/cmdline.txt" ]] || fail "pinned base boot partition has no cmdline.txt"
    [[ -f "$SRC_BOOT_MNT/vmlinuz" ]] || fail "pinned base boot partition has no vmlinuz"
    [[ -f "$SRC_BOOT_MNT/initrd.img" ]] || fail "pinned base boot partition has no initrd.img"
    [[ -f "$SRC_BOOT_MNT/overlays/pcie-32bit-dma-pi5.dtbo" ]] \
        || fail "pinned base is missing pcie-32bit-dma-pi5.dtbo"
}

create_output_layout() {
    echo "==> Creating ${AB_IMAGE_SIZE_MIB} MiB sparse A/B image"
    truncate -s "${AB_IMAGE_SIZE_MIB}M" "$IMG"

    parted -s "$IMG" mklabel msdos
    parted -s "$IMG" mkpart primary fat32 "${P1_START}MiB" "${P1_END}MiB"
    parted -s "$IMG" set 1 boot on
    parted -s "$IMG" mkpart primary fat32 "${P2_START}MiB" "${P2_END}MiB"
    parted -s "$IMG" mkpart primary fat32 "${P3_START}MiB" "${P3_END}MiB"
    parted -s "$IMG" mkpart extended "${P4_START}MiB" "${P4_END}MiB"
    parted -s "$IMG" mkpart logical ext4 "${P5_START}MiB" "${P5_END}MiB"
    parted -s "$IMG" mkpart logical ext4 "${P6_START}MiB" "${P6_END}MiB"

    OUT_LOOP="$(losetup --find --show --partscan "$IMG")"
    settle_partitions

    for n in 1 2 3 4 5 6; do
        [[ -b "$(partdev "$OUT_LOOP" "$n")" ]] || fail "output partition p${n} was not created"
    done

    [[ "$(blkid -s PTTYPE -o value "$OUT_LOOP" 2>/dev/null || true)" == "dos" ]] \
        || fail "output partition table is not DOS/MBR"

    echo "==> Creating filesystems"
    FAT_ID_PREFIX="$(python3 -c 'import secrets; print(f"{secrets.randbits(24):06X}")')"
    mkfs.vfat -F 32 -i "${FAT_ID_PREFIX}01" -n VYOS_AB "$(partdev "$OUT_LOOP" 1)" >/dev/null
    mkfs.vfat -F 32 -i "${FAT_ID_PREFIX}02" -n VYOS_BOOT_A "$(partdev "$OUT_LOOP" 2)" >/dev/null
    mkfs.vfat -F 32 -i "${FAT_ID_PREFIX}03" -n VYOS_BOOT_B "$(partdev "$OUT_LOOP" 3)" >/dev/null
    mkfs.ext4 -F -m 0 -L VYOS_ROOT_A "$(partdev "$OUT_LOOP" 5)" >/dev/null
    mkfs.ext4 -F -m 0 -L VYOS_ROOT_B "$(partdev "$OUT_LOOP" 6)" >/dev/null
    sync
}

write_control_partition() {
    local p1
    p1="$(partdev "$OUT_LOOP" 1)"
    mount "$p1" "$CTRL_MNT"

    cat > "$CTRL_MNT/autoboot.txt" <<'AUTOboot'
[all]
tryboot_a_b=1
boot_partition=2

[tryboot]
boot_partition=3
AUTOboot

    sync
    umount "$CTRL_MNT"
}

copy_boot_template() {
    local dst="$1" label="$2"
    mount "$dst" "$BOOT_MNT"
    echo "==> Copying Armbian boot template to ${label}"
    rsync -rt --delete --modify-window=1 "$SRC_BOOT_MNT/" "$BOOT_MNT/"
    sync
    umount "$BOOT_MNT"
}

patch_cmdline_file() {
    local file="$1" root_partuuid="$2"
    python3 - "$file" "$root_partuuid" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
partuuid = sys.argv[2]
tokens = path.read_text(encoding="utf-8").replace("\r", " ").replace("\n", " ").split()
out = []
root_seen = False
for token in tokens:
    if token.startswith("root="):
        if not root_seen:
            out.append(f"root=PARTUUID={partuuid}")
            root_seen = True
        continue
    out.append(token)

if not root_seen:
    raise SystemExit(f"ERROR: no root= token found in {path}")

for required in ("net.ifnames=0", "modprobe.blacklist=btusb,btmtk"):
    if required not in out:
        out.append(required)

path.write_text(" ".join(out) + "\n", encoding="utf-8")
PY
}

patch_boot_slot() {
    local slot="$1" bootdev="$2" root_partuuid="$3"
    local cfg cmdline

    mount "$bootdev" "$BOOT_MNT"
    cfg="$BOOT_MNT/config.txt"
    cmdline="$BOOT_MNT/cmdline.txt"

    [[ -f "$cfg" ]] || fail "BOOT-${slot} config.txt is missing"
    [[ -f "$cmdline" ]] || fail "BOOT-${slot} cmdline.txt is missing"
    [[ -f "$BOOT_MNT/overlays/pcie-32bit-dma-pi5.dtbo" ]] \
        || fail "BOOT-${slot} is missing pcie-32bit-dma-pi5.dtbo"

    patch_cmdline_file "$cmdline" "$root_partuuid"

    if ! grep -Eq '^[[:space:]]*dtparam=pciex1[[:space:]]*$' "$cfg" ||
       ! grep -Eq '^[[:space:]]*dtoverlay=pcie-32bit-dma-pi5[[:space:]]*$' "$cfg"; then
        printf '\n[all]\n# Enable Raspberry Pi 5 external PCIe x1\n' >> "$cfg"
        grep -Eq '^[[:space:]]*dtparam=pciex1[[:space:]]*$' "$cfg" \
            || printf 'dtparam=pciex1\n' >> "$cfg"
        grep -Eq '^[[:space:]]*dtoverlay=pcie-32bit-dma-pi5[[:space:]]*$' "$cfg" \
            || printf 'dtoverlay=pcie-32bit-dma-pi5\n' >> "$cfg"
    fi

    if grep -Eq '^[[:space:]]*dtparam=pciex1_gen=3([[:space:]]|$)' "$cfg"; then
        fail "BOOT-${slot} unexpectedly enables pciex1_gen=3"
    fi

    sync
    umount "$BOOT_MNT"
}

install_ab_runtime() {
    local root="$1"
    local libexec="${root}/usr/libexec/vyos"
    local op_mode="${libexec}/op_mode"
    local systemd_dir="${root}/etc/systemd/system"
    local wants_dir="${systemd_dir}/multi-user.target.wants"

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

    ln -sfn ../vyos-pi-ab-auto-guard.service \
        "${wants_dir}/vyos-pi-ab-auto-guard.service"
}

patch_add_image_routes() {
    local root="$1"
    local templates="${root}/opt/vyatta/share/vyatta-op/templates/add/system/image"

    [[ -d "$templates" ]] || fail "missing add/system/image op-mode templates in target root"

    python3 - "$templates" <<'PY_ROUTES'
from pathlib import Path
import sys

root = Path(sys.argv[1])
old = "${vyos_op_scripts_dir}/image_installer.py --action add"
new = "${vyos_op_scripts_dir}/vyos_pi_image_dispatch.py --action add"

patched = 0
for path in sorted(root.rglob("node.def")):
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count:
        path.write_text(text.replace(old, new), encoding="utf-8")
        patched += count

if patched == 0:
    existing = sum(
        path.read_text(encoding="utf-8", errors="replace").count(new)
        for path in sorted(root.rglob("node.def"))
    )
    if existing == 0:
        raise SystemExit("ERROR: no add system image route could be patched")
    patched = existing

for path in sorted(root.rglob("node.def")):
    if old in path.read_text(encoding="utf-8", errors="replace"):
        raise SystemExit(f"ERROR: direct image_installer route remains: {path}")

print(patched)
PY_ROUTES
}

install_root_slot() {
    local slot="$1" rootdev="$2" bootdev="$3"
    local root_uuid boot_uuid root_partuuid boot_partuuid

    root_uuid="$(fs_uuid "$rootdev")"
    boot_uuid="$(fs_uuid "$bootdev")"
    root_partuuid="$(part_uuid "$rootdev")"
    boot_partuuid="$(part_uuid "$bootdev")"

    [[ -n "$root_uuid" && -n "$boot_uuid" && -n "$root_partuuid" && -n "$boot_partuuid" ]] \
        || fail "could not determine UUID/PARTUUID for slot ${slot}"

    mount "$rootdev" "$ROOT_MNT"
    echo "==> Installing merged VyOS rootfs into ROOT-${slot}"
    find "$ROOT_MNT" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +

    tar \
        --numeric-owner \
        --acls \
        --xattrs \
        --xattrs-include='*' \
        -xpf "$MERGED_TAR" \
        -C "$ROOT_MNT"

    echo "==> Installing A/B runtime into ROOT-${slot}"
    install_ab_runtime "$ROOT_MNT"

    local route_count
    route_count="$(patch_add_image_routes "$ROOT_MNT")"
    echo "    add system image dispatcher routes: ${route_count}"

    mkdir -p "$ROOT_MNT/etc"
    cat > "$ROOT_MNT/etc/fstab" <<EOF_FSTAB
# VyOS Raspberry Pi A/B slot ${slot}
UUID=${root_uuid} / ext4 defaults,commit=120,errors=remount-ro 0 1
UUID=${boot_uuid} /boot/firmware vfat defaults 0 2
tmpfs /tmp tmpfs defaults,nosuid 0 0
EOF_FSTAB
    chmod 0644 "$ROOT_MNT/etc/fstab"

    # Small immutable-by-convention marker for diagnostics. The future update
    # installer may refresh this when writing a slot.
    printf '%s\n' "$slot" > "$ROOT_MNT/etc/vyos-pi-ab-slot"
    chmod 0644 "$ROOT_MNT/etc/vyos-pi-ab-slot"

    sync
    umount "$ROOT_MNT"

    patch_boot_slot "$slot" "$bootdev" "$root_partuuid"
}

validate_control() {
    local size
    mount -o ro "$(partdev "$OUT_LOOP" 1)" "$CTRL_MNT"
    [[ -f "$CTRL_MNT/autoboot.txt" ]] || fail "VYOS_AB/autoboot.txt is missing"
    size="$(stat -c '%s' "$CTRL_MNT/autoboot.txt")"
    (( size < 512 )) || fail "autoboot.txt must be smaller than 512 bytes"
    grep -Eq '^tryboot_a_b=1$' "$CTRL_MNT/autoboot.txt" || fail "autoboot.txt lost tryboot_a_b=1"
    grep -Eq '^boot_partition=2$' "$CTRL_MNT/autoboot.txt" || fail "autoboot.txt lost normal BOOT-A selection"
    grep -Eq '^boot_partition=3$' "$CTRL_MNT/autoboot.txt" || fail "autoboot.txt lost tryboot BOOT-B selection"
    umount "$CTRL_MNT"
}

validate_slot() {
    local slot="$1" bootdev="$2" rootdev="$3"
    local expected_boot_label="$4" expected_root_label="$5"
    local root_uuid boot_uuid root_partuuid
    local image_target kver dtb_target
    local boot_kernel root_kernel boot_initrd root_initrd

    [[ "$(blkid -s LABEL -o value "$bootdev")" == "$expected_boot_label" ]] \
        || fail "slot ${slot} boot label mismatch"
    [[ "$(blkid -s LABEL -o value "$rootdev")" == "$expected_root_label" ]] \
        || fail "slot ${slot} root label mismatch"

    root_uuid="$(fs_uuid "$rootdev")"
    boot_uuid="$(fs_uuid "$bootdev")"
    root_partuuid="$(part_uuid "$rootdev")"

    mount -o ro,noload "$rootdev" "$ROOT_MNT"
    mount -o ro "$bootdev" "$BOOT_MNT"

    [[ "$(cat "$ROOT_MNT/etc/vyos-pi-ab-slot" 2>/dev/null || true)" == "$slot" ]] \
        || fail "ROOT-${slot} slot marker is missing/wrong"

    grep -Fq "UUID=${root_uuid} / ext4" "$ROOT_MNT/etc/fstab" \
        || fail "ROOT-${slot} fstab does not mount its own root UUID"
    grep -Fq "UUID=${boot_uuid} /boot/firmware vfat" "$ROOT_MNT/etc/fstab" \
        || fail "ROOT-${slot} fstab does not mount BOOT-${slot}"

    grep -Eq "(^|[[:space:]])root=PARTUUID=${root_partuuid}([[:space:]]|$)" "$BOOT_MNT/cmdline.txt" \
        || fail "BOOT-${slot} cmdline does not select ROOT-${slot} PARTUUID"
    if grep -Eq '(^|[[:space:]])root=LABEL=armbi_root([[:space:]]|$)' "$BOOT_MNT/cmdline.txt"; then
        fail "BOOT-${slot} still contains root=LABEL=armbi_root"
    fi
    grep -Eq '(^|[[:space:]])net\.ifnames=0([[:space:]]|$)' "$BOOT_MNT/cmdline.txt" \
        || fail "BOOT-${slot} lost net.ifnames=0"
    grep -Eq '(^|[[:space:]])modprobe\.blacklist=btusb,btmtk([[:space:]]|$)' "$BOOT_MNT/cmdline.txt" \
        || fail "BOOT-${slot} lost Bluetooth blacklist"

    grep -Eq '^[[:space:]]*kernel=vmlinuz[[:space:]]*$' "$BOOT_MNT/config.txt" \
        || fail "BOOT-${slot} config.txt does not select kernel=vmlinuz"
    grep -Eq '^[[:space:]]*initramfs[[:space:]]+initrd\.img[[:space:]]+followkernel[[:space:]]*$' "$BOOT_MNT/config.txt" \
        || fail "BOOT-${slot} config.txt does not select initrd.img"
    grep -Eq '^[[:space:]]*dtparam=pciex1[[:space:]]*$' "$BOOT_MNT/config.txt" \
        || fail "BOOT-${slot} lost dtparam=pciex1"
    grep -Eq '^[[:space:]]*dtoverlay=pcie-32bit-dma-pi5[[:space:]]*$' "$BOOT_MNT/config.txt" \
        || fail "BOOT-${slot} lost pcie-32bit-dma-pi5 overlay"

    image_target="$(readlink "$ROOT_MNT/boot/Image" 2>/dev/null || true)"
    [[ "$image_target" == vmlinuz-* ]] || fail "ROOT-${slot} /boot/Image symlink is invalid"
    kver="${image_target#vmlinuz-}"
    [[ -d "$ROOT_MNT/usr/lib/modules/$kver" ]] || fail "ROOT-${slot} kernel modules missing for $kver"

    boot_kernel="$BOOT_MNT/vmlinuz"
    root_kernel="$ROOT_MNT/boot/vmlinuz-$kver"
    boot_initrd="$BOOT_MNT/initrd.img"
    root_initrd="$ROOT_MNT/boot/initrd.img-$kver"

    for f in "$boot_kernel" "$root_kernel" "$boot_initrd" "$root_initrd"; do
        [[ -f "$f" ]] || fail "slot ${slot} required boot file missing: $f"
    done

    [[ "$(sha256_file "$boot_kernel")" == "$(sha256_file "$root_kernel")" ]] \
        || fail "slot ${slot} FAT/root kernel mismatch"
    [[ "$(sha256_file "$boot_initrd")" == "$(sha256_file "$root_initrd")" ]] \
        || fail "slot ${slot} FAT/root initrd mismatch"

    # Validate Pi 5 DTB parity when the files exist in this base/rootfs.
    if [[ -f "$BOOT_MNT/bcm2712-rpi-5-b.dtb" ]]; then
        dtb_target="$(readlink "$ROOT_MNT/boot/dtb" 2>/dev/null || true)"
        [[ -n "$dtb_target" ]] || fail "ROOT-${slot} /boot/dtb symlink missing"
        [[ -f "$ROOT_MNT/boot/$dtb_target/broadcom/bcm2712-rpi-5-b.dtb" ]] \
            || fail "ROOT-${slot} Pi 5 DTB missing"
        [[ "$(sha256_file "$BOOT_MNT/bcm2712-rpi-5-b.dtb")" == \
           "$(sha256_file "$ROOT_MNT/boot/$dtb_target/broadcom/bcm2712-rpi-5-b.dtb")" ]] \
            || fail "slot ${slot} FAT/root Pi 5 DTB mismatch"
    fi

    [[ -f "$ROOT_MNT/config/config.boot" ]] || fail "ROOT-${slot} VyOS config.boot missing"
    grep -Fq 'url "https://raw.githubusercontent.com/frogro/vyos-build-pi5/rolling/version.json"' "$ROOT_MNT/config/config.boot" \
        || fail "ROOT-${slot} system update-check URL missing"
    [[ -L "$ROOT_MNT/etc/systemd/system/timers.target.wants/pi5-dhcp-wan-firstboot.timer" ]] \
        || fail "ROOT-${slot} Pi first-boot timer is not enabled"
    [[ -x "$ROOT_MNT/home/vyos/ap-dhcp-wan-setup.sh" ]] \
        || fail "ROOT-${slot} AP setup helper missing"
    [[ -f "$ROOT_MNT/home/vyos/.bashrc" ]] || fail "ROOT-${slot} VyOS .bashrc missing"
    [[ -f "$ROOT_MNT/home/vyos/.profile" ]] || fail "ROOT-${slot} VyOS .profile missing"
    grep -Fq '/usr/share/bash-completion/bash_completion' "$ROOT_MNT/home/vyos/.bashrc" \
        || fail "ROOT-${slot} VyOS .bashrc does not initialize bash-completion"

    if grep -Eq 'set interfaces (ethernet|wireless).*hw-id' \
        "$ROOT_MNT/home/vyos/dhcp-wan-ssh-setup.sh" \
        "$ROOT_MNT/home/vyos/ap-dhcp-wan-setup.sh"; then
        fail "ROOT-${slot} helper scripts still create MAC-based VyOS hw-id bindings"
    fi

    for rel in \
        usr/libexec/vyos/vyos-pi-ab-status.py \
        usr/libexec/vyos/vyos-pi-ab-commit.py \
        usr/libexec/vyos/vyos-pi-ab-healthcheck.py \
        usr/libexec/vyos/vyos-pi-ab-auto-guard.py \
        usr/libexec/vyos/install-vyos-pi-ab-update.py \
        usr/libexec/vyos/op_mode/vyos_pi_image_dispatch.py; do
        [[ -x "$ROOT_MNT/$rel" ]] || fail "ROOT-${slot} A/B runtime missing/non-executable: $rel"
    done

    [[ -f "$ROOT_MNT/etc/systemd/system/vyos-pi-ab-auto-guard.service" ]] \
        || fail "ROOT-${slot} A/B auto-guard service missing"
    [[ -L "$ROOT_MNT/etc/systemd/system/multi-user.target.wants/vyos-pi-ab-auto-guard.service" ]] \
        || fail "ROOT-${slot} A/B auto-guard service is not enabled"

    local templates dispatcher upstream routes
    templates="$ROOT_MNT/opt/vyatta/share/vyatta-op/templates/add/system/image"
    dispatcher='${vyos_op_scripts_dir}/vyos_pi_image_dispatch.py --action add'
    upstream='${vyos_op_scripts_dir}/image_installer.py --action add'
    routes="$({ grep -RhsF "$dispatcher" "$templates" --include=node.def || true; } | wc -l)"
    (( routes > 0 )) || fail "ROOT-${slot} has no A/B add system image dispatcher routes"
    if grep -RqsF "$upstream" "$templates" --include=node.def; then
        fail "ROOT-${slot} still has direct upstream add system image routes"
    fi

    python3 "$BRCM_FW_CHECK" "$ROOT_MNT" --check-only \
        || fail "ROOT-${slot} BCM43455 firmware validation failed"

    for rel in \
        mediatek/WIFI_RAM_CODE_MT7922_1.bin \
        mediatek/WIFI_MT7922_patch_mcu_1_1_hdr.bin \
        rtw89/rtw8852b_fw-2.bin \
        rtl_nic/rtl8125b-2.fw; do
        [[ -e "$ROOT_MNT/usr/lib/firmware/$rel" || -L "$ROOT_MNT/usr/lib/firmware/$rel" ]] \
            || fail "ROOT-${slot} critical network firmware missing: $rel"
    done

    echo "    Slot ${slot}: kernel ${kver}, root PARTUUID=${root_partuuid}"

    umount "$BOOT_MNT"
    umount "$ROOT_MNT"
}

validate_final_layout() {
    local count
    count="$(lsblk -ln -o TYPE "$OUT_LOOP" | awk '$1=="part"{n++} END{print n+0}')"
    [[ "$count" -eq 6 ]] || fail "expected 6 MBR partition devices, got: $count"

    [[ "$(blkid -s LABEL -o value "$(partdev "$OUT_LOOP" 1)")" == "VYOS_AB" ]] || fail "p1 label mismatch"
    [[ "$(blkid -s LABEL -o value "$(partdev "$OUT_LOOP" 2)")" == "VYOS_BOOT_A" ]] || fail "p2 label mismatch"
    [[ "$(blkid -s LABEL -o value "$(partdev "$OUT_LOOP" 3)")" == "VYOS_BOOT_B" ]] || fail "p3 label mismatch"
    [[ "$(blkid -s LABEL -o value "$(partdev "$OUT_LOOP" 5)")" == "VYOS_ROOT_A" ]] || fail "p5 label mismatch"
    [[ "$(blkid -s LABEL -o value "$(partdev "$OUT_LOOP" 6)")" == "VYOS_ROOT_B" ]] || fail "p6 label mismatch"

    CTRL_UUID="$(blkid -s UUID -o value "$(partdev "$OUT_LOOP" 1)")"
    BOOT_A_UUID="$(blkid -s UUID -o value "$(partdev "$OUT_LOOP" 2)")"
    BOOT_B_UUID="$(blkid -s UUID -o value "$(partdev "$OUT_LOOP" 3)")"
    [[ -n "$CTRL_UUID" && -n "$BOOT_A_UUID" && -n "$BOOT_B_UUID" ]] || fail "could not determine FAT UUIDs"
    if [[ "$CTRL_UUID" == "$BOOT_A_UUID" || "$CTRL_UUID" == "$BOOT_B_UUID" || "$BOOT_A_UUID" == "$BOOT_B_UUID" ]]; then
        fail "FAT UUID collision between VYOS_AB, VYOS_BOOT_A and VYOS_BOOT_B"
    fi
    echo "    FAT UUIDs: p1=$CTRL_UUID p2=$BOOT_A_UUID p3=$BOOT_B_UUID"

    validate_control
    echo "==> Validating slot A"
    validate_slot A "$(partdev "$OUT_LOOP" 2)" "$(partdev "$OUT_LOOP" 5)" VYOS_BOOT_A VYOS_ROOT_A
    echo "==> Validating slot B"
    validate_slot B "$(partdev "$OUT_LOOP" 3)" "$(partdev "$OUT_LOOP" 6)" VYOS_BOOT_B VYOS_ROOT_B
}

echo "==> VyOS Raspberry Pi production A/B image builder v1.0"
echo "    Armbian base : $ARMBIAN_IMAGE"
echo "    Merged rootfs: $MERGED_TAR"
echo "    Output       : $OUT_IMG"
echo "    Image size   : ${AB_IMAGE_SIZE_MIB} MiB"
echo "    Layout MiB   : p1 ${P1_START}-${P1_END}, p2 ${P2_START}-${P2_END}, p3 ${P3_START}-${P3_END}, p5 ${P5_START}-${P5_END}, p6 ${P6_START}-${P6_END}"

verify_pinned_base
extract_source_base
validate_source_base
create_output_layout
write_control_partition

copy_boot_template "$(partdev "$OUT_LOOP" 2)" "BOOT-A"
copy_boot_template "$(partdev "$OUT_LOOP" 3)" "BOOT-B"

install_root_slot A "$(partdev "$OUT_LOOP" 5)" "$(partdev "$OUT_LOOP" 2)"
install_root_slot B "$(partdev "$OUT_LOOP" 6)" "$(partdev "$OUT_LOOP" 3)"

# Source boot template is no longer needed.
umount "$SRC_BOOT_MNT"
losetup -d "$SRC_LOOP"
SRC_LOOP=""

sync
echo "==> Running complete offline A/B validation"
validate_final_layout
sync

echo "==> Running filesystem consistency checks"
e2fsck -fn "$(partdev "$OUT_LOOP" 5)" >/dev/null || fail "ROOT-A e2fsck validation failed"
e2fsck -fn "$(partdev "$OUT_LOOP" 6)" >/dev/null || fail "ROOT-B e2fsck validation failed"
fsck.vfat -n "$(partdev "$OUT_LOOP" 1)" >/dev/null || fail "VYOS_AB FAT validation failed"
fsck.vfat -n "$(partdev "$OUT_LOOP" 2)" >/dev/null || fail "BOOT-A FAT validation failed"
fsck.vfat -n "$(partdev "$OUT_LOOP" 3)" >/dev/null || fail "BOOT-B FAT validation failed"

losetup -d "$OUT_LOOP"
OUT_LOOP=""

if [[ -e "$OUT_IMG" ]]; then
    rm -f "$OUT_IMG"
fi
mv "$IMG" "$OUT_IMG"

FINAL_SHA="$(sha256_file "$OUT_IMG")"

echo
echo "==> Raspberry Pi VyOS A/B release image complete"
echo "    Image : $OUT_IMG"
echo "    Size  : $(stat -c '%s' "$OUT_IMG") bytes"
echo "    SHA256: $FINAL_SHA"
echo "    Normal boot      : slot A (p2 -> p5)"
echo "    One-shot tryboot : slot B (p3 -> p6)"
echo "    A/B runtime      : auto-guard + healthcheck + watchdog rollback + add system image dispatcher"
