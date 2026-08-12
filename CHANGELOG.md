# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
