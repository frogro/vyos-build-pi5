#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description='Insert or replace one Raspberry Pi release changelog section.')
    p.add_argument('--file', default='CHANGELOG.md')
    p.add_argument('--version', required=True)
    p.add_argument('--upstream-url', required=True)
    p.add_argument('--vyos-ref', required=True)
    p.add_argument('--frr-version', required=True)
    p.add_argument('--podman-version', required=True)
    p.add_argument('--vyos1x-version', required=True)
    p.add_argument('--kernel', required=True)
    p.add_argument('--base-tag', required=True)
    return p.parse_args()


def main() -> int:
    a = parse_args()
    path = Path(a.file)
    text = path.read_text(encoding='utf-8')
    heading = f'## v{a.version}-rpi'

    entry = f'''{heading}

- Synchronized to official VyOS Rolling `{a.version}`.
- Official upstream release: {a.upstream_url}
- Exact `vyos/vyos-build` commit: `{a.vyos_ref}`.
- Verified userspace parity: FRR `{a.frr_version}`, Podman `{a.podman_version}`, vyos-1x `{a.vyos1x_version}`.
- Raspberry Pi hardware base: `{a.base_tag}`.
- Raspberry Pi kernel: `{a.kernel}`.
- Fresh-install `.img.xz` uses the production Raspberry Pi A/B partition layout.
- Matching `update.tar.zst` is published for `add system image` local, HTTP(S), and `latest` updates.
- A/B `tryboot`, automatic health-check/commit and hardware-watchdog rollback have been validated on physical Raspberry Pi hardware.
- Interactive A/B updates offer the test reboot automatically; validation PASS/FAIL is reported on the system console, the final result is shown on the next normal login, and failed or hung test boots roll back automatically without waiting for user input.
- Installer v0.7 preserves a copied custom update metadata URL, injects the Raspberry Pi rolling metadata URL when missing, and requires the running test slot to expose an update URL before commit.
- Published automatically after A/B full-image and update-bundle QA.
- See the linked official VyOS release for the upstream VyOS changes contained in this build.
'''

    lines = text.splitlines(keepends=True)
    start = None
    end = None
    for i, line in enumerate(lines):
        if line.rstrip('\n') == heading:
            start = i
            for j in range(i + 1, len(lines)):
                if lines[j].startswith('## '):
                    end = j
                    break
            if end is None:
                end = len(lines)
            break

    replacement = [line + '\n' for line in entry.rstrip('\n').split('\n')] + ['\n']
    if start is not None:
        lines[start:end] = replacement
    else:
        pos = 1 if lines and lines[0].startswith('# ') else 0
        lines[pos:pos] = ['\n'] + replacement

    path.write_text(''.join(lines), encoding='utf-8')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
