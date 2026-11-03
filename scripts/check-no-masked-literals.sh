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
# are out of scope. Binary files are skipped.
#
# Usage:
#   bash scripts/check-no-masked-literals.sh [--root DIR]
#
# Exit codes:
#   0  no display-mask placeholder found in a value position
#   1  at least one placeholder found
#   2  usage error, or DIR is not a git work tree
set -u

MASK_TOKENS='IP_ADDRESS|EMAIL|PHONE|HOST'

usage() {
  echo "usage: bash scripts/check-no-masked-literals.sh [--root DIR]" >&2
}

ROOT="."
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
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
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

# Build the bracket characters at runtime so no bracketed token literal is
# written into this file; the token set above stays a plain alternation.
OB="$(printf '\x5b')"
CB="$(printf '\x5d')"

# Escaped for a POSIX ERE, and for awk when passed with -v.
TOK_RE="\\${OB}(${MASK_TOKENS})\\${CB}"

# Collect candidate lines from tracked files, skipping binary content.
CANDIDATES="$(git -C "$ROOT" grep -n -I -E "$TOK_RE" -- . ':!*.md' ':!docs/*' 2>/dev/null || true)"

if [ -z "$CANDIDATES" ]; then
  echo "OK: no display-masked literals in tracked code."
  exit 0
fi

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

if [ "$awk_rc" -eq 3 ]; then
  echo "OK: no display-masked literals in tracked code."
  exit 0
fi
if [ "$awk_rc" -ne 0 ]; then
  echo "error: failed to evaluate candidate lines" >&2
  exit 2
fi

printf '%s\n' "$FINDINGS"
count="$(printf '%s\n' "$FINDINGS" | grep -c . || true)"
echo "FAIL: $count display-masked literal(s) found in tracked code." >&2
echo "Replace the placeholder with a value read from config or derived at runtime." >&2
exit 1
