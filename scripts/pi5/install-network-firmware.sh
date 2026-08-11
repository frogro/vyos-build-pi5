#!/bin/bash
# Raspberry Pi 5 network firmware supplement.
# Keeps existing VyOS/Armbian firmware and only fills files that are missing.
set -euo pipefail

ROOTFS="${1:?Usage: install-network-firmware.sh ROOTFS}"
FW_TAG="${LINUX_FIRMWARE_TAG:-20260622}"
FW_EXPECTED_COMMIT_PREFIX="${LINUX_FIRMWARE_COMMIT_PREFIX:-b2722d24}"
FW_REPO="${LINUX_FIRMWARE_REPO:-https://gitlab.com/kernel-firmware/linux-firmware.git}"

[ -d "$ROOTFS" ] || {
    echo "ERROR: rootfs does not exist: $ROOTFS" >&2
    exit 1
}

DEST="$ROOTFS/usr/lib/firmware"
mkdir -p "$DEST"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SRC="$TMP/linux-firmware"

echo "==> Network firmware supplement: linux-firmware $FW_TAG"

GIT_TERMINAL_PROMPT=0 git clone \
    --quiet \
    --depth 1 \
    --filter=blob:none \
    --no-checkout \
    --branch "$FW_TAG" \
    "$FW_REPO" \
    "$SRC"

git -C "$SRC" sparse-checkout set --no-cone \
    '/mediatek/WIFI_*' \
    '/mediatek/BT_*' \
    '/mediatek/mt7925/' \
    '/mediatek/mt7927/' \
    '/mediatek/mt7996/' \
    '/rtw88/' \
    '/rtw89/' \
    '/rtl_bt/' \
    '/rtl_nic/' \
    '/intel/ibt-*' \
    '/intel/iwlwifi/'

git -C "$SRC" checkout --quiet --detach "$FW_TAG"

ACTUAL="$(git -C "$SRC" rev-parse --short=8 HEAD)"
if [ "$ACTUAL" != "$FW_EXPECTED_COMMIT_PREFIX" ]; then
    echo "ERROR: linux-firmware $FW_TAG resolved to $ACTUAL, expected $FW_EXPECTED_COMMIT_PREFIX" >&2
    exit 1
fi

copy_dir_if_present() {
    local rel="$1"
    [ -d "$SRC/$rel" ] || return 0
    mkdir -p "$DEST/$rel"
    rsync -a --ignore-existing "$SRC/$rel/" "$DEST/$rel/"
}

copy_dir_if_present mediatek
copy_dir_if_present rtw88
copy_dir_if_present rtw89
copy_dir_if_present rtl_bt
copy_dir_if_present rtl_nic

# Intel Bluetooth firmware keeps its kernel-requested intel/ path.
mkdir -p "$DEST/intel"
for f in "$SRC"/intel/ibt-*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    base="$(basename "$f")"
    if [ ! -e "$DEST/intel/$base" ] && [ ! -L "$DEST/intel/$base" ]; then
        cp -a "$f" "$DEST/intel/$base"
    fi
done

# Upstream stores iwlwifi blobs in intel/iwlwifi/, while the kernel requests
# them as /lib/firmware/iwlwifi-*.  Copy/dereference them to that location.
for f in "$SRC"/intel/iwlwifi/iwlwifi-*.ucode "$SRC"/intel/iwlwifi/iwlwifi-*.pnvm; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    base="$(basename "$f")"
    if [ ! -e "$DEST/$base" ] && [ ! -L "$DEST/$base" ]; then
        cp -L -p "$f" "$DEST/$base"
    fi
done

# Critical files for the WLAN/BT families validated by the network firmware supplement.
required=(
    mediatek/WIFI_RAM_CODE_MT7922_1.bin
    mediatek/WIFI_MT7922_patch_mcu_1_1_hdr.bin
    mediatek/BT_RAM_CODE_MT7922_1_1_hdr.bin
    mediatek/mt7925/WIFI_MT7925_PATCH_MCU_1_1_hdr.bin
    mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin
    mediatek/mt7925/BT_RAM_CODE_MT7925_1_1_hdr.bin
    mediatek/mt7996/mt7996_rom_patch.bin
    mediatek/mt7996/mt7996_wm.bin
    mediatek/mt7996/mt7992_rom_patch.bin
    rtw89/rtw8852b_fw-2.bin
    rtw89/rtw8922a_fw-4.bin
    rtl_bt/rtl8922au_fw.bin
    rtl_nic/rtl8125b-2.fw
)

missing=0
for rel in "${required[@]}"; do
    if [ -e "$DEST/$rel" ] || [ -L "$DEST/$rel" ]; then
        echo "    OK    $rel"
    else
        echo "    FEHLT $rel" >&2
        missing=1
    fi
done

if ! compgen -G "$DEST/iwlwifi-*.ucode" >/dev/null; then
    echo "ERROR: no Intel iwlwifi firmware found in final rootfs" >&2
    missing=1
fi

if ! find "$DEST/mediatek/mt7927" -maxdepth 1 -type f -name 'WIFI*' -print -quit 2>/dev/null | grep -q .; then
    echo "ERROR: no official MT7927 Wi-Fi firmware found in final rootfs" >&2
    missing=1
else
    echo "    OK    official MT7927 Wi-Fi firmware"
fi

[ "$missing" -eq 0 ] || {
    echo "ERROR: required network firmware is incomplete" >&2
    exit 1
}

echo "==> Network firmware supplement complete"
