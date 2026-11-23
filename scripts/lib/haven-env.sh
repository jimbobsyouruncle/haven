#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/lib/haven-env.sh
# PURPOSE (plain English):
#   The ONE place that works out where this project keeps its files on the
#   host. Source it; do not run it.
#
#   It resolves a small set of NAMED settings and exports them, so every
#   script and every compose call agrees on the same paths:
#
#     HAVEN_APP_DIR   the program/repository directory (default: repo dir)
#     HAVEN_ENV_FILE  the env file           (default: $HAVEN_APP_DIR/.env)
#     HAVEN_DATA_DIR  durable data           (default: repo dir)
#     HAVEN_LOG_DIR   logs                    (default: repo dir)
#     HAVEN_WORK_DIR  scratch/work            (default: repo dir)
#
#   HAVEN_ENV_FILE resolution has ONE bootstrap fallback. When the setting
#   is UNSET and the primary candidate ($HAVEN_APP_DIR/.env) does NOT exist,
#   but a fallback layout file DOES exist, the fallback is used. The fallback
#   location is a NAMED environment variable:
#
#     HAVEN_ENV_FILE_FALLBACK   (default: /etc/haven/haven.env)
#
#   The default is the LAYOUT file scripts/bootstrap.sh writes on a bootstrapped
#   host (mode 0644, paths and names only). The fallback is the LAYOUT file and
#   never the 0600 stack file. An explicit HAVEN_ENV_FILE always wins and the
#   fallback is then never consulted; an existing $HAVEN_APP_DIR/.env always
#   wins over the fallback. Set HAVEN_ENV_FILE_FALLBACK to relocate the probe
#   (tests use a fixture, so they never touch /etc).
#
#   HAVEN_ENV_FILE is the LAYOUT file: it holds paths and names only, never
#   a secret. HAVEN_STACK_ENV_FILE is the file every --env-file consumer
#   hands to `docker compose`; it holds the stack's secrets. On a host with no
#   bootstrap, the two are the same file, so every resolved path and command
#   line is unchanged. After scripts/bootstrap.sh they differ:
#   HAVEN_ENV_FILE=/etc/haven/haven.env (0644) and
#   HAVEN_STACK_ENV_FILE=/etc/haven/stack.env (0600). install.sh writes
#   ONLY the stack file, so a deploy can never erase the layout.
#
#   It also resolves the settings that already existed, with the SAME names and
#   the SAME defaults as before, so a host that sets none of them keeps exactly
#   the paths it has today:
#
#     HAVEN_UID, HAVEN_GID, OPENHANDS_WORKSPACE, AGENT_REPOS_DIR,
#     OPENHANDS_STATE_DIR, BACKUP_CONF_DIR, RESTIC_CACHE_DIR, BACKUP_LOG
#
#   Two INTERNAL settings name the post-deploy verifier and its log, so the
#   deploy hook, install.sh and doctor.sh cannot disagree about either path:
#
#     HAVEN_POST_DEPLOY_VERIFY_CMD  default /usr/local/sbin/run-post-deploy-verify.sh
#     HAVEN_POST_DEPLOY_VERIFY_LOG  default /var/log/haven-post-deploy-verify.log
#
#   They are TEST SEAMS, not documented settings: no .env.example entry and no
#   install.sh template entry. With nothing set they resolve byte-identically to
#   the paths that used to be hardcoded.
#
#   With NO settings, every resolved path equals today's, byte for byte.
#
# RESOLUTION ORDER (per setting):
#   1. the process environment   (an exported variable)
#   2. the env file, parsed LINE BY LINE -- never sourced
#   3. the built-in default
#
# WHY PARSE AND NEVER SOURCE:
#   `source` executes the file as shell code, so a value containing $(...) or
#   backticks would run as a command. The parser here only reads KEY=VALUE
#   lines; the value is treated as DATA, never as code.
#
# SAFETY RULES (a SET value -- from the environment or the env file):
#   * must be an absolute path (a relative path is refused)
#   * must not contain whitespace, a control character, ':' or ','
#   * must not be '/' itself
#   A refused value prints a clear message and the helper exits non-zero, so a
#   strict caller (set -e) stops before it touches a wrong path.
#
# SECURITY: this file never prints a value from the env file. It only puts
#   values into exports. Keep it that way.
# ---------------------------------------------------------------------------

# BEGIN Haven environment compatibility
# Transitional process aliases for installed controls. Values are data; diagnostics
# name keys only. Keep this block identical in the standalone verifier.
_HAVEN_ALIAS_SUFFIXES=( AGENT_CONTEXT_GENERATOR ALERT_WEBHOOK_URL APP_DIR AUTH_COOKIE_MAX_AGE AUTH_COOKIE_SECRET AUTH_HASH
  AUTH_RATE_LIMIT AUTH_RATE_WINDOW AUTH_USER BACKUP_CHECK_TIMER_UNIT BACKUP_CRED_DIR BACKUP_JOURNAL_SCOPE
  BACKUP_MODE BACKUP_SERVICE_UNIT BACKUP_STAGING_DIR BACKUP_SYSTEMCTL_SCOPE BACKUP_TIMER_UNIT BOOTSTRAP_ROOT
  BUILD_CACHE_CAP CADDY_CERT_ROOT CADDY_DATA_DIR DATA_DIR DEFAULT_REPO_DIR DEPLOY_LOCK_FILE
  DEPLOY_PUBLIC_REMOTE DEPLOY_VERDICT_DIR DRY_RUN ENV_FILE ENV_FILE_FALLBACK ENV_FILE_FALLBACK_DEFAULT
  EXPLICIT_SETTINGS GID HERMES_DATA_DIR HERMES_HOME_DIR INSTALL_LOG INSTALL_ROOT_HANDOFF
  LAYOUT_AGENT_REPOS_DIR LAYOUT_GID LAYOUT_OPENHANDS_STATE_DIR LAYOUT_OPENHANDS_WORKSPACE LAYOUT_UID LIB
  LIB_DIR LOG_DIR OLLAMA_DATA_DIR POLKIT_RULES_DIR POST_DEPLOY_VERIFY_CMD POST_DEPLOY_VERIFY_LOG
  PRUNE_AGE_SECONDS PRUNE_ALLOW_LEASE_LESS PRUNE_GRACE_SECONDS PRUNE_MAX_MOVES PRUNE_QUARANTINE_BASE PRUNE_QUARANTINE_RETENTION_DAYS
  REPOSITORY_SLUG RESTORE_WORK_DIR SBIN_DIR STACK_ENV_FILE SYSTEMD_UNIT_DIR TLS_TOKEN_FILE
  UID UNINSTALL_ROOT VERIFY_BACKUP_GATES VERIFY_INSTALL_ROOT WEBUI_DATA_DIR WEBUI_TARGET_ID
  WORK_DIR )
for _haven_import_suffix in "${_HAVEN_ALIAS_SUFFIXES[@]}"; do
  _haven_import_canonical="HAVEN_${_haven_import_suffix}"
  _haven_import_legacy="HYBRID_AI_${_haven_import_suffix}"
  if [[ -v "$_haven_import_canonical" && -v "$_haven_import_legacy" && "${!_haven_import_canonical}" != "${!_haven_import_legacy}" ]]; then
    printf 'haven-env: conflicting aliases for %s; refusing configuration\n' "$_haven_import_canonical" >&2
    exit 2
  fi
  if [[ ! -v "$_haven_import_canonical" && -v "$_haven_import_legacy" ]]; then
    printf -v "$_haven_import_canonical" '%s' "${!_haven_import_legacy}"
    export "${_haven_import_canonical?}"
  fi
done
unset _haven_import_suffix _haven_import_canonical _haven_import_legacy
# END Haven environment compatibility

haven_key() {
  case "$1" in
    HYBRID_AI_AGENT_CONTEXT_GENERATOR|HYBRID_AI_ALERT_WEBHOOK_URL|HYBRID_AI_APP_DIR|HYBRID_AI_AUTH_COOKIE_MAX_AGE|\
    HYBRID_AI_AUTH_COOKIE_SECRET|HYBRID_AI_AUTH_HASH|HYBRID_AI_AUTH_RATE_LIMIT|HYBRID_AI_AUTH_RATE_WINDOW|\
    HYBRID_AI_AUTH_USER|HYBRID_AI_BACKUP_CHECK_TIMER_UNIT|HYBRID_AI_BACKUP_CRED_DIR|HYBRID_AI_BACKUP_JOURNAL_SCOPE|\
    HYBRID_AI_BACKUP_MODE|HYBRID_AI_BACKUP_SERVICE_UNIT|HYBRID_AI_BACKUP_STAGING_DIR|HYBRID_AI_BACKUP_SYSTEMCTL_SCOPE|\
    HYBRID_AI_BACKUP_TIMER_UNIT|HYBRID_AI_BOOTSTRAP_ROOT|HYBRID_AI_BUILD_CACHE_CAP|HYBRID_AI_CADDY_CERT_ROOT|\
    HYBRID_AI_CADDY_DATA_DIR|HYBRID_AI_DATA_DIR|HYBRID_AI_DEFAULT_REPO_DIR|HYBRID_AI_DEPLOY_LOCK_FILE|\
    HYBRID_AI_DEPLOY_PUBLIC_REMOTE|HYBRID_AI_DEPLOY_VERDICT_DIR|HYBRID_AI_DRY_RUN|HYBRID_AI_ENV_FILE|\
    HYBRID_AI_ENV_FILE_FALLBACK|HYBRID_AI_ENV_FILE_FALLBACK_DEFAULT|HYBRID_AI_EXPLICIT_SETTINGS|HYBRID_AI_GID|\
    HYBRID_AI_HERMES_DATA_DIR|HYBRID_AI_HERMES_HOME_DIR|HYBRID_AI_INSTALL_LOG|HYBRID_AI_INSTALL_ROOT_HANDOFF|\
    HYBRID_AI_LAYOUT_AGENT_REPOS_DIR|HYBRID_AI_LAYOUT_GID|HYBRID_AI_LAYOUT_OPENHANDS_STATE_DIR|HYBRID_AI_LAYOUT_OPENHANDS_WORKSPACE|\
    HYBRID_AI_LAYOUT_UID|HYBRID_AI_LIB|HYBRID_AI_LIB_DIR|HYBRID_AI_LOG_DIR|\
    HYBRID_AI_OLLAMA_DATA_DIR|HYBRID_AI_POLKIT_RULES_DIR|HYBRID_AI_POST_DEPLOY_VERIFY_CMD|HYBRID_AI_POST_DEPLOY_VERIFY_LOG|\
    HYBRID_AI_PRUNE_AGE_SECONDS|HYBRID_AI_PRUNE_ALLOW_LEASE_LESS|HYBRID_AI_PRUNE_GRACE_SECONDS|HYBRID_AI_PRUNE_MAX_MOVES|\
    HYBRID_AI_PRUNE_QUARANTINE_BASE|HYBRID_AI_PRUNE_QUARANTINE_RETENTION_DAYS|HYBRID_AI_REPOSITORY_SLUG|HYBRID_AI_RESTORE_WORK_DIR|\
    HYBRID_AI_SBIN_DIR|HYBRID_AI_STACK_ENV_FILE|HYBRID_AI_SYSTEMD_UNIT_DIR|HYBRID_AI_TLS_TOKEN_FILE|\
    HYBRID_AI_UID|HYBRID_AI_UNINSTALL_ROOT|HYBRID_AI_VERIFY_BACKUP_GATES|HYBRID_AI_VERIFY_INSTALL_ROOT|\
    HYBRID_AI_WEBUI_DATA_DIR|HYBRID_AI_WEBUI_TARGET_ID|HYBRID_AI_WORK_DIR) printf 'HAVEN_%s' "${1#HYBRID_AI_}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# --- Where is the repository? (this file lives at <repo>/scripts/lib/) ------
_HAVEN_ENV_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HAVEN_DEFAULT_REPO_DIR="$(cd -- "${_HAVEN_ENV_LIB_DIR}/../.." && pwd)"

# --- Small helpers ----------------------------------------------------------

# Print the canonical form of a path. realpath -m does not require the path to
# exist yet (staging/restore directories usually do not), and it collapses
# ".." textually as well as resolving symlinks on the parts that do exist.
_haven_canon() {
  local p
  p="$(realpath -m -- "$1" 2>/dev/null)" || p="$1"
  printf '%s' "$p"
}

# Expand a leading ~ by hand. A value read from a file is not tilde-expanded by
# the shell, and mounting a literal "~/data" directory is a confusing failure.
_haven_expand_tilde() {
  # Match a literal "~" on purpose: a value read from a file is not expanded.
  # shellcheck disable=SC2088
  case "$1" in
    "~/"*) printf '%s' "${HOME:-}/${1#\~/}" ;;
    "~")   printf '%s' "${HOME:-}" ;;
    *)     printf '%s' "$1" ;;
  esac
}

# Read ONE key from a file, line by line, never sourcing. Returns the LAST
# match (last wins), matching install.sh's loader. Quotes are stripped.
#
# FAIL CLOSED: when the file EXISTS but this process cannot read it, the helper
# must not silently fall back to the built-in defaults -- a non-root unit that
# cannot read the env file would then act on the wrong paths. It names the
# CALLER-SUPPLIED setting (never a value) and returns 1. A file that simply does
# not exist is not an error: the defaults are the correct answer there.
_haven_file_unreadable() {
  local name="$1" file="$2"
  printf 'haven-env: %s is set to %s, but that file exists and cannot be read.\n' \
    "$name" "$file" >&2
  printf 'haven-env: refusing to fall back to the built-in defaults.\n' >&2
}
# Read ONE key from a file, line by line, never sourcing. Returns the LAST
# match (last wins), matching install.sh's loader. Quotes are stripped.
_haven_file_get() {
  local file="$1" key="$2" line candidate="" old_candidate="" raw
  local seen=0 old_seen=0 legacy=""
  [[ -f "$file" ]] || return 0
  [[ -r "$file" ]] || {
    _haven_file_unreadable "${_HAVEN_FILE_SETTING:-HAVEN_ENV_FILE}" "$file"
    return 1
  }
  [[ "$key" != HAVEN_* ]] || legacy="HYBRID_AI_${key#HAVEN_}"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    raw="${BASH_REMATCH[2]}"
    raw="${raw%\"}"; raw="${raw#\"}"
    raw="${raw%\'}"; raw="${raw#\'}"
    if [[ "${BASH_REMATCH[1]}" == "$key" ]]; then
      candidate="$raw"; seen=1
    elif [[ -n "$legacy" && "${BASH_REMATCH[1]}" == "$legacy" ]]; then
      old_candidate="$raw"; old_seen=1
    fi
  done < "$file"
  if (( seen && old_seen )) && [[ "$candidate" != "$old_candidate" ]]; then
    printf 'haven-env: conflicting aliases for %s; refusing configuration\n' "$key" >&2
    return 2
  fi
  if (( seen )); then printf '%s' "$candidate"; else printf '%s' "$old_candidate"; fi
}

# Fail closed on an env file that exists but this process cannot read. Names the
# CALLER-SUPPLIED setting and the path -- never a value. A file that does not
# exist is not an error: the built-in defaults are then the right answer.
_haven_file_require_readable() {
  local name="$1" file="$2"
  [[ -f "$file" ]] || return 0
  [[ -r "$file" ]] || { _haven_file_unreadable "$name" "$file"; return 1; }
  return 0
}

# Refuse a value that is not a usable absolute path. Prints a clear message and
# returns 1. The message names the SETTING and the reason -- never a value that
# came from the env file (the reason is enough to fix it).
_haven_validate_path() {
  local name="$1" val="$2"
  if [[ -z "$val" ]]; then
    printf 'haven-env: %s is empty; give an absolute path or leave it unset.\n' "$name" >&2
    return 1
  fi
  if [[ "$val" == "/" ]]; then
    printf 'haven-env: %s must not be "/".\n' "$name" >&2
    return 1
  fi
  case "$val" in
    *[[:cntrl:]]*)
      printf 'haven-env: %s contains a control character.\n' "$name" >&2
      return 1 ;;
    *[[:space:]]*)
      printf 'haven-env: %s contains whitespace.\n' "$name" >&2
      return 1 ;;
    *:*|*,*)
      printf 'haven-env: %s contains ":" or ",", which is not allowed in a path here.\n' "$name" >&2
      return 1 ;;
  esac
  case "$val" in
    /*) ;;
    *)
      printf 'haven-env: %s must be an absolute path.\n' "$name" >&2
      return 1 ;;
  esac
  return 0
}

# Resolve one PATH setting: environment, then env file, then default.
# Sets the variable named by $1. Set values are validated; defaults are used
# as-is (they are trusted, built-in absolute paths).
_haven_resolve_path() {
  local name="$1" default="$2" envfile="$3" val origin
  val="${!name:-}"
  if [[ -n "$val" ]]; then
    origin="environment"
  else
    val="$(_haven_file_get "$envfile" "$name")" || return 1
    if [[ -n "$val" ]]; then origin="env file"; else origin="default"; fi
  fi
  if [[ "$origin" == "default" ]]; then
    val="$default"
  else
    val="$(_haven_expand_tilde "$val")"
    if ! _haven_validate_path "$name" "$val"; then
      printf 'haven-env: refused the %s value for %s.\n' "$origin" "$name" >&2
      return 1
    fi
    # Remember that this setting was SET (so doctor.sh can warn, and only warn,
    # about a set path that does not exist yet).
    HAVEN_EXPLICIT_SETTINGS="${HAVEN_EXPLICIT_SETTINGS:-} ${name}"
  fi
  # The provisioner verifies the original data path before touching storage.
  if [[ "$name" == HAVEN_DATA_DIR ]]; then _HAVEN_DATA_DIR_RAW="$val"; fi
  printf -v "$name" '%s' "$(_haven_canon "$val")"
  export "${name?}"
  return 0
}

# Resolve one ENUM setting: environment, then env file, then default. The value
# must be one of the allowed words; any other value is refused (non-zero exit),
# so a typo cannot silently select the wrong behaviour. The message names the
# SETTING and the allowed words -- never the rejected value, which may have come
# from the env file.
_haven_resolve_enum() {
  local name="$1" default="$2" allowed="$3" envfile="$4" val origin a matched
  val="${!name:-}"
  if [[ -n "$val" ]]; then
    origin="environment"
  else
    val="$(_haven_file_get "$envfile" "$name")" || return 1
    if [[ -n "$val" ]]; then origin="env file"; else origin="default"; fi
  fi
  if [[ "$origin" == "default" ]]; then
    val="$default"
  else
    matched=0
    for a in $allowed; do [[ "$val" == "$a" ]] && matched=1; done
    if (( ! matched )); then
      printf 'haven-env: %s must be one of: %s.\n' "$name" "$allowed" >&2
      printf 'haven-env: refused the %s value for %s.\n' "$origin" "$name" >&2
      return 1
    fi
  fi
  printf -v "$name" '%s' "$val"
  export "${name?}"
  return 0
}

# Resolve one NON-path setting (a uid, gid, or other scalar): environment, then
# env file, then default. No path validation is applied.
_haven_resolve_scalar() {
  local name="$1" default="$2" envfile="$3" val
  val="${!name:-}"
  if [[ -z "$val" ]]; then
    val="$(_haven_file_get "$envfile" "$name")" || return 1
  fi
  if [[ -z "$val" ]]; then val="$default"; fi
  printf -v "$name" '%s' "$val"
  export "${name?}"
  return 0
}

# --- Isolation helper shared by every guard --------------------------------
# Print the directory of each env file, one realpath per line: the LAYOUT file
# (HAVEN_ENV_FILE) and the STACK file (HAVEN_STACK_ENV_FILE). A workspace
# or a repo tree that is, contains, or lives inside either directory can read a
# secret or a deployment setting, so both are guarded. Callers do the
# containment test; this only prints paths.
haven_env_dirs() {
  local f d
  for f in "$HAVEN_ENV_FILE" "$HAVEN_STACK_ENV_FILE"; do
    [[ -n "$f" ]] || continue
    d="$(dirname "$(readlink -f "$f" 2>/dev/null || echo "$f")")"
    printf '%s\n' "$d"
  done
}

# The LAYOUT file a bootstrapped host uses when $HAVEN_APP_DIR/.env is
# absent. Overridable so tests (and unusual hosts) can relocate the probe.
HAVEN_ENV_FILE_FALLBACK_DEFAULT="/etc/haven/haven.env"

# --- Resolve everything -----------------------------------------------------
haven_env_load() {
  # Bootstrap: find the env file we will read values from. Prefer an explicit
  # HAVEN_ENV_FILE, then an explicit HAVEN_APP_DIR, then the default
  # repository directory.
  local boot_env boot_env_fallback=""
  if [[ -n "${HAVEN_ENV_FILE:-}" ]]; then
    boot_env="${HAVEN_ENV_FILE}"
  elif [[ -n "${HAVEN_APP_DIR:-}" ]]; then
    boot_env="$(_haven_canon "$HAVEN_APP_DIR")/.env"
  else
    boot_env="${HAVEN_DEFAULT_REPO_DIR}/.env"
  fi

  # Bootstrap FALLBACK (D10): on a bootstrapped host the layout moved to
  # /etc/haven/haven.env, so $APP_DIR/.env legitimately does not exist.
  # When HAVEN_ENV_FILE is UNSET and the primary candidate is absent, but a
  # fallback LAYOUT file exists, probe it. An explicit HAVEN_ENV_FILE always
  # wins and is never overridden; an existing $APP_DIR/.env is never replaced.
  # Only the LAYOUT file is probed here -- never the 0600 stack secrets file.
  if [[ -z "${HAVEN_ENV_FILE:-}" && ! -e "$boot_env" ]]; then
    local fallback="${HAVEN_ENV_FILE_FALLBACK:-$HAVEN_ENV_FILE_FALLBACK_DEFAULT}"
    if [[ -n "$fallback" && -e "$fallback" ]]; then
      boot_env_fallback="$(_haven_canon "$fallback")"
      boot_env="$boot_env_fallback"
    fi
  fi

  # Refuse conflicting aliases in the original bootstrap file before following
  # any APP_DIR/ENV_FILE redirection into another file.
  local _alias_suffix
  for _alias_suffix in "${_HAVEN_ALIAS_SUFFIXES[@]}"; do
    _haven_file_get "$boot_env" "HAVEN_${_alias_suffix}" >/dev/null || return 1
  done

  # APP_DIR: environment, then the bootstrap env file, then the repo dir.
  _haven_resolve_path HAVEN_APP_DIR "$HAVEN_DEFAULT_REPO_DIR" "$boot_env" || return 1

  # ENV_FILE: environment, then the bootstrap env file, then $APP_DIR/.env.
  local env_default="${HAVEN_APP_DIR}/.env"
  # When the fallback is active it IS the layout file, so it is the default the
  # ENV_FILE resolution lands on when neither the environment nor the file names
  # a different path.
  if [[ -n "$boot_env_fallback" ]]; then
    env_default="$boot_env_fallback"
  fi
  if [[ -n "${HAVEN_ENV_FILE:-}" ]]; then
    boot_env="${HAVEN_ENV_FILE}"
  else
    local from_file
    from_file="$(_haven_file_get "$boot_env" HAVEN_ENV_FILE)" || return 1
    if [[ -n "$from_file" ]]; then
      boot_env="$(_haven_expand_tilde "$from_file")"
    else
      boot_env="$env_default"
    fi
  fi
  _haven_resolve_path HAVEN_ENV_FILE "$env_default" "$boot_env" || return 1

  # Fail closed on an unreadable layout file BEFORE deciding anything from it.
  # The setting name is printed, never a value from the file.
  _haven_file_require_readable HAVEN_ENV_FILE "$HAVEN_ENV_FILE" || return 1

  # From here on, read LAYOUT settings from the resolved layout file. Any later
  # read of that file therefore names HAVEN_ENV_FILE when it fails closed.
  for _alias_suffix in "${_HAVEN_ALIAS_SUFFIXES[@]}"; do
    _haven_file_get "$HAVEN_ENV_FILE" "HAVEN_${_alias_suffix}" >/dev/null || return 1
  done
  local ef="$HAVEN_ENV_FILE"
  local repo_default="$HAVEN_DEFAULT_REPO_DIR"
  _HAVEN_FILE_SETTING="HAVEN_ENV_FILE"

  # STACK_ENV_FILE is the file every --env-file consumer hands to compose. It
  # DEFAULTS to the resolved layout file, so with nothing set the stack file and
  # the layout file are the same path and every command line is byte-identical
  # to before this setting existed. scripts/bootstrap.sh points it elsewhere
  # (/etc/haven/stack.env) so the secrets and the layout can move apart.
  #
  # STACK_ENV_FILE may itself be named by the layout file, so it is read with
  # the stack setting's name as the fail-closed label.
  _HAVEN_FILE_SETTING="HAVEN_STACK_ENV_FILE"
  _haven_resolve_path HAVEN_STACK_ENV_FILE "$HAVEN_ENV_FILE" "$ef" || return 1
  _HAVEN_FILE_SETTING="HAVEN_ENV_FILE"
  _haven_file_require_readable HAVEN_STACK_ENV_FILE "$HAVEN_STACK_ENV_FILE" || return 1
  if [[ "$HAVEN_STACK_ENV_FILE" != "$ef" ]]; then
    for _alias_suffix in "${_HAVEN_ALIAS_SUFFIXES[@]}"; do
      _haven_file_get "$HAVEN_STACK_ENV_FILE" "HAVEN_${_alias_suffix}" >/dev/null || return 1
    done
  fi

  _haven_resolve_path HAVEN_DATA_DIR "$repo_default" "$ef" || return 1
  _haven_resolve_path HAVEN_LOG_DIR  "$repo_default" "$ef" || return 1
  _haven_resolve_path HAVEN_WORK_DIR "$repo_default" "$ef" || return 1

  # Kept settings -- same names, same defaults as before this helper existed.
  _haven_resolve_scalar HAVEN_UID "" "$ef" || return 1
  _haven_resolve_scalar HAVEN_GID "" "$ef" || return 1
  _haven_resolve_path OPENHANDS_WORKSPACE "${HOME:-}/haven-agent" "$ef" || return 1
  _haven_resolve_path AGENT_REPOS_DIR     "${HOME:-}/haven-repos" "$ef" || return 1
  _haven_resolve_path OPENHANDS_STATE_DIR "${HOME:-}/.openhands"      "$ef" || return 1
  _haven_resolve_path BACKUP_CONF_DIR     "${HOME:-}/.config/haven-backup" "$ef" || return 1
  _haven_resolve_path RESTIC_CACHE_DIR    "${HOME:-}/.cache/restic"   "$ef" || return 1
  # Durable per-user Hermes state captured by the backup. Derived from HOME by
  # default (exactly where backup.sh and restore.sh already looked), but now a
  # named path setting so a system-mode unit can relocate it.
  _haven_resolve_path HAVEN_HERMES_HOME_DIR "${HOME:-}/.hermes" "$ef" || return 1

  # The post-deploy verifier and the log it appends to. Both are INTERNAL test
  # seams (undocumented on purpose): their defaults are the paths the deploy
  # hook and doctor.sh used to hardcode, so a host that sets neither sees no
  # change at all.
  _haven_resolve_path HAVEN_POST_DEPLOY_VERIFY_CMD \
    "/usr/local/sbin/run-post-deploy-verify.sh" "$ef" || return 1
  _haven_resolve_path HAVEN_POST_DEPLOY_VERIFY_LOG \
    "/var/log/haven-post-deploy-verify.log" "$ef" || return 1

  # --- Mode selectors -------------------------------------------------------
  # HAVEN_BACKUP_MODE picks WHICH system units run the backup. "user" keeps
  # today's per-user units; "system" selects the two-unit privilege split. Any
  # other value is refused. It selects units only -- backup.sh's own behaviour
  # is chosen by its --stage-only/--upload-only flags, not by this setting.
  _haven_resolve_enum HAVEN_BACKUP_MODE "user" "user system" "$ef" || return 1
  # BACKUP_CONTAINER_CONTROL=external tells backup.sh that a root helper pauses
  # and unpauses the containers, so backup.sh itself must call no docker command.
  # Default "self" is today's behaviour (the script pauses/execs docker itself).
  _haven_resolve_enum BACKUP_CONTAINER_CONTROL "self" "self external" "$ef" || return 1

  # --- Derived paths (names unchanged) --------------------------------------
  HAVEN_HERMES_DATA_DIR="${HAVEN_DATA_DIR}/hermes_data"
  HAVEN_WEBUI_DATA_DIR="${HAVEN_DATA_DIR}/webui_data"
  HAVEN_OLLAMA_DATA_DIR="${HAVEN_DATA_DIR}/ollama_data"
  # Caddy's /data lives beside webui_data, NOT inside it: the status container
  # mounts webui_data read-only, so ACME private keys must not sit in that tree.
  HAVEN_CADDY_DATA_DIR="${HAVEN_DATA_DIR}/caddy"
  # Caddy's managed ACME storage, defined ONCE. Anything that needs to know where
  # issuance and renewal land reads this, so a relocation of Caddy's /data is a
  # one-line change here rather than a hunt through the scripts.
  HAVEN_CADDY_CERT_ROOT="${HAVEN_CADDY_DATA_DIR}/caddy/certificates"
  HAVEN_INSTALL_LOG="${HAVEN_LOG_DIR}/install.log"
  HAVEN_BACKUP_STAGING_DIR="${HAVEN_WORK_DIR}/.backup-staging"
  HAVEN_RESTORE_WORK_DIR="${HAVEN_WORK_DIR}/.restore-work"
  export HAVEN_HERMES_DATA_DIR HAVEN_WEBUI_DATA_DIR HAVEN_OLLAMA_DATA_DIR
  export HAVEN_CADDY_DATA_DIR HAVEN_CADDY_CERT_ROOT
  export HAVEN_INSTALL_LOG HAVEN_BACKUP_STAGING_DIR HAVEN_RESTORE_WORK_DIR

  # BACKUP_LOG keeps its name. In user mode its default is unchanged:
  # $LOG_DIR/backup.log. In SYSTEM mode the backup runs as a systemd unit and
  # its log lives in the unit's LogsDirectory= (/var/log/haven-backup), the
  # one directory systemd grants write access to under ProtectSystem= strict.
  # Resolving the SAME path here means the units, doctor.sh and install.sh all
  # watch ONE file; the defect was two paths, so doctor.sh watched a file the
  # units never wrote and reported "no successful backup recorded yet" forever.
  # A SET value (environment or env file) still wins in both modes.
  local backup_log_default="${HAVEN_LOG_DIR}/backup.log"
  if [[ "$HAVEN_BACKUP_MODE" == "system" ]]; then
    backup_log_default="/var/log/haven-backup/backup.log"
  fi
  _haven_resolve_path BACKUP_LOG "$backup_log_default" "$ef" || return 1
  unset backup_log_default

  # --- Mode-derived unit names and credential directory ---------------------
  # ONE place resolves which backup units a mode uses, so install.sh, doctor.sh,
  # deploy-remote.sh, collect-diagnostics.sh and backup.sh cannot disagree. In
  # system mode the credentials live in the root-owned credstore the units read;
  # in user mode they live in BACKUP_CONF_DIR, exactly as today. Names and paths
  # only -- never a value.
  if [[ "$HAVEN_BACKUP_MODE" == "system" ]]; then
    HAVEN_BACKUP_TIMER_UNIT="haven-backup-capture.timer"
    HAVEN_BACKUP_SERVICE_UNIT="haven-backup-capture.service"
    HAVEN_BACKUP_CHECK_TIMER_UNIT="haven-backup-check.timer"
    HAVEN_BACKUP_SYSTEMCTL_SCOPE="--system"
    HAVEN_BACKUP_JOURNAL_SCOPE="--system"
    _haven_backup_cred_default="/etc/credstore/haven-backup"
  else
    HAVEN_BACKUP_TIMER_UNIT="haven-backup.timer"
    HAVEN_BACKUP_SERVICE_UNIT="haven-backup.service"
    HAVEN_BACKUP_CHECK_TIMER_UNIT="haven-check.timer"
    HAVEN_BACKUP_SYSTEMCTL_SCOPE="--user"
    HAVEN_BACKUP_JOURNAL_SCOPE="--user"
    _haven_backup_cred_default="$BACKUP_CONF_DIR"
  fi
  # The credential directory is a NAMED path setting (env file or environment may
  # relocate it) whose DEFAULT follows the mode. Names and paths only.
  _haven_resolve_path HAVEN_BACKUP_CRED_DIR "$_haven_backup_cred_default" "$ef" || return 1
  unset _haven_backup_cred_default
  export HAVEN_BACKUP_CRED_DIR HAVEN_BACKUP_TIMER_UNIT
  export HAVEN_BACKUP_SERVICE_UNIT HAVEN_BACKUP_CHECK_TIMER_UNIT
  export HAVEN_BACKUP_SYSTEMCTL_SCOPE HAVEN_BACKUP_JOURNAL_SCOPE

  # Snapshot the LAYOUT-resolved value of every setting that install.sh REWRITES
  # into the stack file. On a bootstrapped host the stack file differs from the
  # layout file, and a legacy stack file still carries the OLD values (empty
  # HAVEN_UID=, login-home OPENHANDS_WORKSPACE, ...). install.sh loads the
  # stack file after this helper runs; it then restores these snapshots so the
  # layout file stays authoritative for paths and identity, while the stack file
  # supplies runtime config and secrets only. With HAVEN_STACK_ENV_FILE
  # unset both files are the same path, so every restore is a no-op.
  HAVEN_LAYOUT_UID="$HAVEN_UID"
  HAVEN_LAYOUT_GID="$HAVEN_GID"
  HAVEN_LAYOUT_OPENHANDS_WORKSPACE="$OPENHANDS_WORKSPACE"
  HAVEN_LAYOUT_AGENT_REPOS_DIR="$AGENT_REPOS_DIR"
  HAVEN_LAYOUT_OPENHANDS_STATE_DIR="$OPENHANDS_STATE_DIR"
  export HAVEN_LAYOUT_UID HAVEN_LAYOUT_GID \
         HAVEN_LAYOUT_OPENHANDS_WORKSPACE HAVEN_LAYOUT_AGENT_REPOS_DIR \
         HAVEN_LAYOUT_OPENHANDS_STATE_DIR

  return 0
}

if ! haven_env_load; then
  # A sourced refusal must be a NON-ZERO EXIT of the calling script, not a
  # warning that lets it blunder on with half-resolved paths.
  exit 1
fi
