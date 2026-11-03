#!/usr/bin/env bash
# Fixture test for scripts/check-no-ip-literals.sh.
#
# Builds throwaway git repositories under a temp dir and asserts the reported
# classifications and, crucially, that warn mode always exits 0. Needs no
# network. The real repository is never modified: the check script is invoked
# with --root so it scans the fixture only.
#
# Every literal is assembled at runtime from shell variables, so this file
# contains no dotted quad of its own.
#
# Usage:
#   bash scripts/test-check-no-ip-literals.sh
#
# Exit 0 when every case passes, non-zero otherwise. Exit 2 on usage error.
set -euo pipefail

if [ "$#" -ne 0 ]; then
  echo "usage: bash scripts/test-check-no-ip-literals.sh" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/check-no-ip-literals.sh"
if [ ! -f "$CHECK_SCRIPT" ]; then
  echo "error: check script not found: $CHECK_SCRIPT" >&2
  exit 2
fi

# quad <o1> <o2> <o3> <o4>
quad() {
  printf '%s.%s.%s.%s' "$1" "$2" "$3" "$4"
}

LOOPBACK="$(quad 127 0 0 1)"
WILDCARD="$(quad 0 0 0 0)"
DOC_A="$(quad 192 0 2 5)"
DOC_B="$(quad 198 51 100 5)"
DOC_C="$(quad 203 0 113 5)"
CGNAT="$(quad 100 64 0 7)"
PRIV_A="$(quad 10 11 12 13)"
PRIV_B="$(quad 172 20 1 1)"
PRIV_C="$(quad 192 168 5 5)"
PUBLIC="$(quad 93 184 216 34)"

TMP_DIR=""
trap 'rm -rf "${TMP_DIR:-}"' EXIT
TMP_DIR="$(mktemp -d)"

FAILURES=0
OUT_FILE="$TMP_DIR/out.txt"

new_fixture() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.name "fixture"
  git -C "$dir" config user.email "fixture@example.invalid"
  git -C "$dir" config commit.gpgsign false
}

# run_check <fixture-dir> [extra args...]; prints the exit code. Stdout and
# stderr land in OUT_FILE.
run_check() {
  local dir="$1"
  shift
  local rc=0
  bash "$CHECK_SCRIPT" --root "$dir" "$@" >"$OUT_FILE" 2>&1 || rc=$?
  echo "$rc"
}

check_case() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" -eq "$expected" ]; then
    echo "PASS: $name (exit $actual)"
  else
    echo "FAIL: $name (expected $expected, got $actual)"
    sed 's/^/      /' "$OUT_FILE" || true
    FAILURES=$((FAILURES + 1))
  fi
}

check_mentions() {
  local name="$1" needle="$2"
  if grep -qF -- "$needle" "$OUT_FILE"; then
    echo "PASS: $name (reported $needle)"
  else
    echo "FAIL: $name (did not report $needle)"
    sed 's/^/      /' "$OUT_FILE" || true
    FAILURES=$((FAILURES + 1))
  fi
}

check_absent() {
  local name="$1" needle="$2"
  if grep -qF -- "$needle" "$OUT_FILE"; then
    echo "FAIL: $name (unexpectedly reported $needle)"
    sed 's/^/      /' "$OUT_FILE" || true
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: $name (did not report $needle)"
  fi
}

# Case 1: addresses that are always allowed produce no violation.
C1="$TMP_DIR/allowed"
new_fixture "$C1"
{
  printf 'listen=%s\n' "$LOOPBACK"
  printf 'bind=%s\n' "$WILDCARD"
  printf 'doc_a=%s\n' "$DOC_A"
  printf 'doc_b=%s\n' "$DOC_B"
  printf 'doc_c=%s\n' "$DOC_C"
} >"$C1/consts.env"
git -C "$C1" add consts.env
git -C "$C1" commit -q -m "fixture: allowed constants"
check_case "allowed constants exit 0" 0 "$(run_check "$C1")"
check_mentions "allowed constants counted" "allowed=5"
check_mentions "no violations for allowed constants" "violations=0"

# Case 2: CGNAT in policy context is allowed; the bare form is not.
C2="$TMP_DIR/cgnat"
new_fixture "$C2"
{
  printf 'mesh_cidr=%s/10\n' "$CGNAT"
  printf 'iptables -A INPUT -s %s -j ACCEPT\n' "$CGNAT"
  printf 'default_gateway=%s\n' "$CGNAT"
} >"$C2/network.sh"
git -C "$C2" add network.sh
git -C "$C2" commit -q -m "fixture: cgnat forms"
check_case "cgnat fixture still exits 0 in warn mode" 0 "$(run_check "$C2")"
check_mentions "bare cgnat reported as cgnat-context" "network.sh:3: cgnat-context"
check_absent "cidr cgnat line not reported" "network.sh:1:"
check_absent "policy-keyword cgnat line not reported" "network.sh:2:"
check_mentions "two cgnat forms counted as allowed" "allowed=2"

# Case 3: each RFC 1918 block is reported as rfc1918.
C3="$TMP_DIR/private"
new_fixture "$C3"
{
  printf 'a=%s\n' "$PRIV_A"
  printf 'b=%s\n' "$PRIV_B"
  printf 'c=%s\n' "$PRIV_C"
} >"$C3/private.env"
git -C "$C3" add private.env
git -C "$C3" commit -q -m "fixture: rfc1918 blocks"
check_case "rfc1918 fixture exits 0 in warn mode" 0 "$(run_check "$C3")"
check_mentions "ten block reported" "private.env:1: rfc1918"
check_mentions "172 block reported" "private.env:2: rfc1918"
check_mentions "192.168 block reported" "private.env:3: rfc1918"
check_mentions "three rfc1918 violations counted" "violations=3"

# Case 4: a public-internet literal is reported as public.
C4="$TMP_DIR/public"
new_fixture "$C4"
printf 'upstream=%s\n' "$PUBLIC" >"$C4/upstream.conf"
git -C "$C4" add upstream.conf
git -C "$C4" commit -q -m "fixture: public literal"
check_case "public fixture exits 0 in warn mode" 0 "$(run_check "$C4")"
check_mentions "public literal reported" "upstream.conf:1: public"

# Case 5: the allowlist suppresses exactly the file it names.
C5="$TMP_DIR/allowlist"
new_fixture "$C5"
printf 'a=%s\n' "$PRIV_A" >"$C5/legacy.conf"
printf 'b=%s\n' "$PRIV_B" >"$C5/current.conf"
printf '%s\n' "# fixture allowlist" "legacy.conf" >"$C5/.ip-literal-allowlist"
git -C "$C5" add legacy.conf current.conf .ip-literal-allowlist
git -C "$C5" commit -q -m "fixture: allowlist"
check_case "allowlist fixture exits 0" 0 "$(run_check "$C5")"
check_absent "allowlisted file suppressed" "legacy.conf:1:"
check_mentions "non-allowlisted file still reported" "current.conf:1: rfc1918"
check_mentions "suppression counted" "suppressed=1"

# The allowlist must not suppress anything it does not name, and
# --no-allowlist must ignore it entirely.
check_case "--no-allowlist re-reports the suppressed file" 0 "$(run_check "$C5" --no-allowlist)"
check_mentions "legacy file reported under --no-allowlist" "legacy.conf:1: rfc1918"

# Case 6: markdown files and docs/ are out of scope.
C6="$TMP_DIR/scope"
new_fixture "$C6"
mkdir -p "$C6/docs"
printf 'a=%s\n' "$PRIV_A" >"$C6/notes.md"
printf 'b=%s\n' "$PRIV_B" >"$C6/docs/design.txt"
printf 'c=%s\n' "$PRIV_C" >"$C6/real.conf"
git -C "$C6" add notes.md docs/design.txt real.conf
git -C "$C6" commit -q -m "fixture: excluded paths"
check_case "scope fixture exits 0" 0 "$(run_check "$C6")"
check_absent "markdown not scanned" "notes.md:"
check_absent "docs directory not scanned" "docs/design.txt"
check_mentions "tracked config still scanned" "real.conf:1: rfc1918"

# Case 7: usage errors are the only non-zero exit.
check_case "missing root exits 2" 2 "$(run_check "$TMP_DIR/does-not-exist")"
C7="$TMP_DIR/not-a-repo"
mkdir -p "$C7"
check_case "non git root exits 2" 2 "$(run_check "$C7")"

if [ "$FAILURES" -ne 0 ]; then
  echo "FAILURES: $FAILURES" >&2
  exit 1
fi
echo "All fixture cases passed."
exit 0
