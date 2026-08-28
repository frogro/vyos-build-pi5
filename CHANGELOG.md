# Changelog

## v2026.08.27-1219-rolling-rpi

- Synchronized to official VyOS Rolling `2026.08.27-1219-rolling`.
- Official upstream release: https://github.com/vyos/vyos-nightly-build/releases/tag/2026.08.27-1219-rolling
- Exact `vyos/vyos-build` commit: `14d959fbb5ce0d2bf051c236b9050be81e17c885`.
- Verified critical userspace package parity: FRR `10.6.1-0`, Podman `5.8.4`, vyos-1x `999.0-14775-gc9822d151`.
- Raspberry Pi hardware base: `rpi-armbian-edge-7.1.8-vyos-parity`.
- Raspberry Pi kernel: `7.1.8`.
- Fresh-install `.img.xz` uses the production Raspberry Pi A/B partition layout.
- Matching `update.tar.zst` is published for `add system image` local, HTTP(S), and `latest` updates.
- A/B `tryboot`, automatic health-check/commit and hardware-watchdog rollback have been validated on physical Raspberry Pi hardware.
- Interactive A/B updates offer the test reboot automatically; validation PASS/FAIL is reported on the system console, the final result is shown on the next normal login, and failed or hung test boots roll back automatically without waiting for user input.
- Installer v0.7 preserves a copied custom update metadata URL, injects the Raspberry Pi rolling metadata URL when missing, and requires the running test slot to expose an update URL before commit.
- Published automatically after A/B full-image and update-bundle QA.
- See the linked official VyOS release for the upstream VyOS changes contained in this build.


## v2026.08.27-0133-rolling-rpi

- Synchronized to official VyOS Rolling `2026.08.27-0133-rolling`.
- Official upstream release: https://github.com/vyos/vyos-nightly-build/releases/tag/2026.08.27-0133-rolling
- Exact `vyos/vyos-build` commit: `14d959fbb5ce0d2bf051c236b9050be81e17c885`.
- Verified critical userspace package parity: FRR `10.6.1-0`, Podman `5.8.4`, vyos-1x `999.0-14775-gc9822d151`.
- Raspberry Pi hardware base: `rpi-armbian-edge-7.1.8-vyos-parity`.
- Raspberry Pi kernel: `7.1.8`.
- Fresh-install `.img.xz` uses the production Raspberry Pi A/B partition layout.
- Matching `update.tar.zst` is published for `add system image` local, HTTP(S), and `latest` updates.
- A/B `tryboot`, automatic health-check/commit and hardware-watchdog rollback have been validated on physical Raspberry Pi hardware.
- Interactive A/B updates offer the test reboot automatically; validation PASS/FAIL is reported on the system console, the final result is shown on the next normal login, and failed or hung test boots roll back automatically without waiting for user input.
- Installer v0.7 preserves a copied custom update metadata URL, injects the Raspberry Pi rolling metadata URL when missing, and requires the running test slot to expose an update URL before commit.
- Published automatically after A/B full-image and update-bundle QA.
- See the linked official VyOS release for the upstream VyOS changes contained in this build.


## v2026.08.26-1406-rolling-rpi

- Synchronized to official VyOS Rolling `2026.08.26-1406-rolling`.
- Official upstream release: https://github.com/vyos/vyos-nightly-build/releases/tag/2026.08.26-1406-rolling
- Exact `vyos/vyos-build` commit: `14d959fbb5ce0d2bf051c236b9050be81e17c885`.
- Verified critical userspace package parity: FRR `10.6.1-0`, Podman `5.8.4`, vyos-1x `999.0-14770-gd2b54b9d0`.
- Raspberry Pi hardware base: `rpi-armbian-edge-7.1.8-vyos-parity`.
- Raspberry Pi kernel: `7.1.8`.
- Fresh-install `.img.xz` uses the production Raspberry Pi A/B partition layout.
- Matching `update.tar.zst` is published for `add system image` local, HTTP(S), and `latest` updates.
- A/B `tryboot`, automatic health-check/commit and hardware-watchdog rollback have been validated on physical Raspberry Pi hardware.
- Interactive A/B updates offer the test reboot automatically; validation PASS/FAIL is reported on the system console, the final result is shown on the next normal login, and failed or hung test boots roll back automatically without waiting for user input.
- Installer v0.7 preserves a copied custom update metadata URL, injects the Raspberry Pi rolling metadata URL when missing, and requires the running test slot to expose an update URL before commit.
- Published automatically after A/B full-image and update-bundle QA.
- See the linked official VyOS release for the upstream VyOS changes contained in this build.


## v2026.08.25-0014-rolling-rpi

- Synchronized to official VyOS Rolling `2026.08.25-0014-rolling`.
- Official upstream release: https://github.com/vyos/vyos-nightly-build/releases/tag/2026.08.25-0014-rolling
- Exact `vyos/vyos-build` commit: `14d959fbb5ce0d2bf051c236b9050be81e17c885`.
- Verified critical userspace package parity: FRR `10.6.1-0`, Podman `5.8.4`, vyos-1x `999.0-14766-g1817a4dc2`.
- Raspberry Pi hardware base: `rpi-armbian-edge-7.1.8-vyos-parity`.
- Raspberry Pi kernel: `7.1.8`.
- Fresh-install `.img.xz` uses the production Raspberry Pi A/B partition layout.
- Matching `update.tar.zst` is published for `add system image` local, HTTP(S), and `latest` updates.
- A/B `tryboot`, automatic health-check/commit and hardware-watchdog rollback have been validated on physical Raspberry Pi hardware.
- Interactive A/B updates offer the test reboot automatically; validation PASS/FAIL is reported on the system console, the final result is shown on the next normal login, and failed or hung test boots roll back automatically without waiting for user input.
- Installer v0.7 preserves a copied custom update metadata URL, injects the Raspberry Pi rolling metadata URL when missing, and requires the running test slot to expose an update URL before commit.
- Published automatically after A/B full-image and update-bundle QA.
- See the linked official VyOS release for the upstream VyOS changes contained in this build.


## v2026.08.22-0013-rolling-rpi

- Synchronized to official VyOS Rolling `2026.08.22-0013-rolling`.
- Official upstream release: https://github.com/vyos/vyos-nightly-build/releases/tag/2026.08.22-0013-rolling
- Exact `vyos/vyos-build` commit: `339947b6ddc3c49b21810aa93d5c89b82218afcd`.
- Verified critical userspace package parity: FRR `10.6.1-0`, Podman `5.8.4`, vyos-1x `999.0-14762-g0712fac9d`.
- Raspberry Pi hardware base: `rpi-armbian-edge-7.1.8-vyos-parity`.
- Raspberry Pi kernel: `7.1.8`.
- Fresh-install `.img.xz` uses the production Raspberry Pi A/B partition layout.
- Matching `update.tar.zst` is published for `add system image` local, HTTP(S), and `latest` updates.
- A/B `tryboot`, automatic health-check/commit and hardware-watchdog rollback have been validated on physical Raspberry Pi hardware.
- Interactive A/B updates offer the test reboot automatically; validation PASS/FAIL is reported on the system console, the final result is shown on the next normal login, and failed or hung test boots roll back automatically without waiting for user input.
- Installer v0.7 preserves a copied custom update metadata URL, injects the Raspberry Pi rolling metadata URL when missing, and requires the running test slot to expose an update URL before commit.
- Published automatically after A/B full-image and update-bundle QA.
- See the linked official VyOS release for the upstream VyOS changes contained in this build.


## v2026.08.21-0014-rolling-rpi

- Synchronized to official VyOS Rolling `2026.08.21-0014-rolling`.
- Official upstream release: https://github.com/vyos/vyos-nightly-build/releases/tag/2026.08.21-0014-rolling
- Exact `vyos/vyos-build` commit: `b84fb1af685a8fa371117a2b5b0e2070ede0ff61`.
- Verified critical userspace package parity: FRR `10.6.1-0`, Podman `5.8.4`, vyos-1x `999.0-14758-gac99e72af`.
- Raspberry Pi hardware base: `rpi-armbian-edge-7.1.8-vyos-parity`.
- Raspberry Pi kernel: `7.1.8`.
- Fresh-install `.img.xz` uses the production Raspberry Pi A/B partition layout.
- Matching `update.tar.zst` is published for `add system image` local, HTTP(S), and `latest` updates.
- A/B `tryboot`, automatic health-check/commit and hardware-watchdog rollback have been validated on physical Raspberry Pi hardware.
- Interactive A/B updates offer the test reboot automatically; validation PASS/FAIL is reported on the system console, the final result is shown on the next normal login, and failed or hung test boots roll back automatically without waiting for user input.
- Installer v0.7 preserves a copied custom update metadata URL, injects the Raspberry Pi rolling metadata URL when missing, and requires the running test slot to expose an update URL before commit.
- Published automatically after A/B full-image and update-bundle QA.
- See the linked official VyOS release for the upstream VyOS changes contained in this build.


## v2026.08.19-0012-rolling-rpi

- Synchronized to official VyOS Rolling `2026.08.19-0012-rolling`.
- Official upstream release: https://github.com/vyos/vyos-nightly-build/releases/tag/2026.08.19-0012-rolling
- Exact `vyos/vyos-build` commit: `b84fb1af685a8fa371117a2b5b0e2070ede0ff61`.
- Verified critical userspace package parity: FRR `10.6.1-0`, Podman `5.8.4`, vyos-1x `999.0-14748-gfb4317a14`.
- Raspberry Pi hardware base: `rpi-armbian-edge-7.1.8-vyos-parity`.
- Raspberry Pi kernel: `7.1.8`.
- Fresh-install `.img.xz` uses the production Raspberry Pi A/B partition layout.
- Matching `update.tar.zst` is published for `add system image` local, HTTP(S), and `latest` updates.
- A/B `tryboot`, automatic health-check/commit and hardware-watchdog rollback have been validated on physical Raspberry Pi hardware.
- Interactive A/B updates offer the test reboot automatically; validation PASS/FAIL is reported on the system console, the final result is shown on the next normal login, and failed or hung test boots roll back automatically without waiting for user input.
- Installer v0.7 preserves a copied custom update metadata URL, injects the Raspberry Pi rolling metadata URL when missing, and requires the running test slot to expose an update URL before commit.
- Published automatically after A/B full-image and update-bundle QA.
- See the linked official VyOS release for the upstream VyOS changes contained in this build.


## v2026.08.18-1030-rolling-rpi

- Synchronized to official VyOS Rolling `2026.08.18-1030-rolling`.
- Official upstream release: https://github.com/vyos/vyos-nightly-build/releases/tag/2026.08.18-1030-rolling
- Exact `vyos/vyos-build` commit: `72bae92436040146e55ca106dce41c9bca416c25`.
- Verified critical userspace package parity: FRR `10.6.1-0`, Podman `5.8.4`, vyos-1x `999.0-14743-gde57cd205`.
- Raspberry Pi hardware base: `rpi-armbian-edge-7.1.8-vyos-parity`.
- Raspberry Pi kernel: `7.1.8`.
- Fresh-install `.img.xz` uses the production Raspberry Pi A/B partition layout.
- Matching `update.tar.zst` is published for `add system image` local, HTTP(S), and `latest` updates.
- A/B `tryboot`, automatic health-check/commit and hardware-watchdog rollback have been validated on physical Raspberry Pi hardware.
- Interactive A/B updates offer the test reboot automatically; validation PASS/FAIL is reported on the system console, the final result is shown on the next normal login, and failed or hung test boots roll back automatically without waiting for user input.
- Installer v0.7 preserves a copied custom update metadata URL, injects the Raspberry Pi rolling metadata URL when missing, and requires the running test slot to expose an update URL before commit.
- Published automatically after A/B full-image and update-bundle QA.
- See the linked official VyOS release for the upstream VyOS changes contained in this build.


## Unreleased
- Fix auto-nightly duplicate rebuilds of an already published Raspberry Pi version by restoring the repository-scoped `GITHUB_TOKEN` for the local release-existence check; upstream VyOS discovery remains REST-free.
- A/B update UX v0.7 reports validation PASS/FAIL on the system console and persists the test result on the shared `VYOS_AB` partition so the next normal login can show either successful activation or automatic rollback.
- Healthy test boots still commit and reboot automatically into `tryboot=0`; failed or hung test boots still return to the previous default without waiting for user input.
- `auto-vyos-pi-nightly.yml` no longer depends on unauthenticated GitHub REST calls to `api.github.com` for VyOS discovery. It uses the official rolling `version.json`, signed release assets, and Git protocol commit resolution for abbreviated upstream SHAs.
- A/B update UX v0.6 hides the Raspberry Pi `tryboot` command during the normal interactive update path: after a successful install the dispatcher offers to reboot into the test slot.
- After a healthy tryboot is committed, the automatic guard requests one final normal reboot so the new default returns with `tryboot=0`; failed or hung test boots still roll back to the previous default slot.
- A/B installer v0.6 now preserves a copied custom `system update-check url` and injects the project rolling metadata URL when the copied configuration has no update source; the runtime healthcheck refuses to commit a test slot if the update URL is missing from the loaded VyOS configuration.
- The manual `v2026.08.14-0025-rolling-rpi-m` baseline can be rebuilt from this v0.6 code and subsequent automated releases inherit the same update and reboot behavior.
- Added support for a manually tagged Raspberry Pi production baseline (`-rpi-m`) while keeping future automated releases on the normal `-rpi` tag scheme.
- `write-version-json.py` can now target an explicit release tag so `latest` can point at the manual baseline until the next successful automated release.

- Handle `Ctrl+C` in the Raspberry Pi A/B installer and image dispatcher without Python tracebacks; interrupted commands exit with status 130.
- Keep the strict safety gate that permits A/B writes only from a normal/default boot (`tryboot=0`).
- Document the required normal reboot after a successful tryboot/auto-commit before another update may overwrite the previous rollback slot.
- Physical Raspberry Pi validation confirmed that the existing `2026.08.14-0025-rolling` public release resolves through `add system image latest`, downloads from GitHub Releases, verifies all A/B payload SHA-256 hashes, and reaches the native A/B installer.
- Existing-image A/B converter v0.2 now preserves the source `config.boot` while ensuring the Raspberry Pi `rolling/version.json` update-check URL is present in both full-image slots and the matching update rootfs payload.

## v2026.08.14-0025-rolling-rpi

- Synchronized to official VyOS Rolling `2026.08.14-0025-rolling`.
- Official upstream release: https://github.com/vyos/vyos-nightly-build/releases/tag/2026.08.14-0025-rolling
- Exact `vyos/vyos-build` commit: `6b7e4d844988a3b5650cbc9ca736c216b1af857d`.
- Verified critical userspace package parity: FRR `10.6.1-0`, Podman `5.8.4`, vyos-1x `999.0-14687-gc0583c996`.
- Raspberry Pi hardware base: `rpi-armbian-edge-7.1.8-vyos-parity`.
- Raspberry Pi kernel: `7.1.8`.
- Fresh-install `.img.xz` uses the production Raspberry Pi A/B partition layout.
- Matching `update.tar.zst` is published for `add system image` local, HTTP(S), and `latest` updates.
- A/B `tryboot`, automatic health-check/commit and hardware-watchdog rollback have been validated on physical Raspberry Pi hardware.
- Interactive A/B updates offer the test reboot automatically; validation PASS/FAIL is reported on the system console, the final result is shown on the next normal login, and failed or hung test boots roll back automatically without waiting for user input.
- Installer v0.7 preserves a copied custom update metadata URL, injects the Raspberry Pi rolling metadata URL when missing, and requires the running test slot to expose an update URL before commit.
- Published automatically after A/B full-image and update-bundle QA.
- See the linked official VyOS release for the upstream VyOS changes contained in this build.

## v2026.08.13-0024-rolling-rpi

- Synchronized to official VyOS Rolling `2026.08.13-0024-rolling`.
- Official upstream release: https://github.com/vyos/vyos-nightly-build/releases/tag/2026.08.13-0024-rolling
- Exact `vyos/vyos-build` commit: `e14a4895cd5add37240fca9da195832b8a8683e3`.
- Verified userspace parity: FRR `10.6.1-0`, Podman `5.8.4`, vyos-1x `999.0-14675-gba8924dd2`.
- Raspberry Pi hardware base remains `rpi-armbian-edge-7.1.8-vyos-parity`.
- Raspberry Pi kernel remains `7.1.8`.
- Published automatically as the latest GitHub release after static build and image QA.
- See the linked official VyOS release for the upstream VyOS changes contained in this build.
- Full-image flashing remains supported; A/B update bundles remain experimental.


## v2026.08.12-0831-rolling-rpi

- Synced VyOS userspace to official VyOS `2026.08.12-0831-rolling`.
- ARM64 release build pinned to exact `vyos/vyos-build` commit `e14a4895cd5add37240fca9da195832b8a8683e3`.
- Updated Raspberry Pi hardware base to `rpi-armbian-edge-7.1.8-vyos-parity`.
- Kernel remains `7.1.8-edge-bcm2711` with expanded VyOS kernel feature parity while preserving Raspberry Pi hardware support.
- Kernel modules use Zstandard compression; module dependency indexes are generated and validated.
- Raspberry Pi 5 validation passed: boot, SSH, NTP, onboard 5 GHz Wi-Fi AP, DHCP, Ethernet WAN/NAT, FM350 USB/RNDIS and Ethernet-to-WWAN failover.
- Full-image flashing remains the supported upgrade method for this release. A/B image upgrades are planned separately.


All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [v2026.08.12-pi5] - 2026-08-12

### Raspberry Pi 5

- Started Raspberry Pi 5 port of the VyOS rolling ARM64 image build.
- Uses a tested Armbian edge image as the Raspberry Pi 5 hardware base.
- Armbian provides boot-chain, kernel, device trees, kernel modules and hardware firmware.
- VyOS rolling provides userspace and routing functionality.
- The project is based conceptually on the proven ROCK 5B VyOS build while remaining an independent repository.

### Hardware validation

- First complete GitHub Actions image pipeline successfully produced a flashable Raspberry Pi image.
- Hardware-tested on Raspberry Pi 5 with VyOS `1.5-rolling-202608121101`.
- Verified Linux `7.1.8-edge-bcm2711` Raspberry Pi kernel and modules.
- Verified onboard Ethernet DHCP, SSH and persistent VyOS configuration.
- Verified `show configuration commands` and normal VyOS configuration handling.
- Verified onboard Broadcom Wi-Fi AP operation at 2.4 GHz / 802.11n.
- Verified onboard Broadcom Wi-Fi AP operation at 5 GHz / 802.11ac / 80 MHz on channel 36.
- Verified complete WPA2 four-way handshake, DHCP, DNS forwarding, NAT and client Internet access.
- Observed 5 GHz link rate up to `433.3 MBit/s`.
- Verified Fibocom FM350-GL USB/RNDIS on Raspberry Pi 5 as native interface `eth1`.
- Verified FM350 AT port detection, FCC unlock and AT/RNDIS Internet data path.
- Verified Ethernet WAN preference on `eth0` with metric 20 and FM350 WWAN fallback on `eth1` with metric 200.
- Verified automatic Ethernet-to-WWAN failover and WWAN-to-Ethernet failback.
- Verified Internet access from a 5 GHz AP client through the FM350.
- Verified modem autostart after reboot.
- Verified locale, DNS and NTP/Chrony setup.

### Build and release

- Added the complete GitHub Actions workflow for a fresh VyOS Rolling ARM64 build, Raspberry Pi merge, image creation, XZ compression and metadata generation.
- Pinned the Raspberry Pi Armbian hardware base to release `rpi-armbian-edge-7.1.8`.
- Full image build validated from GitHub Actions run `31589525721`.
- Release artifact: `vyos-pi5-fresh.img.xz`.
- Release assets: `vyos-pi5-fresh.img.xz` and `SHA256SUMS`.
