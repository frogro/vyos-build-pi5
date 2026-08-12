#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
P="$ROOT/scripts/pi5"

for f in \
    "$P/inject-defaults.sh" \
    "$P/build-vyos-pi5-image.sh" \
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

if grep -Fq 'fail "RPICFG partition changed during image build"' "$P/build-vyos-pi5-image.sh"; then
    echo "ERROR: old byte-identical RPICFG validation is still present" >&2
    exit 1
fi

python3 -m py_compile "$P/validate-brcm43455-firmware.py"

echo "OK: all non-Armbian Pi 5 repo patches are present and syntactically valid"
echo "NOTE: kernel Kconfig is intentionally not checked here; build/test Armbian separately."
