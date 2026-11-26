#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-haven-env.sh
# PURPOSE (plain English):
#   Checks the ONE shared path helper, scripts/lib/haven-env.sh, and the
#   isolation guards the scripts build on it. Fully OFFLINE: it needs no Docker,
#   no sqlite3, no rsync and no restic. It runs on any host with bash.
#
#   It proves four things:
#     1. With no settings, every resolved path equals today's default.
#     2. A value in the env file is treated as DATA and never executed.
#     3. Every value the helper must refuse is refused (non-zero exit).
#     4. The isolation guards refuse every forbidden target.
#   It also greps the tracked scripts to prove no path bypasses the helper.
# ---------------------------------------------------------------------------
set -uo pipefail

# Ambient settings must never leak into the "defaults" assertions. Clear every
# setting the helper resolves so the test is deterministic on any host (a CI
# runner, a developer shell with OPENHANDS_WORKSPACE exported, and so on).
unset HAVEN_APP_DIR HAVEN_ENV_FILE HAVEN_ENV_FILE_FALLBACK \
      HAVEN_DATA_DIR HAVEN_LOG_DIR \
      HAVEN_WORK_DIR HAVEN_UID HAVEN_GID OPENHANDS_WORKSPACE \
      AGENT_REPOS_DIR OPENHANDS_STATE_DIR BACKUP_CONF_DIR RESTIC_CACHE_DIR \
      BACKUP_LOG HAVEN_HERMES_HOME_DIR HAVEN_BACKUP_MODE \
      HAVEN_POST_DEPLOY_VERIFY_CMD HAVEN_POST_DEPLOY_VERIFY_LOG \
      BACKUP_CONTAINER_CONTROL 2>/dev/null || true

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "${HERE}/.." && pwd)"
HELPER="${REPO}/scripts/lib/haven-env.sh"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$(( PASS + 1 )); printf 'ok   %s\n' "$*"; }
bad()  { FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n' "$*" >&2; }
check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}
assert() { # desc command...
  local d="$1"; shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}

# Run the helper in a fresh shell with a given env file and extra env, and
# print the value of one resolved variable on stdout. Non-zero exit on refusal.
resolve() { # envfile var [extra K=V ...]
  local envfile="$1" var="$2"; shift 2
  env "$@" HAVEN_ENV_FILE="$envfile" bash -c "source '$HELPER' >/dev/null 2>&1; printf '%s' \"\$$var\""
}

# Run the helper and return its exit code only.
resolve_rc() { # envfile [extra K=V ...]
  local envfile="$1"; shift
  env "$@" HAVEN_ENV_FILE="$envfile" bash -c "source '$HELPER'" >/dev/null 2>&1
  return $?
}

# ---------------------------------------------------------------------------
# 1. Defaults equal today's paths
# ---------------------------------------------------------------------------
echo "== defaults =="
EMPTY="${TMPROOT}/empty.env"
: > "$EMPTY"

check "APP_DIR default is the repo dir" "$REPO" "$(resolve "$EMPTY" HAVEN_APP_DIR)"
# ENV_FILE default depends on APP_DIR, so resolve it with a fresh APP_DIR and NO
# explicit HAVEN_ENV_FILE.
DEFAULT_APPD="${TMPROOT}/default-app"
mkdir -p "$DEFAULT_APPD"
check "ENV_FILE default is APP_DIR/.env" "${DEFAULT_APPD}/.env" \
  "$(env HAVEN_APP_DIR="$DEFAULT_APPD" bash -c "source '$HELPER' >/dev/null 2>&1; printf '%s' \"\$HAVEN_ENV_FILE\"")"
check "DATA_DIR default is the repo dir" "$REPO" "$(resolve "$EMPTY" HAVEN_DATA_DIR)"
check "LOG_DIR default is the repo dir" "$REPO" "$(resolve "$EMPTY" HAVEN_LOG_DIR)"
check "WORK_DIR default is the repo dir" "$REPO" "$(resolve "$EMPTY" HAVEN_WORK_DIR)"
check "hermes_data keeps its name" "${REPO}/hermes_data" "$(resolve "$EMPTY" HAVEN_HERMES_DATA_DIR)"
check "webui_data keeps its name" "${REPO}/webui_data" "$(resolve "$EMPTY" HAVEN_WEBUI_DATA_DIR)"
check "ollama_data keeps its name" "${REPO}/ollama_data" "$(resolve "$EMPTY" HAVEN_OLLAMA_DATA_DIR)"
check "caddy data dir is a sibling of webui_data" "${REPO}/caddy" "$(resolve "$EMPTY" HAVEN_CADDY_DATA_DIR)"
check "install.log default" "${REPO}/install.log" "$(resolve "$EMPTY" HAVEN_INSTALL_LOG)"
check "backup.log default" "${REPO}/backup.log" "$(resolve "$EMPTY" BACKUP_LOG)"
check "staging default" "${REPO}/.backup-staging" "$(resolve "$EMPTY" HAVEN_BACKUP_STAGING_DIR)"
check "restore work default" "${REPO}/.restore-work" "$(resolve "$EMPTY" HAVEN_RESTORE_WORK_DIR)"
check "OPENHANDS_WORKSPACE default" "$HOME/haven-agent" "$(resolve "$EMPTY" OPENHANDS_WORKSPACE)"
check "AGENT_REPOS_DIR default" "$HOME/haven-repos" "$(resolve "$EMPTY" AGENT_REPOS_DIR)"
check "OPENHANDS_STATE_DIR default" "$HOME/.openhands" "$(resolve "$EMPTY" OPENHANDS_STATE_DIR)"
check "BACKUP_CONF_DIR default" "$HOME/.config/haven-backup" "$(resolve "$EMPTY" BACKUP_CONF_DIR)"
check "RESTIC_CACHE_DIR default" "$HOME/.cache/restic" "$(resolve "$EMPTY" RESTIC_CACHE_DIR)"
check "HAVEN_HERMES_HOME_DIR default" "$HOME/.hermes" "$(resolve "$EMPTY" HAVEN_HERMES_HOME_DIR)"
# The post-deploy verifier command and log. INTERNAL test seams, but their
# defaults are exactly the paths the deploy hook used to hardcode.
check "HAVEN_POST_DEPLOY_VERIFY_CMD default" \
  "/usr/local/sbin/run-post-deploy-verify.sh" "$(resolve "$EMPTY" HAVEN_POST_DEPLOY_VERIFY_CMD)"
check "HAVEN_POST_DEPLOY_VERIFY_LOG default" \
  "/var/log/haven-post-deploy-verify.log" "$(resolve "$EMPTY" HAVEN_POST_DEPLOY_VERIFY_LOG)"
# An exported value wins for both, which is how the harnesses relocate them.
check "an exported POST_DEPLOY_VERIFY_CMD wins" "${TMPROOT}/sbin/run-post-deploy-verify.sh" \
  "$(resolve "$EMPTY" HAVEN_POST_DEPLOY_VERIFY_CMD \
      HAVEN_POST_DEPLOY_VERIFY_CMD="${TMPROOT}/sbin/run-post-deploy-verify.sh")"
check "an exported POST_DEPLOY_VERIFY_LOG wins" "${TMPROOT}/logs/verify.log" \
  "$(resolve "$EMPTY" HAVEN_POST_DEPLOY_VERIFY_LOG \
      HAVEN_POST_DEPLOY_VERIFY_LOG="${TMPROOT}/logs/verify.log")"
check "HAVEN_BACKUP_MODE default is user" "user" "$(resolve "$EMPTY" HAVEN_BACKUP_MODE)"
check "BACKUP_CONTAINER_CONTROL default is self" "self" "$(resolve "$EMPTY" BACKUP_CONTAINER_CONTROL)"
check "UID default is empty" "" "$(resolve "$EMPTY" HAVEN_UID)"
check "GID default is empty" "" "$(resolve "$EMPTY" HAVEN_GID)"

# A handoff may normalize duplicate layout keys; the documented last-wins
# rule must select one path, never concatenate two roots.
printf 'HAVEN_APP_DIR=/opt/hybrid-ai\nHAVEN_APP_DIR=/opt/haven\n' > "$TMPROOT/duplicate-layout"
check "duplicate app roots resolve to the last layout value" "/opt/haven" \
  "$(resolve "$TMPROOT/duplicate-layout" HAVEN_APP_DIR)"

# --- STACK_ENV_FILE defaults to the resolved LAYOUT file --------------------
# With the setting unset the stack file and the layout file are the SAME path,
# so every `--env-file` command line stays byte-identical to today's.
check "STACK_ENV_FILE defaults to the resolved ENV_FILE" "$(resolve "$EMPTY" HAVEN_ENV_FILE)" \
  "$(resolve "$EMPTY" HAVEN_STACK_ENV_FILE)"
STACKD="${TMPROOT}/stack-default"
mkdir -p "$STACKD"
# The bootstrap layout: the LAYOUT file names itself and the stack file.
cat > "$STACKD/.env" <<STACKEOF
HAVEN_ENV_FILE=${STACKD}/.env
HAVEN_STACK_ENV_FILE=${STACKD}/stack.env
STACKEOF
: > "${STACKD}/stack.env"
check "STACK_ENV_FILE resolves the layout file's own value" "${STACKD}/stack.env" \
  "$(env HAVEN_ENV_FILE="${STACKD}/.env" bash -c "source '$HELPER' >/dev/null 2>&1; printf '%s' \"\$HAVEN_STACK_ENV_FILE\"")"
# An explicit environment value wins over the layout file.
check "an exported STACK_ENV_FILE wins" "${TMPROOT}/exported-stack.env" \
  "$(env HAVEN_ENV_FILE="${STACKD}/.env" HAVEN_STACK_ENV_FILE="${TMPROOT}/exported-stack.env" \
      bash -c "source '$HELPER' >/dev/null 2>&1; printf '%s' \"\$HAVEN_STACK_ENV_FILE\"")"

# The whole resolved set, byte for byte, with nothing set. This is the strongest
# form of "with no settings, every path is identical to today": the complete
# sorted KEY=VALUE dump of the new helper must equal the expected dump.
CLONE="${TMPROOT}/clone-app"
mkdir -p "${CLONE}/scripts/lib" "${CLONE}/backup" "${CLONE}/openhands" "${CLONE}/hermes"
: > "${CLONE}/docker-compose.yml"
cp "$HELPER" "${CLONE}/scripts/lib/"
CH="${TMPROOT}/clonehome"
mkdir -p "$CH"
DUMP_SCRIPT="${TMPROOT}/dump.sh"
cat > "$DUMP_SCRIPT" <<'DUMPEOF'
# shellcheck source=/dev/null
source "$HAVEN_LIB" >/dev/null 2>&1
for v in HAVEN_APP_DIR HAVEN_ENV_FILE HAVEN_STACK_ENV_FILE \
         HAVEN_DATA_DIR \
         HAVEN_LOG_DIR HAVEN_WORK_DIR \
         HAVEN_HERMES_DATA_DIR HAVEN_WEBUI_DATA_DIR \
         HAVEN_OLLAMA_DATA_DIR HAVEN_CADDY_DATA_DIR HAVEN_INSTALL_LOG \
         HAVEN_BACKUP_STAGING_DIR HAVEN_RESTORE_WORK_DIR \
         HAVEN_HERMES_HOME_DIR HAVEN_BACKUP_MODE \
         HAVEN_POST_DEPLOY_VERIFY_CMD HAVEN_POST_DEPLOY_VERIFY_LOG \
         BACKUP_CONTAINER_CONTROL BACKUP_LOG BACKUP_CONF_DIR \
         RESTIC_CACHE_DIR OPENHANDS_WORKSPACE AGENT_REPOS_DIR \
         OPENHANDS_STATE_DIR; do
  printf '%s=%s\n' "$v" "${!v}"
done
DUMPEOF
DUMP="$(env -i HOME="$CH" PATH="$PATH" HAVEN_LIB="${CLONE}/scripts/lib/haven-env.sh" \
        HAVEN_APP_DIR="$CLONE" bash "$DUMP_SCRIPT" | sort)"
EXPECT="$(sort <<EOF
HAVEN_APP_DIR=${CLONE}
HAVEN_ENV_FILE=${CLONE}/.env
HAVEN_STACK_ENV_FILE=${CLONE}/.env
HAVEN_DATA_DIR=${CLONE}
HAVEN_LOG_DIR=${CLONE}
HAVEN_WORK_DIR=${CLONE}
HAVEN_HERMES_DATA_DIR=${CLONE}/hermes_data
HAVEN_WEBUI_DATA_DIR=${CLONE}/webui_data
HAVEN_OLLAMA_DATA_DIR=${CLONE}/ollama_data
HAVEN_CADDY_DATA_DIR=${CLONE}/caddy
HAVEN_INSTALL_LOG=${CLONE}/install.log
HAVEN_BACKUP_STAGING_DIR=${CLONE}/.backup-staging
HAVEN_RESTORE_WORK_DIR=${CLONE}/.restore-work
HAVEN_HERMES_HOME_DIR=${CH}/.hermes
HAVEN_POST_DEPLOY_VERIFY_CMD=/usr/local/sbin/run-post-deploy-verify.sh
HAVEN_POST_DEPLOY_VERIFY_LOG=/var/log/haven-post-deploy-verify.log
HAVEN_BACKUP_MODE=user
BACKUP_CONTAINER_CONTROL=self
BACKUP_LOG=${CLONE}/backup.log
BACKUP_CONF_DIR=${CH}/.config/haven-backup
RESTIC_CACHE_DIR=${CH}/.cache/restic
OPENHANDS_WORKSPACE=${CH}/haven-agent
AGENT_REPOS_DIR=${CH}/haven-repos
OPENHANDS_STATE_DIR=${CH}/.openhands
EOF
)"
check "the full resolved set with no settings is byte-identical to today" \
      "$EXPECT" "$DUMP"

# ---------------------------------------------------------------------------
# 2. A value in the env file is DATA, not code
# ---------------------------------------------------------------------------
echo "== env file is never executed =="
MARKER="${TMPROOT}/PWNED"
PWN_ENV="${TMPROOT}/pwn.env"
# A single literal dollar sign. Built this way so shellcheck sees the dollar as
# data being assembled, not as a single-quoted expression that can never expand.
DOLLAR='$'
printf 'HAVEN_DATA_DIR=%s(touch %s; echo /tmp/should_not_appear)\n' "$DOLLAR" "$MARKER" > "$PWN_ENV"
resolve "$PWN_ENV" HAVEN_DATA_DIR >/dev/null 2>&1 || true
assert "a \$(...) in the env file is NOT executed" bash -c "[[ ! -e '$MARKER' ]]"

# The same, with a command substitution that has no spaces, must be accepted as
# a literal path and still not run.
LITERAL_ENV="${TMPROOT}/lit.env"
printf 'HAVEN_DATA_DIR=/tmp/hai%s%s\n' "$DOLLAR" '(whoami)' > "$LITERAL_ENV"
GOT="$(resolve "$LITERAL_ENV" HAVEN_DATA_DIR 2>/dev/null || true)"
check "a command substitution is kept literally" "/tmp/hai${DOLLAR}(whoami)" "$GOT"
assert "still not executed when accepted" bash -c "[[ ! -e '$MARKER' ]]"

# ---------------------------------------------------------------------------
# 3. Every refused value is refused (AC2)
# ---------------------------------------------------------------------------
echo "== refused values =="
REFUSE_CASES=(
  "relative|sub/dir"
  "whitespace|/tmp/a b"
  "control-char|/tmp/a$(printf '\001')b"
  "colon|/tmp/a:b"
  "comma|/tmp/a,b"
  "root-slash|/"
)
for case in "${REFUSE_CASES[@]}"; do
  name="${case%%|*}"; val="${case#*|}"
  f="${TMPROOT}/refuse_${name}.env"
  printf 'HAVEN_DATA_DIR=%s\n' "$val" > "$f"
  if resolve_rc "$f"; then
    bad "refused '${name}' value (helper accepted it)"
  else
    ok "refused '${name}' value"
  fi
done

# A valid absolute value IS accepted.
GOOD_ENV="${TMPROOT}/good.env"
printf 'HAVEN_DATA_DIR=/tmp/hai-ok\n' > "$GOOD_ENV"
check "accepts a valid absolute value" "/tmp/hai-ok" "$(resolve "$GOOD_ENV" HAVEN_DATA_DIR)"

# ENUM settings: the allowed words are accepted; any other value is refused.
for v in user system; do
  fe="${TMPROOT}/mode_${v}.env"; printf 'HAVEN_BACKUP_MODE=%s\n' "$v" > "$fe"
  check "HAVEN_BACKUP_MODE accepts '${v}'" "$v" "$(resolve "$fe" HAVEN_BACKUP_MODE)"
done
for v in self external; do
  fe="${TMPROOT}/ctrl_${v}.env"; printf 'BACKUP_CONTAINER_CONTROL=%s\n' "$v" > "$fe"
  check "BACKUP_CONTAINER_CONTROL accepts '${v}'" "$v" "$(resolve "$fe" BACKUP_CONTAINER_CONTROL)"
done
for bad_val in "System" "host" "yes" "USER" "systemd"; do
  fe="${TMPROOT}/bad_mode.env"; printf 'HAVEN_BACKUP_MODE=%s\n' "$bad_val" > "$fe"
  if resolve_rc "$fe"; then
    bad "refused HAVEN_BACKUP_MODE value '${bad_val}' (helper accepted it)"
  else
    ok "refused HAVEN_BACKUP_MODE value '${bad_val}'"
  fi
done
# An empty value means "unset": the default applies, exactly as for a path.
fe="${TMPROOT}/empty_mode.env"; printf 'HAVEN_BACKUP_MODE=\n' > "$fe"
check "an empty HAVEN_BACKUP_MODE falls back to user" "user" "$(resolve "$fe" HAVEN_BACKUP_MODE)"
for bad_val in "docker" "none" "TRUE"; do
  fe="${TMPROOT}/bad_ctrl.env"; printf 'BACKUP_CONTAINER_CONTROL=%s\n' "$bad_val" > "$fe"
  if resolve_rc "$fe"; then
    bad "refused BACKUP_CONTAINER_CONTROL value '${bad_val}' (helper accepted it)"
  else
    ok "refused BACKUP_CONTAINER_CONTROL value '${bad_val}'"
  fi
done

# The mode-derived unit names and credential directory are resolved by the ONE
# helper, so doctor.sh/install.sh/deploy-remote.sh/collect-diagnostics.sh/
# backup.sh cannot disagree about which units run.
echo "== mode-derived names =="
check "user-mode backup timer"       "haven-backup.timer"         "$(resolve "$EMPTY" HAVEN_BACKUP_TIMER_UNIT)"
check "user-mode backup service"     "haven-backup.service"       "$(resolve "$EMPTY" HAVEN_BACKUP_SERVICE_UNIT)"
check "user-mode check timer"        "haven-check.timer"          "$(resolve "$EMPTY" HAVEN_BACKUP_CHECK_TIMER_UNIT)"
check "user-mode systemctl scope"    "--user"                         "$(resolve "$EMPTY" HAVEN_BACKUP_SYSTEMCTL_SCOPE)"
check "user-mode journal scope"      "--user"                         "$(resolve "$EMPTY" HAVEN_BACKUP_JOURNAL_SCOPE)"
check "user-mode cred dir is BACKUP_CONF_DIR" "$HOME/.config/haven-backup" "$(resolve "$EMPTY" HAVEN_BACKUP_CRED_DIR)"

SYSMODE="${TMPROOT}/sysmode.env"; printf 'HAVEN_BACKUP_MODE=system\n' > "$SYSMODE"
check "system-mode backup timer"     "haven-backup-capture.timer" "$(resolve "$SYSMODE" HAVEN_BACKUP_TIMER_UNIT)"
check "system-mode backup service"   "haven-backup-capture.service" "$(resolve "$SYSMODE" HAVEN_BACKUP_SERVICE_UNIT)"
check "system-mode check timer"      "haven-backup-check.timer"   "$(resolve "$SYSMODE" HAVEN_BACKUP_CHECK_TIMER_UNIT)"
check "system-mode systemctl scope"  "--system"                       "$(resolve "$SYSMODE" HAVEN_BACKUP_SYSTEMCTL_SCOPE)"
check "system-mode journal scope"    "--system"                       "$(resolve "$SYSMODE" HAVEN_BACKUP_JOURNAL_SCOPE)"
check "system-mode cred dir is the credstore" "/etc/credstore/haven-backup" "$(resolve "$SYSMODE" HAVEN_BACKUP_CRED_DIR)"

# BACKUP_LOG resolves to ONE path per mode: the units' LogsDirectory= in system
# mode, $LOG_DIR/backup.log in user mode. doctor.sh reads the same value, so the
# two can no longer disagree (D9).
check "user-mode BACKUP_LOG default" "${REPO}/backup.log" "$(resolve "$EMPTY" BACKUP_LOG)"
check "system-mode BACKUP_LOG default is the units' LogsDirectory path" \
  "/var/log/haven-backup/backup.log" "$(resolve "$SYSMODE" BACKUP_LOG)"
# A SET value still wins in both modes (no mode may silently ignore it).
SETLOG="${TMPROOT}/setlog.env"
printf 'HAVEN_BACKUP_MODE=system\nBACKUP_LOG=/tmp/explicit/backup.log\n' > "$SETLOG"
check "an explicit BACKUP_LOG wins in system mode" \
  "/tmp/explicit/backup.log" "$(resolve "$SETLOG" BACKUP_LOG)"
SETLOG_U="${TMPROOT}/setlog-user.env"
printf 'BACKUP_LOG=/tmp/explicit-user/backup.log\n' > "$SETLOG_U"
check "an explicit BACKUP_LOG wins in user mode" \
  "/tmp/explicit-user/backup.log" "$(resolve "$SETLOG_U" BACKUP_LOG)"

# ---------------------------------------------------------------------------
# 3b. Fail closed on an env file that exists but cannot be read
# ---------------------------------------------------------------------------
echo "== fail closed on an unreadable env file =="
# A file that exists with mode 0000 cannot be read by this (non-root) process,
# so the helper must refuse rather than silently use the built-in defaults.
# Only meaningful when this test is NOT root: root bypasses the read bit.
if [[ "$(id -u)" != "0" ]]; then
  LOCKED_LAYOUT="${TMPROOT}/locked-layout.env"
  printf 'HAVEN_DATA_DIR=/tmp/x\n' > "$LOCKED_LAYOUT"
  chmod 000 "$LOCKED_LAYOUT"
  rc=0; err="$(env HAVEN_ENV_FILE="$LOCKED_LAYOUT" bash -c "source '$HELPER'" 2>&1 >/dev/null)" || rc=$?
  check "an unreadable layout file exits non-zero" "1" "$rc"
  if [[ "$err" == *HAVEN_ENV_FILE* ]]; then
    ok "the message names HAVEN_ENV_FILE"
  else
    bad "the message did not name HAVEN_ENV_FILE: $err"
  fi
  if [[ "$err" == *locked-layout.env* ]]; then
    ok "the message names the path"
  else
    bad "the message did not name the path: $err"
  fi

  # The same for the STACK file: it, too, must refuse rather than default.
  LAYOUTDIR="${TMPROOT}/fc-layout"; mkdir -p "$LAYOUTDIR"
  LOCKED_STACK="${TMPROOT}/locked-stack.env"
  printf 'HAVEN_STACK_ENV_FILE=%s\n' "$LOCKED_STACK" > "${LAYOUTDIR}/layout.env"
  printf 'SECRET=1\n' > "$LOCKED_STACK"
  chmod 000 "$LOCKED_STACK"
  rc=0; err="$(env HAVEN_ENV_FILE="${LAYOUTDIR}/layout.env" bash -c "source '$HELPER'" 2>&1 >/dev/null)" || rc=$?
  check "an unreadable stack file exits non-zero" "1" "$rc"
  if [[ "$err" == *HAVEN_STACK_ENV_FILE* ]]; then
    ok "the message names HAVEN_STACK_ENV_FILE"
  else
    bad "the message did not name HAVEN_STACK_ENV_FILE: $err"
  fi
  chmod 600 "$LOCKED_STACK" "$LOCKED_LAYOUT"
else
  printf 'ok   skip unreadable-env-file assertions (running as root)\n'
fi

# ---------------------------------------------------------------------------
# 3c. Bootstrap LAYOUT fallback (D10)
# ---------------------------------------------------------------------------
# On a bootstrapped host $HAVEN_APP_DIR/.env does not exist: the layout
# moved to /etc/haven/haven.env. When HAVEN_ENV_FILE is UNSET the
# helper must probe the fallback layout file. The fallback location is the NAMED
# variable HAVEN_ENV_FILE_FALLBACK, so these fixtures live in the temp dir
# and NOTHING here reads or writes /etc.
echo "== bootstrap layout fallback (D10) =="
FBDIR="${TMPROOT}/fb"; mkdir -p "${FBDIR}/app"
FBDIR_APP="${FBDIR}/app"            # has NO .env
LAYOUT="${FBDIR}/haven.env"     # the fallback LAYOUT file
STACK_FB="${FBDIR}/stack.env"       # the secrets file the layout names
: > "$STACK_FB"
cat > "$LAYOUT" <<FBEOF
HAVEN_ENV_FILE=${LAYOUT}
HAVEN_STACK_ENV_FILE=${STACK_FB}
HAVEN_BACKUP_MODE=system
FBEOF

# A resolver that runs the helper with NO explicit HAVEN_ENV_FILE and an
# explicit fallback location, printing one resolved variable.
fb_resolve() { # var [extra K=V ...]
  local var="$1"; shift
  env "$@" HAVEN_ENV_FILE_FALLBACK="$LAYOUT" \
      HAVEN_APP_DIR="$FBDIR_APP" \
      bash -c "source '$HELPER' >/dev/null 2>&1; printf '%s' \"\$$var\""
}
fb_rc() { # [extra K=V ...]
  env "$@" HAVEN_ENV_FILE_FALLBACK="$LAYOUT" HAVEN_APP_DIR="$FBDIR_APP" \
      bash -c "source '$HELPER'" >/dev/null 2>&1
  return $?
}

# Criterion 1 + 3: with $APP_DIR/.env absent, the fallback resolves and the
# WHOLE chain follows the layout file.
check "fallback: HAVEN_ENV_FILE resolves to the fallback layout" "$LAYOUT" \
  "$(fb_resolve HAVEN_ENV_FILE)"
check "fallback: mode is read from the layout (system)" "system" \
  "$(fb_resolve HAVEN_BACKUP_MODE)"
check "fallback: BACKUP_LOG follows the mode" "/var/log/haven-backup/backup.log" \
  "$(fb_resolve BACKUP_LOG)"
check "fallback: HAVEN_BACKUP_CRED_DIR is the credstore default" \
  "/etc/credstore/haven-backup" "$(fb_resolve HAVEN_BACKUP_CRED_DIR)"
check "fallback: STACK_ENV_FILE is the file the layout names" "$STACK_FB" \
  "$(fb_resolve HAVEN_STACK_ENV_FILE)"
check "fallback: APP_DIR keeps its explicit value" "$FBDIR_APP" \
  "$(fb_resolve HAVEN_APP_DIR)"

# Criterion 2 (b): when $APP_DIR/.env EXISTS the fallback is never consulted.
PRESENT_DIR="${FBDIR}/present"; mkdir -p "$PRESENT_DIR"
PRESENT_LAYOUT="${FBDIR}/present-layout.env"
printf 'HAVEN_DATA_DIR=/tmp/from-present-layout\n' > "$PRESENT_LAYOUT"
cat > "${PRESENT_DIR}/.env" <<PEOF
HAVEN_DATA_DIR=/tmp/from-app-dotenv
PEOF
check "fallback not used when \$APP_DIR/.env exists" "/tmp/from-app-dotenv" \
  "$(env HAVEN_ENV_FILE_FALLBACK="$PRESENT_LAYOUT" HAVEN_APP_DIR="$PRESENT_DIR" \
      bash -c "source '$HELPER' >/dev/null 2>&1; printf '%s' \"\$HAVEN_DATA_DIR\"")"

# Criterion 2 (a): an explicit HAVEN_ENV_FILE always wins; the fallback is
# never consulted even when it exists and $APP_DIR/.env does not.
check "explicit HAVEN_ENV_FILE wins over the fallback" "/tmp/from-explicit" \
  "$(env HAVEN_ENV_FILE="$LAYOUT" HAVEN_ENV_FILE_FALLBACK="$PRESENT_LAYOUT" \
      HAVEN_APP_DIR="$FBDIR_APP" HAVEN_DATA_DIR=/tmp/from-explicit \
      bash -c "source '$HELPER' >/dev/null 2>&1; printf '%s' \"\$HAVEN_DATA_DIR\"")"
check "explicit HAVEN_ENV_FILE is not replaced by the fallback" "$LAYOUT" \
  "$(env HAVEN_ENV_FILE="$LAYOUT" HAVEN_ENV_FILE_FALLBACK="$PRESENT_LAYOUT" \
      HAVEN_APP_DIR="$FBDIR_APP" \
      bash -c "source '$HELPER' >/dev/null 2>&1; printf '%s' \"\$HAVEN_ENV_FILE\"")"

# The fallback override variable is honoured: point it at a DIFFERENT layout and
# that layout's value is the one that applies.
OVERRIDE_LAYOUT="${FBDIR}/override.env"
printf 'HAVEN_DATA_DIR=/tmp/from-override\n' > "$OVERRIDE_LAYOUT"
check "the fallback override variable is honoured" "/tmp/from-override" \
  "$(env HAVEN_ENV_FILE_FALLBACK="$OVERRIDE_LAYOUT" HAVEN_APP_DIR="$FBDIR_APP" \
      bash -c "source '$HELPER' >/dev/null 2>&1; printf '%s' \"\$HAVEN_DATA_DIR\"")"

# Criterion 4: fail closed. With the fallback active and the resolved stack file
# PRESENT but unreadable to this uid, the helper exits non-zero and names the
# setting and path -- never a value. Only meaningful when NOT root.
if [[ "$(id -u)" != "0" ]]; then
  LOCKED_FB_STACK="${FBDIR}/locked-stack.env"
  printf 'SECRET=1\n' > "$LOCKED_FB_STACK"
  chmod 000 "$LOCKED_FB_STACK"
  LOCKED_LAYOUT="${FBDIR}/locked-layout.env"
  cat > "$LOCKED_LAYOUT" <<LFBEOF
HAVEN_ENV_FILE=${LOCKED_LAYOUT}
HAVEN_STACK_ENV_FILE=${LOCKED_FB_STACK}
LFBEOF
  rc=0; err="$(env HAVEN_ENV_FILE_FALLBACK="$LOCKED_LAYOUT" HAVEN_APP_DIR="$FBDIR_APP" \
               bash -c "source '$HELPER'" 2>&1 >/dev/null)" || rc=$?
  check "fallback: an unreadable stack file exits non-zero" "1" "$rc"
  if [[ "$err" == *HAVEN_STACK_ENV_FILE* && "$err" == *locked-stack.env* ]]; then
    ok "fallback: the message names the setting and the path"
  else
    bad "fallback: the message did not name the setting and path: $err"
  fi
  if [[ "$err" == *"SECRET"* || "$err" == *"=1"* ]]; then
    bad "fallback: the message leaked a value from the file"
  else
    ok "fallback: the message leaks no value"
  fi
  chmod 600 "$LOCKED_FB_STACK"
else
  printf 'ok   skip fallback unreadable-stack assertion (running as root)\n'
fi

# A file that simply does not exist is NOT an error: the defaults apply.
MISSING_ENV="${TMPROOT}/does-not-exist.env"
if resolve_rc "$MISSING_ENV"; then
  ok "a missing env file still resolves to the defaults"
else
  bad "a missing env file was refused"
fi

# ---------------------------------------------------------------------------
# 4. Isolation guards (AC6)
# ---------------------------------------------------------------------------
echo "== isolation guards =="

# Build a scratch "app" with the helper and the two guard scripts.
APPD="${TMPROOT}/app"
mkdir -p "${APPD}/scripts/lib" "${APPD}/backup" "${APPD}/openhands" "${APPD}/hermes"
cp "$HELPER" "${APPD}/scripts/lib/"
cp "${REPO}/scripts/setup-agent-workspace.sh" "${APPD}/scripts/"
cp "${REPO}/scripts/sync-agent-repos.sh" "${APPD}/scripts/"
cp "${REPO}/doctor.sh" "${APPD}/"
cp "${REPO}/backup/backup.sh" "${APPD}/backup/"
cp "${REPO}/backup/restore.sh" "${APPD}/backup/"
: > "${APPD}/docker-compose.yml"

DATAD="${TMPROOT}/data"; LOGD="${TMPROOT}/log"; WORKD="${TMPROOT}/work"
CONFD_GOOD="${TMPROOT}/conf-good"; CONFD_BAD="${TMPROOT}/conf-bad"
mkdir -p "$DATAD" "$LOGD" "$WORKD" "$CONFD_GOOD" "$CONFD_BAD/inside-app"
mkdir -p "${TMPROOT}/etc"
ENVF="${TMPROOT}/etc/env"; : > "$ENVF"

# A helper env shared by the guard runs, relocating every tree.
GUARD_ENV=(HOME="$TMPROOT/home" HAVEN_APP_DIR="$APPD" HAVEN_ENV_FILE="$ENVF"
           HAVEN_DATA_DIR="$DATAD" HAVEN_LOG_DIR="$LOGD" HAVEN_WORK_DIR="$WORKD"
           BACKUP_CONF_DIR="$CONFD_GOOD")
mkdir -p "${TMPROOT}/home"

# --- The STACK file's directory is guarded too -------------------------------
# With the bootstrap layout the secrets live in HAVEN_STACK_ENV_FILE, so a
# workspace or repo tree that is, contains, or lives inside ITS directory must be
# refused exactly like the layout file's directory.
STACKD="${TMPROOT}/stackdir"
mkdir -p "$STACKD"
STACKF="${STACKD}/stack.env"; : > "$STACKF"
GUARD_ENV_STACK=("${GUARD_ENV[@]}" HAVEN_STACK_ENV_FILE="$STACKF")
for t in "$STACKD" "${STACKD}/child" "${TMPROOT}" ; do
  if env "${GUARD_ENV_STACK[@]}" OPENHANDS_WORKSPACE="$t" \
       bash "${APPD}/scripts/setup-agent-workspace.sh" --non-interactive >/dev/null 2>&1; then
    bad "setup-agent-workspace refused stack-dir workspace '${t}'"
  else
    ok "setup-agent-workspace refused stack-dir workspace '${t}'"
  fi
done
for t in "$STACKD" "${STACKD}/repos" "${TMPROOT}"; do
  if env "${GUARD_ENV_STACK[@]}" AGENT_REPOS_DIR="$t" \
       bash "${APPD}/scripts/sync-agent-repos.sh" --dry-run >/dev/null 2>&1; then
    bad "sync-agent-repos refused stack-dir AGENT_REPOS_DIR '${t}'"
  else
    ok "sync-agent-repos refused stack-dir AGENT_REPOS_DIR '${t}'"
  fi
done
# doctor.sh refuses a workspace that IS the stack file's directory. doctor.sh
# reads OPENHANDS_WORKSPACE from the env FILES (env_get), so seed it there.
DL="${TMPROOT}/doctor-layout.env"
printf 'OPENHANDS_WORKSPACE=%s\n' "$STACKD" > "$DL"
DMSG="$(env HOME="$TMPROOT/home" HAVEN_APP_DIR="$APPD" HAVEN_ENV_FILE="$DL" \
        HAVEN_STACK_ENV_FILE="$STACKF" HAVEN_DATA_DIR="$DATAD" \
        HAVEN_LOG_DIR="$LOGD" HAVEN_WORK_DIR="$WORKD" BACKUP_CONF_DIR="$CONFD_GOOD" \
        bash "${APPD}/doctor.sh" --no-cloud 2>&1 || true)"
if [[ "$DMSG" == *"env-file directory"* ]]; then
  ok "doctor.sh refused a workspace at the stack file's directory"
else
  bad "doctor.sh did not flag a workspace at the stack file's directory"
fi

# --- setup-agent-workspace.sh refuses a workspace in a protected tree --------
guarded_targets=(
  "$APPD"                    # the app dir
  "${APPD}/child"            # inside the app dir
  "$DATAD"                   # the data dir
  "${DATAD}/child"           # inside the data dir
  "$LOGD"                    # the log dir
  "$WORKD"                   # the work dir
  "${TMPROOT}/etc"           # the directory the env file lives in
  "$CONFD_GOOD"              # the backup credential directory
  "${TMPROOT}"               # contains every protected dir
)
for t in "${guarded_targets[@]}"; do
  if env "${GUARD_ENV[@]}" OPENHANDS_WORKSPACE="$t" \
       bash "${APPD}/scripts/setup-agent-workspace.sh" --non-interactive >/dev/null 2>&1; then
    bad "setup-agent-workspace refused workspace '${t}'"
  else
    ok "setup-agent-workspace refused workspace '${t}'"
  fi
done

# --- setup-agent-workspace.sh does NOT refuse a clean sibling -----------------
# The guard must not fire for a path outside every protected tree. --check also
# fails when no clone exists; we assert only that the GUARD did not fire.
MSG="$(env "${GUARD_ENV[@]}" OPENHANDS_WORKSPACE="${TMPROOT}/agent-ws" \
      bash "${APPD}/scripts/setup-agent-workspace.sh" --check 2>&1 || true)"
if [[ "$MSG" == *"protected directory"* || "$MSG" == *"workspace containment"* ]]; then
  bad "setup-agent-workspace wrongly refused a clean sibling"
else
  ok "setup-agent-workspace did not fire the guard for a clean sibling"
fi

# Exercise the root routing branch without requiring root on CI. Only the
# EUID predicate in the scratch copy changes; Git operates on real local repos.
sed 's/(( EUID == 0 ))/(( 1 ))/' "$REPO/scripts/setup-agent-workspace.sh" \
  > "$APPD/scripts/setup-agent-workspace.sh"
WS="${TMPROOT}/agent-ws"
REMOTE="${TMPROOT}/origin.git"
git init -q --bare --initial-branch=main "$REMOTE"
git clone -q "$REMOTE" "$WS" 2>/dev/null
git -C "$WS" -c user.name=Fixture -c user.email=fixture@example.invalid \
  commit -q --allow-empty -m initial
git -C "$WS" push -q origin main
git -C "$WS" remote set-head origin main
git init -q "$APPD"
git -C "$APPD" remote add origin "$REMOTE"
mkdir -p "$WS/bin" "$WS/bash_events" "$WS/.shared-actions-fixture"
printf 'preserve\n' > "$WS/bin/keep"
cp "$WS/bin/keep" "$TMPROOT/keep.before"
TEST_BIN="$TMPROOT/identity-bin"
mkdir -p "$TEST_BIN"
cat > "$TEST_BIN/runuser" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == -u && "$2" == "$(id -un)" && "$3" == -- ]] || exit 90
shift 3
printf '%s\n' "$*" >> "$IDENTITY_CALLS"
exec "$@"
STUB
chmod +x "$TEST_BIN/runuser"
IDENTITY_CALLS="$TMPROOT/identity.calls"
export IDENTITY_CALLS
if env "${GUARD_ENV[@]}" PATH="$TEST_BIN:$PATH" HAVEN_UID="$(id -u)" \
    OPENHANDS_WORKSPACE="$WS" GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=core.bare GIT_CONFIG_VALUE_0=true \
    bash "$APPD/scripts/setup-agent-workspace.sh" --non-interactive > "$TMPROOT/identity.out" 2>&1; then
  ok "workspace maintenance routes Git through the configured runtime identity"
else
  bad "workspace maintenance failed with the runtime identity fixture"
fi
assert "untracked workspace bytes preserved" cmp -s "$TMPROOT/keep.before" "$WS/bin/keep"
assert "runtime Git receives a clean environment and disabled hooks" \
  grep -q 'env -i HOME=.*PATH=/usr/bin:/bin GIT_TERMINAL_PROMPT=0 git -c core.hooksPath=/dev/null' "$IDENTITY_CALLS"
assert "dirty workspace refresh is skipped" grep -q 'uncommitted changes' "$TMPROOT/identity.out"
# Wrong configured owner must fail before invoking any workspace Git command.
: > "$IDENTITY_CALLS"
if env "${GUARD_ENV[@]}" PATH="$TEST_BIN:$PATH" HAVEN_UID=65534 \
    OPENHANDS_WORKSPACE="$WS" bash "$APPD/scripts/setup-agent-workspace.sh" \
    --non-interactive > "$TMPROOT/identity.out" 2>&1; then
  bad "mismatched workspace owner was accepted"
else
  ok "mismatched workspace owner refused"
fi
check "owner mismatch invokes no workspace Git" "0" "$(wc -c < "$IDENTITY_CALLS" | tr -d ' ')"
# Restore the original script for subsequent guards.
cp "$REPO/scripts/setup-agent-workspace.sh" "$APPD/scripts/"

# --- sync-agent-repos.sh refuses a tree in a protected target ----------------
for t in "$APPD" "${APPD}/repos" "$DATAD" "$LOGD" "$WORKD" "${TMPROOT}/etc" \
         "$CONFD_GOOD" "${TMPROOT}"; do
  if env "${GUARD_ENV[@]}" AGENT_REPOS_DIR="$t" \
       bash "${APPD}/scripts/sync-agent-repos.sh" --dry-run >/dev/null 2>&1; then
    bad "sync-agent-repos refused AGENT_REPOS_DIR '${t}'"
  else
    ok "sync-agent-repos refused AGENT_REPOS_DIR '${t}'"
  fi
done

# --- backup.sh / restore.sh refuse a BACKUP_CONF_DIR inside the trees --------
for script in backup/backup.sh backup/restore.sh; do
  for t in "$APPD" "$DATAD" "$WORKD"; do
    if env "${GUARD_ENV[@]}" BACKUP_CONF_DIR="$t" \
         bash "${APPD}/${script}" --dry-run >/dev/null 2>&1; then
      bad "${script} refused BACKUP_CONF_DIR inside '${t}'"
    else
      ok "${script} refused BACKUP_CONF_DIR inside '${t}'"
    fi
  done
done

# ---------------------------------------------------------------------------
# 5. No path bypasses the helper (AC3 grep)
# ---------------------------------------------------------------------------
echo "== no bypassing paths =="
# Search every tracked shell script EXCEPT the helper and this test for the
# forbidden constructs: a repo-relative data/log/env path, a bare --env-file .env,
# or a $HOME-derived state/data path.
BYPASS_FILES="$(cd "$REPO" && git ls-files '*.sh' | grep -vE '^(scripts/lib/(hybrid-ai|haven)-env\.sh|scripts/test-haven-env\.sh)$')"
HITS="$(cd "$REPO" && printf '%s\n' "$BYPASS_FILES" | while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  grep -nE '\$\{REPO_DIR\}|\$\{SCRIPT_DIR\}/\.env|--env-file [.]env|\$\{HOME\}/\.openhands|\$\{HOME\}/\.hermes|\$\{HOME\}/\.config/haven-backup|\$\{HOME\}/\.cache/restic' "$f" 2>/dev/null | sed "s|^|$f:|"
done)"
if [[ -z "$HITS" ]]; then
  ok "no repo-relative, SCRIPT_DIR, HOME-derived, or bare --env-file paths remain"
else
  bad "found paths that bypass the helper:"
  printf '%s\n' "$HITS" >&2
fi

# --- Every --env-file consumer passes the STACK file --------------------------
# The split is only real if every compose call hands over HAVEN_STACK_ENV_FILE.
# A consumer left on HAVEN_ENV_FILE would read the layout file, which holds
# no secrets. The helper itself and this test are excluded (they define/mention
# the setting name).
STACK_CONSUMERS="$(cd "$REPO" && git ls-files '*.sh' | grep -vE '^(scripts/lib/(hybrid-ai|haven)-env\.sh|scripts/test-haven-env\.sh)$')"
BAD_CONSUMERS="$(cd "$REPO" && printf '%s\n' "$STACK_CONSUMERS" | while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  # Files that pass an env file to docker compose must name the STACK setting.
  if grep -qE -- '--env-file' "$f" 2>/dev/null; then
    if ! grep -qE 'HAVEN_STACK_ENV_FILE' "$f" 2>/dev/null; then
      printf '%s\n' "$f"
    fi
  fi
done)"
if [[ -z "$BAD_CONSUMERS" ]]; then
  ok "every --env-file consumer uses HAVEN_STACK_ENV_FILE"
else
  bad "these --env-file consumers do not use the stack file:"
  printf '%s\n' "$BAD_CONSUMERS" >&2
fi

# install.sh must WRITE the stack file, never the layout file.
STACK_ASSIGN="ENV_FILE=\"\$HAVEN_STACK_ENV_FILE\""
if grep -qF "$STACK_ASSIGN" "$REPO/install.sh"; then
  ok "install.sh writes the stack env file"
else
  bad "install.sh does not set ENV_FILE from HAVEN_STACK_ENV_FILE"
fi

# ---------------------------------------------------------------------------
# 6. install.sh STEP 8 template renders the startup-grace default
# ---------------------------------------------------------------------------
echo "== install.sh STEP 8 template: OPENHANDS_STARTUP_GRACE_SECONDS =="
# shellcheck source=scripts/lib/installer-env-render.sh
source "$REPO/scripts/lib/installer-env-render.sh"

check "STEP 8 renders the default grace (120) when unset" \
  "OPENHANDS_STARTUP_GRACE_SECONDS=120" "$(installer_render_openhands_grace '')"
check "STEP 8 preserves an owner-set grace (180)" \
  "OPENHANDS_STARTUP_GRACE_SECONDS=180" "$(installer_render_openhands_grace 180)"

# ---------------------------------------------------------------------------
echo
if (( FAIL != 0 )); then
  printf 'FAILED: %d of %d checks\n' "$FAIL" "$(( PASS + FAIL ))" >&2
  exit 1
fi
printf 'All %d haven-env checks passed.\n' "$PASS"

# Focused layout security regressions use the real resolver.
python3 - "$REPO" <<'PY_IDENTITY'
import os
import sys
import re
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(sys.argv.pop(1))
class ConfigIdentityTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.layout = Path(self.work.name) / "layout"
        self.layout.write_text("")
        self.env = {"PATH": os.environ["PATH"], "HOME": self.work.name,
                    "HAVEN_ENV_FILE": str(self.layout)}

    def resolve(self, text="", exports=None, expression='printf "%s" "$HAVEN_DATA_DIR"', helper="haven-env.sh"):
        self.layout.write_text(text)
        env = dict(self.env, **(exports or {}))
        command = 'source "$1"; ' + expression
        return subprocess.run(["bash", "-eu", "-c", command, "identity-test",
                               str(ROOT / "scripts/lib" / helper)], env=env,
                              text=True, capture_output=True)

    def test_legacy_layout_and_process_import(self):
        result = self.resolve("HYBRID_AI_DATA_DIR=/tmp/from-layout\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "/tmp/from-layout")
        result = self.resolve(exports={"HYBRID_AI_DATA_DIR": "/tmp/from-process"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "/tmp/from-process")

    def test_process_precedes_either_file_spelling(self):
        for name in ("HAVEN_DATA_DIR", "HYBRID_AI_DATA_DIR"):
            result = self.resolve(name + "=/tmp/from-file\n",
                                  {"HAVEN_DATA_DIR": "/tmp/from-process"})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "/tmp/from-process")

    def test_equal_aliases_and_legacy_entrypoint(self):
        text = 'HAVEN_DATA_DIR="/tmp/same"\nHYBRID_AI_DATA_DIR=/tmp/same\n'
        result = self.resolve(text, helper="hybrid-ai-env.sh",
                              expression='printf "%s" "$HYBRID_AI_DATA_DIR"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "/tmp/same")

    def test_conflicts_refuse_without_disclosing_values(self):
        secret = "synthetic-private-value"
        cases = [
            ("", {"HAVEN_DATA_DIR": "/tmp/one", "HYBRID_AI_DATA_DIR": "/tmp/" + secret}),
            ("HAVEN_DATA_DIR=/tmp/one\nHYBRID_AI_DATA_DIR=/tmp/" + secret + "\n", {}),
            ("HAVEN_AUTH_COOKIE_SECRET=one\nHYBRID_AI_AUTH_COOKIE_SECRET=" + secret + "\n", {}),
            ("HAVEN_DATA_DIR=\nHYBRID_AI_DATA_DIR=/tmp/" + secret + "\n", {}),
        ]
        for text, exports in cases:
            with self.subTest(text=bool(text), exports=bool(exports)):
                result = self.resolve(text, exports)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(secret, result.stdout + result.stderr)

    def test_conflicts_in_separate_stack_refuse_before_caller(self):
        stack = Path(self.work.name) / "stack"
        stack.write_text("HAVEN_AUTH_USER=one\nHYBRID_AI_AUTH_USER=two\n")
        result = self.resolve("HAVEN_STACK_ENV_FILE=" + str(stack) + "\n",
                              expression='printf caller-ran')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_quotes_dollars_and_backticks_remain_literal(self):
        marker = Path(self.work.name) / "executed"
        value = "/tmp/$(touch " + str(marker) + ")`whoami`$$"
        # Scalars can contain whitespace; values must never be evaluated.
        result = self.resolve("HYBRID_AI_UID='" + value + "'\n",
                              expression='printf "%s" "$HAVEN_UID"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, value)
        self.assertFalse(marker.exists())

    def test_original_layout_conflicts_cannot_hide_behind_redirection(self):
        code = Path(self.work.name) / "original"
        helper = code / "scripts/lib/haven-env.sh"
        helper.parent.mkdir(parents=True)
        helper.write_text((ROOT / "scripts/lib/haven-env.sh").read_text())
        other = Path(self.work.name) / "new-root"
        other.mkdir()
        (code / ".env").write_text(
            "HAVEN_APP_DIR=" + str(other) + "\n" +
            "HAVEN_ENV_FILE=" + str(other / "one") + "\n" +
            "HYBRID_AI_ENV_FILE=" + str(other / "two") + "\n")
        result = subprocess.run(["bash", "-eu", "-c", 'source "$1"; printf caller-ran',
                                 "identity-test", str(helper)],
                                env={"PATH": os.environ["PATH"], "HOME": self.work.name},
                                text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_unknown_keys_are_not_platform_aliases(self):
        result = self.resolve(expression='haven_key HYBRID_AI_VENDOR_EXTENSION')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "HYBRID_AI_VENDOR_EXTENSION")

    def test_empty_keeps_existing_default_semantics(self):
        result = self.resolve("HAVEN_DATA_DIR=\nHYBRID_AI_DATA_DIR=\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, str(ROOT))

    def test_current_source_has_only_reviewed_legacy_namespace_readers(self):
        allowed = {
            "auth/app.py",  # installed credential import
            "auth/test_auth.py",  # import and old-cookie refusal
            "scripts/bootstrap.sh",  # installed process import
            "scripts/check-hermes-nonroot.sh",  # installed UID import
            "scripts/ci-parity.sh",  # existing generator override
            "scripts/lib/build-gate.sh",  # heartbeat setting import
            "scripts/lib/haven-env.sh",  # explicit key/process alias readers
            "scripts/lib/hybrid-ai-env.sh",  # legacy external entrypoint
            "scripts/lib/repository-identity.sh",  # installed selector import
            "scripts/prune-docker-cache.sh",  # installed cap import
            "scripts/uninstall.sh",  # legacy layout/process recovery
            "scripts/test-haven-env.sh",  # handoff/refusal fixtures
            "scripts/test-repository-identity.sh",  # legacy selector import
            "scripts/test-install-auth-env-leak.sh",  # literal credential migration
        }
        # These exact lines discard a stale installed log alias and exercise
        # that refusal. Keep rejecting any other legacy use in these files.
        reviewed_log_alias_lines = {
            "scripts/deploy-forced-command.sh": "unset HAVEN_LOG_DIR HYBRID_AI_LOG_DIR",
            "scripts/test-deploy-forced-command.sh":
                '"${priv_pre[@]}" env HAVEN_LOG_DIR=/opt/haven HYBRID_AI_LOG_DIR=/opt/haven HAVEN_STACK_ENV_FILE=/unreadable/fixture ' + chr(92),
        }
        files = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
        unexpected = []
        for name in files:
            path = ROOT / name
            if (not name or name in allowed or name.startswith("docs/") or
                    path.suffix not in (".sh", ".py", ".yml", ".tmpl", ".service", ".timer")):
                continue
            content = "\n".join(line for line in path.read_text().splitlines()
                                if line.strip() != reviewed_log_alias_lines.get(name))
            if re.search(r"HYBRID_AI_|hybrid_ai_|HYBRID_PROGRESS_|hybrid_progress_", content):
                unexpected.append(name)
        self.assertEqual(unexpected, [], "unreviewed legacy namespace in active source")

unittest.main()
PY_IDENTITY
