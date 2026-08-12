# VyOS for Raspberry Pi 4 / Raspberry Pi 5

> Unofficial community build of **VyOS Rolling ARM64** for the **Raspberry Pi 4 and Raspberry Pi 5**.

[![GitHub Release](https://img.shields.io/github/v/release/frogro/vyos-build-pi5?style=for-the-badge)](https://github.com/frogro/vyos-build-pi5/releases)
[![GitHub Downloads](https://img.shields.io/github/downloads/frogro/vyos-build-pi5/total?style=for-the-badge)](https://github.com/frogro/vyos-build-pi5/releases)
[![Donate with PayPal](https://img.shields.io/badge/Donate-PayPal-00457C?style=for-the-badge&logo=paypal&logoColor=white)](https://paypal.me/FGrootens)

## Table of Contents

- [Features](#features)
- [Quick Start](#quick-start)
- [First Boot and Login](#first-boot-and-login)
- [Optional Helper Scripts](#optional-helper-scripts)
- [Supported Hardware](#supported-hardware)
- [Build from Source](#build-from-source)
- [Build Design](#build-design)
- [Releases](#releases)
- [Changelog](CHANGELOG.md)
- [Contributing](CONTRIBUTING.md)
- [Security](SECURITY.md)
- [License and Trademarks](#license-and-trademarks)
- [Support the Project](#support-the-project)

This repository provides a build system for creating bootable **VyOS Rolling ARM64 images for Raspberry Pi 4 and Raspberry Pi 5**.

The image combines:

- the current VyOS Rolling ARM64 userspace and configuration system;
- a pinned and checksummed Armbian Raspberry Pi hardware base;
- Raspberry Pi Linux kernel, Device Trees, overlays, modules and firmware;
- Raspberry Pi-specific image integration;
- automatic first-boot Ethernet/DHCP configuration;
- SSH configuration;
- wireless access-point tools;
- cellular / WWAN integration and failover tools.

The result is a reproducible, ready-to-flash VyOS image without requiring users to manually assemble the Raspberry Pi boot environment and VyOS root filesystem.

**Upstream attribution:** VyOS provides the routing userspace and configuration framework. Armbian provides the Raspberry Pi-compatible Linux kernel, modules, firmware, Device Trees and boot integration used as the hardware base.

> [!WARNING]
> This is an independent community project. It is not produced, supported, sponsored, certified, or endorsed by VyOS, Sentrium S.L., Armbian, or Raspberry Pi.
>
> VyOS Rolling changes continuously and may contain regressions. Check the release notes and verify checksums before production use.

## Features

- Raspberry Pi 4 and Raspberry Pi 5 support
- Current VyOS Rolling ARM64 userspace and configuration system
- Pinned and checksummed Armbian Raspberry Pi hardware base
- Raspberry Pi Linux kernel, Device Trees, overlays, modules and firmware
- Automated GitHub Actions builds
- Ready-to-flash compressed images
- SHA-256 verification
- Automatic wired WAN configuration on first boot
- Automatic Ethernet interface detection
- DHCP WAN configuration
- Default-route verification
- SSH enabled during initial configuration
- Persistent VyOS configuration
- Optional wireless access point
- Optional DHCP server, DNS forwarding and NAT for wireless clients
- Cellular / WWAN modem setup
- Ethernet / WWAN failover
- WWAN health monitoring and recovery
- Missing-only network firmware supplementation
- Complete build and integration sources available on GitHub

The build system is designed so that the same VyOS image can be used on both **Raspberry Pi 4 and Raspberry Pi 5**.

Board-specific hardware behavior can differ between the two platforms. Hardware-specific validation is documented in the corresponding release notes where relevant.

---

## Quick Start

### 1. Download the ready-to-use image

Open the [GitHub Releases page](https://github.com/frogro/vyos-build-pi5/releases) and download:

```text
vyos-pi5-fresh.img.xz
SHA256SUMS
```

The same image is intended for both:

```text
Raspberry Pi 4
Raspberry Pi 5
```

Verify the download on Linux:

```bash
sha256sum -c SHA256SUMS
```

Expected result:

```text
vyos-pi5-fresh.img.xz: OK
```

You can also verify the XZ archive itself:

```bash
xz -t vyos-pi5-fresh.img.xz
```

Use a target drive that is larger than the uncompressed image.

### 2. Flash with balenaEtcher

[balenaEtcher](https://etcher.balena.io/) is available for Linux, Windows and macOS.

1. Start balenaEtcher.
2. Select `vyos-pi5-fresh.img.xz` directly.
3. Select the SD card, USB drive, SSD or other supported Raspberry Pi boot device.
4. Click **Flash**.
5. Wait for flashing and verification to complete.

> [!CAUTION]
> Flashing destroys all data on the selected target drive. Verify the destination carefully.

### 3. Flash from Linux with `dd`

Replace `/dev/sdX` with the complete target device, not a partition such as `/dev/sdX1`.

#### Option A: write the compressed image directly

```bash
sudo umount /dev/sdX?* 2>/dev/null || true
xz -dc vyos-pi5-fresh.img.xz | \
  sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
sync
sudo eject /dev/sdX
```

#### Option B: extract first, then write

```bash
xz -dk vyos-pi5-fresh.img.xz

sudo umount /dev/sdX?* 2>/dev/null || true
sudo dd if=vyos-pi5-fresh.img \
  of=/dev/sdX \
  bs=4M \
  status=progress \
  conv=fsync

sync
sudo eject /dev/sdX
```

---

## First Boot and Login

1. Connect the Raspberry Pi Ethernet port to a network that provides DHCP.
2. Insert or attach the flashed boot device.
3. Power on the Raspberry Pi 4 or Raspberry Pi 5.
4. Allow the first-boot configuration to complete.
5. Find the assigned IPv4 address in your router or DHCP server.
6. Connect over SSH.

During first boot the image automatically performs:

```text
Raspberry Pi boot
        ↓
VyOS Rolling startup
        ↓
wired Ethernet detection
        ↓
DHCP configuration
        ↓
IPv4 address verification
        ↓
default-route verification
        ↓
SSH configuration
        ↓
VyOS configuration commit + save
        ↓
first-boot service disables itself
```

Default credentials:

```text
Username: vyos
Password: vyos
```

Example:

```bash
ssh vyos@192.168.1.100
```

Replace `192.168.1.100` with the address assigned by your DHCP server.

> [!IMPORTANT]
> Change the default password immediately after the first login. For stronger security, configure SSH key authentication and stop using password-based login.

Change the password:

```text
configure
set system login user vyos authentication plaintext-password 'YOUR_NEW_PASSWORD'
commit
save
exit
```

The wired interface selected during first boot is recorded in:

```text
/config/.dhcp-wan-interface
```

Display it:

```bash
cat /config/.dhcp-wan-interface
```

Check its IPv4 address:

```bash
IFACE="$(cat /config/.dhcp-wan-interface)"
ip -4 -br addr show "$IFACE"
```

Check the default route:

```bash
ip -4 route show default
```

### First-boot diagnostics

```bash
cat /config/dhcp-wan-firstboot-wrapper.log
cat /config/dhcp-wan-ssh-setup.log
```

The successful first-boot marker is:

```text
/config/.dhcp-wan-ssh-firstboot-done
```

Check the DHCP client:

```bash
IFACE="$(cat /config/.dhcp-wan-interface)"
systemctl status "dhclient@${IFACE}.service" --no-pager -l
```

Check SSH:

```bash
ss -ltn | grep ':22'
```

---

## Optional Helper Scripts

The image includes networking helper scripts in:

```text
/home/vyos
```

### Wired DHCP and SSH

```bash
/home/vyos/dhcp-wan-ssh-setup.sh --auto
```

The helper automatically detects an appropriate wired Ethernet interface and configures:

- DHCP
- default-route preference
- SSH
- persistent VyOS configuration

An interface can also be selected explicitly:

```bash
/home/vyos/dhcp-wan-ssh-setup.sh --interface=eth0
```

### Wireless access point

```bash
/home/vyos/ap-dhcp-wan-setup.sh
```

The AP helper can configure:

- wireless access point
- DHCP server
- DNS forwarding
- NAT
- optional wired WAN

The helper discovers available Linux wireless PHYs and reads the capabilities reported by the kernel instead of depending only on one fixed adapter name or chipset.

### Configure a modem

```bash
sudo /home/vyos/modem-connect.sh
```

Modem support depends on the modem, transport, drivers, firmware, carrier, and APN.

---

## Supported Hardware

### Raspberry Pi boards

The build system targets:

- **Raspberry Pi 4**
- **Raspberry Pi 5**

The Raspberry Pi-compatible boot environment, Linux kernel, Device Trees, overlays, kernel modules and firmware are supplied by the pinned Armbian hardware base.

The same VyOS userspace and image-integration process are used for both boards.

### Ethernet

The first-boot configuration automatically discovers the wired Ethernet interface rather than relying on a fixed Raspberry Pi Ethernet MAC address.

The selected interface receives:

```text
DHCP address
default route
VyOS WAN configuration
SSH access
```

### Onboard Wi-Fi

Raspberry Pi onboard wireless support uses the Raspberry Pi kernel, `brcmfmac` driver and Broadcom firmware supplied by the hardware base and firmware integration.

Useful diagnostics:

```bash
iw dev
iw phy
ip link show
dmesg
```

Wireless behavior can differ between Raspberry Pi 4 and Raspberry Pi 5 and between kernel/firmware revisions.

### Additional Wi-Fi adapters

The AP helper can use compatible Linux wireless adapters that advertise AP mode.

The firmware-supplement mechanism covers network firmware families including:

- Broadcom Raspberry Pi Wi-Fi
- MediaTek Wi-Fi and Bluetooth
- Realtek `rtw88`
- Realtek `rtw89`
- Intel `iwlwifi`
- Intel Bluetooth

Actual support depends on the hardware, kernel driver and firmware.

### USB and PCIe

The Armbian hardware base provides the Raspberry Pi kernel and Device Trees used for USB and PCIe support.

Raspberry Pi 4 and Raspberry Pi 5 have different physical hardware capabilities, so device-specific results are documented in release notes where necessary.


### Cellular modems

`modem-connect.sh` supports PCIe- and USB-attached modems through ModemManager using QMI or MBIM, as well as a raw AT/RNDIS fallback path.

#### Included modem support

- Fibocom FM350-GL, including automatic FCC unlock over the AT port
- Quectel RM505Q-AE
- Intel XMM7560-based modems
- Other QMI- or MBIM-capable modems supported by ModemManager

Actual connectivity also depends on the SIM carrier, APN, regional firmware, and supported bands.

> [!NOTE]
> Cellular modem integration is included in the Raspberry Pi 4 / Raspberry Pi 5 image. Hardware-specific validation on Raspberry Pi 4 and Raspberry Pi 5 is documented in the corresponding release notes.

---

## Build from Source

The complete build and integration sources are available in this repository.

The build system combines a fresh VyOS Rolling ARM64 userspace with a pinned Raspberry Pi hardware base.

The automated build design is:

```text
current VyOS Rolling source
        ↓
VyOS ARM64 root filesystem
        +
pinned Armbian Raspberry Pi hardware base
        ↓
Raspberry Pi 4 / Raspberry Pi 5 integration
        ↓
first-boot networking
        ↓
network firmware integration
        ↓
flashable disk image
        ↓
XZ compression
        ↓
SHA256SUMS
```

The repository contains GitHub Actions automation for reproducible VyOS Rolling ARM64 builds and all scripts required to assemble the Raspberry Pi image.

The pinned Armbian hardware base is defined in:

```text
config/pi5-armbian-base.env
```

The base definition records the exact release asset, version information and SHA-256 checksums used during image assembly.

A hardware-base update is therefore an explicit repository change rather than a silent move to a different kernel or boot image.

### Current repository build components

Important build files include:

```text
.github/workflows/
scripts/pi5/
config/pi5-armbian-base.env
```

The Raspberry Pi integration scripts handle:

- Armbian base validation
- VyOS root filesystem merge
- Raspberry Pi boot/kernel/module preservation
- network firmware supplementation
- first-boot helper injection
- final disk-image generation
- image validation
- XZ compression and checksum generation

---

## Build Design

The image is assembled from two main components.

### 1. Armbian Raspberry Pi hardware base

Provides:

- Raspberry Pi boot environment
- ARM64 Linux kernel
- Device Trees
- overlays
- kernel modules
- hardware firmware

### 2. VyOS Rolling ARM64 root filesystem

Provides:

- VyOS userspace
- configuration system
- CLI
- routing
- firewall
- NAT
- DHCP
- SSH
- networking services

The merge process preserves the Raspberry Pi hardware environment while integrating the current VyOS Rolling ARM64 userspace.

```text
Pinned Armbian Raspberry Pi hardware base
        │
        ├── boot environment
        ├── kernel
        ├── Device Trees / overlays
        ├── modules
        └── firmware
        │
        ▼
Raspberry Pi 4 / Raspberry Pi 5 base
        ▲
        │
Current VyOS Rolling ARM64 root filesystem
        │
        ├── configuration system
        ├── routing
        ├── firewall / NAT
        ├── DHCP
        └── SSH
        │
        ▼
Raspberry Pi integration
        │
        ├── first-boot DHCP / SSH
        ├── AP helper
        ├── modem helper
        ├── network firmware
        └── image validation
        │
        ▼
Ready-to-flash VyOS image
        │
        ▼
.img.xz + SHA256SUMS
```

The hardware base is intentionally pinned.

This allows VyOS Rolling to be updated independently from the Raspberry Pi kernel and boot environment and makes hardware-base changes explicit, reproducible and independently testable.

---

## Releases

Prebuilt images are published on the [GitHub Releases page](https://github.com/frogro/vyos-build-pi5/releases).

The project uses two release types.

### VyOS Raspberry Pi release

This is the image intended for normal users.

Release assets normally include:

```text
vyos-pi5-fresh.img.xz
SHA256SUMS
```

Despite the historical `pi5` filename, the generated image is intended for both **Raspberry Pi 4 and Raspberry Pi 5**.

The compressed image can be flashed directly with balenaEtcher or written from Linux with `xz` and `dd`.

See [CHANGELOG.md](CHANGELOG.md) and the individual GitHub Release notes for version and hardware-validation information.

### Armbian hardware-base release

The Raspberry Pi hardware base is published separately as a pinned build input.

It contains the Raspberry Pi boot environment, kernel, Device Trees, overlays, modules and firmware used during VyOS image generation.

The exact hardware-base release asset and checksum are recorded in:

```text
config/pi5-armbian-base.env
```

The checksum is verified before the base is used for a VyOS image build.

Normal users should download the **VyOS Raspberry Pi release**, not the Armbian hardware-base image.

---

## License and Trademarks

The repository contains or builds software from multiple upstream projects. Their respective licenses remain in effect.

“VyOS” and associated marks are trademarks of their respective owner.

“Armbian” and associated marks are trademarks of their respective owner.

“Raspberry Pi” and associated marks are trademarks of their respective owner.

These names are used solely to identify compatibility, upstream software, boot/kernel components and supported hardware.

No affiliation, sponsorship, certification or endorsement is claimed.

This repository does not redistribute third-party logo artwork.

---

## Support the Project

If this project saves you time or makes it easier to run VyOS on a **Raspberry Pi 4 or Raspberry Pi 5**, please consider supporting its development.

Contributions help cover hardware, testing, maintenance and development time.

[![Donate with PayPal](https://img.shields.io/badge/Donate-PayPal-00457C?style=for-the-badge&logo=paypal&logoColor=white)](https://paypal.me/FGrootens)

Thank you for your support. ☕
