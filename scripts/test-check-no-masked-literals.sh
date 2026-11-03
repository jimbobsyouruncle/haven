#!/usr/bin/env bash
# Fixture test for scripts/check-no-masked-literals.sh.
#
# Builds throwaway git repositories under a temp dir and asserts the exit codes
# of the check script. Needs no network. The real repository is never modified.
# The check script is invoked with --root so it scans the fixture only.
#
# The bracketed placeholders are assembled from shell variables here, so this
# test script does not itself contain a display-mask literal.
#
# Usage:
#   bash scripts/test-check-no-masked-literals.sh
#
# Exit 0 when every case passes, non-zero otherwise. Exit 2 on usage error.
set -euo pipefail

if [ "$#" -ne 0 ]; then
  echo "usage: bash scripts/test-check-no-masked-literals.sh" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/check-no-masked-literals.sh"
if [ ! -f "$CHECK_SCRIPT" ]; then
  echo "error: check script not found: $CHECK_SCRIPT" >&2
  exit 2
fi

OB="$(printf '\x5b')"
CB="$(printf '\x5d')"
IP_TOK="${OB}IP_ADDRESS${CB}"

TMP_DIR=""
trap 'rm -rf "${TMP_DIR:-}"' EXIT
TMP_DIR="$(mktemp -d)"

FAILURES=0

new_fixture() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.name "fixture"
  git -C "$dir" config user.email "fixture@example.com"
  git -C "$dir" config commit.gpgsign false
}

# run_check <fixture-dir>; echoes the exit code, stdout/stderr land in OUT_FILE.
OUT_FILE="$TMP_DIR/out.txt"
run_check() {
  local rc=0
  bash "$CHECK_SCRIPT" --root "$1" >"$OUT_FILE" 2>&1 || rc=$?
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
  if grep -qF "$needle" "$OUT_FILE"; then
    echo "PASS: $name (reported $needle)"
  else
    echo "FAIL: $name (did not report $needle)"
    sed 's/^/      /' "$OUT_FILE" || true
    FAILURES=$((FAILURES + 1))
  fi
}

# Case 1: a URL holding a placeholder fails, and the finding names file:line.
C1="$TMP_DIR/case1"
new_fixture "$C1"
printf 'url=http://%s:8080/healthz\n' "$IP_TOK" >"$C1/svc.sh"
git -C "$C1" add svc.sh
git -C "$C1" commit -q -m "fixture: url placeholder"
check_case "url placeholder fails" 1 "$(run_check "$C1")"
check_mentions "url placeholder names file and line" "svc.sh:1:"

# Case 2: a URL whose value comes from a shell variable passes.
C2="$TMP_DIR/case2"
new_fixture "$C2"
cat >"$C2/svc.sh" <<'EOF'
#!/usr/bin/env bash
set -u
ADDR="${SERVICE_ADDR:?set SERVICE_ADDR}"
url="http://${ADDR}:8080/healthz"
echo "GET $url"
EOF
git -C "$C2" add svc.sh
git -C "$C2" commit -q -m "fixture: variable url"
check_case "url from variable passes" 0 "$(run_check "$C2")"

# Case 3: an echo line holding a placeholder fails.
C3="$TMP_DIR/case3"
new_fixture "$C3"
printf 'echo "host is %s"\n' "$IP_TOK" >"$C3/echo.sh"
git -C "$C3" add echo.sh
git -C "$C3" commit -q -m "fixture: echo placeholder"
check_case "echo placeholder fails" 1 "$(run_check "$C3")"

# Case 3b: a printf line holding a placeholder fails.
C3B="$TMP_DIR/case3b"
new_fixture "$C3B"
printf 'printf "%%s\\n" "%s"\n' "$IP_TOK" >"$C3B/printf.sh"
git -C "$C3B" add printf.sh
git -C "$C3B" commit -q -m "fixture: printf placeholder"
check_case "printf placeholder fails" 1 "$(run_check "$C3B")"

# Case 4: a case pattern arm holding a placeholder fails.
C4="$TMP_DIR/case4"
new_fixture "$C4"
{
  printf '%s\n' '#!/usr/bin/env bash' 'case true in'
  printf '  %s) echo matched ;;\n' "$IP_TOK"
  printf '%s\n' '  *) echo other ;;' 'esac'
} >"$C4/case.sh"
git -C "$C4" add case.sh
git -C "$C4" commit -q -m "fixture: case placeholder"
check_case "case pattern placeholder fails" 1 "$(run_check "$C4")"

# Case 5: markdown and docs/ placeholders are ignored.
C5="$TMP_DIR/case5"
new_fixture "$C5"
mkdir -p "$C5/docs"
printf 'Endpoint is http://%s:8080/\n' "$IP_TOK" >"$C5/NOTES.md"
printf 'echo "%s"\n' "$IP_TOK" >"$C5/docs/guide.sh"
cat >"$C5/tool.sh" <<'EOF'
#!/usr/bin/env bash
echo "clean"
EOF
git -C "$C5" add NOTES.md docs/guide.sh tool.sh
git -C "$C5" commit -q -m "fixture: docs and markdown"
check_case "markdown and docs ignored" 0 "$(run_check "$C5")"

if [ "$FAILURES" -ne 0 ]; then
  echo "FAILURES: $FAILURES" >&2
  exit 1
fi
echo "All fixture cases passed."
exit 0
