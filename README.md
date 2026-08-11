# VyOS Raspberry Pi 5

Custom VyOS rolling ARM64 image build for Raspberry Pi 5.

The project combines:

- a tested Armbian edge Raspberry Pi 5 hardware base
- the VyOS rolling ARM64 root filesystem
- Raspberry Pi 5 specific boot/kernel integration
- custom networking and first-boot automation

## Build architecture

Armbian Raspberry Pi 5 edge image
        +
VyOS rolling ARM64 root filesystem
        +
Pi 5 specific merge/configuration
        =
flashable VyOS Raspberry Pi 5 image
