# ROCK 5B to Raspberry Pi 5 porting notes

Reference repository:

https://github.com/frogro/vyos-build

Reference release:

```text
v2026.08.10-rock5b-r2
```

## Reuse candidates

Review these ROCK 5B components for reuse:

- VyOS Rolling ARM64 rootfs build
- first-boot script injection
- `set-locales.sh`
- `dhcp-wan-ssh-setup.sh`
- `modem-connect.sh`
- AP/DHCP/NAT higher-level logic
- missing-only network firmware installation
- XZ generation
- `SHA256SUMS` generation
- GitHub Actions artifact handling
- GitHub release workflow

## Reuse only after Raspberry Pi 5 validation

- `ap-dhcp-wan-setup.sh`
- wireless PHY discovery
- wireless interface selection
- wireless driver assumptions
- ModemManager hardware discovery
- PCIe modem handling
- USB modem handling

## Do not copy board-specific implementation blindly

- RK3588 boot chain
- ROCK 5B U-Boot configuration
- ROCK 5B Device Trees
- Rockchip partition assumptions
- Rockchip boot scripts
- Rockchip kernel assumptions
- Rockchip module paths
- Rockchip-specific firmware assumptions

## Porting principle

Preserve the tested Raspberry Pi-compatible Armbian kernel, boot files,
Device Trees, modules and firmware, and merge VyOS Rolling userspace
around that environment.

Do not replace working Raspberry Pi hardware support unless there is a
specific, tested reason to do so.
