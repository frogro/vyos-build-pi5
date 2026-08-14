#!/usr/bin/env python3
from __future__ import annotations

import argparse
from datetime import datetime
import json
from pathlib import Path
import re

VERSION_RE = re.compile(r'^\d{4}\.\d{2}\.\d{2}-\d{4}-rolling$')


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description='Write VyOS Raspberry Pi latest-update metadata.')
    p.add_argument('--version', required=True)
    p.add_argument('--timestamp', required=True)
    p.add_argument('--repository', required=True, help='owner/repository')
    p.add_argument('--output', default='version.json')
    return p.parse_args()


def main() -> int:
    a = parse_args()
    if not VERSION_RE.fullmatch(a.version):
        raise SystemExit(f'ERROR: invalid VyOS Rolling version: {a.version}')
    if '/' not in a.repository or a.repository.startswith('/') or a.repository.endswith('/'):
        raise SystemExit(f'ERROR: invalid GitHub repository: {a.repository}')
    try:
        datetime.fromisoformat(a.timestamp.replace('Z', '+00:00'))
    except ValueError as exc:
        raise SystemExit(f'ERROR: invalid ISO timestamp: {a.timestamp}') from exc

    tag = f'v{a.version}-rpi'
    asset = f'vyos-{a.version}-rpi-arm64-update.tar.zst'
    url = f'https://github.com/{a.repository}/releases/download/{tag}/{asset}'
    payload = [{'url': url, 'version': a.version, 'timestamp': a.timestamp}]
    Path(a.output).write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
