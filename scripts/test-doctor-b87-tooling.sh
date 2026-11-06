#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-doctor-b87-tooling.sh
# PURPOSE (plain English):
#   Proves the two B87 tooling checks in doctor.sh by RUNNING doctor.sh against
#   a stubbed docker -- it does not grep the text of doctor.sh.
#
#   The two blind spots this change closes:
#     A. the hermes-agent image must carry shellcheck. It is an apt package in
#        the image's root layer, and the runtime uid cannot add it. A stale
#        image therefore looks healthy while the shell lint silently cannot run.
#     B. the DEPLOYED backup.sh must exclude backups/ from capture, otherwise a
#        backup is captured into the next backup of itself.
#
#   Fully OFFLINE. No Docker, no network, no root. The docker stub answers from
#   fixture variables, and the host commands doctor.sh probes are stubbed on
#   PATH so nothing else can move the verdict.
#
#   Proven here:
#     A pass  shellcheck present       -> exactly one pass line, byte-exact
#                                         message, no warn and no fail from
#                                         this check
#     A warn  container absent/stopped -> one warn, no pass, no fail
#     A warn  docker erroring          -> one warn, no pass, no fail
#     A fail  reachable, tool missing  -> one fail with the byte-exact message,
#                                         and doctor.sh exits 2
#     B pass  deployed file has entry  -> exactly one pass line, byte-exact
#     B warn  file missing/unreadable  -> one warn, no pass, no fail
#     B fail  readable, entry absent   -> one fail with the byte-exact message,
#                                         and doctor.sh exits 2
#     B       an entry that appears ONLY inside a comment does not count
#     -       the same run against the same doctor.sh with both blocks removed
#             produces NONE of these messages, which is what proves the
#             assertions above are caused by the checks and not by the fixture.
#
#   Exit-code semantics are unchanged: fail drives exit 2, warn drives exit 1.
#   The fixture host has unrelated warnings of its own, so "unchanged" is
#   stated as a comparison with the stripped baseline where it matters and as
#   the exact expected code where the check is the only failure.
#
# USAGE:
#   bash scripts/test-doctor-b87-tooling.sh [path-to-doctor.sh]
#
#   The path defaults to doctor.sh at the repository root, resolved from this
#   script's own location so the harness runs from anywhere. Point it at a copy
#   of the base doctor.sh to prove the harness fails without the checks.
#
# EXIT CODES:
#   0  every assertion passed
#   1  one or more assertions failed
#   2  a required tool is missing, or doctor.sh was not found
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

DOCTOR="${1:-$REPO_ROOT/doctor.sh}"
if [[ ! -f "$DOCTOR" ]]; then
  echo "FAIL: doctor.sh not found: $DOCTOR" >&2
  exit 2
fi

for t in mktemp date git bash timeout awk sed grep find; do
  command -v "$t" >/dev/null 2>&1 || { echo "FAIL: ${t} is required" >&2; exit 2; }
done
REAL_JQ="$(command -v jq || true)"

# The host-side bind doctor.sh expects when it reads the port bindings. Taken
# from doctor.sh itself so the stub can never drift from the real check.
BRIDGE_IP="$(sed -n "s/.*\"\\\$BINDINGS\" == \\*\"\\([^:\"]*\\):\\\${OH_PORT}\".*/\\1/p" "$DOCTOR" | head -1)"
BRIDGE_IP="${BRIDGE_IP:-[IP_ADDRESS]}"

WORK="$(mktemp -d)"
if [[ -n "${B87_KEEP:-}" ]]; then
  trap 'echo "kept: $WORK" >&2' EXIT
else
  trap 'rm -rf -- "$WORK"' EXIT
fi

PASS=0
FAILURES=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }

BIN="$WORK/bin"
APPD="$WORK/app"
mkdir -p "$BIN" "$APPD/scripts/lib" "$WORK/home" "$WORK/ws" "$WORK/ohstate"

# The frozen pass messages. A downstream reconciler matches these byte for
# byte, so they are written once here and compared with grep -Fx.
MSG_A_PASS='shellcheck present in the hermes-agent container'
MSG_B_PASS='deployed backup.sh excludes backups/ from capture'

# --- PATH stubs -------------------------------------------------------------
# One dispatcher, linked under every name doctor.sh probes. Each branch pins a
# fixed answer so an unrelated check cannot flip between runs. The docker branch
# is FIXTURE-DRIVEN: the scenarios differ only by the FIX_* variables passed in.
cat > "$BIN/stub" <<'STUB'
#!/usr/bin/env bash
trap '' PIPE
me="$(basename "$0")"
case "$me" in
  docker)
    [[ "${FIX_DOCKER_MODE:-ok}" == "error" ]] && exit 1
    for a in "$@"; do [[ "$a" == "info" ]] && exit 0; done
    for a in "$@"; do [[ "$a" == "network" ]] && exit 1; done
    tmpl=""; prev=""
    for a in "$@"; do [[ "$prev" == "-f" ]] && tmpl="$a"; prev="$a"; done
    last="${*: -1}"
    case "$*" in
      # Check A: the tool probe. FIX_SHELLCHECK=0 makes it report "not found".
      *"exec hermes-agent command -v shellcheck"*)
        [[ "${FIX_SHELLCHECK:-1}" == "1" ]] && { echo '/usr/bin/shellcheck'; exit 0; }
        exit 1 ;;
      *"top hermes-agent"*)  echo '7 hermes gateway run'; exit 0 ;;
      *"exec hermes-agent"*) exit 1 ;;
    esac
    if [[ "$*" == *"name=oh-agent-server"* ]]; then
      [[ -n "${FIX_SANDBOXES:-}" ]] || exit 0
      tr ' ' '\n' <<<"$FIX_SANDBOXES"
      exit 0
    fi
    case "$tmpl" in
      '{{.Id}}')
        [[ "$last" == "hybrid-ai-openhands" ]] || exit 1
        echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'
        exit 0 ;;
      '{{.Config.Image}}') echo 'docker.openhands.dev/openhands/agent-server:1.33.0-python'; exit 0 ;;
      *".Mounts"*)       echo 'false'; exit 0 ;;
      *".Config.User"*)  echo '10001'; exit 0 ;;
      *".State.Status"*) echo running; exit 0 ;;
      *".State.Health"*) echo none; exit 0 ;;
      *".State.Running"*) echo "${FIX_HERMES_RUNNING:-true}"; exit 0 ;;
      *"RestartCount"*)  echo 0; exit 0 ;;
      *"PortBindings"*)  printf '%s:3001 %s:3001 ' "$BRIDGE_IP" "$BRIDGE_IP"; exit 0 ;;
      *"println ."*)
        if [[ "$last" == "hybrid-ai-openhands" ]]; then
          printf '%s\n' \
            'SANDBOX_HOST_PORT=3001' \
            'SANDBOX_CONTAINER_URL_PATTERN=http://example.test:{port}' \
            'OH_PERMITTED_CORS_ORIGINS_0=http://localhost:3001'
        else
          printf '%s\n' \
            'OH_WEBHOOKS_0_BASE_URL=http://example.test:3001/' \
            'SANDBOX_HOST_PORT=3001'
        fi
        exit 0 ;;
    esac
    exit 1 ;;
  curl)
    url="${*: -1}"
    case "$url" in
      *"/api/v1/app-conversations/start-tasks/search"*)
        printf '%s\n' '{"items":[],"next_page_id":null}'; exit 0 ;;
      *":11434/api/tags") printf '%s' '{"models":[{"name":"llama3.2:3b"}]}'; exit 0 ;;
      *":3000/health") exit 0 ;;
      *":80/status/healthz") exit 0 ;;
      *":80/openwebui") printf '302'; exit 0 ;;
      *":80/health") printf '200'; exit 0 ;;
      *":80/hub") printf '200'; exit 0 ;;
      *":80/app/") printf '200'; exit 0 ;;
      *":3001/"*) exit 0 ;;
      *) exit 7 ;;
    esac ;;
  jq)
    prog=""
    for a in "$@"; do
      case "$a" in -*) continue ;; *) prog="$a"; break ;; esac
    done
    case "$prog" in
      *'has("items")'*|*'@tsv'*|*'next_page_id'*) exit 0 ;;
      *)
        if [[ -n "${REAL_JQ:-}" ]]; then exec "$REAL_JQ" "$@"; fi
        exit 0 ;;
    esac ;;
  getfacl) printf 'user:10001:rwx\ndefault:user:10001:rwx\n'; exit 0 ;;
  iptables) printf '%s\n' '-P INPUT ACCEPT' '-A DOCKER-USER -j RETURN'; exit 0 ;;
  df) printf 'Use%%\n 41%%\n' ;;
  findmnt) echo '/dev/nvme0n1p2' ;;
  nvme|lsblk|vcgencmd|getent) exit 1 ;;
  dmesg|ip) exit 0 ;;
  hostname) for a in "$@"; do [[ "$a" == "-I" ]] && { echo '[IP_ADDRESS] '; exit 0; }; done; echo host ;;
  uname) for a in "$@"; do [[ "$a" == "-m" ]] && { echo aarch64; exit 0; }; done; echo Linux ;;
  nproc) echo 4 ;;
  tailscale)
    for a in "$@"; do
      case "$a" in
        status) echo '{"BackendState":"Running","Peer":{"k":{"HostName":"runpod-worker","Online":true}}}'; exit 0 ;;
        ip) echo '[IP_ADDRESS]'; exit 0 ;;
      esac
    done
    exit 0 ;;
  systemctl|journalctl|sqlite3|rsync|restic|mountpoint|shellcheck) exit 1 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/stub"

for n in docker curl jq getfacl iptables df findmnt nvme lsblk dmesg vcgencmd \
         hostname getent uname nproc tailscale systemctl journalctl sqlite3 \
         rsync restic mountpoint ip shellcheck; do
  ln -sf "$BIN/stub" "$BIN/$n"
done

# --- scratch app ------------------------------------------------------------
cp "$REPO_ROOT/scripts/lib/hybrid-ai-env.sh" "$APPD/scripts/lib/"
cp "$DOCTOR" "$APPD/doctor.sh"
chmod +x "$APPD/doctor.sh"

# Baseline: the same doctor.sh with both NEW code blocks removed, so a message
# that still appeared would be coming from something other than these checks.
# Only the code is stripped; the explanatory comments are harmless because they
# contain none of the frozen messages.
awk '
  /^SHELLCHECK_PATH=/ { skipA=1 }
  skipA && /^fi$/      { skipA=0; next }
  skipA                { next }
  /^DEPLOYED_BACKUP_SH=/ { skipB=1 }
  skipB && /^unset DEPLOYED_BACKUP_SH$/ { skipB=0; next }
  skipB                { next }
  { print }
' "$APPD/doctor.sh" > "$APPD/doctor-base.sh"
chmod +x "$APPD/doctor-base.sh"

if ! grep -qF "$MSG_A_PASS" "$APPD/doctor.sh"; then
  fail "the doctor.sh under test has no shellcheck check (unpatched base)"
fi
if ! grep -qF "$MSG_B_PASS" "$APPD/doctor.sh"; then
  fail "the doctor.sh under test has no deployed-backup.sh check (unpatched base)"
fi
if grep -qF "$MSG_A_PASS" "$APPD/doctor-base.sh" || grep -qF "$MSG_B_PASS" "$APPD/doctor-base.sh"; then
  fail "could not build the baseline: a check body survived the strip"
fi

# A deployed backup.sh fixture with the entry, one without it, and one that
# mentions 'backups/' only inside a comment. Fixtures are tiny and secret-free.
mkdir -p "$APPD/backup"
cat > "$WORK/backup-with-entry.sh" <<'EOF'
#!/usr/bin/env bash
HERMES_EXCLUDES=(
  'tools/' 'logs/'
  # Backups are never captured into backups (self-recursion).
  'backups/'
  '*.db'
)
EOF
cat > "$WORK/backup-without-entry.sh" <<'EOF'
#!/usr/bin/env bash
HERMES_EXCLUDES=(
  'tools/' 'logs/'
  '*.db'
)
EOF
cat > "$WORK/backup-comment-only.sh" <<'EOF'
#!/usr/bin/env bash
# NOTE: 'backups/' must never be captured into a backup of itself.
HERMES_EXCLUDES=(
  'tools/' 'logs/'
  '*.db'
)
EOF

( cd "$WORK/ws" && git init -q && touch .keep ) >/dev/null 2>&1
chmod 700 "$WORK/ohstate"

# Minimal env so the Configuration checks pass rather than fail. Placeholders
# only; none is a real credential and none is printed.
cat > "$APPD/.env" <<EOF
WEBUI_SECRET_KEY=fixture
RUNPOD_API_KEY=fixture
RUNPOD_POD_ID=fixture
PEER_HOSTNAME=fixture
OPENROUTER_API_KEY=fixture
OPENHANDS_PORT=3001
OPENHANDS_WORKSPACE=$WORK/ws
OPENHANDS_SANDBOX_HOST=example.test
OPENHANDS_STATE_DIR=$WORK/ohstate
EOF
chmod 600 "$APPD/.env"

# run_doctor <tag> <doctor path> [env assignments...]
# Sets RC and OUT.
run_doctor() {
  local tag="$1" doc="$2"
  shift 2
  OUT="$WORK/out.$tag"
  (
    cd "$APPD" || exit 1
    env "$@" \
      PATH="$BIN:$PATH" HOME="$WORK/home" SHELL=/bin/bash \
      REAL_JQ="$REAL_JQ" BRIDGE_IP="$BRIDGE_IP" \
      HYBRID_AI_APP_DIR="$APPD" HYBRID_AI_ENV_FILE="$APPD/.env" \
      HYBRID_AI_DATA_DIR="$APPD" HYBRID_AI_LOG_DIR="$APPD" HYBRID_AI_WORK_DIR="$APPD" \
      HYBRID_AI_HERMES_DATA_DIR="$APPD/hermes_data" \
      timeout 120 bash "$doc" --no-cloud
  ) > "$OUT" 2>&1
  RC=$?
}

# count_line <outfile> <exact message>: how many pass/fail lines carry it.
# The pass/fail prefixes are stripped so the frozen message is compared alone.
count_line() {
  sed 's/^  [^ ]* //' "$1" | grep -Fxc -- "$2" || true
}

echo "== Running doctor.sh B87 tooling tests =="

run_doctor base "$APPD/doctor-base.sh" FIX_SHELLCHECK=1 FIX_HERMES_RUNNING=true
RC_BASE=$RC

# --- A pass -----------------------------------------------------------------
run_doctor a_pass "$APPD/doctor.sh" FIX_SHELLCHECK=1 FIX_HERMES_RUNNING=true
RC_A_PASS=$RC
if [[ "$(count_line "$OUT" "$MSG_A_PASS")" == "1" ]]; then
  pass "A pass: exactly one byte-exact pass line"
else
  fail "A pass: expected exactly one pass line, got $(count_line "$OUT" "$MSG_A_PASS")"
fi
if [[ "$(grep -c 'shellcheck presence in the hermes-agent container could not be checked' "$OUT")" == "0" ]] \
   && [[ "$(grep -c 'shellcheck is NOT present in the hermes-agent container' "$OUT")" == "0" ]]; then
  pass "A pass: no warn and no fail from this check"
else
  fail "A pass: this check also warned or failed"
fi
if [[ "$RC_A_PASS" == "$RC_BASE" ]]; then
  pass "A pass: exit code matches the check-free baseline (${RC_BASE})"
else
  fail "A pass: exit code ${RC_A_PASS} differs from the baseline (${RC_BASE})"
fi

# --- A warn: container absent / not running ---------------------------------
run_doctor a_absent "$APPD/doctor.sh" FIX_SHELLCHECK=0 FIX_HERMES_RUNNING=false
if [[ "$(grep -c 'shellcheck presence in the hermes-agent container could not be checked' "$OUT")" == "1" ]]; then
  pass "A warn: absent container produces exactly one warn"
else
  fail "A warn: expected exactly one warn for an absent container"
fi
if [[ "$(count_line "$OUT" "$MSG_A_PASS")" == "0" ]] \
   && [[ "$(grep -c 'shellcheck is NOT present in the hermes-agent container' "$OUT")" == "0" ]]; then
  pass "A warn: absent container produces no pass and no fail"
else
  fail "A warn: absent container still passed or failed"
fi

# --- A warn: docker itself is erroring --------------------------------------
run_doctor a_dockererr "$APPD/doctor.sh" FIX_DOCKER_MODE=error FIX_SHELLCHECK=0
if [[ "$(grep -c 'shellcheck presence in the hermes-agent container could not be checked' "$OUT")" == "1" ]] \
   && [[ "$(count_line "$OUT" "$MSG_A_PASS")" == "0" ]]; then
  pass "A warn: an erroring docker warns and does not pass"
else
  fail "A warn: an erroring docker did not warn cleanly"
fi

# --- A fail: container reachable, tool missing ------------------------------
run_doctor a_fail "$APPD/doctor.sh" FIX_SHELLCHECK=0 FIX_HERMES_RUNNING=true
RC_A_FAIL=$RC
if [[ "$(grep -c 'shellcheck is NOT present in the hermes-agent container' "$OUT")" == "1" ]]; then
  pass "A fail: missing shellcheck produces exactly one fail"
else
  fail "A fail: expected exactly one fail for a missing shellcheck"
fi
if [[ "$(count_line "$OUT" "$MSG_A_PASS")" == "0" ]]; then
  pass "A fail: missing shellcheck produces no pass line"
else
  fail "A fail: missing shellcheck still produced a pass line"
fi
if [[ "$RC_A_FAIL" == "2" ]]; then
  pass "A fail: doctor.sh exits 2"
else
  fail "A fail: doctor.sh exited ${RC_A_FAIL}, expected 2"
fi
if grep -q 'rebuild and recreate it' "$OUT"; then
  pass "A fail: the remedy names an image rebuild"
else
  fail "A fail: the remedy does not name an image rebuild"
fi

# --- B pass -----------------------------------------------------------------
cp "$WORK/backup-with-entry.sh" "$APPD/backup/backup.sh"
run_doctor b_pass "$APPD/doctor.sh" FIX_SHELLCHECK=1 FIX_HERMES_RUNNING=true
RC_B_PASS=$RC
if [[ "$(count_line "$OUT" "$MSG_B_PASS")" == "1" ]]; then
  pass "B pass: exactly one byte-exact pass line"
else
  fail "B pass: expected exactly one pass line, got $(count_line "$OUT" "$MSG_B_PASS")"
fi
if [[ "$RC_B_PASS" == "$RC_BASE" ]]; then
  pass "B pass: exit code matches the check-free baseline (${RC_BASE})"
else
  fail "B pass: exit code ${RC_B_PASS} differs from the baseline (${RC_BASE})"
fi

# --- B warn: deployed file missing ------------------------------------------
rm -f "$APPD/backup/backup.sh"
run_doctor b_missing "$APPD/doctor.sh" FIX_SHELLCHECK=1 FIX_HERMES_RUNNING=true
if [[ "$(grep -c 'deployed backup.sh could not be read at' "$OUT")" == "1" ]]; then
  pass "B warn: a missing file produces exactly one warn"
else
  fail "B warn: expected exactly one warn for a missing file"
fi
if [[ "$(count_line "$OUT" "$MSG_B_PASS")" == "0" ]] \
   && [[ "$(grep -c 'deployed backup.sh does NOT exclude' "$OUT")" == "0" ]]; then
  pass "B warn: a missing file produces no pass and no fail"
else
  fail "B warn: a missing file still passed or failed"
fi

# --- B fail: readable, entry absent -----------------------------------------
cp "$WORK/backup-without-entry.sh" "$APPD/backup/backup.sh"
run_doctor b_fail "$APPD/doctor.sh" FIX_SHELLCHECK=1 FIX_HERMES_RUNNING=true
RC_B_FAIL=$RC
if [[ "$(grep -c 'deployed backup.sh does NOT exclude backups/ from capture' "$OUT")" == "1" ]]; then
  pass "B fail: a missing entry produces exactly one fail"
else
  fail "B fail: expected exactly one fail for a missing entry"
fi
if [[ "$RC_B_FAIL" == "2" ]]; then
  pass "B fail: doctor.sh exits 2"
else
  fail "B fail: doctor.sh exited ${RC_B_FAIL}, expected 2"
fi

# --- B: the entry must be an array element, not a comment -------------------
cp "$WORK/backup-comment-only.sh" "$APPD/backup/backup.sh"
run_doctor b_comment "$APPD/doctor.sh" FIX_SHELLCHECK=1 FIX_HERMES_RUNNING=true
if [[ "$(count_line "$OUT" "$MSG_B_PASS")" == "0" ]] \
   && [[ "$(grep -c 'deployed backup.sh does NOT exclude' "$OUT")" == "1" ]]; then
  pass "B comment-only: a mention inside a comment does not count as the entry"
else
  fail "B comment-only: a comment mention was accepted as the entry"
fi

# --- proof that the harness rejects a doctor.sh without the checks ----------
# The baseline above is exactly that doctor.sh. A harness that passes against
# it would prove nothing, so re-run the message assertions against it.
run_doctor base_assert "$APPD/doctor-base.sh" FIX_SHELLCHECK=1 FIX_HERMES_RUNNING=true
if [[ "$(count_line "$OUT" "$MSG_A_PASS")" == "0" ]] \
   && [[ "$(count_line "$OUT" "$MSG_B_PASS")" == "0" ]]; then
  pass "unpatched doctor.sh: neither check produces a message, so the assertions bite"
else
  fail "unpatched doctor.sh: a check message appeared without the check code"
fi

if [[ -z "${B87_HARNESS_NESTED:-}" ]]; then
  B87_HARNESS_NESTED=1 bash "$0" "$APPD/doctor-base.sh" > "$WORK/nested.log" 2>&1
  NESTED_RC=$?
  if [[ "$NESTED_RC" != "0" ]]; then
    pass "unpatched doctor.sh: this harness fails against a copy without the checks"
  else
    fail "unpatched doctor.sh: the harness passed, so its assertions prove nothing"
  fi
fi

echo "---"
if (( FAILURES != 0 )); then
  echo "FAILURES: ${FAILURES}" >&2
  exit 1
fi
echo "All B87 tooling assertions passed (${PASS})."
exit 0
