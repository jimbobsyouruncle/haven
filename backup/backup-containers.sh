#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: backup/backup-containers.sh
# PURPOSE (plain English):
#   The ONLY part of a system-mode backup that is allowed to talk to Docker.
#   It is run as root (systemd's leading "+" on an Exec line drops every
#   sandbox restriction for that one command) by the capture unit's
#   ExecStartPre/ExecStopPost, and it does exactly three fixed things:
#
#     pause      pause the app containers that write durable state, and record
#                which ones were paused
#     unpause    unpause them again (idempotent; succeeds when nothing is
#                paused)
#     host-info  collect the host facts the capture cannot: docker's version
#                and the local model list
#
# WHY IT EXISTS -- THE PRIVILEGE SPLIT:
#   The capture unit runs as the unprivileged haven-backup account with a
#   single capability (CAP_DAC_READ_SEARCH) so it can read the container-owned
#   data, and with PrivateNetwork=yes and the docker socket made inaccessible,
#   so it holds no network and no docker access. The upload unit holds the R2
#   credentials but no read privilege. Neither unit may do the other's job.
#   A tiny, fixed, root-owned helper bridges exactly the one gap: pausing the
#   containers for a point-in-time capture and reading docker's own facts.
#
# WHAT IT WILL NOT DO:
#   * It never STARTs or STOPs a container -- only pause and unpause. Stopping
#     hermes-agent kills in-flight agent sessions (incident B1, 2026-10-15);
#     a pause is a SIGSTOP with no restart.
#   * It takes NO path and NO container name from its arguments. The only
#     argument it accepts is the verb above; the container list is the fixed
#     APP_CONTAINERS set below.
#   * It writes ONLY under /run/haven-backup-control (a root-owned runtime dir).
#   * It refuses to run as a non-root account.
#
# USAGE:
#   backup/backup-containers.sh pause
#   backup/backup-containers.sh unpause
#   backup/backup-containers.sh host-info
#
# EXIT CODES:
#   0  the verb did its work
#   1  not root, or the runtime directory could not be prepared
#   2  usage error (a missing or unknown verb)
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Every host path comes from the ONE shared helper, exactly as backup.sh does.
# shellcheck source=scripts/lib/haven-env.sh
source "${SCRIPT_DIR}/../scripts/lib/haven-env.sh"

# A direct child of the root-owned /run. The systemd RuntimeDirectory is
# writable by the service account and must never be used for root output.
CONTROL_RUN_DIR=/run/haven-backup-control
CONTROL_GROUP=haven-backup
umask 027

# The FIXED list of containers that write durable state. It is the same
# APP_CONTAINERS set backup.sh uses; nothing here is ever taken from an argument.
APP_CONTAINERS=(open-webui hermes-agent)

# Every compose file, so 'config --images' reports the full stack, matching the
# way backup.sh and doctor.sh render it.
COMPOSE=(docker compose -p haven --env-file "$HAVEN_STACK_ENV_FILE"
         --project-directory "$HAVEN_APP_DIR"
         -f "$HAVEN_APP_DIR/docker-compose.yml"
         -f "$HAVEN_APP_DIR/openhands/docker-compose.openhands.yml"
         -f "$HAVEN_APP_DIR/hermes/docker-compose.hermes.yml")

log() { printf '[ * ] %s\n' "$*"; }

die() { printf '[ X ] %s\n' "$*" >&2; exit 1; }

is_running() { [[ "$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null)" == "running" ]]; }

# Only accept a directory whose owner alone can write. Validate before making
# any changes, and never follow a symlink or re-own an existing directory.
trusted_run_dir() {
  [[ ! -L "$CONTROL_RUN_DIR" && -d "$CONTROL_RUN_DIR" ]] || return 1
  case "$(stat -c '%u:%a' -- "$CONTROL_RUN_DIR")" in
    0:700|0:2750) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_run_dir() {
  if [[ ! -e "$CONTROL_RUN_DIR" && ! -L "$CONTROL_RUN_DIR" ]]; then
    mkdir -m 0700 -- "$CONTROL_RUN_DIR"
  fi
  trusted_run_dir || die "Unsafe backup control directory."
  chgrp --no-dereference -- "$CONTROL_GROUP" "$CONTROL_RUN_DIR"
  chmod 2750 -- "$CONTROL_RUN_DIR"
}

# An empty record tells capture to use SQLite's online backup. During this
# pre-start command the record also tells ExecStopPost whether a pause was
# attempted, including when systemd interrupts an in-flight Docker command.
cmd_pause() {
  ensure_run_dir
  local paused_file="${CONTROL_RUN_DIR}/paused" c
  if [[ ! -L "$paused_file" && -f "$paused_file" && -s "$paused_file" ]]; then
    resume_apps
  fi
  rm -f -- "$paused_file"
  : > "$paused_file"
  if [[ "${BACKUP_NO_PAUSE:-0}" == "1" ]]; then
    log "Container pause disabled by BACKUP_NO_PAUSE=1."
    return 0
  fi
  for c in "${APP_CONTAINERS[@]}"; do
    if ! is_running "$c"; then
      log "Cannot confirm ${c} is running (missing, stopped, or Docker inspection failed)."
      return 0
    fi
  done
  for c in "${APP_CONTAINERS[@]}"; do
    printf '%s\n' "$c" >> "$paused_file"
    if ! docker pause "$c" >/dev/null 2>&1; then
      log "Docker pause failed for ${c}."
      resume_apps
      : > "$paused_file"
      return 0
    fi
  done
}

# A failed unpause is normal for a stopped or missing container. If Docker
# reports an error, confirm that no app container is still paused.
resume_apps() {
  local c paused failed=0
  for c in "${APP_CONTAINERS[@]}"; do
    docker unpause "$c" >/dev/null 2>&1 || failed=1
  done
  (( failed )) || return 0
  paused="$(docker ps --filter status=paused --format '{{.Names}}' 2>/dev/null)" \
    || die "Could not verify that app containers resumed."
  for c in "${APP_CONTAINERS[@]}"; do
    if grep -qxF -- "$c" <<< "$paused"; then
      die "Could not resume ${c}. Run: docker unpause ${c}"
    fi
  done
}

cmd_unpause() {
  local paused_file="${CONTROL_RUN_DIR}/paused"
  # An empty, trusted record means there was no pause to undo. In particular,
  # a Docker outage that prevented pausing must still permit online upload.
  # With no usable record, attempt recovery directly through Docker.
  if ! trusted_run_dir || [[ -L "$paused_file" || ! -f "$paused_file" || -s "$paused_file" ]]; then
    resume_apps
  fi
  if trusted_run_dir; then
    rm -f -- "$paused_file"
    rm -rf -- "${CONTROL_RUN_DIR}/host-info"
  fi
}

# host-info: collect the facts the capture unit cannot gather without docker.
# Only docker's server version, the local model names, and the rendered image
# list -- never a secret, never a data-tree path.
cmd_host_info() {
  ensure_run_dir
  local out="${CONTROL_RUN_DIR}/host-info"
  # Start with fresh entries under a directory the service account cannot
  # modify. rm removes a symlink itself, and mkdir creates a new directory.
  rm -rf -- "$out"
  mkdir -- "$out"

  if command -v docker >/dev/null 2>&1; then
    printf '%s\n' "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo n/a)" \
      > "${out}/platform-docker.txt" 2>/dev/null || true
  else
    printf 'n/a\n' > "${out}/platform-docker.txt" 2>/dev/null || true
  fi

  if is_running ollama; then
    docker exec ollama ollama list 2>/dev/null \
      | awk 'NR>1 {print $1}' > "${out}/ollama-models.txt" || true
    mkdir -p "${out}/modelfiles"
    local m safe
    while IFS= read -r m; do
      [[ -z "$m" ]] && continue
      safe="${m//[^A-Za-z0-9._-]/_}"
      docker exec ollama ollama show --modelfile "$m" \
        > "${out}/modelfiles/${safe}.Modelfile" 2>/dev/null || true
    done < "${out}/ollama-models.txt"
  fi

  if [[ -f "${HAVEN_ENV_FILE}" ]]; then
    "${COMPOSE[@]}" config --images > "${out}/container-images.txt" 2>/dev/null || true
  fi
  return 0
}

if (( $# != 1 )); then
  printf 'usage: %s pause|unpause|host-info\n' "${0##*/}" >&2
  exit 2
fi

[[ "$(id -u)" == "0" ]] || die "This helper modifies container state and must run as root."

case "$1" in
  pause)     cmd_pause ;;
  unpause)   cmd_unpause ;;
  host-info) cmd_host_info ;;
  *)         printf 'usage: %s pause|unpause|host-info\n' "${0##*/}" >&2; exit 2 ;;
esac
