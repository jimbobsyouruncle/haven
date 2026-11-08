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
exit 0
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
  if (( skip )); then skip=0; continue; fi
  case "$a" in
    --arg|--argjson|--slurpfile|--rawfile|-f) skip=1; continue ;;
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
export PATH="$BINDIR:$PATH"

# --- Throwaway git trees ----------------------------------------------------
REAL_GIT="$(command -v git)"

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
  local env_args=()
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

  rm -f "$GIT_CALL_LOG"
  set +e
  # Scrub the gate's inputs so a value leaked into the caller's environment
  # cannot make a case pass: the layout file must be the only source here.
  # HYBRID_AI_DEPLOY_VERDICT_DIR keeps every case out of the real data dir.
  env -u BACKUP_LOG -u BACKUP_GROUP_GID -u LOCAL_DOMAIN -u VERIFY_STATUS_UID \
    -u VERIFY_STATUS_GID "${env_args[@]}" GIT_CALL_LOG="$GIT_CALL_LOG" \
    HYBRID_AI_DEPLOY_VERDICT_DIR="$vdir" \
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
if [[ "$RC" -eq 0 && "$RESOLVED" == "$TREE_A" ]] && grep -qx 'PASS' <<<"$OUT"; then
  pass "env HYBRID_AI_APP_DIR wins over the layout file (PASS)"
else
  fail "env should win over the layout file: rc $RC, resolved '$RESOLVED', out '$OUT'"
fi

# Case 2: env unset -> the layout file supplies APP_DIR. It names TREE_A, which
# is on SHA_A, so the run must PASS. On the unpatched base this reads /workspace
# instead and FAILs.
write_layout "$TREE_A"
run_verify "__unset__" "$LAYOUT"
if [[ "$RC" -eq 0 && "$RESOLVED" == "$TREE_A" ]] && grep -qx 'PASS' <<<"$OUT"; then
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

# Case 5: green run, tree on the expected SHA -> PASS exit 0.
run_verify "$TREE_A" "__absent__"
if [[ "$RC" -eq 0 ]] && grep -qx 'PASS' <<<"$OUT"; then
  pass "tree on the expected SHA -> PASS exit 0"
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

# Case 8: the same log, a healthy tile -> the verdict is unchanged (PASS).
export JQ_STUB_TILE=ok
run_verify "__unset__" "$LAYOUT"
if [[ "$RC" -eq 0 ]] && grep -qx 'PASS' <<<"$OUT"; then
  pass "log success + ok tile -> PASS exit 0 (verdict unchanged)"
else
  fail "expected PASS with a healthy tile, got rc $RC, out '$OUT'"
fi

# Case 9: an unreachable status API is a skip note, never a pass or a FAIL on
# its own account -- with a healthy tree the verdict stays PASS.
export CURL_TILE_CODE=000 JQ_STUB_TILE=""
run_verify "__unset__" "$LAYOUT"
if [[ "$RC" -eq 0 ]] && grep -qx 'PASS' <<<"$OUT"; then
  if grep -q 'skip: the status API was unreachable' <<<"$OUT"; then
    pass "unreachable status API -> skip note, verdict unchanged (PASS)"
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

# Case 11: PASS writes a well-formed file with all eight keys.
rm -rf "$VDIR"
write_layout "$TREE_A"
export CURL_STUB_CODE=200 JQ_STUB_ROWS=$'1\tcompleted\tsuccess\n'
run_verify "$TREE_A" "__absent__"
if [[ "$RC" -eq 0 ]] && grep -qx 'PASS' <<<"$OUT_STDOUT" && [[ -f "$VDIR_FILE" ]]; then
  if "$REAL_JQ" -e '
      (keys == ["app_dir","at","detail","head","rc","run_ids","sha","verdict"])
      and (.verdict == "PASS")
      and (.rc == 0)
      and (.detail == "")
      and (.sha == "'"$SHA_A"'")
      and (.head == "'"$SHA_A"'")
      and (.app_dir == "'"$TREE_A"'")
      and (.run_ids | type == "array")
      and (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    ' "$VDIR_FILE" >/dev/null 2>&1; then
    pass "PASS writes <sha>.json with all 8 keys, verdict PASS, rc 0, detail '', head, run_ids array"
  else
    fail "the PASS verdict file is malformed or carries wrong values: $("$REAL_JQ" -c . "$VDIR_FILE" 2>&1)"
  fi
else
  fail "a PASS run did not write $VDIR_FILE: rc $RC, out '$OUT'"
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

# Case 13: a verdict write that cannot succeed changes nothing. The parent of the
# target is a REGULAR FILE, so `install -d` cannot create the dir even as root.
BLOCKER="$WORKDIR/blocker"
printf 'not a directory\n' > "$BLOCKER"
rm -rf "$VDIR"
run_verify "$TREE_A" "__absent__"
# The verifier prints a current timestamp in its opening status line.
# Compare that line's shape separately so crossing a second boundary cannot
# make the optional-verdict-write isolation check flaky.
NORMAL_STDOUT="$(sed -E 's/ at [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/ at <timestamp>/' <<<"$OUT_STDOUT")"
NORMAL_RC="$RC"
NORMAL_LINES="$(grep -c '' <<<"$OUT_STDERR" || true)"
run_verify "$TREE_A" "__absent__" "$BLOCKER/deploy-verdicts"
LINES="$(grep -c '' <<<"$OUT_STDERR" || true)"
if [[ "$RC" -eq "$NORMAL_RC" && "$(sed -E 's/ at [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/ at <timestamp>/' <<<"$OUT_STDOUT")" == "$NORMAL_STDOUT" ]]; then
  # Exactly ONE new stderr line, naming the reason; nothing else changes.
  if [[ ! -e "$BLOCKER/deploy-verdicts/$SHA_A.json" ]] \
     && [[ "$LINES" -le $(( NORMAL_LINES + 1 )) ]] \
     && grep -qxF "run-post-deploy-verify: could not create the verdict directory $BLOCKER/deploy-verdicts" <<<"$OUT_STDERR"; then
    pass "an impossible verdict path is a warning only: stdout and rc unchanged, script did not abort"
  else
    fail "an impossible verdict path broke the isolation (stderr lines $LINES vs $NORMAL_LINES): '$OUT_STDERR'"
  fi
else
  fail "the verdict write changed the result: rc $RC vs $NORMAL_RC, stdout '$OUT_STDOUT' vs '$NORMAL_STDOUT'"
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

# Case 16: ownership/mode. Assert mode always; assert hermes:hermes only when the
# account exists here. Never touches the real /var/lib path.
rm -rf "$VDIR"
run_verify "$TREE_A" "__absent__"
if [[ -f "$VDIR_FILE" ]]; then
  DMODE="$(stat -c '%a' "$VDIR")"
  FMODE="$(stat -c '%a' "$VDIR_FILE")"
  if [[ "$DMODE" == "755" && "$FMODE" == "644" ]]; then
    if id -u hermes >/dev/null 2>&1; then
      OWNER="$(stat -c '%U:%G' "$VDIR_FILE")"
      DOWNER="$(stat -c '%U:%G' "$VDIR")"
      if [[ "$OWNER" == "hermes:hermes" && "$DOWNER" == "hermes:hermes" ]]; then
        pass "verdict dir is hermes:hermes 0755 and file is hermes:hermes 0644"
      else
        fail "expected hermes:hermes ownership, got dir '$DOWNER' file '$OWNER'"
      fi
    else
      echo "skip: hermes account absent"
      pass "verdict dir mode 0755 and file mode 0644 (owner not asserted)"
    fi
  else
    fail "expected dir mode 755 and file mode 644, got dir '$DMODE' file '$FMODE'"
  fi
else
  fail "no verdict file to check ownership on: out '$OUT'"
fi

echo "== done =="
if [[ "$failures" -ne 0 ]]; then
  echo "$failures case(s) failed."
  exit 1
fi
echo "All cases passed."
exit 0
