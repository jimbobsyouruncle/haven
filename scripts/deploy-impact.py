#!/usr/bin/env python3
"""Classify cumulative deployment changes since an independently trusted SHA."""
import re
import subprocess
import sys

SHA = re.compile(r'[0-9a-f]{40}')

# Match only a version change in the same known application image, leaving
# every other byte of the deployable configuration unchanged.
IMAGE_PINS = {
    'docker-compose.yml.tmpl': (
        rb'    image: \$\{OLLAMA_IMAGE:-ollama/ollama:[0-9][0-9.]*@sha256:[0-9a-f]{64}\}',
        rb'    image: \$\{WEBUI_IMAGE:-ghcr\.io/open-webui/open-webui:v[0-9][0-9.]*\}',
    ),
    'openhands/docker-compose.openhands.yml': (
        rb'    image: \$\{OPENHANDS_IMAGE:-docker\.openhands\.dev/openhands/openhands:[0-9][0-9.]*\}',
    ),
}
DOC_PATH = re.compile(
    r'(?:docs/(?:[a-zA-Z0-9_-]+/)*[a-zA-Z0-9_.-]+\.md|README\.md|REPO_MAP\.md|CODE_INDEX\.md)'
)


class UntrustedRange(ValueError):
    pass


def classify(git, base, target):
    """Return docs-only, routine, or protected. Invalid history always refuses."""
    for sha in (base, target):
        if not SHA.fullmatch(sha) or git('cat-file', '-t', sha) != b'commit\n':
            raise UntrustedRange('expected a full commit SHA')
    history = git('rev-list', '--first-parent', target, '^' + base).decode('ascii').splitlines()
    if (not history and base != target) or (
            history and git('rev-parse', history[-1] + '^1').strip() != base.encode()):
        raise UntrustedRange('accepted SHA is outside the requested first-parent history')

    impact = 'docs-only'
    # Include topic commits even when a later commit or merge reverts them.
    for child in git('rev-list', target, '^' + base).decode('ascii').splitlines():
        parent = git('rev-parse', child + '^1').decode('ascii').strip()
        raw = git('diff-tree', '--no-commit-id', '--raw', '--no-abbrev',
                  '--no-renames', '-r', '-z', parent, child, '--')
        entries = raw.split(b'\0')
        if entries.pop() != b'' or len(entries) % 2:
            raise UntrustedRange('unexpected Git diff format')
        for metadata, path in zip(entries[::2], entries[1::2]):
            if not path.isascii():
                return 'protected'
            name = path.decode('ascii')
            if metadata.startswith(b':000000 100644 ') and metadata.endswith(b' A'):
                # Other additions can create new executable inputs.
                # An accompanying deletion is protected, including a rename.
                if DOC_PATH.fullmatch(name):
                    continue
                return 'protected'
            match = re.fullmatch(rb':100644 100644 ([0-9a-f]{40}) ([0-9a-f]{40}) M', metadata)
            if not match:
                return 'protected'
            if DOC_PATH.fullmatch(name):
                continue
            pins = IMAGE_PINS.get(name)
            if not pins:
                return 'protected'
            old, new = (git('cat-file', 'blob', oid.decode('ascii')) for oid in match.groups())
            if normalize_pins(old, pins) != normalize_pins(new, pins):
                return 'protected'
            impact = 'routine'
    return impact


def normalize_pins(content, pins):
    lines = content.split(b'\n')
    for pin in pins:
        matches = [index for index, line in enumerate(lines) if re.fullmatch(pin, line)]
        if len(matches) == 1:
            lines[matches[0]] = pin
    return lines


def main():
    if len(sys.argv) != 4:
        return 2
    directory, base, target = sys.argv[1:]

    def git(*args):
        return subprocess.check_output(['git', '--no-replace-objects', '-C', directory, *args],
                                       stderr=subprocess.DEVNULL)
    try:
        print(classify(git, base, target))
    except (UntrustedRange, OSError, subprocess.SubprocessError):
        print('AUTHORIZATION_REQUIRED: cumulative deployment range could not be established',
              file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
