#!/usr/bin/env bash
# Offline fixture harness for scripts/ci-parity.sh.
#
# Builds throwaway git work trees under a temp dir from the CURRENT tracked
# file set, then proves the runner rejects each class of repo-gate finding and
# accepts a clean tree. The real repository is never modified: every fixture is
# a copy, and the runner is pointed at it with --root.
#
# Each case prints two lines of evidence:
#   BEFORE  the pristine fixture, which the runner must accept (exit 0)
#   AFTER   the same fixture with ONE injected fault (exit 1, gate named)
# so a regression in the runner shows up as a missing "AFTER" failure rather
# than as a quiet pass.
#
# Cases:
#   (a) clean tree                         -> exit 0
#   (b) injected display-masked literal    -> exit 1 naming check-no-masked-literals
#   (c) stale REPO_MAP.md                  -> exit 1 naming check-agent-context
#   (d) shell file with a syntax error     -> exit 1 naming Shell syntax check
#   (e) usage error                        -> exit 2
#
# The bracketed placeholders are assembled from shell variables, so this file
# does not itself contain a display-mask literal.
#
# The pinned agent-context generator is required for the map gate and is
# resolved the same way the runner resolves it: --generator, then
# HYBRID_AI_AGENT_CONTEXT_GENERATOR, then .shared-actions/agent-context/
# generate.py in this tree. It is never fetched from the network.
#
# Usage:
#   bash scripts/test-ci-parity.sh [GENERATOR]
#
# Exit 0 when every case passes, 1 on any case failure, 2 on usage error or a
# missing prerequisite.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="$SCRIPT_DIR/ci-parity.sh"

if [ "$#" -gt 1 ]; then
  echo "usage: bash scripts/test-ci-parity.sh [GENERATOR]" >&2
  exit 2
fi

if [ ! -f "$RUNNER" ]; then
  echo "error: runner not found: $RUNNER" >&2
  exit 2
fi

GENERATOR="${1:-${HYBRID_AI_AGENT_CONTEXT_GENERATOR:-}}"
if [ -z "$GENERATOR" ] && [ -f "$REPO_ROOT/.shared-actions/agent-context/generate.py" ]; then
  GENERATOR="$REPO_ROOT/.shared-actions/agent-context/generate.py"
fi
if [ -z "$GENERATOR" ] || [ ! -f "$GENERATOR" ]; then
  echo "error: missing prerequisite: the pinned agent-context generator." >&2
  echo "  git clone https://github.com/jimbobsyouruncle/shared-actions /tmp/shared-actions" >&2
  echo "  git -C /tmp/shared-actions checkout 3156ad16725e149a9baebeb71862a8d1d341418c" >&2
  echo "  bash scripts/test-ci-parity.sh /tmp/shared-actions/agent-context/generate.py" >&2
  exit 2
fi
GENERATOR="$(cd "$(dirname "$GENERATOR")" && pwd)/$(basename "$GENERATOR")"

OB="$(printf '\x5b')"
CB="$(printf '\x5d')"
IP_TOK="${OB}IP_ADDRESS${CB}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR:-}"' EXIT

FAILURES=0
CASES=0

OUT_FILE="$TMP_DIR/out.txt"

record() {
  local name="$1" expected="$2" actual="$3" needle="${4:-}"
  CASES=$((CASES + 1))
  local ok=1
  if [ "$actual" -ne "$expected" ]; then
    ok=0
  fi
  if [ -n "$needle" ] && ! grep -Fq -- "$needle" "$OUT_FILE"; then
    ok=0
  fi
  local detail=""
  if [ -n "$needle" ]; then
    detail=", output mentioning $needle"
  fi
  if [ "$ok" -eq 1 ]; then
    echo "PASS: $name (exit $actual)"
  else
    echo "FAIL: $name (expected exit $expected$detail, got exit $actual)" >&2
    sed -n '1,40p' "$OUT_FILE" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# run_runner <fixture-dir> [extra args...]; echoes the exit code.
run_runner() {
  local dir="$1"
  shift
  local rc=0
  bash "$RUNNER" --root "$dir" --generator "$GENERATOR" "$@" >"$OUT_FILE" 2>&1 || rc=$?
  echo "$rc"
}

# --- template: a faithful copy of the current tracked tree --------------------
TEMPLATE="$TMP_DIR/template"
mkdir -p "$TEMPLATE"
(
  cd "$REPO_ROOT"
  git ls-files -z | while IFS= read -r -d '' path; do
    mkdir -p "$TEMPLATE/$(dirname "$path")"
    cp -- "$path" "$TEMPLATE/$path"
  done
)
git -C "$TEMPLATE" init -q
git -C "$TEMPLATE" config user.name "fixture"
git -C "$TEMPLATE" config user.email "fixture@example.test"
git -C "$TEMPLATE" config commit.gpgsign false
git -C "$TEMPLATE" add -A
git -C "$TEMPLATE" commit -q -m "fixture base"

new_case() {
  local dir="$TMP_DIR/$1"
  cp -a "$TEMPLATE" "$dir"
  printf '%s' "$dir"
}

echo "ci-parity tests: runner=$RUNNER"
echo "ci-parity tests: generator=$GENERATOR"
echo "ci-parity tests: fixtures under $TMP_DIR"

# --- (a) clean tree ----------------------------------------------------------
CLEAN="$(new_case clean)"
rc="$(run_runner "$CLEAN")"
echo "BEFORE (no fault injected): exit $rc"
record "a: clean tree exits 0" 0 "$rc"

# Everything below asserts the runner still FAILS on the injected fault; the
# pristine tree above is the "before" baseline each case is measured against.

# --- (b) new display-masked literal in tracked code --------------------------
MASKED="$(new_case masked)"
mkdir -p "$MASKED/scripts"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  "echo \"http://${IP_TOK}:8080/fixture\"" >"$MASKED/scripts/fixture-masked.sh"
git -C "$MASKED" add -A
git -C "$MASKED" commit -q -m "inject masked literal"
rc="$(run_runner "$MASKED")"
echo "AFTER (display-masked literal injected): exit $rc"
grep -F 'NEW: scripts/fixture-masked.sh' "$OUT_FILE" >/dev/null 2>&1 \
  && echo "  finding reported: NEW scripts/fixture-masked.sh"
record "b: display-masked literal exits 1" 1 "$rc" "check-no-masked-literals"

# --- (c) stale generated map -------------------------------------------------
STALE="$(new_case stale)"
printf '\nstale fixture line\n' >>"$STALE/REPO_MAP.md"
git -C "$STALE" add -A
git -C "$STALE" commit -q -m "stale map"
rc="$(run_runner "$STALE")"
echo "AFTER (REPO_MAP.md made stale): exit $rc"
grep -F 'STALE: REPO_MAP.md' "$OUT_FILE" >/dev/null 2>&1 \
  && echo "  finding reported: STALE REPO_MAP.md"
record "c: stale map exits 1" 1 "$rc" "check-agent-context"

# --- (d) shell syntax error --------------------------------------------------
BROKEN="$(new_case broken)"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [ -n "x" ; then' \
  '  echo hi' \
  'fi' >"$BROKEN/scripts/fixture-broken.sh"
git -C "$BROKEN" add -A
git -C "$BROKEN" commit -q -m "broken syntax"
rc="$(run_runner "$BROKEN")"
echo "AFTER (unbalanced shell syntax added): exit $rc"
record "d: broken shell syntax exits 1" 1 "$rc" "Shell syntax check"

# --- (e) usage error ---------------------------------------------------------
rc=0
bash "$RUNNER" --not-a-flag >"$OUT_FILE" 2>&1 || rc=$?
echo "usage error (--not-a-flag): exit $rc"
record "e: unknown flag exits 2" 2 "$rc" "usage:"

rc=0
bash "$RUNNER" --root "$TMP_DIR/does-not-exist" --generator "$GENERATOR" \
  >"$OUT_FILE" 2>&1 || rc=$?
echo "usage error (missing --root dir): exit $rc"
record "e: missing root exits 2" 2 "$rc" "root directory not found"

rc=0
bash "$RUNNER" --root "$TMP_DIR" --generator "$GENERATOR" >"$OUT_FILE" 2>&1 || rc=$?
echo "usage error (--root is not a git work tree): exit $rc"
record "e: non-work-tree root exits 2" 2 "$rc" "not a git work tree"

echo "ci-parity tests: $CASES case(s), $FAILURES failure(s)"
if [ "$FAILURES" -ne 0 ]; then
  echo "FAIL: $FAILURES case(s) failed." >&2
  exit 1
fi
echo "OK: every ci-parity case passed."
exit 0
