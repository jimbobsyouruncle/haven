#!/usr/bin/env python3
"""Small conservative PR test selector; unknown paths select full validation."""
import argparse
import re
import subprocess

COMPONENTS = ('backup', 'auth', 'proxy', 'status', 'inference', 'hermes', 'doctor')


def select(paths):
    selected = set()
    for path in paths:
        # Only prose and the two generated navigation maps are test-free.
        if path.endswith('.md') or path == 'LICENSE':
            continue
        if path.startswith('backup/') or path in (
            'scripts/test-backup.sh', 'scripts/test-backup-system-units.sh',
            'scripts/test-backup-mode-timers.sh', 'scripts/test-backup-containers.sh',
        ):
            selected.update(('backup', 'status', 'doctor'))
        elif path.startswith('auth/') or path in (
            'scripts/reset-passwords.sh', 'scripts/test-reset-passwords.sh',
            'scripts/test-auth-render.sh', 'scripts/test-install-auth-env-leak.sh',
        ):
            selected.update(('auth', 'proxy'))
        elif path.startswith('openwebui/'):
            # The status wake probe and doctor consume the same mesh/API contract.
            selected.update(('inference', 'status', 'doctor'))
        elif path.startswith('caddy/') or path.startswith('scripts/test-tls-') or path in (
            'scripts/tls-check.sh',
            'scripts/test-b77-port80-dynamic.sh',
            'status/Caddyfile', 'status/Caddyfile.tmpl',
        ):
            selected.update(('proxy', 'auth'))
        elif path.startswith('status/') or path.startswith('scripts/test-status-'):
            selected.update(('status', 'backup', 'proxy'))
        elif path.startswith('hermes/') or path == 'scripts/test-secret-guard.sh':
            selected.add('hermes')
        elif path == 'doctor.sh' or path.startswith('scripts/test-doctor-'):
            selected.update(('doctor', 'backup', 'status', 'inference'))
        else:
            # Shared paths, install/deploy, firewall/isolation, CI, new components:
            # intentionally no inference from directory names for these boundaries.
            return dict.fromkeys(('full',) + COMPONENTS, True)
    return {key: key in selected for key in ('full',) + COMPONENTS}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', help='exact PR base SHA; omitted means full suite')
    args = parser.parse_args()
    if args.base is None:
        result = dict.fromkeys(('full',) + COMPONENTS, True)
    else:
        if not re.fullmatch(r'[0-9a-f]{40}', args.base):
            parser.error('base must be a full lowercase commit SHA')
        # No shell or path interpolation. Deleted/renamed paths are included on
        # both sides; NUL records preserve whitespace/newlines in Git filenames.
        raw = subprocess.check_output([
            'git', 'diff', '--name-only', '-z', '--no-renames', args.base, 'HEAD', '--',
        ])
        paths = raw.decode('utf-8', errors='surrogateescape').split('\0')
        result = select([path for path in paths if path])
    for key, value in result.items():
        print(f'{key}={str(value).lower()}')


if __name__ == '__main__':
    main()
