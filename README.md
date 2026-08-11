# VyOS for Raspberry Pi 5

> Unofficial community build of **VyOS Rolling** for the **Raspberry Pi 5**.

[![GitHub Release](https://img.shields.io/github/v/release/frogro/vyos-build-pi5?style=for-the-badge)](https://github.com/frogro/vyos-build-pi5/releases)
[![GitHub Downloads](https://img.shields.io/github/downloads/frogro/vyos-build-pi5/total?style=for-the-badge)](https://github.com/frogro/vyos-build-pi5/releases)
[![Donate with PayPal](https://img.shields.io/badge/Donate-PayPal-00457C?style=for-the-badge&logo=paypal&logoColor=white)](https://paypal.me/FGrootens)

> [!NOTE]
> **Status: Raspberry Pi 5 port in development.**
>
> The first Armbian edge hardware base has been built and its compressed
> image has passed integrity verification. The VyOS merge, first-boot
> integration and final Raspberry Pi 5 hardware validation are still in
> progress.

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Armbian Raspberry Pi 5 Base](#armbian-raspberry-pi-5-base)
- [Quick Start](#quick-start)
- [First Boot and Login](#first-boot-and-login)
- [Optional Helper Scripts](#optional-helper-scripts)
- [Supported Hardware](#supported-hardware)
- [WAN Failover Design](#wan-failover-design)
- [Network Firmware Supplement](#network-firmware-supplement)
- [Build from Source](#build-from-source)
- [Build Design](#build-design)
- [Repository Layout](#repository-layout)
- [Releases](#releases)
- [Validation Before Release](#validation-before-release)
- [ROCK 5B Reference Implementation](#rock-5b-reference-implementation)
- [Changelog](CHANGELOG.md)
- [Contributing](CONTRIBUTING.md)
- [Security](SECURITY.md)
- [License and Trademarks](#license-and-trademarks)
- [Support the Project](#️-support-the-project)

## Overview

This repository provides an independent Raspberry Pi 5 port of the
VyOS Rolling ARM64 image-build concept developed and proven in the
separate ROCK 5B project:

https://github.com/frogro/vyos-build

The image design combines:

- the VyOS ARM64 userspace and configuration system;
- a pinned Armbian Raspberry Pi hardware base;
- the Armbian Linux kernel and kernel modules;
- Raspberry Pi Device Trees, overlays and boot support;
- hardware firmware supplied by Armbian;
- Raspberry Pi 5-specific image merge logic;
- VyOS first-boot networking helpers;
- optional Wi-Fi AP and cellular/WWAN automation.

The Raspberry Pi 5 project is maintained separately from the ROCK 5B
repository and has its own Git history, workflow, tags and releases.

**Upstream attribution:** VyOS provides the routing userspace and
configuration framework. Armbian provides the Raspberry Pi-compatible
kernel, modules, firmware, Device Trees and boot integration used as the
hardware base.

> [!WARNING]
> This is an independent community project. It is not produced,
> supported, sponsored, certified, or endorsed by VyOS, Sentrium S.L.,
> Armbian, or Raspberry Pi. Rolling releases may contain regressions and
> should be tested before production use.

## Features

The Raspberry Pi 5 port is intended to retain the high-level functionality
of the ROCK 5B implementation while keeping Raspberry Pi-specific boot,
kernel, Device Tree and hardware handling separate.

Planned features:

- Raspberry Pi 5 boot using a pinned Armbian edge hardware base
- VyOS Rolling ARM64 userspace and configuration system
- Raspberry Pi-compatible kernel, Device Trees, modules and firmware from Armbian
- automatic wired WAN setup on first boot
- DHCP on the detected Ethernet interface
- SSH access
- optional wireless access point
- optional DHCP server, DNS forwarding and NAT for AP clients
- optional LTE/5G modem support
- Ethernet/WWAN failover
- missing-only network firmware supplementation
- GitHub Actions workflow for reproducible image builds
- ready-to-flash compressed images through GitHub Releases
- SHA-256 verification

Only functionality actually verified on Raspberry Pi 5 hardware will be
listed as confirmed working in release notes.

## Armbian Raspberry Pi 5 Base

The initial Raspberry Pi 5 hardware base was built with:

```text
Armbian version: 26.08.0-trunk
Debian release:  trixie
Branch:          edge
Kernel:          7.1.8
Armbian target:  rpi4b
Build type:      minimal
```

Original Armbian build command:

```bash
./compile.sh build \
  BOARD=rpi4b \
  BRANCH=edge \
  BUILD_MINIMAL=yes \
  KERNEL_BTF=no \
  KERNEL_CONFIGURE=no \
  RELEASE=trixie
```

Original build artifact:

```text
Armbian-unofficial_26.08.0-trunk_Rpi4b_trixie_edge_7.1.8_minimal.img
```

Original uncompressed image SHA-256:

```text
f810ec01742611fc37fbc5ce7bd18562b2e1aee94afa909e06616864bd818f90
```

Compressed `.img.xz` SHA-256:

```text
4ab4c80263652f16f02594d27da129299f8dc5cbff0404e73f65ada2eeb43275
```

The compressed image has passed `xz -t`.

The exact base release, asset name and checksum are pinned in:

```text
config/pi5-armbian-base.env
```

The internal Armbian target is intentionally recorded as `rpi4b`, because
that is the actual target used by the Armbian build that produced this
Raspberry Pi image.

Updating the Armbian hardware base will be an explicit repository change.
The build workflow must never silently follow an unpinned moving image.

## Quick Start

> [!NOTE]
> The first hardware-tested VyOS Raspberry Pi 5 image has not yet been
> published. The instructions below describe the intended installation
> process once a release is available.

### 1. Download the ready-to-use image

Open the Releases page:

https://github.com/frogro/vyos-build-pi5/releases

A normal VyOS Raspberry Pi 5 release will contain:

```text
vyos-pi5-fresh.img.xz
SHA256SUMS
```

Verify the download on Linux:

```bash
sha256sum -c SHA256SUMS
```

Use a target drive that is larger than the uncompressed image. The final
minimum storage size will be documented after the first complete Pi 5
VyOS image has been built and tested.

### 2. Flash with balenaEtcher

[balenaEtcher](https://etcher.balena.io/) is available for Linux, Windows
and macOS.

1. Start balenaEtcher.
2. Select `vyos-pi5-fresh.img.xz` directly.
3. Select the SD card, NVMe SSD, USB drive, or other supported Pi 5 boot device.
4. Click **Flash**.
5. Wait for flashing and verification to finish.

> [!CAUTION]
> Flashing destroys all data on the selected target drive. Verify the
> destination carefully.

### 3. Flash from Linux with `dd`

Replace `/dev/sdX` with the complete target device, not a partition such
as `/dev/sdX1`.

Write the compressed image directly:

```bash
sudo umount /dev/sdX?* 2>/dev/null || true
xz -dc vyos-pi5-fresh.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
sync
sudo eject /dev/sdX
```

Or extract first:

```bash
xz -dk vyos-pi5-fresh.img.xz
sudo umount /dev/sdX?* 2>/dev/null || true
sudo dd if=vyos-pi5-fresh.img of=/dev/sdX bs=4M status=progress conv=fsync
sync
sudo eject /dev/sdX
```

## First Boot and Login

The intended first-boot behavior follows the proven ROCK 5B networking
design, but exact Raspberry Pi 5 interface names, timing and diagnostics
will be documented only after hardware validation.

Planned sequence:

```text
Raspberry Pi 5 starts
        ↓
Armbian-derived kernel/boot environment starts
        ↓
VyOS configuration loads
        ↓
first-boot networking helper runs
        ↓
Ethernet interface is detected
        ↓
DHCP is configured
        ↓
SSH is enabled
        ↓
configuration is committed and saved
```

The intended default credentials are:

```text
Username: vyos
Password: vyos
```

Example SSH login after DHCP has assigned an address:

```bash
ssh vyos@192.168.1.100
```

> [!IMPORTANT]
> Change the default password immediately after first login. For stronger
> security, configure SSH key authentication and stop using password-based
> login.

Change the password:

```text
configure
set system login user vyos authentication plaintext-password 'YOUR_NEW_PASSWORD'
commit
save
exit
```

## Optional Helper Scripts

The Raspberry Pi 5 port is intended to retain the helper-script model used
by the ROCK 5B project. Applicable scripts will be installed under:

```text
/home/vyos
```

Planned helper scripts include:

```text
/home/vyos/ap-dhcp-wan-setup.sh
/home/vyos/dhcp-wan-ssh-setup.sh
/home/vyos/modem-connect.sh
/home/vyos/set-locales.sh
```

### Configure a wireless access point

Planned command:

```bash
/home/vyos/ap-dhcp-wan-setup.sh
```

The helper is intended to configure an access point, DHCP server, DNS
forwarding and NAT. Raspberry Pi 5 wireless PHY, driver and AP behavior
must be validated before onboard Wi-Fi is listed as confirmed.

### Configure a modem

Planned command:

```bash
sudo /home/vyos/modem-connect.sh
```

The higher-level modem logic from the ROCK 5B implementation will be
ported where it is independent of the board. Actual connectivity depends
on modem transport, drivers, firmware, carrier, APN and Pi 5 USB/PCIe
support.

## Supported Hardware

### Raspberry Pi 5 platform

Initial hardware validation will cover:

- cold boot
- reboot
- ARM64 kernel
- Raspberry Pi Device Tree
- boot partition and firmware
- Ethernet
- USB
- PCIe
- onboard Wi-Fi
- Bluetooth
- HDMI/console
- storage

Hardware is only listed as confirmed working after real testing.

### Wi-Fi adapters

The AP helper design inherited from the ROCK 5B implementation can
enumerate Linux wireless PHYs under `/sys/class/ieee80211`, inspect
`iw phy` capabilities and offer devices that advertise AP mode.

Candidate adapter families include:

- MediaTek MT7921/MT7922-class PCIe Wi-Fi adapters
- Realtek RTL8852-class PCIe Wi-Fi adapters
- MediaTek MT7612U USB adapters
- other Linux `mac80211` adapters that advertise AP mode

These are not automatically considered Raspberry Pi 5-tested devices.

Useful diagnostics:

```bash
ip link show
iw dev
iw phy
dmesg
```

### Cellular modems

The ROCK 5B modem implementation provides reusable concepts for:

- ModemManager
- MBIM
- QMI
- PCIe/MHI
- USB
- raw AT commands
- RNDIS fallback
- WWAN interface discovery
- runtime IPv4 configuration
- fallback routing
- NAT/firewall integration
- connection validation and recovery

Porting candidates include:

- Fibocom FM350-GL
- Quectel RM505Q-AE
- other ModemManager-compatible MBIM/QMI devices

No modem is considered Raspberry Pi 5-tested until the corresponding
transport, driver and data path have been validated on Pi 5 hardware.

## WAN Failover Design

The intended routing model follows the ROCK 5B implementation:

```text
Ethernet WAN
default route metric 20
        │
        │ preferred
        ▼
Internet

5G / WWAN
default route metric 200
        │
        │ fallback
        ▼
Internet
```

Intended behavior:

```text
Ethernet available
        ↓
Ethernet is primary WAN

Ethernet disconnected
        ↓
WWAN becomes the usable fallback

Ethernet restored
        ↓
Ethernet becomes preferred again
WWAN remains available as fallback
```

This behavior must be revalidated on the Raspberry Pi 5.

## Network Firmware Supplement

The ROCK 5B build keeps Armbian firmware as the primary firmware tree and
adds missing network firmware without replacing files already supplied by
Armbian.

The Raspberry Pi 5 port will follow the same principle:

```text
Armbian firmware
        │
        ├── preserved
        ▼
missing-only linux-firmware supplement
```

Candidate supplemental firmware families include:

- MediaTek Wi-Fi / Bluetooth
- Realtek `rtw88`
- Realtek `rtw89`
- Realtek Bluetooth
- Realtek NIC firmware
- Intel `iwlwifi`
- Intel Bluetooth

The exact firmware set will be reviewed against the Raspberry Pi 5 kernel
and actual attached hardware before the workflow is finalized.

## Build from Source

The intended workflow is:

```text
.github/workflows/build-vyos-pi5.yml
```

> [!NOTE]
> The workflow will not be enabled until the Raspberry Pi-specific merge
> process has been implemented and reviewed.

Intended GitHub Actions process:

```text
workflow_dispatch
        ↓
download pinned Armbian Pi 5 base release
        ↓
verify SHA-256
        ↓
build/extract VyOS Rolling ARM64 rootfs
        ↓
prepare working image
        ↓
preserve Raspberry Pi boot/kernel/modules/firmware
        ↓
merge VyOS userspace
        ↓
inject first-boot helpers
        ↓
supplement missing network firmware
        ↓
create final image
        ↓
compress with xz
        ↓
generate SHA256SUMS
        ↓
upload GitHub Actions artifact
```

Once enabled, start the workflow with GitHub CLI:

```bash
gh workflow run build-vyos-pi5.yml \
  --repo frogro/vyos-build-pi5 \
  --ref rolling
```

Watch a run:

```bash
gh run watch RUN_ID \
  --repo frogro/vyos-build-pi5 \
  --exit-status
```

Download a completed artifact:

```bash
mkdir -p ~/Downloads/vyos-pi5-RUN_ID
gh run download RUN_ID \
  --repo frogro/vyos-build-pi5 \
  --dir ~/Downloads/vyos-pi5-RUN_ID
```

Intended artifact layout:

```text
vyos-pi5-image/
├── vyos-pi5-fresh.img.xz
└── SHA256SUMS
```

## Build Design

The image is assembled from two main components:

1. **Pinned Armbian Raspberry Pi hardware base**
   - Raspberry Pi boot environment
   - Linux kernel
   - Device Trees and overlays
   - kernel modules
   - hardware firmware

2. **VyOS Rolling ARM64 root filesystem**
   - VyOS userspace
   - configuration system
   - services
   - routing stack
   - firewall/NAT
   - CLI

Simplified design:

```text
Pinned Armbian Pi 5 image
        │
        ├── boot
        ├── kernel
        ├── Device Trees / overlays
        ├── modules
        └── firmware
        │
        ▼
Raspberry Pi 5 merge process
        ▲
        │
VyOS Rolling ARM64 rootfs
        │
        ▼
first-boot + networking integration
        │
        ▼
flashable Raspberry Pi 5 VyOS image
```

The build deliberately preserves the tested Raspberry Pi-compatible
physical image and hardware-support environment rather than replacing it
with ROCK 5B/RK3588 boot assumptions.

The Armbian base is pinned so a kernel or boot-chain update becomes an
explicit and independently testable change.

## Repository Layout

Target structure:

```text
vyos-build-pi5/
│
├── .github/
│   └── workflows/
│       └── build-vyos-pi5.yml
│
├── config/
│   └── pi5-armbian-base.env
│
├── docs/
│   └── ROCK5B-PORTING-NOTES.md
│
├── scripts/
│   └── pi5/
│       ├── merge-vyos-pi5.sh
│       ├── inject-defaults.sh
│       ├── install-network-firmware.sh
│       └── first-boot/
│           ├── ap-dhcp-wan-setup.sh
│           ├── dhcp-wan-ssh-setup.sh
│           ├── modem-connect.sh
│           └── set-locales.sh
│
├── CHANGELOG.md
├── CONTRIBUTING.md
├── SECURITY.md
├── README.md
└── .gitignore
```

Some files are intentionally added only when the corresponding Raspberry
Pi 5 implementation exists.

## Releases

This repository uses two distinct release types.

### Armbian hardware-base release

The pinned Armbian image used as build input is published separately.

Initial planned tag:

```text
pi5-armbian-edge-7.1.8
```

Assets:

```text
armbian-pi5-trixie-edge-7.1.8-minimal.img.xz
SHA256SUMS
```

The GitHub Actions workflow will download this exact asset and verify its
checksum before beginning the VyOS merge.

### VyOS Raspberry Pi 5 release

After a generated image has passed real Raspberry Pi 5 hardware testing,
a VyOS release can be published.

Tag format:

```text
vYYYY.MM.DD-pi5
```

Additional release on the same day:

```text
vYYYY.MM.DD-pi5-r2
```

Assets:

```text
vyos-pi5-fresh.img.xz
SHA256SUMS
```

Release notes must distinguish between implemented functionality,
hardware actually tested on Raspberry Pi 5, and inherited/reference
functionality that is not yet Pi5-verified.

See [CHANGELOG.md](CHANGELOG.md) for release changes.

## Validation Before Release

Before a VyOS Raspberry Pi 5 release is marked as tested, validate at
least:

```text
[ ] XZ integrity
[ ] SHA-256
[ ] Raspberry Pi 5 cold boot
[ ] reboot
[ ] correct ARM64 kernel
[ ] correct Raspberry Pi Device Tree
[ ] root filesystem
[ ] Ethernet detection
[ ] Ethernet DHCP
[ ] SSH
[ ] onboard Wi-Fi detection
[ ] Bluetooth detection
[ ] AP mode
[ ] wireless DHCP
[ ] NAT
[ ] Internet access from AP client
[ ] supplemental network firmware
[ ] USB devices
[ ] PCIe devices where applicable
[ ] cellular modem detection where applicable
[ ] WWAN connection where applicable
[ ] Ethernet -> WWAN failover where applicable
[ ] WWAN -> Ethernet return path where applicable
```

Release notes should only claim tests that were actually completed.

## ROCK 5B Reference Implementation

The Raspberry Pi 5 project is based on experience from the independently
maintained ROCK 5B repository:

https://github.com/frogro/vyos-build

Reference release during initial Pi 5 development:

```text
v2026.08.10-rock5b-r2
```

Reusable higher-level concepts include:

- VyOS Rolling ARM64 rootfs integration
- first-boot networking
- Wi-Fi AP configuration
- DHCP and NAT
- cellular modem handling
- Ethernet/WWAN failover
- missing-only network firmware supplementation
- GitHub Actions image packaging
- XZ and `SHA256SUMS` release handling

Board-specific ROCK 5B components are not reused blindly, including:

- RK3588 boot chain
- ROCK 5B U-Boot configuration
- Rockchip Device Trees
- Rockchip-specific partition assumptions
- Rockchip kernel/module assumptions

The Raspberry Pi 5 port instead preserves the tested Raspberry
Pi-compatible Armbian kernel and boot environment.

## License and Trademarks

The repository contains or builds software from multiple upstream
projects. Their respective licenses remain in effect. Review the license
and copyright files included in the repository and generated image.

“VyOS” and associated marks are trademarks of their respective owner.
“Armbian” and associated marks are trademarks of their respective owner.
“Raspberry Pi” and associated marks are trademarks of their respective
owner.

These names are used solely to identify compatibility, upstream software,
hardware, kernel and boot components.

No affiliation, sponsorship, certification or endorsement is claimed.

This repository does not redistribute third-party logo artwork.

## ❤️ Support the Project

If this project saves you time or makes it easier to run VyOS on the
Raspberry Pi 5, please consider supporting its development.

Contributions help cover hardware, testing, maintenance and development
time.

[![Donate with PayPal](https://img.shields.io/badge/Donate-PayPal-00457C?style=for-the-badge&logo=paypal&logoColor=white)](https://paypal.me/FGrootens)

Thank you for your support. ☕
