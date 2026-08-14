#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description='Render Raspberry Pi VyOS GitHub release notes.')
    p.add_argument('--version', required=True)
    p.add_argument('--upstream-name', required=True)
    p.add_argument('--upstream-published', required=True)
    p.add_argument('--upstream-url', required=True)
    p.add_argument('--vyos-ref', required=True)
    p.add_argument('--frr-version', required=True)
    p.add_argument('--podman-version', required=True)
    p.add_argument('--vyos1x-version', required=True)
    p.add_argument('--kernel', required=True)
    p.add_argument('--base-tag', required=True)
    p.add_argument('--upstream-notes-file', required=True)
    p.add_argument('--manual-baseline', action='store_true', help='mark this release as a manually published production baseline')
    p.add_argument('--output', required=True)
    return p.parse_args()


def main() -> int:
    a = parse_args()
    upstream_path = Path(a.upstream_notes_file)
    upstream = upstream_path.read_text(encoding='utf-8').strip() if upstream_path.exists() else ''
    if not upstream:
        upstream = 'No upstream release notes were supplied for this Nightly.'

    image = f'vyos-{a.version}-rpi-arm64.img.xz'
    update = f'vyos-{a.version}-rpi-arm64-update.tar.zst'

    baseline = '''
## Manual production baseline

This release was published manually as the production baseline for the Raspberry Pi A/B release pipeline. It uses the same image layout, update bundle format, `latest` metadata source, validation rules and runtime that subsequent automated Raspberry Pi releases use. The `-m` tag suffix identifies the manual baseline only; the embedded VyOS version remains unchanged.
''' if a.manual_baseline else ''

    text = f'''# VyOS {a.version} for Raspberry Pi 4 / 5

Unofficial Raspberry Pi ARM64 build based directly on the corresponding official VyOS Rolling Nightly.
{baseline}

## Official VyOS Rolling release

- Release: `{a.upstream_name}`
- Version: `{a.version}`
- Published: `{a.upstream_published}`
- Official release: {a.upstream_url}
- Exact `vyos/vyos-build` commit: `{a.vyos_ref}`

The build uses the exact `vyos/vyos-build` commit identified by this official Rolling release. Critical VyOS userspace package versions are checked against the signed official AMD64 ISO, while the complete AMD64/ARM64 package-lock comparison is retained as diagnostic metadata.

## Official VyOS release notes

{upstream}

## Verified critical userspace package parity

Strictly checked against the signed official VyOS AMD64 ISO:

- FRR: `{a.frr_version}`
- Podman: `{a.podman_version}`
- vyos-1x: `{a.vyos1x_version}`

## Raspberry Pi adaptation

- Architecture: `arm64`
- Build type: `release`
- Raspberry Pi hardware base: `{a.base_tag}`
- Kernel: `{a.kernel}`
- Fresh-install image: `{image}`
- A/B update bundle: `{update}`

The Raspberry Pi-specific kernel, boot environment, Device Trees, kernel modules and firmware are supplied by the pinned Raspberry Pi hardware base.

### Kernel note

This Raspberry Pi build uses a platform-specific Raspberry Pi/Armbian kernel instead of the kernel shipped with the official VyOS amd64 image. Therefore, kernel-related changes listed in the official VyOS Rolling release notes are not necessarily applied through the same VyOS kernel patches or configuration.

Some of these changes may already be present in the newer Raspberry Pi kernel, may be enabled through its kernel configuration, or may not be applicable to the Raspberry Pi platform at all. When a particular kernel feature or driver is important, its availability should be verified on the running system.

If you notice a kernel feature from the corresponding official VyOS Rolling release that is missing on the Raspberry Pi build and is relevant to this platform, please open an issue or, preferably, submit a pull request.

## A/B layout

The normal `.img.xz` release image is the production Raspberry Pi A/B image:

- `VYOS_AB` — control partition
- `VYOS_BOOT_A` / `VYOS_BOOT_B` — boot slots
- `VYOS_ROOT_A` / `VYOS_ROOT_B` — root slots

A fresh installation boots slot A by default. Slot B is the one-shot Raspberry Pi `tryboot` target.

## Updating an A/B installation

Local bundle:

    add system image /path/to/{update}

HTTP or HTTPS URL:

    add system image https://example/path/{update}

Latest published Raspberry Pi A/B release:

    add system image latest

Fresh images are preconfigured to use this repository's `rolling/version.json` as the Raspberry Pi update metadata source for `latest`.

Updates are written only to the inactive slot. After a successful interactive install, the dispatcher offers to reboot and test the new image immediately. The Raspberry Pi-specific `tryboot` command stays internal during the normal update flow.

During the one-shot test boot, the automatic A/B guard arms the hardware watchdog and runs the VyOS health check. A healthy slot reports validation PASSED on the system console, is committed as the new default, and after a short notice the guard requests one final normal reboot automatically. A failed validation reports FAILED and returns automatically to the previous default slot; a hung test boot is recovered by the watchdog. The result is persisted on the shared A/B control partition so the next normal interactive login reports successful activation or rollback.

When `/config` is copied to the new slot, installer v0.7 preserves an existing custom `system update-check url` and injects this repository's rolling metadata URL when no update source is present. The healthcheck verifies that an update URL is loaded before the test slot can be committed.

The installer accepts writes only from a normal/default boot (`tryboot=0`), keeping the previous slot as a known-good rollback target until the new default has completed a normal boot.

## Automated validation

This build passed:

- official VyOS ISO Minisign verification
- official VyOS version validation
- exact upstream source-commit resolution
- ARM64 release metadata validation
- FRR package-version parity
- Podman package-version parity
- vyos-1x package-version parity
- complete AMD64/ARM64 package-lock diagnostic comparison
- pinned Raspberry Pi hardware-base SHA256 validation
- Raspberry Pi kernel/module/DTB/firmware validation
- A/B partition/layout validation
- A/B runtime/dispatcher validation in both slots
- full-image and update-bundle SHA256 verification
- XZ integrity validation
- Zstandard update-bundle integrity validation

## Hardware validation status

The Raspberry Pi A/B mechanism — including A/B boot selection, Raspberry Pi `tryboot`, automatic health-check/commit, hardware-watchdog rollback, local bundle updates, HTTP(S) URL updates and `add system image latest` — has been validated on physical Raspberry Pi hardware.

Automatically generated Nightly artifacts still pass automated build-time validation rather than an individual physical boot test for every newly published Nightly.

## Disclaimer

This is an unofficial community Raspberry Pi build and is not an official VyOS image.
'''

    Path(a.output).write_text(text, encoding='utf-8')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
