#!/usr/bin/env bash
# Fail when a display-mask placeholder stands in for a real value.
#
# A display mask turns a real value into a bracketed placeholder in tool
# output. A real value and such a placeholder look identical in a transcript,
# so copying one into committed code ships a broken executable value. This
# check finds them mechanically in three contexts:
#
#   (a) inside a URL after the scheme (http, https, ws, wss, ftp)
#   (b) on an echo or printf line
#   (c) in a case pattern arm
#
# Only git-tracked files are scanned. Markdown files and anything under docs/
# are out of scope. Binary files are skipped. The baseline file itself is never
# scanned, even if a comment in it happens to hold a token-shaped string.
#
# Baseline ratchet:
#   Pre-existing findings are frozen in scripts/no-masked-literals-baseline.txt,
#   one "<repo-relative path><TAB><sha256 hex of the offending source line>" per
#   line, where the hash covers the line text exactly with no trailing newline.
#   A finding whose fingerprint is in the baseline is ACCEPTED. Anything else is
#   NEW and fails. A baseline entry with no matching finding is STALE and also
#   fails, so the file can only shrink. Adding an entry needs explicit owner
#   approval quoted in the pull request.
#
# Usage:
#   bash scripts/check-no-masked-literals.sh [--root DIR] [--baseline[=FILE]]
#                                            [--no-baseline] [BASELINE_FILE]
#
#   --root DIR          scan the git work tree at DIR (default: .)
#   --baseline          use DIR/scripts/no-masked-literals-baseline.txt
#   --baseline=FILE     use FILE as the baseline
#   --no-baseline       ignore any baseline; every finding is NEW
#   BASELINE_FILE       a lone positional argument sets the baseline file
#
#   The default is the baseline named above. A missing baseline file is treated
#   as empty, so every finding is NEW and the check fails safe.
#
# Exit codes:
#   0  no display-mask placeholder found, or every finding is in the baseline
#   1  a NEW placeholder was found, or a baseline entry is STALE
#   2  usage error, DIR is not a git work tree, or the baseline is malformed
set -u

MASK_TOKENS='IP_ADDRESS|EMAIL|PHONE|HOST'

usage() {
  echo "usage: bash scripts/check-no-masked-literals.sh [--root DIR] [--baseline[=FILE]] [--no-baseline] [BASELINE_FILE]" >&2
}

ROOT="."
BASELINE_SET=0
BASELINE_FILE=""
BASELINE_OPT=""
POSITIONAL=""

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
    --baseline)
      BASELINE_SET=1
      BASELINE_FILE=""
      BASELINE_OPT="default"
      shift
      ;;
    --baseline=*)
      BASELINE_SET=1
      BASELINE_FILE="${1#*=}"
      BASELINE_OPT="file"
      shift
      ;;
    --no-baseline)
      BASELINE_SET=1
      BASELINE_OPT="none"
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
      if [ -n "$POSITIONAL" ]; then
        echo "error: too many positional arguments" >&2
        usage
        exit 2
      fi
      POSITIONAL="$1"
      shift
      ;;
  esac
done

# A lone positional argument is the baseline file, matching the historical
# "BASELINE_FILE" calling convention.
if [ -n "$POSITIONAL" ]; then
  if [ "$BASELINE_SET" -eq 1 ] && [ "$BASELINE_OPT" != "none" ]; then
    echo "error: baseline given both as an option and as a positional argument" >&2
    usage
    exit 2
  fi
  if [ "$BASELINE_SET" -eq 0 ]; then
    BASELINE_SET=1
    BASELINE_FILE="$POSITIONAL"
    BASELINE_OPT="file"
  fi
fi

if [ ! -d "$ROOT" ]; then
  echo "error: root directory not found: $ROOT" >&2
  exit 2
fi

if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "error: not a git work tree: $ROOT" >&2
  exit 2
fi

# Resolve the baseline file. The default lives at the repository's scripts/
# directory; a missing file is treated as empty so the check fails safe.
DEFAULT_BASELINE_REL="scripts/no-masked-literals-baseline.txt"
if [ "$BASELINE_SET" -eq 0 ]; then
  BASELINE_SET=1
  BASELINE_OPT="default"
fi

case "$BASELINE_OPT" in
  none)
    BASELINE_FILE=""
    ;;
  default)
    BASELINE_FILE="$ROOT/$DEFAULT_BASELINE_REL"
    ;;
  file)
    : # already set from --baseline=FILE or the positional argument
    ;;
esac

# Exclusions for the scan. The baseline file must never be scanned, so a
# token-shaped string in a baseline comment cannot be reported as a finding.
EXCLUDES=":!*.md :!docs/*"
ROOT_ABS="$(cd "$ROOT" && pwd)"
if [ -n "$BASELINE_FILE" ]; then
  if [ -e "$BASELINE_FILE" ]; then
    BL_DIR="$(cd "$(dirname "$BASELINE_FILE")" && pwd)"
    BL_ABS="$BL_DIR/$(basename "$BASELINE_FILE")"
  else
    BL_ABS=""
  fi
  case "$BL_ABS" in
    "$ROOT_ABS"/*)
      EXCLUDES="$EXCLUDES :!${BL_ABS#"$ROOT_ABS/"}"
      ;;
  esac
fi
# Also exclude the conventional location even when the resolved path differs,
# so a shadowed copy cannot be scanned by accident.
EXCLUDES="$EXCLUDES :!$DEFAULT_BASELINE_REL"

# Build the bracket characters at runtime so no bracketed token literal is
# written into this file; the token set above stays a plain alternation.
OB="$(printf '\x5b')"
CB="$(printf '\x5d')"

# Escaped for a POSIX ERE, and for awk when passed with -v.
TOK_RE="\\${OB}(${MASK_TOKENS})\\${CB}"

# Collect candidate lines from tracked files, skipping binary content.
# shellcheck disable=SC2086
CANDIDATES="$(git -C "$ROOT" grep -n -I -E "$TOK_RE" -- . $EXCLUDES 2>/dev/null || true)"

FINDINGS=""
awk_rc=3
if [ -n "$CANDIDATES" ]; then
  FINDINGS="$(printf '%s\n' "$CANDIDATES" | awk -v ob="$OB" -v cb="$CB" -v toks="$MASK_TOKENS" '
  function any_token(s,   i, t) {
    for (i = 1; i <= nt; i++) {
      t = ob alts[i] cb
      if (index(s, t) > 0) {
        return 1
      }
    }
    return 0
  }
  function url_has_token(line,   rest, at, seg, cut) {
    rest = line
    while ((at = match(rest, /(https?|wss?|ftp):\/\//)) > 0) {
      rest = substr(rest, at + RLENGTH)
      seg = rest
      cut = length(seg) + 1
      if (match(seg, /["\047[:space:]]/) > 0) {
        cut = RSTART
      }
      seg = substr(seg, 1, cut - 1)
      if (any_token(seg)) {
        return 1
      }
      rest = substr(rest, cut)
    }
    return 0
  }
  function is_value_context(line) {
    if (url_has_token(line)) {
      return 1
    }
    if (line ~ /(^|[^[:alnum:]_])printf([^[:alnum:]_]|$)/) {
      return 1
    }
    if (line ~ /(^|[^[:alnum:]_])echo([^[:alnum:]_]|$)/) {
      return 1
    }
    if (in_case && line ~ /\)/) {
      return 1
    }
    return 0
  }
  BEGIN {
    nt = split(toks, alts, "|")
    in_case = 0
  }
  {
    line = $0
    if (is_value_context(line)) {
      print line
      count++
    }
    if (line ~ /(^|[[:space:];])case[[:space:]].*[[:space:]]in[[:space:]]*;?[[:space:]]*$/) {
      in_case = 1
    }
    if (line ~ /(^|[[:space:];])esac([^[:alnum:]_]|$)/) {
      in_case = 0
    }
  }
  END { if (count == 0) exit 3 }
')"
  awk_rc=$?
fi

# rc 3 means "candidates existed but none sat in a value position". That is not
# an early success: the baseline may still hold entries whose findings are gone,
# so fall through to classification with no findings.
if [ "$awk_rc" -eq 3 ]; then
  FINDINGS=""
elif [ "$awk_rc" -ne 0 ]; then
  echo "error: failed to evaluate candidate lines" >&2
  exit 2
fi

# Classify each finding against the baseline. A finding is ACCEPTED when its
# "<path>\t<sha256 of the line text>" fingerprint appears in the baseline. A
# baseline entry with no matching finding is STALE. Everything else is NEW.
#
# python3 computes the SHA-256 and does the set comparison. Findings go through
# a temp file rather than stdin, because the heredoc already occupies stdin.
FINDINGS_FILE="$(mktemp)"
trap 'rm -f "${FINDINGS_FILE:-}"' EXIT
printf '%s\n' "$FINDINGS" >"$FINDINGS_FILE"

CLASSIFY_OUT="$(python3 - "$BASELINE_FILE" "$FINDINGS_FILE" <<'PY'
import hashlib
import sys

baseline_path = sys.argv[1] if len(sys.argv) > 1 else ""
findings_path = sys.argv[2] if len(sys.argv) > 2 else ""

accepted_fps = set()
baseline_lines = []
errors = []

if baseline_path:
    try:
        with open(baseline_path, "rb") as handle:
            raw = handle.read()
    except FileNotFoundError:
        raw = b""
    except OSError as exc:
        sys.stderr.write("error: cannot read baseline: %s\n" % exc)
        sys.exit(2)
    for lineno, bline in enumerate(raw.splitlines(), 1):
        if not bline.strip():
            continue
        if bline.lstrip().startswith(b"#"):
            continue
        if bline.count(b"\t") != 1:
            errors.append("baseline line %d: expected exactly one tab" % lineno)
            continue
        bpath, bsha = bline.split(b"\t")
        bsha = bsha.strip()
        if not bpath.strip():
            errors.append("baseline line %d: empty path" % lineno)
            continue
        if len(bsha) != 64 or any(c not in b"0123456789abcdef" for c in bsha):
            errors.append("baseline line %d: expected a 64-char lowercase hex sha256" % lineno)
            continue
        fp = (bpath.decode("utf-8", "surrogateescape"), bsha.decode("ascii"))
        accepted_fps.add(fp)
        baseline_lines.append(fp)

if errors:
    for err in errors:
        sys.stderr.write("error: malformed %s: %s\n" % (baseline_path, err))
    sys.stderr.write("error: fix the baseline format: <path><TAB><sha256 hex>\n")
    sys.exit(2)

with open(findings_path, "rb") as handle:
    findings_raw = handle.read()

finding_fps = []
for raw_line in findings_raw.splitlines():
    if not raw_line.strip():
        continue
    text = raw_line.decode("utf-8", "surrogateescape")
    parts = text.split(":", 2)
    if len(parts) != 3 or not parts[1].isdigit():
        sys.stderr.write("error: unexpected finding format: %s\n" % text)
        sys.exit(2)
    path, lineno, content = parts
    sha = hashlib.sha256(content.encode("utf-8", "surrogateescape")).hexdigest()
    finding_fps.append((path, lineno, sha))

seen = set()
new_findings = []
for path, lineno, sha in finding_fps:
    fp = (path, sha)
    if fp in accepted_fps:
        seen.add(fp)
        sys.stdout.write("ACCEPTED: %s:%s\n" % (path, lineno))
    else:
        new_findings.append((path, lineno))
        sys.stdout.write("NEW: %s:%s\n" % (path, lineno))

stale = [fp for fp in baseline_lines if fp not in seen]
for path, sha in stale:
    sys.stdout.write("STALE: %s\t%s\n" % (path, sha))

sys.stdout.write("SUMMARY\t%d\t%d\t%d\t%d\n" % (
    len(accepted_fps) - len(stale), len(new_findings), len(stale), len(finding_fps)))
sys.exit(0)
PY
)"
classify_rc=$?

if [ "$classify_rc" -ne 0 ]; then
  exit "$classify_rc"
fi

ACCEPTED_LINES="$(printf '%s\n' "$CLASSIFY_OUT" | grep '^ACCEPTED: ' || true)"
NEW_LINES="$(printf '%s\n' "$CLASSIFY_OUT" | grep '^NEW: ' || true)"
STALE_LINES="$(printf '%s\n' "$CLASSIFY_OUT" | grep '^STALE: ' || true)"
SUMMARY_LINE="$(printf '%s\n' "$CLASSIFY_OUT" | grep '^SUMMARY' || true)"

if [ -n "$SUMMARY_LINE" ]; then
  # SUMMARY <accepted> <new> <stale> <total>
  ACCEPTED_COUNT="$(printf '%s\n' "$SUMMARY_LINE" | cut -f2)"
  NEW_COUNT="$(printf '%s\n' "$SUMMARY_LINE" | cut -f3)"
  STALE_COUNT="$(printf '%s\n' "$SUMMARY_LINE" | cut -f4)"
  TOTAL_COUNT="$(printf '%s\n' "$SUMMARY_LINE" | cut -f5)"
else
  ACCEPTED_COUNT=0
  NEW_COUNT=0
  STALE_COUNT=0
  TOTAL_COUNT=0
fi

if [ -n "$ACCEPTED_LINES" ]; then
  printf '%s\n' "$ACCEPTED_LINES"
fi

status=0

if [ "$NEW_COUNT" -gt 0 ]; then
  printf '%s\n' "$NEW_LINES"
  echo "FAIL: $NEW_COUNT NEW display-masked literal(s) found in tracked code." >&2
  echo "Replace the placeholder with a value read from config or derived at runtime." >&2
  echo "Do not add a baseline entry without explicit owner approval quoted in the pull request." >&2
  status=1
fi

if [ "$STALE_COUNT" -gt 0 ]; then
  printf '%s\n' "$STALE_LINES"
  echo "FAIL: $STALE_COUNT stale baseline entr(y/ies); the finding is gone, so remove the entry in this commit." >&2
  status=1
fi

if [ "$status" -ne 0 ]; then
  echo "Baseline: ${BASELINE_FILE:-<none>}" >&2
  exit 1
fi

if [ "$TOTAL_COUNT" -gt 0 ]; then
  echo "OK: $ACCEPTED_COUNT baselined display-masked literal(s); no new or stale findings."
  echo "Baseline: ${BASELINE_FILE:-<none>}"
  exit 0
fi

echo "OK: no display-masked literals in tracked code."
exit 0
