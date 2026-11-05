#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-install-auth-env-leak.sh
# PURPOSE (plain English):
#   Offline tests for the login-gate leak in install.sh's compose phase. They
#   need NO root, NO Docker and NO network: every host command install.sh probes
#   is stubbed on PATH, `docker` included, and the whole run is pointed at a
#   scratch app/data tree.
#
#   The bug this covers (B90, seen live 2026-11-04): install.sh STEP 2 loads the
#   stack env file line by line and EXPORTS every key, so the Compose-escaped
#   form of the login-gate pair (63 bytes for a 60-byte bcrypt hash: every `$`
#   doubled) lives in the installer's own shell at deploy time. STEP 8 re-escapes
#   idempotently, so the file stays correct, but `docker compose up` prefers the
#   process environment over --env-file. The container therefore received the
#   63-byte escaped hash, bcrypt.checkpw raised ValueError, the gate read that as
#   a wrong password, and every login answered 401. The fix unsets the pair in
#   the installer's shell immediately before the compose up invocation.
#
# CASES:
#   (a) fail-before: with the unset line removed from install.sh (the base
#       code path), the environment at the stubbed compose up carries
#       HYBRID_AI_AUTH_HASH (63 bytes, the escaped 60-byte fixture) and
#       HYBRID_AI_AUTH_USER
#   (b) pass-after: with the fix, neither variable is present in that
#       environment, the compose argv still passes --env-file, and the env file
#       still holds the escaped pair intact (63 bytes, un-escapes to the 60-byte
#       fixture) so the container gets the operator's bytes
#   (c) the fail-closed refusal for an empty login-gate value still fires
#       (AUTH_ENABLED=on with TLS on and no hash)
#
#   Length and digest assertions only. The fixture hash is synthetic and never
#   printed.
#
# USAGE:
#   bash scripts/test-install-auth-env-leak.sh
#
# EXIT CODES:
#   0  every case passed
#   1  one or more cases failed
#   2  a required tool is missing
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
[[ -f "${REPO}/install.sh" ]] || { echo "FATAL: cannot find install.sh" >&2; exit 2; }
for t in mktemp stat grep cmp sed; do
  command -v "$t" >/dev/null 2>&1 || { echo "error: $t is required" >&2; exit 2; }
done

PASS=0
FAIL=0
ok()   { PASS=$(( PASS + 1 )); printf 'ok   %s\n' "$*"; }
bad()  { FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n' "$*" >&2; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }

WORK="$(mktemp -d)"
if [[ "${KEEP:-0}" == "1" ]]; then
  printf 'keeping %s\n' "$WORK"
else
  trap 'rm -rf -- "$WORK"' EXIT
fi

# --- synthetic fixture -------------------------------------------------------
# A bcrypt-shaped string of exactly 60 bytes. Its three `$` separators make the
# Compose-escaped form 63 bytes, which is the whole point of the case.
RAW_HASH="\$2a\$14\$DUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDDD"
ESCAPED_HASH="${RAW_HASH//\$/&&}"
check "(fixture) the synthetic hash is 60 bytes" "60" "${#RAW_HASH}"
check "(fixture) its escaped form is 63 bytes" "63" "${#ESCAPED_HASH}"

# --- scratch app + layout ----------------------------------------------------
APP="$WORK/app"
BIN="$WORK/bin"
SYSD="$WORK/systemd"
mkdir -p "$APP/scripts/lib" "$APP/deploy" "$APP/status" "$BIN" "$SYSD" \
         "$WORK/data" "$WORK/log" "$WORK/work" "$WORK/ws" "$WORK/repos" \
         "$WORK/ohstate" "$WORK/conf" "$WORK/restic" "$WORK/etc/hybrid-ai" \
         "$WORK/sysstate"
cp "$REPO/install.sh" "$APP/install.sh"
cp "$REPO/scripts/lib/hybrid-ai-env.sh" "$APP/scripts/lib/"
[ -f "$REPO/scripts/lib/build-gate.sh" ] || { echo "FATAL: scripts/lib/build-gate.sh is missing" >&2; exit 2; }
cp "$REPO/scripts/lib/build-gate.sh" "$APP/scripts/lib/"
cp "$REPO/scripts/lib/tls.sh" "$APP/scripts/lib/"
cp "$REPO/status/Caddyfile.tmpl" "$APP/status/Caddyfile.tmpl"
cp "$REPO/docker-compose.yml.tmpl" "$APP/docker-compose.yml.tmpl"
cp "$REPO/deploy/hybrid-ai-firewall.service" "$APP/deploy/" 2>/dev/null || true
mkdir -p "$APP/openhands" "$WORK/ws/.git/info"
cp "$REPO/openhands/sandbox-gitconfig" "$APP/openhands/sandbox-gitconfig" 2>/dev/null || true
: > "$WORK/ws/.git/info/exclude"
printf '#!/usr/bin/env bash\nexit 0\n' > "$APP/scripts/setup-agent-workspace.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$APP/scripts/sync-agent-repos.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$APP/scripts/check-hermes-nonroot.sh"
chmod +x "$APP/scripts/"*.sh

LAYOUT="$WORK/etc/hybrid-ai/hybrid-ai.env"
STACK="$WORK/etc/hybrid-ai/stack.env"
{
  printf 'HYBRID_AI_APP_DIR=%s\n' "$APP"
  printf 'HYBRID_AI_ENV_FILE=%s\n' "$LAYOUT"
  printf 'HYBRID_AI_STACK_ENV_FILE=%s\n' "$STACK"
  printf 'HYBRID_AI_DATA_DIR=%s\n' "$WORK/data"
  printf 'HYBRID_AI_LOG_DIR=%s\n' "$WORK/log"
  printf 'HYBRID_AI_WORK_DIR=%s\n' "$WORK/work"
  printf 'OPENHANDS_WORKSPACE=%s\n' "$WORK/ws"
  printf 'AGENT_REPOS_DIR=%s\n' "$WORK/repos"
  printf 'OPENHANDS_STATE_DIR=%s\n' "$WORK/ohstate"
  printf 'BACKUP_CONF_DIR=%s\n' "$WORK/conf"
  printf 'RESTIC_CACHE_DIR=%s\n' "$WORK/restic"
  printf 'HYBRID_AI_HERMES_HOME_DIR=%s\n' "$WORK/hermes"
  printf 'HYBRID_AI_BACKUP_MODE=system\n'
  printf 'BACKUP_CONTAINER_CONTROL=external\n'
  printf 'HYBRID_AI_UID=1000\n'
  printf 'HYBRID_AI_GID=1000\n'
} > "$LAYOUT"
chmod 644 "$LAYOUT"

# The deployed-host shape: an existing stack env file that already carries the
# escaped login-gate pair. STEP 2 exports it; that export is the bug.
seed_stack() {
  {
    printf 'ENV_VERSION=2\n'
    printf 'AUTH_ENABLED=on\n'
    printf 'HYBRID_AI_AUTH_USER=operator\n'
    printf 'HYBRID_AI_AUTH_HASH=%s\n' "$ESCAPED_HASH"
  } > "$STACK"
  chmod 600 "$STACK"
}
seed_stack

# --- stubs -------------------------------------------------------------------
for d in git jq openssl sqlite3 rsync tailscale hostname \
         loginctl setfacl apt-get restic; do
  # shellcheck disable=SC2016  # $0 must expand inside the generated stub
  printf '#!/usr/bin/env bash\nprintf "%%s stub\\n" "$0"\nexit 0\n' > "$BIN/$d"
done
# nproc must answer with a number: install.sh uses it in arithmetic.
printf '#!/usr/bin/env bash\nprintf "4\\n"\n' > "$BIN/nproc"
cat > "$BIN/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SUDO_ARGV_LOG:-/dev/null}"
exit 0
EOF
# shellcheck disable=SC2016  # $@ must expand inside the generated stub
printf '#!/usr/bin/env bash\nif [[ "${1:-}" == "-u" ]]; then printf "1000\\n"; exit 0; fi\nif [[ "${1:-}" == "-g" ]]; then printf "1000\\n"; exit 0; fi\nexec /usr/bin/id "$@"\n' > "$BIN/id"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/chown"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/sleep"
cat > "$BIN/getent" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  group) printf 'docker:x:999:\n' ;;
  hosts) printf '[IP_ADDRESS] %s\n' "${2:-}" ;;
  passwd) printf 'hybrid-ai-backup:x:999:999::/var/lib/hybrid-ai-backup:/usr/sbin/nologin\n'; exit 0 ;;
esac
exit 0
EOF
# curl answers healthy for every probe, so the run reaches the compose phase and
# then runs to completion.
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/curl"
cat > "$BIN/install" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${INSTALL_ARGV_LOG:-/dev/null}"
case " $* " in
  *" -o hybrid-ai-backup "*)
    for a in "$@"; do last="$a"; done
    mkdir -p "$last"
    exit 0 ;;
esac
exec /usr/bin/install "$@"
EOF
cat > "$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG:-/dev/null}"
[[ "${1:-}" == "--user" ]] && shift
cmd="${1:-}"; unit="${2:-}"
state="${SYSTEMCTL_STATE:-/nonexistent}"
case "$cmd" in
  daemon-reload|reload|start|restart|stop|disable) exit 0 ;;
  cat)
    [[ -f "${SYSTEMCTL_UNIT_DIR:-/nonexistent}/${unit}" ]] && exit 0
    case "$unit" in hybrid-ai-backup*|hybrid-ai-check*) exit 0 ;; esac
    exit 1 ;;
  enable)
    [[ "$unit" == "--now" ]] && unit="${3:-}"
    [[ -n "$unit" ]] && : > "${state}/${unit}.enabled"
    exit 0 ;;
  is-enabled)
    if [[ -e "${state}/${unit}.enabled" ]]; then printf 'enabled\n'; exit 0; fi
    printf 'disabled\n'; exit 1 ;;
  is-active) printf 'active\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
# docker: records every argv, and at the `compose ... up` call dumps the
# login-gate pair AS SEEN IN THE PROCESS ENVIRONMENT -- presence and byte length
# only, never a value. Compose reads that environment ahead of --env-file, so
# this dump is exactly what the auth container would be started with.
cat > "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_ARGV_LOG:-/dev/null}"
if [[ "${1:-}" == "compose" ]]; then
  for a in "$@"; do
    if [[ "$a" == "up" ]]; then
      cap="${COMPOSE_ENV_CAPTURE:-/dev/null}"
      for v in HYBRID_AI_AUTH_HASH HYBRID_AI_AUTH_USER; do
        if [[ -n "${!v+x}" ]]; then
          len="$(printf '%s' "${!v}" | wc -c | tr -d ' ')"
          printf '%s set %s\n' "$v" "$len" >> "$cap"
        else
          printf '%s unset\n' "$v" >> "$cap"
        fi
      done
      break
    fi
  done
fi
exit 0
EOF
chmod +x "$BIN"/*

DOCKER_ARGV="$WORK/docker-argv.log"
CAPTURE="$WORK/compose-env.log"
SUDO_ARGV="$WORK/sudo-argv.log"
SYSTEMCTL_ARGV="$WORK/systemctl-argv.log"
INSTALL_ARGV="$WORK/install-argv.log"
INSTALL_LOG="$WORK/log/install.log"

# run_install log [extra args...]
run_install() {
  local log="$1" rc=0
  shift
  : > "$CAPTURE"; : > "$DOCKER_ARGV"
  env -u HYBRID_AI_APP_DIR -u HYBRID_AI_DATA_DIR -u HYBRID_AI_LOG_DIR \
      -u HYBRID_AI_WORK_DIR -u HYBRID_AI_STACK_ENV_FILE \
      -u OPENHANDS_WORKSPACE -u AGENT_REPOS_DIR -u OPENHANDS_STATE_DIR \
      -u BACKUP_CONF_DIR -u RESTIC_CACHE_DIR -u HYBRID_AI_HERMES_HOME_DIR \
      -u HYBRID_AI_BACKUP_MODE -u BACKUP_CONTAINER_CONTROL \
      -u HYBRID_AI_UID -u HYBRID_AI_GID \
      -u HYBRID_AI_AUTH_HASH -u HYBRID_AI_AUTH_USER -u HYBRID_AI_AUTH_COOKIE_SECRET \
      -u AUTH_ENABLED -u TLS_ENABLED -u ENV_VERSION \
      PATH="$BIN:$PATH" \
      HYBRID_AI_ENV_FILE="$LAYOUT" \
      HYBRID_AI_SYSTEMD_UNIT_DIR="$SYSD" \
      INSTALL_ARGV_LOG="$INSTALL_ARGV" \
      SUDO_ARGV_LOG="$SUDO_ARGV" \
      SYSTEMCTL_LOG="$SYSTEMCTL_ARGV" \
      SYSTEMCTL_STATE="$WORK/sysstate" \
      SYSTEMCTL_UNIT_DIR="$SYSD" \
      DOCKER_ARGV_LOG="$DOCKER_ARGV" \
      COMPOSE_ENV_CAPTURE="$CAPTURE" \
      LOCAL_DOMAIN=example.test OPENROUTER_API_KEY=stub RUNPOD_API_KEY=stub \
      RUNPOD_POD_ID=stub RUNPOD_HOST=stub PI_HOST=stub \
      OPENHANDS_SANDBOX_HOST=example.test PEER_HOSTNAMES="none" \
      USER=fixture \
      bash "$APP/install.sh" --non-interactive "$@" >> "$log" 2>&1 || rc=$?
  return "$rc"
}

# The fix under test: this exact line, immediately before the compose up.
UNSET_LINE='unset HYBRID_AI_AUTH_HASH HYBRID_AI_AUTH_USER'
FIXED_SH="$REPO/install.sh"

# ---------------------------------------------------------------------------
echo
echo "== (a) fail-before: the unfixed code path leaks the escaped pair =="
if grep -qxF "$UNSET_LINE" "$FIXED_SH"; then
  ok "(a) install.sh carries the unset line"
else
  bad "(a) install.sh does not unset the login-gate pair before compose up"
fi
grep -vxF "$UNSET_LINE" "$FIXED_SH" > "$WORK/install-unfixed.sh"
if cmp -s "$FIXED_SH" "$WORK/install-unfixed.sh"; then
  bad "(a) could not build the unfixed copy (nothing was removed)"
else
  ok "(a) the unfixed copy differs by exactly the unset line"
fi
check "(a) the unfixed copy is one line shorter" \
  "$(( $(wc -l < "$FIXED_SH") - 1 ))" "$(wc -l < "$WORK/install-unfixed.sh")"

cp "$WORK/install-unfixed.sh" "$APP/install.sh"
: > "$INSTALL_LOG"
rc=0
run_install "$WORK/a.log" || rc=$?
check "(a) the unfixed run exits 0" "0" "$rc"
if grep -qxF 'HYBRID_AI_AUTH_HASH set 63' "$CAPTURE"; then
  ok "(a) the escaped hash (63 bytes) was visible to compose up"
else
  bad "(a) the escaped hash was NOT visible to compose up"
  sed 's/^/      /' "$CAPTURE" >&2
fi
if grep -qxF 'HYBRID_AI_AUTH_USER set 8' "$CAPTURE"; then
  ok "(a) the auth user was visible to compose up"
else
  bad "(a) the auth user was NOT visible to compose up"
fi

# ---------------------------------------------------------------------------
echo
echo "== (b) pass-after: the fix keeps the pair out of the compose environment =="
cp "$FIXED_SH" "$APP/install.sh"
seed_stack
: > "$INSTALL_LOG"
rc=0
run_install "$WORK/b.log" || rc=$?
check "(b) the fixed run exits 0" "0" "$rc"
if grep -qxF 'HYBRID_AI_AUTH_HASH unset' "$CAPTURE"; then
  ok "(b) HYBRID_AI_AUTH_HASH is absent from the compose environment"
else
  bad "(b) HYBRID_AI_AUTH_HASH is still present at compose up"
  sed 's/^/      /' "$CAPTURE" >&2
fi
if grep -qxF 'HYBRID_AI_AUTH_USER unset' "$CAPTURE"; then
  ok "(b) HYBRID_AI_AUTH_USER is absent from the compose environment"
else
  bad "(b) HYBRID_AI_AUTH_USER is still present at compose up"
fi
if grep -q -- '--env-file' "$DOCKER_ARGV" && grep -qF -- "--env-file $STACK" "$DOCKER_ARGV"; then
  ok "(b) compose up still receives --env-file <stack env>"
else
  bad "(b) compose up does not pass --env-file <stack env>"
fi

# The env file is what the container is told to use, so it must still carry the
# escaped form byte-for-byte: Compose un-escapes it back to the 60-byte hash.
file_hash="$(sed -n 's/^HYBRID_AI_AUTH_HASH=//p' "$STACK")"
file_user="$(sed -n 's/^HYBRID_AI_AUTH_USER=//p' "$STACK")"
check "(b) the env file still holds the 63-byte escaped hash" "63" "${#file_hash}"
if [[ "$file_hash" == "$ESCAPED_HASH" ]]; then
  ok "(b) the env file hash is byte-identical to the escaped fixture"
else
  bad "(b) the env file hash changed"
fi
unescaped="${file_hash//\$\$/\$}"
check "(b) the env file un-escapes to the 60-byte hash" "60" "${#unescaped}"
if [[ "$unescaped" == "$RAW_HASH" ]]; then
  ok "(b) the env file delivers the operator's bytes intact"
else
  bad "(b) the env file does not deliver the operator's bytes"
fi
if [[ "$file_user" == "operator" ]]; then
  ok "(b) the env file still holds the auth user"
else
  bad "(b) the env file lost the auth user"
fi
check "(b) the env file is still 0600" "600" "$(stat -c '%a' "$STACK" 2>/dev/null)"

# ---------------------------------------------------------------------------
echo
AT='@'
echo "== (c) the fail-closed refusal for an empty login-gate value still fires =="
# TLS on, AUTH_ENABLED=on and an EMPTY hash: the refusal must fire before any
# start. The address is built from fragments so the source holds no literal.
{
  printf 'ENV_VERSION=2\n'
  printf 'TLS_ENABLED=yes\n'
  printf 'TLS_DOMAIN=auth-leak.example.test\n'
  printf 'ACME_EMAIL=operator%sauth-leak.example.test\n' "$AT"
  printf 'TLS_VALIDATION=http\n'
  printf 'AUTH_ENABLED=on\n'
  printf 'HYBRID_AI_AUTH_USER=operator\n'
  printf 'HYBRID_AI_AUTH_HASH=\n'
} > "$STACK"
chmod 600 "$STACK"
if grep -qx 'AUTH_ENABLED=on' "$STACK" && grep -qx 'TLS_ENABLED=yes' "$STACK"; then
  ok "(c) fixture: the stack env file asks for TLS and the gate"
else
  bad "(c) fixture: the stack env file does not ask for TLS and the gate"
fi
: > "$CAPTURE"
rc=0
run_install "$WORK/c.log" || rc=$?
if (( rc != 0 )); then
  ok "(c) the empty hash is refused (exit $rc)"
else
  bad "(c) the empty hash was accepted"
fi
if grep -q 'HYBRID_AI_AUTH_HASH' "$WORK/c.log"; then
  ok "(c) the refusal names the missing key"
else
  bad "(c) the refusal does not name the missing key"
  sed 's/^/      /' "$WORK/c.log" >&2
fi
if grep -qxF 'HYBRID_AI_AUTH_HASH set 63' "$CAPTURE"; then
  bad "(c) a compose up ran with the escaped hash"
else
  ok "(c) no compose up ran with the escaped pair"
fi

# ---------------------------------------------------------------------------
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
