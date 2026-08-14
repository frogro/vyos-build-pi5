#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
P="$ROOT/scripts/pi5"
AUTO_NIGHTLY="$ROOT/.github/workflows/auto-vyos-pi-nightly.yml"

for f in \
    "$P/inject-defaults.sh" \
    "$P/build-vyos-pi5-image.sh" \
    "$P/build-vyos-pi-ab-update.sh" \
    "$P/convert-vyos-rpi-image-to-ab.sh" \
    "$P/merge-vyos-pi5.sh" \
    "$P/install-network-firmware.sh" \
    "$P/first-boot/dhcp-wan-ssh-setup.sh" \
    "$P/first-boot/set-locales.sh" \
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
grep -Fq 'UPDATE_CHECK_URL="https://raw.githubusercontent.com/frogro/vyos-build-pi5/rolling/version.json"' \
    "$P/first-boot/dhcp-wan-ssh-setup.sh"
grep -Fq 'set system update-check url "$UPDATE_CHECK_URL"' \
    "$P/first-boot/dhcp-wan-ssh-setup.sh"
grep -Fq 'UPDATE_CHECK_URL="https://raw.githubusercontent.com/frogro/vyos-build-pi5/rolling/version.json"' \
    "$P/first-boot/set-locales.sh"
grep -Fq 'set system update-check url "$UPDATE_CHECK_URL"' \
    "$P/first-boot/set-locales.sh"
grep -Fq 'UPDATE_CHECK_ALREADY_SET=0' \
    "$P/first-boot/set-locales.sh"
grep -Fq 'Raspberry Pi rolling/latest (already set)' \
    "$P/first-boot/set-locales.sh"
grep -Fq 'Raspberry Pi rolling/latest (will be set)' \
    "$P/first-boot/set-locales.sh"
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
grep -Fq 'FAT_ID_PREFIX=' "$P/build-vyos-pi5-image.sh"
grep -Fq 'FAT UUID collision between VYOS_AB, VYOS_BOOT_A and VYOS_BOOT_B' "$P/build-vyos-pi5-image.sh"
grep -Fq 'vyos-pi-ab-auto-guard.service' "$P/build-vyos-pi5-image.sh"
grep -Fq 'vyos_pi_image_dispatch.py --action add' "$P/build-vyos-pi5-image.sh"
grep -Fq 'except KeyboardInterrupt:' "$P/install-vyos-pi-ab-update.py"
grep -Fq 'except KeyboardInterrupt:' "$P/vyos-pi-image-dispatch.py"
grep -Fq 'raise SystemExit(130)' "$P/install-vyos-pi-ab-update.py"
grep -Fq 'raise SystemExit(130)' "$P/vyos-pi-image-dispatch.py"
grep -Fq 'reboot normally once and retry' "$P/install-vyos-pi-ab-update.py"
grep -Fq 'Reboot and test the new image now? [Y/n]' "$P/vyos-pi-image-dispatch.py"
grep -Fq '["/sbin/reboot", "0 tryboot"]' "$P/vyos-pi-image-dispatch.py"
grep -Fq 'One final normal reboot will complete activation with tryboot=0.' "$P/vyos-pi-ab-auto-guard.py"
grep -Fq 'run("/usr/bin/systemctl", "--no-block", "reboot", check=False)' "$P/vyos-pi-ab-auto-guard.py"
grep -Fq 'v0.7' "$P/install-vyos-pi-ab-update.py"
grep -Fq 'DEFAULT_UPDATE_CHECK_URL = "https://raw.githubusercontent.com/frogro/vyos-build-pi5/rolling/version.json"' "$P/install-vyos-pi-ab-update.py"
grep -Fq 'target_update_url = ensure_update_check_url(root / "config/config.boot")' "$P/install-vyos-pi-ab-update.py"
grep -Fq 'ROOT-{slot} system update-check URL is missing' "$P/install-vyos-pi-ab-update.py"
grep -Fq 'system update-check url is missing from the running configuration' "$P/vyos-pi-ab-healthcheck.py"
grep -Fq 'system update-check URL missing' "$P/build-vyos-pi5-image.sh"
grep -Fq 'merged rootfs system update-check URL is missing' "$P/build-vyos-pi-ab-update.sh"
grep -Fq 'Reboot cancelled; the update remains installed in the inactive slot.' "$P/vyos-pi-image-dispatch.py"
grep -Fq 'dispatcher offers to reboot and test the new image immediately' "$P/render-release-notes.py"
grep -Fq "p.add_argument('--manual-baseline'" "$P/render-release-notes.py"
grep -Fq "p.add_argument('--tag'" "$P/write-version-json.py"
grep -Fq "TAG_RE = re.compile" "$P/write-version-json.py"
grep -Fq 'Interactive A/B updates offer the test reboot automatically' "$P/update-changelog.py"
grep -Fq 'Raspberry Pi A/B update validation PASSED.' "$P/vyos-pi-ab-auto-guard.py"
grep -Fq 'Raspberry Pi A/B update validation FAILED.' "$P/vyos-pi-ab-auto-guard.py"
grep -Fq 'UPDATE_STATE_NAME = "update-state.json"' "$P/vyos-pi-ab-auto-guard.py"
grep -Fq 'publish_normal_boot_result(running_slot)' "$P/vyos-pi-ab-auto-guard.py"
grep -Fq 'next normal login will show the final update result' "$P/vyos-pi-image-dispatch.py"
grep -Fq 'REST-free upstream discovery: PASS' "$AUTO_NIGHTLY"
grep -Fq 'official-package-lock.tsv' "$AUTO_NIGHTLY"
grep -Fq 'package_lock_sha256=' "$AUTO_NIGHTLY"
grep -Fq 'vyos-nightly-lock-${{ github.run_id }}' "$AUTO_NIGHTLY"
grep -Fq 'GH_TOKEN: ${{ github.token }}' "$AUTO_NIGHTLY"
grep -Fq 'LATEST_TAG=' "$AUTO_NIGHTLY"
grep -Fq 'releases/latest' "$AUTO_NIGHTLY"
grep -Fq 'UPDATE_ASSET="vyos-${VERSION}-rpi-arm64-update.tar.zst"' "$AUTO_NIGHTLY"
grep -Fq -- '--tag "$TAG"' "$AUTO_NIGHTLY"
grep -Fq 'EXPECTED_UPDATE_URL="https://github.com/${GITHUB_REPOSITORY}/releases/download/${TAG}/${UPDATE_ASSET}"' "$AUTO_NIGHTLY"
if grep -Eq -- '-rpi-m([0-9]+)?/' "$ROOT/version.json"; then
    echo "ERROR: production version.json points to a manual -rpi-m baseline" >&2
    exit 1
fi
BUILD_WORKFLOW="$ROOT/.github/workflows/build-vyos-pi5.yml"
grep -Fq 'Rebuild pinned VyOS core userspace package set' "$BUILD_WORKFLOW"
grep -Fq 'pinned-vyos-1x-src' "$BUILD_WORKFLOW"
grep -Fq 'parity_policy=diagnostic_full_lock+strict_frr_podman_vyos1x' "$BUILD_WORKFLOW"
grep -Fq 'BINNMU_EQUIVALENT' "$BUILD_WORKFLOW"
grep -Fq 'VyOS critical package parity validation: PASS (FRR/Podman/vyos-1x)' "$BUILD_WORKFLOW"
grep -Fq 'official-amd64-package-lock.tsv' "$BUILD_WORKFLOW"
grep -Fq 'gh release view "$TAG"' "$AUTO_NIGHTLY"
grep -Fq 'https://raw.githubusercontent.com/vyos/vyos-nightly-build/rolling/version.json' "$AUTO_NIGHTLY"
grep -Fq 'SIG_URL="${ISO_URL}.minisig"' "$AUTO_NIGHTLY"
grep -Fq 'git ls-remote --symref https://github.com/vyos/vyos-build.git HEAD' "$AUTO_NIGHTLY"
if grep -Fq 'api.github.com/repos/vyos/' "$AUTO_NIGHTLY"; then
    echo "ERROR: auto-nightly still contains direct VyOS GitHub REST discovery calls" >&2
    exit 1
fi

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
