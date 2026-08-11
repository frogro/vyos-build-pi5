# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Raspberry Pi 5

- Started Raspberry Pi 5 port of the VyOS rolling ARM64 image build.
- Uses a tested Armbian edge image as the Raspberry Pi 5 hardware base.
- Armbian provides boot-chain, kernel, device trees, kernel modules and hardware firmware.
- VyOS rolling provides userspace and routing functionality.
- The project is based conceptually on the proven ROCK 5B VyOS build while remaining an independent repository.
