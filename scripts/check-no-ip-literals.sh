#!/usr/bin/env bash
# Report environment-specific IPv4 literals in tracked code (WARN MODE).
#
# A hard-coded IPv4 address in code or config pins one deployment's topology.
# This check classifies every dotted-quad literal in the tracked tree and
# prints the ones that do not belong in a portable repository.
#
# Classification:
#   allowed always   loopback block, the wildcard address, and the three
#                    RFC 5737 documentation blocks
#   allowed in policy context
#                    the RFC 6598 CGNAT block, but only when written with a
#                    CIDR suffix or on a line carrying a policy keyword
#   rfc1918          the three RFC 1918 private blocks
#   cgnat-context    a bare CGNAT address with no CIDR suffix and no policy
#                    keyword on the line
#   public           any other syntactically valid IPv4 address
#
# The blocks are declared once as octet tuples with a prefix length and are
# turned into 32-bit bounds by a single parser, so no dotted-quad string is
# written into this file.
#
# Only git-tracked files are scanned. Markdown files, anything under docs/,
# binary files and the allowlist file are skipped. Files named in the allowlist
# are scanned and their findings are reported as suppressed.
#
# WARN MODE: findings never change the exit code. The report is the burn-down
# list for a later error-mode change.
#
# Usage:
#   bash scripts/check-no-ip-literals.sh [--root DIR] [--allowlist FILE]
#                                        [--no-allowlist] [--inventory]
#
#   --root DIR        scan the git work tree at DIR (default: .)
#   --allowlist FILE  use FILE (default: DIR/.ip-literal-allowlist)
#   --no-allowlist    ignore the allowlist entirely
#   --inventory       print a sorted per-file classification and per-class
#                     totals after the summary
#
# Exit codes:
#   0  the scan ran, whatever the finding count
#   2  usage error, or DIR is not a git work tree
set -u

usage() {
  echo "usage: bash scripts/check-no-ip-literals.sh [--root DIR] [--allowlist FILE] [--no-allowlist] [--inventory]" >&2
}

ROOT="."
ALLOWLIST_OPT="default"
ALLOWLIST_FILE=""
INVENTORY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      if [ "$#" -lt 2 ]; then
        usage
        exit 2
      fi
      ROOT="$2"
      shift 2
      ;;
    --root=*)
      ROOT="${1#*=}"
      shift
      ;;
    --allowlist)
      if [ "$#" -lt 2 ]; then
        usage
        exit 2
      fi
      ALLOWLIST_OPT="file"
      ALLOWLIST_FILE="$2"
      shift 2
      ;;
    --allowlist=*)
      ALLOWLIST_OPT="file"
      ALLOWLIST_FILE="${1#*=}"
      shift
      ;;
    --no-allowlist)
      ALLOWLIST_OPT="none"
      shift
      ;;
    --inventory)
      INVENTORY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "error: unknown argument: $1" >&2
      usage
      exit 2
      ;;
    *)
      echo "error: unexpected argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [ ! -d "$ROOT" ]; then
  echo "error: root directory not found: $ROOT" >&2
  exit 2
fi

if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "error: not a git work tree: $ROOT" >&2
  exit 2
fi

ROOT_ABS="$(cd "$ROOT" && pwd)"
DEFAULT_ALLOWLIST_REL=".ip-literal-allowlist"

# Resolve the allowlist path. A missing file suppresses nothing.
ALLOWLIST_ABS=""
case "$ALLOWLIST_OPT" in
  none)
    ALLOWLIST_ABS=""
    ;;
  default)
    if [ -e "$ROOT_ABS/$DEFAULT_ALLOWLIST_REL" ]; then
      ALLOWLIST_ABS="$ROOT_ABS/$DEFAULT_ALLOWLIST_REL"
    fi
    ;;
  file)
    if [ -e "$ALLOWLIST_FILE" ]; then
      AL_DIR="$(cd "$(dirname "$ALLOWLIST_FILE")" && pwd)"
      ALLOWLIST_ABS="$AL_DIR/$(basename "$ALLOWLIST_FILE")"
    fi
    ;;
esac

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR:-}"' EXIT
LIST_FILE="$TMP_DIR/tracked.nul"

# Tracked files only. NUL separators keep paths with spaces intact.
git -C "$ROOT_ABS" ls-files -z >"$LIST_FILE" || {
  echo "error: cannot list tracked files in $ROOT" >&2
  exit 2
}

python3 - "$ROOT_ABS" "$ALLOWLIST_ABS" "$DEFAULT_ALLOWLIST_REL" "$INVENTORY" "$LIST_FILE" <<'PY'
import os
import re
import sys

root = sys.argv[1]
allowlist_path = sys.argv[2]
default_allowlist_rel = sys.argv[3]
inventory = sys.argv[4] == "1"
list_path = sys.argv[5]


def parse_cidr(cidr):
    """Return (first, last) as 32-bit ints for an (o1, o2, o3, o4, len) tuple."""
    o1, o2, o3, o4, plen = cidr
    addr = (o1 << 24) | (o2 << 16) | (o3 << 8) | o4
    mask = (0xFFFFFFFF << (32 - plen)) & 0xFFFFFFFF if plen else 0
    first = addr & mask
    return first, (first | (~mask & 0xFFFFFFFF)) & 0xFFFFFFFF


def bounds(blocks):
    return [parse_cidr(block) for block in blocks]


def in_blocks(value, block_bounds):
    return any(first <= value <= last for first, last in block_bounds)


LOOPBACK_BLOCKS = [(127, 0, 0, 0, 8)]
WILDCARD_BLOCKS = [(0, 0, 0, 0, 32)]
DOCUMENTATION_BLOCKS = [
    (192, 0, 2, 0, 24),
    (198, 51, 100, 0, 24),
    (203, 0, 113, 0, 24),
]
CGNAT_BLOCKS = [(100, 64, 0, 0, 10)]
PRIVATE_BLOCKS = [
    (10, 0, 0, 0, 8),
    (172, 16, 0, 0, 12),
    (192, 168, 0, 0, 16),
]

LOOPBACK = bounds(LOOPBACK_BLOCKS)
WILDCARD = bounds(WILDCARD_BLOCKS)
DOCUMENTATION = bounds(DOCUMENTATION_BLOCKS)
CGNAT = bounds(CGNAT_BLOCKS)
PRIVATE = bounds(PRIVATE_BLOCKS)

POLICY_KEYWORDS = (
    "firewall",
    "firewalld",
    "iptables",
    "nft",
    "nftables",
    "allowlist",
    "allow-list",
    "trusted",
    "egress",
    "mesh",
    "tailscale",
    "cidr",
    "route",
)

LITERAL_RE = re.compile(
    r"(?<![\d.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\d.])"
    r"(?:/(\d{1,2}))?"
)

CLASS_ORDER = ("rfc1918", "public", "cgnat-context")


def read_allowlist(path):
    """Return the set of repo-relative paths named in the allowlist."""
    if not path:
        return set()
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError:
        return set()
    paths = set()
    for line in raw.decode("utf-8", "surrogateescape").splitlines():
        text = line.strip()
        if not text or text.startswith("#"):
            continue
        if text.startswith("./"):
            text = text[2:]
        paths.add(text)
    return paths


def skip_name(rel):
    if rel.endswith(".md"):
        return True
    if rel.startswith("docs/"):
        return True
    if rel == default_allowlist_rel:
        return True
    if allowlist_path:
        rel_abs = os.path.join(root, rel)
        if os.path.realpath(rel_abs) == os.path.realpath(allowlist_path):
            return True
    return False


allowlisted = read_allowlist(allowlist_path)

with open(list_path, "rb") as handle:
    tracked = [p for p in handle.read().split(b"\0") if p]

violations = []
per_file = {}
suppressed = 0
allowed_count = 0
classes_seen = {name: 0 for name in CLASS_ORDER}

for raw_path in tracked:
    rel = raw_path.decode("utf-8", "surrogateescape")
    if skip_name(rel):
        continue
    full = os.path.join(root, rel)
    try:
        with open(full, "rb") as handle:
            data = handle.read()
    except OSError:
        continue
    if b"\0" in data:
        continue

    is_allowlisted = rel in allowlisted
    text = data.decode("utf-8", "surrogateescape")
    for lineno, line in enumerate(text.splitlines(), 1):
        lowered = line.lower()
        policy_context = any(word in lowered for word in POLICY_KEYWORDS)
        for match in LITERAL_RE.finditer(line):
            octets = [int(match.group(i)) for i in range(1, 5)]
            if any(o > 255 for o in octets):
                continue
            if match.group(5) is not None and int(match.group(5)) > 32:
                continue
            value = (
                (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
            )
            has_cidr = match.group(5) is not None

            if (
                in_blocks(value, LOOPBACK)
                or in_blocks(value, WILDCARD)
                or in_blocks(value, DOCUMENTATION)
            ):
                allowed_count += 1
                continue
            if in_blocks(value, CGNAT):
                if has_cidr or policy_context:
                    allowed_count += 1
                    continue
                cls = "cgnat-context"
            elif in_blocks(value, PRIVATE):
                cls = "rfc1918"
            else:
                cls = "public"

            if is_allowlisted:
                suppressed += 1
                continue
            violations.append((rel, lineno, cls))
            entry = per_file.setdefault(rel, {"count": 0, "classes": set()})
            entry["count"] += 1
            entry["classes"].add(cls)
            classes_seen[cls] += 1

for rel, lineno, cls in violations:
    sys.stdout.write("%s:%d: %s\n" % (rel, lineno, cls))

sys.stdout.write(
    "summary: violations=%d suppressed=%d allowed=%d\n"
    % (len(violations), suppressed, allowed_count)
)

if inventory:
    for rel in sorted(per_file):
        entry = per_file[rel]
        sys.stdout.write(
            "%s\t%s\t%d\n"
            % (rel, ",".join(sorted(entry["classes"])), entry["count"])
        )
    totals = " ".join("%s=%d" % (name, classes_seen[name]) for name in CLASS_ORDER)
    sys.stdout.write("totals: %s\n" % totals)
    sys.stdout.write("files: %d\n" % len(per_file))

sys.exit(0)
PY
