#!/usr/bin/env bash
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# FILE: scripts/run-post-deploy-verify.sh
# PURPOSE (plain English):
#   Checks the deploy AFTER the deploy workflow has finished. scripts/
#   deploy-remote.sh starts it in a transient systemd unit when it is present,
#   so the check outlives the deploy unit's cgroup (a child of the deploy unit
#   would be killed the moment that unit exits).
#
#   It waits for the GitHub Actions run(s) for one commit SHA to complete, then
#   checks that every one of them concluded "success", then checks that the
#   deployed tree still sits on that same commit. It writes ONE result line:
#   PASS, WARN, FAIL (with the reason) or TIMEOUT.
#
#   It also records that verdict as JSON for Hermes consumers through the
#   existing data mount: one file per deploy SHA at
#   ${HYBRID_AI_DATA_DIR:-/var/lib/hybrid-ai}/hermes_data/deploy-verdicts/
#   <sha>.json. Optional missing evidence produces WARN (exit 0); mandatory
#   missing evidence produces FAIL (exit 1). See backup/README.md for policy.
#
# WHY IT EXISTS:
#   The deploy workflow reports on the work it started, not on the result of the
#   build it kicked off in the same run. A verification that runs after the run
#   completes is the only place that can see the final verdict AND the tree.
#   Before this script existed the hook pointed at a file nothing installed, so
#   the check silently never ran.
#
# DEPENDENCIES: bash, curl, jq, git, date -- all already probed by install.sh.
#   No Python, no token, no credential. The GitHub API is read ANONYMOUSLY.
#
# USAGE:
#   ./scripts/run-post-deploy-verify.sh --wait-for <full-40-hex-commit-sha>
#
#   APP_DIR resolves in order: HYBRID_AI_APP_DIR from the environment; else
#   HYBRID_AI_APP_DIR parsed line by line from the layout file named by
#   ${HYBRID_AI_ENV_FILE_FALLBACK:-/etc/hybrid-ai/hybrid-ai.env}; else /workspace.
#   The layout file is read as DATA (KEY=VALUE), never sourced, and no value from
#   it is ever printed. Tests point APP_DIR at a throwaway checkout.
#
# EXIT CODES:
#   0  PASS   all gates passed
#   0  WARN   mandatory gates passed; optional evidence missing or warning
#   1  FAIL   a run failed, the API refused, or the tree is on another commit
#   1  TIMEOUT (also non-zero) no completed run inside the 60 minute deadline
#   2  usage error: bad argument, unknown option, or a malformed SHA
# ---------------------------------------------------------------------------

# Embedded for the standalone /usr/local/sbin installation. The identity
# fixture suite checks this block against scripts/lib/repository-identity.sh.
# BEGIN repository identity selector
hybrid_ai_repository_slug() {
  case "${HYBRID_AI_REPOSITORY_SLUG-jimbobsyouruncle/hybrid-ai}" in
    jimbobsyouruncle/hybrid-ai|jimbobsyouruncle/haven)
      printf '%s' "${HYBRID_AI_REPOSITORY_SLUG-jimbobsyouruncle/hybrid-ai}"
      ;;
    *)
      printf 'repository identity: HYBRID_AI_REPOSITORY_SLUG must select an approved repository\n' >&2
      return 2
      ;;
  esac
}
# END repository identity selector
REPO_SLUG="$(hybrid_ai_repository_slug)" || exit 2
POLL_SECONDS=30
DEADLINE_SECONDS=3600
USER_AGENT="hybrid-ai-post-deploy-verify"

usage_refuse() {
  printf 'run-post-deploy-verify: %s\n' "$1" >&2
  printf 'usage: run-post-deploy-verify.sh --wait-for <40-hex-commit-sha>\n' >&2
  exit 2
}

# Gate evidence contains fixed diagnostic strings, never file contents or API bodies.
GATES='{"workflow_runs":{"required":true,"state":"SKIPPED","reason":"not reached"},"deployed_head":{"required":true,"state":"SKIPPED","reason":"not reached"}}'
record_gate() { # <name> <required:true|false> <state> <reason>
  GATES="$(jq -nc --argjson gates "$GATES" --arg name "$1" \
    --argjson required "$2" --arg state "$3" --arg reason "$4" \
    '$gates + {($name): {required: $required, state: $state, reason: $reason}}')" || exit 1
}

verdict_dir() {
  printf '%s' "${HYBRID_AI_DEPLOY_VERDICT_DIR:-${DATA_DIR}/hermes_data/deploy-verdicts}"
}

# Records a per-SHA receipt using the numeric identity used by Compose. No
# passwd lookup, host account creation, recursive chown or permission widening.
# The directory/file modes retain the existing 0755/0644 receipt contract.
write_verdict() { # <verdict> <rc> [detail]
  local verdict="$1" rc="$2" detail="${3:-}"
  local dir at head="" json ids_json="null" tmp target
  local owner_uid owner_gid
  dir="$(verdict_dir)"
  owner_uid="${HYBRID_AI_UID:-$(layout_value HYBRID_AI_UID)}"
  owner_gid="${HYBRID_AI_GID:-$(layout_value HYBRID_AI_GID)}"
  owner_uid="${owner_uid:-0}"; owner_gid="${owner_gid:-0}"
  if [[ ! "$owner_uid" =~ ^[0-9]+$ || ! "$owner_gid" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  [[ ! -L "$dir" ]] || return 1
  # A non-root local invocation can publish only as its own configured identity.
  if [[ "$(id -u)" == 0 ]]; then
    install -d -o "$owner_uid" -g "$owner_gid" -m 0755 "$dir" 2>/dev/null || return 1
  else
    [[ "$(id -u)" == "$owner_uid" && "$(id -g)" == "$owner_gid" ]] || return 1
    install -d -m 0755 "$dir" 2>/dev/null || return 1
  fi
  target="${dir}/${SHA}.json"
  [[ ! -L "$target" ]] || return 1
  tmp="$(mktemp "${dir}/.${SHA}.XXXXXX" 2>/dev/null)" || return 1
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || { rm -f -- "$tmp"; return 1; }
  head="$(git -C "$APP_DIR" rev-parse HEAD 2>/dev/null)" || head=""
  if (( ${#RUN_IDS[@]} > 0 )); then
    ids_json="$(printf '%s\n' "${RUN_IDS[@]}" | jq -R . | jq -s -c .)" || { rm -f -- "$tmp"; return 1; }
  fi
  if ! json="$(jq -nc \
      --arg sha "$SHA" --arg verdict "$verdict" --argjson rc "$rc" \
      --arg at "$at" --arg head "$head" --arg app_dir "$APP_DIR" \
      --arg detail "$detail" --argjson run_ids "$ids_json" --argjson gates "$GATES" \
      '{schema_version: 2, sha: $sha, verdict: $verdict, rc: $rc, at: $at,
        head: (if $head == "" then null else $head end), app_dir: $app_dir,
        detail: $detail, run_ids: $run_ids, gates: $gates}' 2>/dev/null)" \
      || ! printf '%s\n' "$json" > "$tmp" \
      || ! chmod 0644 "$tmp" \
      || { [[ "$(id -u)" == 0 ]] && ! chown "$owner_uid:$owner_gid" "$tmp"; } \
      || ! mv -fT -- "$tmp" "$target" 2>/dev/null; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Keep FAIL/TIMEOUT authoritative. Optional skipped/warning evidence can never
# become a clean PASS. JSON publication itself is optional and reported in log.
finish() { # <PASS|FAIL|TIMEOUT> <rc> [detail]
  local verdict="$1" rc="$2" detail="${3:-}"
  if [[ "$verdict" == PASS ]]; then
    local coverage
    coverage="$(jq -r '
      if any(.[]; .required and .state != "PASS") then "FAIL"
      elif any(.[]; .state != "PASS") then "WARN" else "PASS" end
      ' <<<"$GATES")" || coverage=FAIL
    case "$coverage" in
      PASS) ;;
      WARN) verdict=WARN; detail="optional verification evidence missing or warning" ;;
      *) verdict=FAIL; rc=1; detail="mandatory verification evidence missing or unsuccessful" ;;
    esac
  fi
  record_gate verdict_file false PASS "receipt published with configured numeric ownership"
  if ! write_verdict "$verdict" "$rc" "$detail"; then
    printf 'run-post-deploy-verify: could not publish verdict receipt with configured numeric ownership\n' >&2
    if [[ "$verdict" == PASS || "$verdict" == WARN ]]; then
      verdict=WARN; detail="optional verdict receipt could not be published"
    fi
  fi
  if [[ -n "$detail" ]]; then
    printf '%s: %s\n' "$verdict" "$detail"
  else
    printf '%s\n' "$verdict"
  fi
  exit "$rc"
}

[[ $# -eq 2 ]] || usage_refuse "expected exactly one option: --wait-for <sha>"
[[ "$1" == "--wait-for" ]] || usage_refuse "unknown option or missing --wait-for"
SHA="$2"
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] \
  || usage_refuse "--wait-for needs a 40-character lowercase hex commit SHA"

printf 'waiting for %s at %s\n' "$SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Resolve APP_DIR in three steps. The layout file is read as DATA, one KEY=VALUE
# line at a time -- it is NEVER sourced, and no value read from it is printed.
# An unreadable EXISTING file fails closed and names the setting, never a value.
HYBRID_AI_ENV_FILE_FALLBACK="${HYBRID_AI_ENV_FILE_FALLBACK:-/etc/hybrid-ai/hybrid-ai.env}"

# Check this even with an APP_DIR environment override: otherwise an unreadable
# system-mode layout could silently select optional user-mode verification.
if [[ -e "$HYBRID_AI_ENV_FILE_FALLBACK" && ! -r "$HYBRID_AI_ENV_FILE_FALLBACK" ]]; then
  printf 'FAIL: layout file is unreadable; refusing defaults\n'
  exit 1
fi

resolve_app_dir() {
  local value="" line key

  if [[ -n "${HYBRID_AI_APP_DIR:-}" ]]; then
    printf '%s' "$HYBRID_AI_APP_DIR"
    return 0
  fi

  if [[ -e "$HYBRID_AI_ENV_FILE_FALLBACK" ]]; then
    if [[ ! -r "$HYBRID_AI_ENV_FILE_FALLBACK" ]]; then
      printf 'run-post-deploy-verify: HYBRID_AI_ENV_FILE_FALLBACK (%s) exists but is not readable\n' \
        "$HYBRID_AI_ENV_FILE_FALLBACK" >&2
      return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line#"${line%%[![:space:]]*}"}"
      [[ "$line" == HYBRID_AI_APP_DIR=* ]] || continue
      value="${line#HYBRID_AI_APP_DIR=}"
      key="$value"
      [[ "$key" == /* ]] || { value=""; break; }
      if [[ "$key" == *[[:space:]]* || "$key" == *:* || "$key" == *","* ]]; then
        value=""
        break
      fi
      break
    done < "$HYBRID_AI_ENV_FILE_FALLBACK"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
  fi

  printf '%s' "/workspace"
  return 0
}

APP_DIR="$(resolve_app_dir)" || { printf 'FAIL: application directory could not be resolved\n'; exit 1; }
API_URL="https://api.github.com/repos/${REPO_SLUG}/actions/runs?head_sha=${SHA}"

# --- Backups tile gate ------------------------------------------------------
# A release can leave the Backups tile blind while the writer's log records a
# success: the reader is then wrong, not the backups. This gate catches exactly
# that. It reads settings from the layout file as DATA (never sourced, values
# never printed) and needs three things:
#   (a) BACKUP_LOG is a regular, non-empty file;
#   (b) the configured STATUS CONTAINER identity (legacy uid 1000/gid 999, plus
#       supplementary BACKUP_GROUP_GID) can read it -- probed by DROPPING
#       privileges from root with setpriv, because a root read proves nothing;
#   (c) the live status API's Backups tile is not `warn` while the log holds a
#       backup_success line.
# Missing required evidence fails closed. Missing optional evidence produces
# WARN and is recorded as SKIPPED, never PASS.
GATE_REASON=""
gate_skip() {
  record_gate "$CURRENT_GATE" "$BACKUP_REQUIRED" SKIPPED "$1"
  printf 'run-post-deploy-verify: skip: %s\n' "$1" >&2
}

# Read ONE allowlisted key from a configuration file as literal data.
file_value() { # <file> <KEY>; literal data only, never shell evaluation
  local file="$1" key="$2" line value=""
  [[ -f "$file" && -r "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ "$line" == "$key="* ]] || continue
    value="${line#*=}"
    value="${value%\"}"; value="${value#\"}"
    value="${value%\'}"; value="${value#\'}"
  done < "$file"
  printf '%s' "$value"
}

layout_value() { # <KEY>
  file_value "$HYBRID_AI_ENV_FILE_FALLBACK" "$1"
}

# Standalone installation cannot source repository helpers. Resolve only
# non-secret layout keys as data, matching the shared helper's mode defaults.
DATA_DIR="${HYBRID_AI_DATA_DIR:-$(layout_value HYBRID_AI_DATA_DIR)}"
DATA_DIR="${DATA_DIR:-/var/lib/hybrid-ai}"
BACKUP_MODE="${HYBRID_AI_BACKUP_MODE:-$(layout_value HYBRID_AI_BACKUP_MODE)}"
BACKUP_MODE="${BACKUP_MODE:-user}"
BACKUP_POLICY="${HYBRID_AI_VERIFY_BACKUP_GATES:-$(layout_value HYBRID_AI_VERIFY_BACKUP_GATES)}"
BACKUP_POLICY="${BACKUP_POLICY:-optional}"
STATUS_RUN_UID="${VERIFY_STATUS_UID:-${HYBRID_AI_UID:-$(layout_value HYBRID_AI_UID)}}"
STATUS_RUN_UID="${STATUS_RUN_UID:-${STATUS_UID:-$(layout_value STATUS_UID)}}"
STATUS_RUN_UID="${STATUS_RUN_UID:-1000}"
STATUS_RUN_GID="${VERIFY_STATUS_GID:-${DOCKER_GID:-$(layout_value DOCKER_GID)}}"
STATUS_RUN_GID="${STATUS_RUN_GID:-$(getent group docker 2>/dev/null | cut -d: -f3 || true)}"
STATUS_RUN_GID="${STATUS_RUN_GID:-999}"
BACKUP_REQUIRED=false
[[ "$BACKUP_MODE" == system || "$BACKUP_POLICY" == required ]] && BACKUP_REQUIRED=true
for gate in backup_log backup_readability backup_tile; do
  record_gate "$gate" "$BACKUP_REQUIRED" SKIPPED "not reached"
done
if [[ "$BACKUP_MODE" != system && "$BACKUP_MODE" != user ]] \
   || [[ "$BACKUP_POLICY" != required && "$BACKUP_POLICY" != optional ]]; then
  printf 'FAIL: invalid backup mode or verification policy\n'
  exit 1
fi

# True when the log holds at least one success line, read as the caller (root in
# the transient unit). Used only to decide whether a `warn` tile contradicts the
# writer; a read failure here is "unknown", never "no success".
log_has_success() { # <path>
  grep -q 'event=backup_success' "$1" 2>/dev/null
}

# Probe readability as the status container's identity. Sets B_READ_STATE to
# readable | unreadable | skipped. A root read is NEVER reported as readable.
B_READ_STATE=""
probe_read_as_status() { # <path> <supplementary-gid>
  local path="$1" gid="$2"
  CURRENT_GATE=backup_readability
  B_READ_STATE="skipped"
  if [[ "$(id -u)" != "0" ]]; then
    gate_skip "not root: cannot drop privileges to the status container's identity; readability not proven by this run"
    return 0
  fi
  if ! command -v setpriv >/dev/null 2>&1; then
    gate_skip "setpriv is unavailable: readability as the status identity not proven"
    return 0
  fi
  if [[ ! "$gid" =~ ^[0-9]+$ || ! "$STATUS_RUN_UID" =~ ^[0-9]+$ || ! "$STATUS_RUN_GID" =~ ^[0-9]+$ ]]; then
    gate_skip "BACKUP_GROUP_GID is not a numeric gid: readability as the status identity not proven"
    return 0
  fi
  if setpriv --reuid="$STATUS_RUN_UID" --regid="$STATUS_RUN_GID" \
       --groups="$gid" --inh-caps=-all --bounding-set=-all -- \
       test -r "$path" 2>/dev/null; then
    B_READ_STATE="readable"
    record_gate backup_readability "$BACKUP_REQUIRED" PASS "readable as status identity"
  else
    B_READ_STATE="unreadable"
    record_gate backup_readability "$BACKUP_REQUIRED" FAIL "status identity cannot read backup log"
  fi
  return 0
}

# Query only the Backups state on the private status-owned Unix socket.
# No Caddy redirects, session credentials, TCP listener or Docker API access.
B_TILE=""
probe_tile() {
  local socket_dir="${DATA_DIR}/status-verifier" socket_path body code
  socket_path="${socket_dir}/backup.sock"
  B_TILE=""
  CURRENT_GATE=backup_tile
  if [[ "$DATA_DIR" != /* || -L "$socket_dir" || -L "$socket_path" ]] \
     || [[ ! -d "$socket_dir" || ! -S "$socket_path" ]] \
     || [[ "$(stat -c '%a:%u' "$socket_dir" 2>/dev/null)" != "700:${STATUS_RUN_UID}" ]] \
     || [[ "$(stat -c '%a:%u' "$socket_path" 2>/dev/null)" != "600:${STATUS_RUN_UID}" ]]; then
    gate_skip "the private Backups socket is missing or has unsafe ownership or permissions"
    return 0
  fi
  body="$(mktemp)"
  if ! code="$(curl -q -sS --max-time 10 --max-filesize 4096 -A "$USER_AGENT" \
      --noproxy '*' --unix-socket "$socket_path" \
      -o "$body" -w '%{http_code}' "http://localhost/backup" 2>/dev/null)" \
      || [[ "$code" != 200 ]]; then
    rm -f -- "$body"
    gate_skip "the private Backups socket did not return HTTP 200"
    return 0
  fi
  B_TILE="$(jq -er 'select(type == "object" and keys == ["name", "state"]
    and .name == "Backups" and (.state == "ok" or .state == "warn" or .state == "fail"))
    | .state' "$body" 2>/dev/null)" || B_TILE=""
  rm -f -- "$body"
  if [[ -z "$B_TILE" ]]; then
    gate_skip "the private Backups socket returned an invalid tile response"
  fi
}

# Returns 1 and fills GATE_REASON when the release leaves the tile blind while
# the writer's log reports success.
check_backup_tile() {
  local log gid log_dir
  CURRENT_GATE=backup_log
  log="${BACKUP_LOG:-$(layout_value BACKUP_LOG)}"
  if [[ -z "$log" ]]; then
    if [[ "$BACKUP_MODE" == system ]]; then
      log=/var/log/hybrid-ai-backup/backup.log
    else
      log_dir="${HYBRID_AI_LOG_DIR:-$(layout_value HYBRID_AI_LOG_DIR)}"
      [[ -z "$log_dir" ]] || log="${log_dir}/backup.log"
    fi
  fi
  gid="${BACKUP_GROUP_GID:-$(layout_value BACKUP_GROUP_GID)}"
  if [[ -z "$gid" && "$BACKUP_MODE" == system ]]; then
    gid="$(getent group hybrid-ai-backup 2>/dev/null | cut -d: -f3 || true)"
  fi

  GATE_REASON=""
  if [[ -z "$log" ]]; then
    gate_skip "BACKUP_LOG is not set: the backup log was not checked"
    return 0
  fi
  if [[ ! -f "$log" || ! -s "$log" ]]; then
    GATE_REASON="the backup log is not a regular, non-empty file"
    record_gate backup_log "$BACKUP_REQUIRED" FAIL "$GATE_REASON"
    return 1
  fi
  record_gate backup_log "$BACKUP_REQUIRED" PASS "regular non-empty backup log"
  probe_read_as_status "$log" "$gid"
  if [[ "$B_READ_STATE" == "unreadable" ]]; then
    GATE_REASON="the status container's identity cannot read the backup log"
    return 1
  fi
  probe_tile
  if [[ "$B_TILE" == "warn" ]] && log_has_success "$log"; then
    GATE_REASON="the backup log records event=backup_success but the Backups tile reports warn"
    record_gate backup_tile "$BACKUP_REQUIRED" FAIL "$GATE_REASON"
    return 1
  fi
  case "$B_TILE" in
    ok) record_gate backup_tile "$BACKUP_REQUIRED" PASS "Backups tile reports ok" ;;
    warn) record_gate backup_tile "$BACKUP_REQUIRED" WARN "Backups tile reports warn" ;;
    fail) GATE_REASON="Backups tile reports fail"
      record_gate backup_tile "$BACKUP_REQUIRED" FAIL "$GATE_REASON"; return 1 ;;
    "") ;; # probe_tile already recorded why it was skipped
    *) record_gate backup_tile "$BACKUP_REQUIRED" SKIPPED "Backups tile state is invalid" ;;
  esac
  return 0
}

BODY_FILE="$(mktemp)"
ERR_FILE="$(mktemp)"
trap 'rm -f -- "$BODY_FILE" "$ERR_FILE"' EXIT

# Filled by probe_runs(). Kept as globals so the caller can print the exact
# run ids and conclusions in one FAIL line.
PROBE_STATE=""
PROBE_ERROR=""
RUN_IDS=()
RUN_STATUS=()
RUN_CONCLUSION=()

# Ask the API once. Always returns 0; the outcome is in PROBE_STATE.
#   completed  at least one run, every run completed
#   pending    no run yet, or a run still in progress
#   error      the API, the network or the body was unusable
# Never sends an Authorization header: the request is anonymous on purpose.
probe_runs() {
  local http_code rows id status conclusion

  PROBE_STATE="pending"
  PROBE_ERROR=""
  RUN_IDS=(); RUN_STATUS=(); RUN_CONCLUSION=()

  if ! http_code="$(curl -sS --max-time 20 -A "$USER_AGENT" \
        -o "$BODY_FILE" -w '%{http_code}' "$API_URL" 2>"$ERR_FILE")"; then
    PROBE_STATE="error"
    PROBE_ERROR="curl could not reach the github api"
    return 0
  fi

  case "$http_code" in
    2*) ;;
    *)
      PROBE_STATE="error"
      PROBE_ERROR="github api returned HTTP ${http_code}"
      return 0
      ;;
  esac

  if ! jq -e 'has("workflow_runs")' "$BODY_FILE" >/dev/null 2>&1; then
    PROBE_STATE="error"
    PROBE_ERROR="github api returned a body that jq could not parse"
    return 0
  fi

  if ! rows="$(jq -r '.workflow_runs[] | "\(.id)\t\(.status)\t\(.conclusion // "")"' \
        "$BODY_FILE" 2>/dev/null)"; then
    PROBE_STATE="error"
    PROBE_ERROR="github api returned a body that jq could not parse"
    return 0
  fi

  while IFS=$'\t' read -r id status conclusion; do
    [[ -n "$id" ]] || continue
    RUN_IDS+=("$id")
    RUN_STATUS+=("$status")
    RUN_CONCLUSION+=("$conclusion")
  done <<<"$rows"

  # Zero runs is NOT "completed": the run may not exist for a few seconds after
  # the deploy starts the check.
  (( ${#RUN_IDS[@]} > 0 )) || return 0

  local s
  for s in "${RUN_STATUS[@]}"; do
    [[ "$s" == "completed" ]] || return 0
  done
  PROBE_STATE="completed"
  return 0
}

# Which conclusions a completed set carries, as one comma-separated word list.
conclusion_list() {
  local out="" i
  for i in "${!RUN_CONCLUSION[@]}"; do
    [[ -n "$out" ]] && out+=","
    out+="${RUN_CONCLUSION[$i]:-none}"
  done
  printf '%s' "$out"
}


START_TS="$(date +%s)"
while :; do
  probe_runs

  case "$PROBE_STATE" in
    error)
      record_gate workflow_runs true FAIL "$PROBE_ERROR"
      finish FAIL 1 "$PROBE_ERROR"
      ;;
    completed)
      all_success=1
      idx=0
      while (( idx < ${#RUN_CONCLUSION[@]} )); do
        [[ "${RUN_CONCLUSION[$idx]}" == "success" ]] || all_success=0
        idx=$(( idx + 1 ))
      done
      unset idx

      if (( ! all_success )); then
        record_gate workflow_runs true FAIL "one or more workflow conclusions were not success"
        if (( ${#RUN_IDS[@]} == 1 )); then
          finish FAIL 1 "run ${RUN_IDS[0]} conclusion ${RUN_CONCLUSION[0]:-none}"
        fi
        finish FAIL 1 "run conclusions: $(conclusion_list)"
      fi

      record_gate workflow_runs true PASS "all returned workflow runs succeeded"
      # The workflow is green. Now prove the host is actually on that commit.
      record_gate deployed_head true FAIL "deployed HEAD unreadable or mismatched"
      deployed_head=""
      if ! deployed_head="$(git -C "$APP_DIR" rev-parse HEAD 2>/dev/null)"; then
        finish FAIL 1 "cannot read HEAD of the deployed tree at ${APP_DIR} (expected ${SHA})"
      fi
      if [[ -z "$deployed_head" ]]; then
        finish FAIL 1 "cannot read HEAD of the deployed tree at ${APP_DIR} (expected ${SHA})"
      fi
      if [[ "${deployed_head,,}" != "${SHA,,}" ]]; then
        finish FAIL 1 "deployed tree is on ${deployed_head}, expected ${SHA}"
      fi

      record_gate deployed_head true PASS "deployed HEAD matches requested SHA"
      # The tree is right. Record backup coverage before aggregating policy.
      if ! check_backup_tile; then
        finish FAIL 1 "${GATE_REASON}"
      fi

      finish PASS 0
      ;;
  esac

  if (( $(date +%s) - START_TS >= DEADLINE_SECONDS )); then
    record_gate workflow_runs true FAIL "workflow wait timed out"
    finish TIMEOUT 1 "no completed run for ${SHA} after $(( DEADLINE_SECONDS / 60 )) minutes"
  fi

  sleep "$POLL_SECONDS"
done
