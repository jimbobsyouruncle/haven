#!/usr/bin/env bash
set -Eeuo pipefail
# ---------------------------------------------------------------------------
# FILE: scripts/test-run-post-deploy-verify.sh
# PURPOSE (plain English):
#   Offline tests for scripts/run-post-deploy-verify.sh. They need no network,
#   no Docker and no access to /etc. curl and jq are stubbed on PATH, and the
#   deployed tree is a throwaway git checkout in a temp dir. A fixture layout
#   file is pointed at with HYBRID_AI_ENV_FILE_FALLBACK.
#
#   They prove the three-step APP_DIR resolution (environment, then layout file,
#   then /workspace) and the two tree-check verdicts (PASS on the expected SHA,
#   FAIL with the exact message on any other commit).
#
# USAGE:
#   bash scripts/test-run-post-deploy-verify.sh
#
# EXIT CODES:
#   0  every case passed
#   1  one or more cases failed
# ---------------------------------------------------------------------------

# Cases control the selector explicitly; ignore the invoking shell setting.
unset HYBRID_AI_REPOSITORY_SLUG HYBRID_AI_BACKUP_MODE HYBRID_AI_VERIFY_BACKUP_GATES
unset HYBRID_AI_DATA_DIR HYBRID_AI_LOG_DIR DOCKER_GID STATUS_UID

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_SCRIPT="$SCRIPT_DIR/run-post-deploy-verify.sh"

if [[ ! -f "$VERIFY_SCRIPT" ]]; then
  echo "FATAL: cannot find $VERIFY_SCRIPT" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf -- "$WORKDIR"' EXIT

BINDIR="$WORKDIR/bin"
mkdir -p "$BINDIR"

failures=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; failures=$((failures + 1)); }

# --- PATH stubs -------------------------------------------------------------
# curl: write a controlled body to the -o target and print a controlled status
# code. It never opens a socket.
cat > "$BINDIR/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_CALL_LOG:?}"
out=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --max-time|-A|--resolve) shift 2 ;;
    -w|-sS) shift ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
# The status API is a different endpoint from the GitHub API: a case sets
# CURL_TILE_CODE/CURL_TILE_BODY to control the Backups tile, or CURL_TILE_CODE=000
# to make the service unreachable.
if [[ "$url" == *"/status/api"* ]]; then
  [[ -n "$out" ]] && printf '%s' "${CURL_TILE_BODY:-}" > "$out"
  printf '%s' "${CURL_TILE_CODE:-200}"
  exit 0
fi
[[ -n "$out" ]] && printf '%s' "${CURL_STUB_BODY:-}" > "$out"
printf '%s' "${CURL_STUB_CODE:-200}"
exit "${CURL_STUB_RC:-0}"
EOF

# jq: answer only the filters the verifier uses. Rows come from JQ_STUB_ROWS; the
# Backups tile state comes from JQ_STUB_TILE. Any other filter (the verdict JSON
# builder and the assertions that read it back) goes to the real jq.
REAL_JQ="$(command -v jq)"
if [[ -z "$REAL_JQ" ]]; then
  echo "FATAL: jq is required to run these tests" >&2
  exit 1
fi
export REAL_JQ

cat > "$BINDIR/jq" <<'EOF'
#!/usr/bin/env bash
# Only the FILTER selects a stub mode; --arg/--argjson values are skipped so a
# detail string can never be mistaken for a filter.
mode=""
skip=0
for a in "$@"; do
  if (( skip )); then skip=$(( skip - 1 )); continue; fi
  case "$a" in
    --arg|--argjson|--slurpfile|--rawfile) skip=2; continue ;;
    -f) skip=1; continue ;;
    -*) continue ;;
  esac
  case "$a" in
    *'has("workflow_runs")'*) mode=has ;;
    *'workflow_runs[]'*) mode=rows ;;
    *'Backups'*) mode=tile ;;
  esac
  break
done
case "$mode" in
  has) exit "${JQ_STUB_HAS_EXIT:-0}" ;;
  rows) printf '%b' "${JQ_STUB_ROWS:-}"; exit 0 ;;
  tile) printf '%s' "${JQ_STUB_TILE:-}"; exit 0 ;;
  *) exec "${REAL_JQ:?}" "$@" ;;
esac
EOF

chmod +x "$BINDIR/curl" "$BINDIR/jq"
REAL_DATE="$(command -v date)"
export REAL_DATE
cat > "$BINDIR/date" <<'EOF'
#!/usr/bin/env bash
if [[ "${VERIFY_FAKE_CLOCK:-0}" == 1 && "$*" == +%s ]]; then
  if [[ -e "$VERIFY_CLOCK_MARKER" ]]; then printf '3601\n';
  else : > "$VERIFY_CLOCK_MARKER"; printf '0\n'; fi
else
  exec "$REAL_DATE" "$@"
fi
EOF
chmod +x "$BINDIR/date"
export CURL_CALL_LOG="$WORKDIR/curl.argv" VERIFY_CLOCK_MARKER="$WORKDIR/clock"
export PATH="$BINDIR:$PATH"

# --- Throwaway git trees ----------------------------------------------------
REAL_GIT="$(command -v git)"
HYBRID_AI_UID="$(id -u)"
HYBRID_AI_GID="$(id -g)"
export HYBRID_AI_UID HYBRID_AI_GID

# A git stub that records its argv (so the tests can see which -C directory the
# verifier resolved) and then delegates to the real git.
cat > "$BINDIR/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\${GIT_CALL_LOG:-/dev/null}"
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$BINDIR/git"

make_tree() { # <dir> <marker> -> prints the commit sha
  local dir="$1" marker="$2"
  mkdir -p "$dir"
  (
    cd "$dir"
    "$REAL_GIT" init -q
    "$REAL_GIT" config user.email [EMAIL]
    "$REAL_GIT" config user.name test
    printf '%s\n' "$marker" > marker.txt
    "$REAL_GIT" add marker.txt
    "$REAL_GIT" commit -q -m "$marker"
  ) >/dev/null
  (cd "$dir" && "$REAL_GIT" rev-parse HEAD)
}

TREE_A="$WORKDIR/tree-a"
TREE_B="$WORKDIR/tree-b"
SHA_A="$(make_tree "$TREE_A" alpha)"
SHA_B="$(make_tree "$TREE_B" bravo)"
if [[ "$SHA_A" == "$SHA_B" ]]; then
  echo "FATAL: the two fixture commits collided ($SHA_A)" >&2
  exit 1
fi

LAYOUT="$WORKDIR/hybrid-ai.env"
write_layout() { # <app-dir>
  printf 'HYBRID_AI_APP_DIR=%s\n' "$1" > "$LAYOUT"
}

# A green, completed API run for SHA_A.
export CURL_STUB_CODE=200
export CURL_STUB_BODY='{"workflow_runs":[{"id":1,"status":"completed","conclusion":"success"}]}'
export JQ_STUB_ROWS=$'1\tcompleted\tsuccess\n'

GIT_CALL_LOG="$WORKDIR/git-calls.argv"

# run_verify <app|__unset__> <layout|__absent__> [verdict-dir] ->
#   sets RC, OUT (stdout+stderr), OUT_STDOUT, OUT_STDERR, GIT_CALLS, RESOLVED
run_verify() {
  local app="$1" layout="$2" vdir="${3:-$WORKDIR/verdicts}"
  local env_args=() owner_args=() receipt_args=()
  if [[ "${TEST_OWNER_LAYOUT:-0}" == 1 ]]; then
    owner_args=(-u HYBRID_AI_UID -u HYBRID_AI_GID)
  fi
  if [[ "$app" != "__unset__" ]]; then
    env_args+=(HYBRID_AI_APP_DIR="$app")
  else
    env_args+=(-u HYBRID_AI_APP_DIR)
  fi
  if [[ "$layout" != "__absent__" ]]; then
    env_args+=(HYBRID_AI_ENV_FILE_FALLBACK="$layout")
  else
    env_args+=(HYBRID_AI_ENV_FILE_FALLBACK="$WORKDIR/no-such-layout.env")
  fi

  if [[ "$vdir" == __layout__ ]]; then
    owner_args+=(-u HYBRID_AI_DEPLOY_VERDICT_DIR)
  else
    receipt_args=(HYBRID_AI_DEPLOY_VERDICT_DIR="$vdir")
  fi

  rm -f "$GIT_CALL_LOG" "$CURL_CALL_LOG" "$VERIFY_CLOCK_MARKER"
  set +e
  # Scrub the gate's inputs so a value leaked into the caller's environment
  # cannot make a case pass: the layout file must be the only source here.
  # HYBRID_AI_DEPLOY_VERDICT_DIR keeps every case out of the real data dir.
  env -u BACKUP_LOG -u BACKUP_GROUP_GID -u LOCAL_DOMAIN -u VERIFY_STATUS_UID \
    -u VERIFY_STATUS_GID "${owner_args[@]}" "${env_args[@]}" GIT_CALL_LOG="$GIT_CALL_LOG" \
    "${receipt_args[@]}" \
    "$VERIFY_SCRIPT" --wait-for "$SHA_A" > "$WORKDIR/out" 2> "$WORKDIR/err"
  RC=$?
  set -e
  OUT_STDOUT="$(cat "$WORKDIR/out")"
  OUT_STDERR="$(cat "$WORKDIR/err")"
  OUT="$(cat "$WORKDIR/out" "$WORKDIR/err")"
  GIT_CALLS="$(cat "$GIT_CALL_LOG" 2>/dev/null || true)"
  # The verifier runs `git -C <dir> rev-parse HEAD`; read back the directory it
  # actually resolved.
  RESOLVED="$(sed -n 's/^-C \([^ ]*\) rev-parse HEAD$/\1/p' <<<"$GIT_CALLS" | head -1)"
}

echo "== Running run-post-deploy-verify.sh tests =="

# Case 1: the environment wins over the layout file. The env tree is on SHA_A
# (PASS), the layout names TREE_B (would FAIL), so PASS proves env precedence.
write_layout "$TREE_B"
run_verify "$TREE_A" "$LAYOUT"
if [[ "$RC" -eq 0 && "$RESOLVED" == "$TREE_A" ]] && grep -qE '^(PASS|WARN: optional verification evidence missing or warning)$' <<<"$OUT"; then
  pass "env HYBRID_AI_APP_DIR wins over the layout file (PASS)"
else
  fail "env should win over the layout file: rc $RC, resolved '$RESOLVED', out '$OUT'"
fi

# Case 2: env unset -> the layout file supplies APP_DIR. It names TREE_A, which
# is on SHA_A, so the run must PASS. On the unpatched base this reads /workspace
# instead and FAILs.
write_layout "$TREE_A"
run_verify "__unset__" "$LAYOUT"
if [[ "$RC" -eq 0 && "$RESOLVED" == "$TREE_A" ]] && grep -qE '^(PASS|WARN: optional verification evidence missing or warning)$' <<<"$OUT"; then
  pass "layout file supplies APP_DIR when the env is unset (PASS)"
else
  fail "layout file should supply APP_DIR when the env is unset: rc $RC, resolved '$RESOLVED', out '$OUT'"
fi

# Case 3: neither the env nor a layout file -> the /workspace fallback.
run_verify "__unset__" "__absent__"
if [[ "$RESOLVED" == "/workspace" ]]; then
  pass "no env and no layout file -> APP_DIR resolves to /workspace"
else
  fail "expected the /workspace fallback, resolved '$RESOLVED'"
fi

# Case 4: green run, tree on another commit -> FAIL with the exact message.
run_verify "$TREE_B" "__absent__"
if [[ "$RC" -eq 1 ]] \
   && grep -qxF "FAIL: deployed tree is on ${SHA_B}, expected ${SHA_A}" <<<"$OUT"; then
  pass "tree on another commit -> FAIL 'deployed tree is on <head>, expected <sha>' exit 1"
else
  fail "expected the wrong-commit FAIL, got rc $RC, out '$OUT'"
fi

# Case 5: green run, tree on the expected SHA -> exit 0, optional missing coverage WARN.
run_verify "$TREE_A" "__absent__"
if [[ "$RC" -eq 0 ]] && grep -qE '^(PASS|WARN: optional verification evidence missing or warning)$' <<<"$OUT"; then
  pass "tree on the expected SHA -> exit 0, optional missing coverage WARN"
else
  fail "expected PASS exit 0, got rc $RC, out '$OUT'"
fi

# Case 6: a layout value that is not an absolute path is refused; the run falls
# through to /workspace rather than trusting the value.
printf 'HYBRID_AI_APP_DIR=relative/path\n' > "$LAYOUT"
run_verify "__unset__" "$LAYOUT"
if [[ "$RESOLVED" == "/workspace" ]]; then
  pass "a non-absolute layout value is ignored -> /workspace fallback"
else
  fail "expected a non-absolute layout value to be ignored, resolved '$RESOLVED'"
fi

# --- Backups tile gate ------------------------------------------------------
# These cases need a layout file that names the log, the supplementary gid and
# the domain, plus a real log file. They run as whoever runs the suite; the
# readability probe then prints a skip note (it never claims a root read as a
# pass), so the verdict is driven by (a) the file check and (c) the tile query,
# which is exactly the contract.
BLOG="$WORKDIR/backup.log"
write_gate_layout() { # <app-dir> <log-path>
  printf 'HYBRID_AI_APP_DIR=%s\nBACKUP_LOG=%s\nBACKUP_GROUP_GID=982\nLOCAL_DOMAIN=example.test\n' \
    "$1" "$2" > "$LAYOUT"
}

printf 'EVENT ts=2026-01-01T00:00:00Z event=backup_success detail=stub\n' > "$BLOG"

# Case 7: the writer's log holds a success but the live tile says warn -> FAIL.
# This is the whole point of the gate: a release that leaves the reader blind.
write_gate_layout "$TREE_A" "$BLOG"
export CURL_TILE_CODE=200 JQ_STUB_TILE=warn
run_verify "__unset__" "$LAYOUT"
if [[ "$RC" -eq 1 ]] \
   && grep -qxF 'FAIL: the backup log records event=backup_success but the Backups tile reports warn' <<<"$OUT"; then
  pass "log success + warn tile -> FAIL exit 1"
else
  fail "expected the blind-tile FAIL, got rc $RC, out '$OUT'"
fi

# Case 8: a healthy tile is nonblocking; skipped readability produces WARN.
export JQ_STUB_TILE=ok
run_verify "__unset__" "$LAYOUT"
if [[ "$RC" -eq 0 ]] && grep -qE '^(PASS|WARN: optional verification evidence missing or warning)$' <<<"$OUT"; then
  pass "log success + ok tile -> exit 0; incomplete optional coverage remains WARN"
else
  fail "expected PASS with a healthy tile, got rc $RC, out '$OUT'"
fi

# Case 9: an optional unreachable API produces SKIPPED evidence and WARN.
export CURL_TILE_CODE=000 JQ_STUB_TILE=""
run_verify "__unset__" "$LAYOUT"
if [[ "$RC" -eq 0 ]] && grep -qE '^(PASS|WARN: optional verification evidence missing or warning)$' <<<"$OUT"; then
  if grep -q 'skip: the status API was unreachable' <<<"$OUT"; then
    pass "unreachable status API -> skip note and WARN"
  else
    fail "an unreachable API did not print a skip note: '$OUT'"
  fi
else
  fail "an unreachable API should not change the verdict: rc $RC, out '$OUT'"
fi

# Case 10: the log is not a regular, non-empty file -> FAIL, because the reader
# can never work from it whatever the tile says.
: > "$BLOG"
export CURL_TILE_CODE=200 JQ_STUB_TILE=ok
run_verify "__unset__" "$LAYOUT"
if [[ "$RC" -eq 1 ]] \
   && grep -qxF 'FAIL: the backup log is not a regular, non-empty file' <<<"$OUT"; then
  pass "empty backup log -> FAIL exit 1"
else
  fail "expected the empty-log FAIL, got rc $RC, out '$OUT'"
fi
printf 'EVENT ts=2026-01-01T00:00:00Z event=backup_success detail=stub\n' > "$BLOG"
unset CURL_TILE_CODE JQ_STUB_TILE

# --- Verdict JSON -----------------------------------------------------------
# The container cannot see the host log, so each deploy SHA gets a JSON file in
# the data dir. Every case above already ran with HYBRID_AI_DEPLOY_VERDICT_DIR
# pointed at $WORKDIR/verdicts and still had to print the same result line.
VDIR="$WORKDIR/verdicts"
VDIR_FILE="$VDIR/$SHA_A.json"

# jq programs that compare against arguments live in files: a heredoc keeps the
# jq variables literal without a shell-expansion warning.
FAIL_FILTER="$WORKDIR/fail.jq"
cat > "$FAIL_FILTER" <<'JQEOF'
(.verdict == "FAIL") and (.rc == 1) and (.detail == $d) and (.sha == $sha) and (.head == $head)
JQEOF

DETAIL_FILTER="$WORKDIR/detail.jq"
cat > "$DETAIL_FILTER" <<'JQEOF'
(.detail == $d) and (.verdict == "FAIL")
JQEOF

# Case 11: WARN preserves the eight legacy fields and adds gate evidence.
rm -rf "$VDIR"
write_layout "$TREE_A"
export CURL_STUB_CODE=200 JQ_STUB_ROWS=$'1\tcompleted\tsuccess\n'
run_verify "$TREE_A" "__absent__"
if [[ "$RC" -eq 0 ]] && grep -qE '^(PASS|WARN: optional verification evidence missing or warning)$' <<<"$OUT_STDOUT" && [[ -f "$VDIR_FILE" ]]; then
  if "$REAL_JQ" -e '
      (keys == ["app_dir","at","detail","gates","head","rc","run_ids","schema_version","sha","verdict"])
      and (.verdict == "WARN")
      and (.schema_version == 2)
      and (.gates.backup_log.state == "SKIPPED")
      and (.gates.backup_log.required == false)
      and (.gates.workflow_runs.state == "PASS")
      and (.gates.deployed_head.state == "PASS")
      and (.rc == 0)
      and (.detail == "optional verification evidence missing or warning")
      and (.sha == "'"$SHA_A"'")
      and (.head == "'"$SHA_A"'")
      and (.app_dir == "'"$TREE_A"'")
      and (.run_ids | type == "array")
      and (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    ' "$VDIR_FILE" >/dev/null 2>&1; then
    pass "WARN receipt preserves legacy fields and adds schema/coverage evidence"
  else
    fail "the WARN verdict file is malformed or carries wrong values: $("$REAL_JQ" -c . "$VDIR_FILE" 2>&1)"
  fi
else
  fail "a WARN run did not write $VDIR_FILE: rc $RC, out '$OUT'"
fi

# Case 12: a FAIL path writes verdict FAIL with the SAME detail as the line, and
# rc stays 1. The tree is on SHA_B while SHA_A is verified.
rm -rf "$VDIR"
run_verify "$TREE_B" "__absent__"
EXPECT_DETAIL="deployed tree is on ${SHA_B}, expected ${SHA_A}"
if [[ "$RC" -eq 1 ]] && grep -qxF "FAIL: ${EXPECT_DETAIL}" <<<"$OUT_STDOUT" && [[ -f "$VDIR_FILE" ]]; then
  if "$REAL_JQ" -e --arg d "$EXPECT_DETAIL" --arg sha "$SHA_A" --arg head "$SHA_B" \
      -f "$FAIL_FILTER" "$VDIR_FILE" >/dev/null 2>&1; then
    pass "FAIL path writes verdict FAIL with the same detail as the stdout line, rc 1"
  else
    fail "the FAIL verdict file does not match the stdout line: $("$REAL_JQ" -c . "$VDIR_FILE" 2>&1)"
  fi
else
  fail "a FAIL run did not write a matching $VDIR_FILE: rc $RC, out '$OUT'"
fi

# Case 13: failed optional receipt publication is explicit WARN, not PASS.
BLOCKER="$WORKDIR/blocker"
printf 'not a directory\n' > "$BLOCKER"
run_verify "$TREE_A" "__absent__" "$BLOCKER/deploy-verdicts"
if [[ "$RC" == 0 ]] && grep -qxF 'WARN: optional verdict receipt could not be published' <<<"$OUT_STDOUT" \
   && [[ ! -e "$BLOCKER/deploy-verdicts/$SHA_A.json" ]]; then
  pass "an impossible verdict path produces an explicit warning"
else
  fail "receipt failure was not visible: $OUT"
fi

# Case 14: the detail lands in the JSON as ONE line. `grep -c ''` counts the
# lines of the file, so 1 proves the object is on a single line with exactly one
# trailing newline, and jq -r proves the value reads back unchanged.
rm -rf "$VDIR"
export CURL_STUB_CODE=500
run_verify "$TREE_A" "__absent__"
unset CURL_STUB_CODE
export CURL_STUB_CODE=200
if [[ -f "$VDIR_FILE" ]]; then
  if "$REAL_JQ" -e . "$VDIR_FILE" >/dev/null 2>&1 \
     && [[ "$(grep -c '' "$VDIR_FILE")" -eq 1 ]] \
     && [[ "$("$REAL_JQ" -r .detail "$VDIR_FILE")" == "github api returned HTTP 500" ]] \
     && [[ "$("$REAL_JQ" -r .detail "$VDIR_FILE")" != *$'\n'* ]] \
     && [[ "$(tail -c 1 "$VDIR_FILE" | wc -l)" -eq 1 ]]; then
    pass "the verdict file parses, is one line, and .detail holds the single-line reason"
  else
    fail "the verdict file is not one parseable line: $("$REAL_JQ" -c . "$VDIR_FILE" 2>&1)"
  fi
else
  fail "the HTTP-error FAIL wrote no verdict file: out '$OUT'"
fi

# Case 15: a quote in the detail is escaped by jq, never hand-concatenated, so
# the file still parses and the raw bytes hold the escaped form.
rm -rf "$VDIR"
TRICKY='fail"ure'
export JQ_STUB_ROWS="1"$'\t'"completed"$'\t'"${TRICKY}"$'\n'
run_verify "$TREE_A" "__absent__"
export JQ_STUB_ROWS=$'1\tcompleted\tsuccess\n'
TRICKY_DETAIL="run 1 conclusion ${TRICKY}"
if [[ -f "$VDIR_FILE" ]] && grep -qxF "FAIL: ${TRICKY_DETAIL}" <<<"$OUT_STDOUT"; then
  if "$REAL_JQ" -e --arg d "$TRICKY_DETAIL" -f "$DETAIL_FILTER" "$VDIR_FILE" >/dev/null 2>&1 \
     && grep -qF 'fail\"ure' "$VDIR_FILE" \
     && [[ "$(grep -c '' "$VDIR_FILE")" -eq 1 ]]; then
    pass "an awkward detail is JSON-escaped: the file parses and stays one line"
  else
    fail "the awkward detail was not escaped correctly: $(cat "$VDIR_FILE" 2>&1)"
  fi
else
  fail "the awkward-detail FAIL did not match the stdout line: rc $RC, out '$OUT'"
fi

# Case 16: numeric ownership is independent of a host account named hermes.
rm -rf "$VDIR"
run_verify "$TREE_A" "__absent__"
if [[ -f "$VDIR_FILE" ]] && [[ "$(stat -c '%a' "$VDIR")" == 755 ]] \
   && [[ "$(stat -c '%a' "$VDIR_FILE")" == 644 ]] \
   && [[ "$(stat -c '%u:%g' "$VDIR_FILE")" == "$HYBRID_AI_UID:$HYBRID_AI_GID" ]] \
   && [[ "$(stat -c '%u:%g' "$VDIR")" == "$HYBRID_AI_UID:$HYBRID_AI_GID" ]] \
   && ! grep -q 'hermes account' <<<"$OUT_STDERR"; then
  pass "numeric owner and existing 0755/0644 modes without a host hermes account"
else fail "numeric ownership/mode contract failed: $OUT"; fi

echo "== repository identity, standalone installation and fail-closed HTTP =="
export CURL_STUB_CODE=200 JQ_STUB_ROWS=$'1\tcompleted\tsuccess\n'
run_verify "$TREE_A" "__absent__"
if grep -Fq "https://api.github.com/repos/jimbobsyouruncle/hybrid-ai/actions/runs?head_sha=$SHA_A" "$CURL_CALL_LOG"; then
  pass "default verifier API identity remains hybrid-ai"
else fail "default API identity changed"; fi
# Simulate install.sh copying only this executable into /usr/local/sbin.
SOURCE_VERIFY="$VERIFY_SCRIPT"
mkdir -p "$WORKDIR/sbin"
cp "$VERIFY_SCRIPT" "$WORKDIR/sbin/run-post-deploy-verify.sh"
VERIFY_SCRIPT="$WORKDIR/sbin/run-post-deploy-verify.sh"
export HYBRID_AI_REPOSITORY_SLUG=jimbobsyouruncle/haven
run_verify "$TREE_A" "__absent__"
if [[ "$RC" == 0 ]] && grep -q '^WARN:' <<< "$OUT_STDOUT" && grep -Fq "https://api.github.com/repos/jimbobsyouruncle/haven/actions/runs?head_sha=$SHA_A" "$CURL_CALL_LOG"; then
  pass "standalone installed verifier selects Haven without a sibling helper"
else fail "standalone Haven verifier failed: $OUT"; fi
for code in 301 302 403 404 500; do
  export CURL_STUB_CODE="$code"
  run_verify "$TREE_A" "__absent__"
  if [[ "$RC" == 1 ]] && grep -qxF "FAIL: github api returned HTTP $code" <<< "$OUT_STDOUT" && ! grep -Eq -- '(^| )(-L|--location)( |$)' "$CURL_CALL_LOG"; then
    pass "HTTP $code fails closed without following redirects"
  else fail "HTTP $code did not fail closed"; fi
done
export CURL_STUB_CODE=200 CURL_STUB_RC=28
run_verify "$TREE_A" "__absent__"
if [[ "$RC" == 1 ]] && grep -qxF 'FAIL: curl could not reach the github api' <<< "$OUT_STDOUT"; then
  pass "curl timeout fails verification"
else fail "curl timeout was not a failure"; fi
unset CURL_STUB_RC
export VERIFY_FAKE_CLOCK=1 JQ_STUB_ROWS=''
run_verify "$TREE_A" "__absent__"
if [[ "$RC" == 1 ]] && grep -qxF "TIMEOUT: no completed run for $SHA_A after 60 minutes" <<< "$OUT_STDOUT"; then
  pass "empty run list reaches deadline without a real wait"
else fail "empty run deadline did not fail: $OUT"; fi
unset VERIFY_FAKE_CLOCK HYBRID_AI_REPOSITORY_SLUG
VERIFY_SCRIPT="$SOURCE_VERIFY"

echo "== coverage policy and system layout =="
export JQ_STUB_ROWS=$'1\tcompleted\tsuccess\n'
# A mocked root/setpriv boundary exercises the real probe and policy logic
# without privileged execution. The fixture file remains owned by this caller.
REAL_ID="$(command -v id)"
export REAL_ID
cat > "$BINDIR/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${VERIFY_MOCK_ROOT:-0}" == 1 && "$*" == -u ]]; then echo 0;
else exec "$REAL_ID" "$@"; fi
EOF
cat > "$BINDIR/setpriv" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$VERIFY_PRIV_LOG"
exit "${VERIFY_PRIV_RC:-0}"
EOF
chmod +x "$BINDIR/id" "$BINDIR/setpriv"
export VERIFY_PRIV_LOG="$WORKDIR/setpriv.argv"

# System default must resolve the systemd LogsDirectory without touching /var.
# Intercept only the log path in an instrumented standalone copy; the captured
# path is the production function's resolved argument, not a test reimplementation.
SOURCE_VERIFY="$VERIFY_SCRIPT"
cp "$VERIFY_SCRIPT" "$WORKDIR/verify-path.sh"
# shellcheck disable=SC2016  # Literal variables execute only in the instrumented fixture.
sed -i '/  if \[\[ ! -f "$log"/i\  printf "%s" "$log" > "$VERIFY_RESOLVED_LOG"; log="$VERIFY_FIXTURE_LOG"' "$WORKDIR/verify-path.sh"
VERIFY_SCRIPT="$WORKDIR/verify-path.sh"
export VERIFY_RESOLVED_LOG="$WORKDIR/resolved-log" VERIFY_FIXTURE_LOG="$BLOG"
export VERIFY_MOCK_ROOT=1 CURL_TILE_CODE=200 JQ_STUB_TILE=ok
write_layout "$TREE_A"
printf 'HYBRID_AI_BACKUP_MODE=system\nBACKUP_GROUP_GID=982\nLOCAL_DOMAIN=example.test\nHYBRID_AI_UID=%s\n' "$HYBRID_AI_UID" >> "$LAYOUT"
run_verify "__unset__" "$LAYOUT"
if [[ "$(cat "$VERIFY_RESOLVED_LOG")" == /var/log/hybrid-ai-backup/backup.log ]] \
   && [[ "$RC" == 0 ]] && grep -qx PASS <<<"$OUT_STDOUT" \
   && "$REAL_JQ" -e 'all(.gates[]; .state == "PASS") and .gates.backup_log.required' "$VDIR_FILE" >/dev/null; then
  pass "system layout resolves units log and all executed gates produce PASS"
else fail "system resolution/complete PASS failed: $OUT"; fi
if grep -q -- "--reuid=$HYBRID_AI_UID" "$VERIFY_PRIV_LOG" \
   && grep -q -- '--groups=982 --inh-caps=-all --bounding-set=-all' "$VERIFY_PRIV_LOG"; then
  pass "status probe uses configured numeric UID and drops capabilities"
else fail "wrong status probe identity: $(cat "$VERIFY_PRIV_LOG")"; fi
# Explicit BACKUP_LOG overrides the system default.
printf 'BACKUP_LOG=/fixture/explicit.log\n' >> "$LAYOUT"
run_verify "__unset__" "$LAYOUT"
if [[ "$(cat "$VERIFY_RESOLVED_LOG")" == /fixture/explicit.log ]]; then
  pass "explicit layout log overrides system default"
else fail "system override ignored"; fi
# Numeric identity resolves from layout even without corresponding host names.
printf 'HYBRID_AI_GID=%s\n' "$HYBRID_AI_GID" >> "$LAYOUT"
export TEST_OWNER_LAYOUT=1
run_verify "__unset__" "$LAYOUT"
if [[ "$RC" == 0 ]] && grep -qx PASS <<<"$OUT_STDOUT" \
   && [[ "$(stat -c '%u:%g' "$VDIR_FILE")" == "$HYBRID_AI_UID:$HYBRID_AI_GID" ]]; then
  pass "receipt numeric ownership resolves from non-secret layout"
else fail "layout numeric ownership failed: $OUT"; fi
unset TEST_OWNER_LAYOUT
# User-mode defaults use the configured log directory, not the system path.
write_layout "$TREE_A"
printf 'HYBRID_AI_LOG_DIR=/fixture/user-log\n' >> "$LAYOUT"
run_verify "__unset__" "$LAYOUT"
if [[ "$(cat "$VERIFY_RESOLVED_LOG")" == /fixture/user-log/backup.log ]]; then
  pass "user-mode log directory resolution"
else fail "wrong user-mode default"; fi
VERIFY_SCRIPT="$SOURCE_VERIFY"

# Required missing API evidence must fail even if a user-mode policy says optional.
write_gate_layout "$TREE_A" "$BLOG"
printf 'HYBRID_AI_BACKUP_MODE=system\nHYBRID_AI_VERIFY_BACKUP_GATES=optional\n' >> "$LAYOUT"
export CURL_TILE_CODE=000
run_verify "__unset__" "$LAYOUT"
if [[ "$RC" == 1 ]] && "$REAL_JQ" -e '.verdict == "FAIL" and .gates.backup_tile.state == "SKIPPED" and .gates.backup_tile.required' "$VDIR_FILE" >/dev/null; then
  pass "system-mode missing API evidence fails closed; optional cannot downgrade"
else fail "missing mandatory API evidence passed: $OUT"; fi
# User-mode can opt into mandatory coverage; missing privilege evidence also fails.
write_gate_layout "$TREE_A" "$BLOG"
printf 'HYBRID_AI_VERIFY_BACKUP_GATES=required\n' >> "$LAYOUT"
export CURL_TILE_CODE=200
unset VERIFY_MOCK_ROOT
run_verify "__unset__" "$LAYOUT"
if [[ "$("$REAL_ID" -u)" != 0 ]]; then
  if [[ "$RC" == 1 ]] && "$REAL_JQ" -e '.gates.backup_readability.state == "SKIPPED" and .gates.backup_readability.required' "$VDIR_FILE" >/dev/null; then
    pass "required readability without privileges fails closed"
  else fail "missing required privilege evidence passed: $OUT"; fi
fi
# Optional unavailable API remains nonblocking but is recorded as SKIPPED/WARN.
write_gate_layout "$TREE_A" "$BLOG"
export VERIFY_MOCK_ROOT=1 CURL_TILE_CODE=000
run_verify "__unset__" "$LAYOUT"
if [[ "$RC" == 0 ]] && "$REAL_JQ" -e '.verdict == "WARN" and .gates.backup_tile.state == "SKIPPED" and (.gates.backup_tile.required | not)' "$VDIR_FILE" >/dev/null; then
  pass "optional unavailable API is SKIPPED and overall WARN"
else fail "optional skipped API not represented: $OUT"; fi
# A detected unreadable log stays FAIL even under optional policy.
export CURL_TILE_CODE=200 VERIFY_PRIV_RC=1
run_verify "__unset__" "$LAYOUT"
if [[ "$RC" == 1 ]] && "$REAL_JQ" -e '.gates.backup_readability.state == "FAIL"' "$VDIR_FILE" >/dev/null; then
  pass "detected unreadability fails under optional policy too"
else fail "unreadable log passed: $OUT"; fi
unset VERIFY_PRIV_RC
# Warning and malformed tile states must never produce clean PASS.
for state in warn nonsense ''; do
  printf 'event=backup_started\n' > "$BLOG"
  export JQ_STUB_TILE="$state"
  run_verify "__unset__" "$LAYOUT"
  if [[ "$RC" == 0 ]] && grep -q '^WARN:' <<<"$OUT_STDOUT" \
     && "$REAL_JQ" -e '.gates.backup_tile.state != "PASS"' "$VDIR_FILE" >/dev/null; then
    pass "optional tile '$state' cannot produce PASS"
  else fail "optional tile '$state' passed cleanly: $OUT"; fi
done
# Layout data directory controls the actual standalone receipt destination.
write_layout "$TREE_A"
printf 'HYBRID_AI_DATA_DIR=%s\n' "$WORKDIR/layout-data" >> "$LAYOUT"
run_verify "__unset__" "$LAYOUT" __layout__
if [[ -f "$WORKDIR/layout-data/hermes_data/deploy-verdicts/$SHA_A.json" ]]; then
  pass "standalone receipt directory resolves from non-secret layout"
else fail "receipt ignored layout data directory: $OUT"; fi
if [[ "$("$REAL_ID" -u)" != 0 ]]; then
  chmod 000 "$LAYOUT"
  run_verify "$TREE_A" "$LAYOUT"
  chmod 600 "$LAYOUT"
  if [[ "$RC" == 1 ]] && grep -qxF 'FAIL: layout file is unreadable; refusing defaults' <<<"$OUT_STDOUT"; then
    pass "unreadable layout fails even with explicit app directory"
  else fail "unreadable layout silently selected defaults: $OUT"; fi
fi
# Invalid policies fail closed; file values are never executed as shell code.
write_layout "$TREE_A"
printf 'HYBRID_AI_VERIFY_BACKUP_GATES=invalid\n' >> "$LAYOUT"
run_verify "__unset__" "$LAYOUT"
if [[ "$RC" == 1 ]] && ! grep -qx PASS <<<"$OUT_STDOUT"; then
  pass "invalid backup policy fails closed"
else fail "invalid policy accepted"; fi
write_layout "$TREE_A"
# shellcheck disable=SC2016  # Injection fixture must remain literal data.
printf 'HYBRID_AI_UID=$(touch %s)\n' "$WORKDIR/injected" >> "$LAYOUT"
export TEST_OWNER_LAYOUT=1
run_verify "__unset__" "$LAYOUT"
unset TEST_OWNER_LAYOUT
if grep -q '^WARN: optional verdict receipt' <<<"$OUT_STDOUT" \
   && [[ ! -e "$WORKDIR/injected" ]]; then
  pass "nonnumeric owner is refused without executing layout data"
else fail "owner injection was accepted/executed"; fi
write_gate_layout "$TREE_A" "$BLOG"
# Reject a symlink target without overwriting its referent.
rm -f "$VDIR_FILE"
printf 'untouched\n' > "$WORKDIR/referent"
ln -s "$WORKDIR/referent" "$VDIR_FILE"
run_verify "__unset__" "$LAYOUT"
if grep -q '^WARN: optional verdict receipt' <<<"$OUT_STDOUT" \
   && [[ "$(cat "$WORKDIR/referent")" == untouched ]]; then
  pass "receipt symlink is refused and referent unchanged"
else fail "receipt symlink was followed"; fi
unset VERIFY_MOCK_ROOT CURL_TILE_CODE JQ_STUB_TILE

echo "== done =="
if [[ "$failures" -ne 0 ]]; then
  echo "$failures case(s) failed."
  exit 1
fi
echo "All cases passed."
exit 0
