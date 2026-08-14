#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
P="$ROOT/scripts/pi5"

for f in \
    "$P/inject-defaults.sh" \
    "$P/build-vyos-pi5-image.sh" \
    "$P/build-vyos-pi-ab-update.sh" \
    "$P/convert-vyos-rpi-image-to-ab.sh" \
    "$P/merge-vyos-pi5.sh" \
    "$P/install-network-firmware.sh" \
    "$P/first-boot/dhcp-wan-ssh-setup.sh" \
    "$P/first-boot/pi5-dhcp-wan-firstboot-wrapper.sh" \
    "$P/first-boot/ap-dhcp-wan-setup.sh"; do
    bash -n "$f"
done

test -f "$P/first-boot/home-dotfiles/.bashrc"
test -f "$P/first-boot/home-dotfiles/.profile"
test -f "$P/first-boot/home-dotfiles/.bash_logout"
grep -Fq '/usr/share/bash-completion/bash_completion' "$P/first-boot/home-dotfiles/.bashrc"
grep -Fq '. "$HOME/.bashrc"' "$P/first-boot/home-dotfiles/.profile"

if grep -Eq 'set interfaces (ethernet|wireless).*hw-id' \
    "$P/first-boot/dhcp-wan-ssh-setup.sh" \
    "$P/first-boot/ap-dhcp-wan-setup.sh"; then
    echo "ERROR: helper scripts still configure a MAC-based hw-id" >&2
    exit 1
fi

grep -Fq 'net.ifnames=0' "$P/build-vyos-pi5-image.sh"
grep -Fq 'modprobe.blacklist=btusb,btmtk' "$P/build-vyos-pi5-image.sh"
grep -Fq 'dtparam=pciex1' "$P/build-vyos-pi5-image.sh"
grep -Fq 'dtoverlay=pcie-32bit-dma-pi5' "$P/build-vyos-pi5-image.sh"
grep -Fq 'Default-Route aktiv:' "$P/first-boot/pi5-dhcp-wan-firstboot-wrapper.sh"
grep -Fq 'AP_IF_CACHE="${AP_IF_CACHE:-/config/photobooth-ap-interface.conf}"' "$P/first-boot/ap-dhcp-wan-setup.sh"
grep -Fq 'PI5_VYATTACFG_REEXEC=1' "$P/first-boot/dhcp-wan-ssh-setup.sh"
grep -Fq 'PI5_VYATTACFG_REEXEC=1' "$P/first-boot/ap-dhcp-wan-setup.sh"
grep -Fq 'https://raw.githubusercontent.com/frogro/vyos-build-pi5/rolling/version.json' \
    "$P/first-boot/config.boot.default"
grep -Fq 'UPDATE_CHECK_URL="${UPDATE_CHECK_URL:-https://raw.githubusercontent.com/frogro/vyos-build-pi5/rolling/version.json}"' \
    "$P/convert-vyos-rpi-image-to-ab.sh"
grep -Fq 'ensure_update_check_url "$CONFIG_BOOT_OVERLAY" "$UPDATE_CHECK_URL"' \
    "$P/convert-vyos-rpi-image-to-ab.sh"
grep -Fq 'converted rootfs config.boot does not contain update-check URL' \
    "$P/convert-vyos-rpi-image-to-ab.sh"
grep -Fq 'ROOT-{slot} config.boot is missing update-check URL' \
    "$P/convert-vyos-rpi-image-to-ab.sh"

for marker in VYOS_AB VYOS_BOOT_A VYOS_BOOT_B VYOS_ROOT_A VYOS_ROOT_B; do
    grep -Fq "$marker" "$P/build-vyos-pi5-image.sh"
done
grep -Fq 'tryboot_a_b=1' "$P/build-vyos-pi5-image.sh"
grep -Fq 'boot_partition=2' "$P/build-vyos-pi5-image.sh"
grep -Fq 'boot_partition=3' "$P/build-vyos-pi5-image.sh"
grep -Fq 'vyos-pi-ab-auto-guard.service' "$P/build-vyos-pi5-image.sh"
grep -Fq 'vyos_pi_image_dispatch.py --action add' "$P/build-vyos-pi5-image.sh"
grep -Fq 'except KeyboardInterrupt:' "$P/install-vyos-pi-ab-update.py"
grep -Fq 'except KeyboardInterrupt:' "$P/vyos-pi-image-dispatch.py"
grep -Fq 'raise SystemExit(130)' "$P/install-vyos-pi-ab-update.py"
grep -Fq 'raise SystemExit(130)' "$P/vyos-pi-image-dispatch.py"
grep -Fq 'reboot normally once and retry' "$P/install-vyos-pi-ab-update.py"
grep -Fq 'reboot normally once before' "$P/install-vyos-pi-ab-update.py"
grep -Fq 'perform one normal `sudo reboot` before installing another update' "$P/render-release-notes.py"
grep -Fq "p.add_argument('--manual-baseline'" "$P/render-release-notes.py"
grep -Fq "p.add_argument('--tag'" "$P/write-version-json.py"
grep -Fq "TAG_RE = re.compile" "$P/write-version-json.py"
grep -Fq 'perform one normal reboot before installing another update' "$P/update-changelog.py"

if grep -Fq 'fail "RPICFG partition changed during image build"' "$P/build-vyos-pi5-image.sh"; then
    echo "ERROR: old byte-identical RPICFG validation is still present" >&2
    exit 1
fi

for f in \
    "$P/validate-brcm43455-firmware.py" \
    "$P/install-vyos-pi-ab-update.py" \
    "$P/vyos-pi-ab-auto-guard.py" \
    "$P/vyos-pi-ab-commit.py" \
    "$P/vyos-pi-ab-healthcheck.py" \
    "$P/vyos-pi-ab-status.py" \
    "$P/vyos-pi-ab-watchdog-test.py" \
    "$P/vyos-pi-image-dispatch.py" \
    "$P/render-release-notes.py" \
    "$P/update-changelog.py" \
    "$P/write-version-json.py"; do
    python3 -m py_compile "$f"
done

echo "OK: production Raspberry Pi A/B repo patches are present and syntactically valid"
echo "NOTE: kernel Kconfig is intentionally not checked here; build/test Armbian separately."
