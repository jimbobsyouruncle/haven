#!/usr/bin/env bash
# Prepare application configuration for a dedicated Haven persona.
set +ax
set -euo pipefail
export LC_ALL=C
umask 077
ulimit -c 0

die() { printf 'setup-persona: %s\n' "$*" >&2; exit 1; }
exists() { [[ -e "$1" || -L "$1" ]]; }

protected_path() {
  local path="$1" owner mode
  [[ "$(realpath -e -- "$path")" == "$path" ]] || die "Unsafe configuration path."
  path="$(dirname -- "$path")"
  while [[ "$path" != / ]]; do
    read -r owner mode < <(stat -c '%u %a' -- "$path")
    if [[ "$owner" != 0 ]] || (( (8#$mode & 022) != 0 && (8#$mode & 01000) == 0 )); then
      die "Configuration directories must be controlled by root."
    fi
    path="$(dirname -- "$path")"
  done
}

bcrypt_valid() {
  local pattern='^[$]2[aby][$](0[4-9]|[12][0-9]|3[01])[$][./A-Za-z0-9]{53}$'
  [[ "$1" =~ $pattern ]]
}

canvas_password_hash() {
  local +x password confirmation
  local hash tty
  command -v htpasswd >/dev/null || die "Install apache2-utils for bcrypt password setup."
  { exec {tty}<>/dev/tty; } 2>/dev/null || die "A controlling terminal is required."
  printf 'New Canvas password: ' >&"$tty"
  IFS= read -rs -u "$tty" password || die "Password input interrupted."
  printf '\nConfirm Canvas password: ' >&"$tty"
  IFS= read -rs -u "$tty" confirmation || die "Password input interrupted."
  printf '\n' >&"$tty"
  exec {tty}>&-
  [[ "$password" == "$confirmation" ]] || die "Passwords do not match."
  (( ${#password} >= 1 && ${#password} <= 72 )) ||
    die "Canvas password must be between 1 and 72 bytes."
  hash="$(printf '%s\n' "$password" | htpasswd -niBC 12 canvas 2>/dev/null)" ||
    die "Could not hash the Canvas password."
  if [[ "$hash" != canvas:* ]] || ! bcrypt_valid "${hash#canvas:}"; then
    die "Unexpected Canvas bcrypt output."
  fi
  tls_compose_escape "${hash#canvas:}"
}

lock_deployment() {
  local path="$1" fd
  [[ -f "$path" && ! -L "$path" && "$(stat -c '%u:%a:%h' -- "$path")" == 0:600:1 ]] ||
    die "Expected the protected deployment lock from an existing Haven installation."
  exec {fd}<"$path"
  [[ "$(stat -Lc '%d:%i:%u:%a:%h' -- "/proc/$BASHPID/fd/$fd")" == "$(stat -c '%d:%i:%u:%a:%h' -- "$path")" ]] ||
    die "Deployment lock changed while opening it."
  flock -n -x "$fd" || die "A deployment or another setup is in progress."
}

setup_canvas() (
  local app="$1" layout="$2" stack="$3" mode="$4" locks="$5"
  local script_dir line key raw value identity uid gid state generated entry
  local tmp='' changed=false
  local -A current=() desired=() seen=()
  local -a keys=(CANVAS_UID CANVAS_GID CANVAS_SESSION_KEY CANVAS_STATE_KEY CANVAS_PASSWORD_HASH CANVAS_ENABLED)
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

  protected_path "$layout"
  protected_path "$stack"
  [[ -f "$layout" && "$(stat -c '%u:%g:%a:%h' -- "$layout")" == 0:0:644:1 &&
     -f "$stack" && "$(stat -c '%u:%g:%a:%h' -- "$stack")" == 0:0:600:1 ]] ||
    die "Expected a root-owned Haven layout (0644) and stack environment (0600)."
  if [[ "$mode" != --check ]]; then
    lock_deployment "$locks/hybrid-ai-deploy.lock"
    lock_deployment "$locks/haven-deploy.lock"
  fi

  export HAVEN_ENV_FILE="$layout"
  # shellcheck source=scripts/lib/haven-env.sh
  source "$script_dir/lib/haven-env.sh"
  [[ "$HAVEN_APP_DIR" == "$app" && "$HAVEN_ENV_FILE" == "$layout" &&
     "$HAVEN_STACK_ENV_FILE" == "$stack" ]] || die "Expected the installed Haven layout."
  raw="$(_haven_file_get "$layout" HAVEN_STACK_ENV_FILE)"
  [[ "$raw" == "$stack" ]] || die "Unsafe stack environment path."

  local TLS_ENABLED='' TLS_DOMAIN='' TLS_VALIDATION='' ACME_EMAIL='' ACME_CA='' ACME_DNS_PROVIDER=''
  local HAVEN_TLS_TOKEN_FILE='' AUTH_ENABLED='' HAVEN_AUTH_USER='' HAVEN_AUTH_HASH='' HAVEN_AUTH_COOKIE_SECRET=''
  local LOCAL_DOMAIN='' APP_DIR="$app" ENV_FILE="$stack"

  # shellcheck source=scripts/lib/tls.sh
  source "$script_dir/lib/tls.sh"
  # Read persisted settings using the installer's assignment syntax. Reject
  # duplicates in managed keys so Compose and the installer cannot disagree.
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:blank:]]*(export[[:blank:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:blank:]]*=(.*)$ ]] || continue
    entry="${BASH_REMATCH[2]}"
    raw="${BASH_REMATCH[3]}"
    key="$(haven_key "$entry")"
    value="${raw%\"}"; value="${value#\"}"
    value="${value%\'}"; value="${value#\'}"
    case "$key" in
      CANVAS_UID|CANVAS_GID|CANVAS_SESSION_KEY|CANVAS_STATE_KEY|CANVAS_PASSWORD_HASH|CANVAS_ENABLED)
        [[ "$line" == "$entry="* && ! -v "current[$key]" ]] ||
          die "Duplicate or noncanonical Canvas setting."
        current[$key]="$value"
        ;;
      TLS_ENABLED|TLS_DOMAIN|TLS_VALIDATION|ACME_EMAIL|ACME_CA|ACME_DNS_PROVIDER|HAVEN_TLS_TOKEN_FILE|LOCAL_DOMAIN|\
      AUTH_ENABLED|HAVEN_AUTH_USER|HAVEN_AUTH_HASH|HAVEN_AUTH_COOKIE_SECRET)
        [[ "$line" == "$entry="* && ! -v "seen[$key]" ]] ||
          die "Duplicate or noncanonical Haven TLS/auth setting."
        seen[$key]=1
        printf -v "$key" '%s' "$value"
        ;;
    esac
  done < "$stack"
  if ! tls_is_on || ! tls_auth_is_on; then
    die "Canvas requires TLS and Haven authentication."
  fi
  tls_auth_fail_closed
  if [[ ! "$HAVEN_AUTH_USER" =~ [^[:space:]] || ! "$HAVEN_AUTH_COOKIE_SECRET" =~ ^[^[:space:]]{32,}$ ]] ||
      ! bcrypt_valid "$(tls_compose_unescape "$HAVEN_AUTH_HASH")"; then
    die "Invalid Haven authentication settings."
  fi
  if ! ( tls_validate_settings ) >/dev/null 2>&1; then
    die "Invalid Haven TLS settings. Review the existing TLS configuration."
  fi

  case "${current[CANVAS_ENABLED]:-off}" in
    on|off) ;;
    *) die "Invalid Canvas enablement setting." ;;
  esac
  # Existing unmanaged Canvas accounts/data are refused by the provisioner.
  # Verify existing identities before any credential changes.
  if [[ "$mode" == --check ]] || exists "$HAVEN_DATA_DIR/canvas_data" ||
      getent passwd haven-canvas >/dev/null || getent group haven-canvas >/dev/null ||
      [[ -n "${current[CANVAS_UID]:-}${current[CANVAS_GID]:-}" || "${current[CANVAS_ENABLED]:-}" == on ]]; then
    identity="$(env -u HAVEN_DATA_DIR "$script_dir/provision-persona.sh" canvas --check)" ||
      die "Canvas identity requires provisioning or reviewed adoption."
  else
    identity="$(env -u HAVEN_DATA_DIR "$script_dir/provision-persona.sh" canvas)" || die "Canvas identity provisioning failed."
  fi
  [[ "$identity" =~ ^persona=canvas\ uid=([1-9][0-9]*)\ gid=([1-9][0-9]*)\ data_dir= &&
     "${identity#* data_dir=}" == "$HAVEN_DATA_DIR" ]] || die "Unexpected persona identity."
  uid="${BASH_REMATCH[1]}" gid="${BASH_REMATCH[2]}"
  [[ "$uid" != "${HAVEN_UID:-}" && "$gid" != "${HAVEN_GID:-}" &&
     "${current[CANVAS_UID]:-$uid}" == "$uid" && "${current[CANVAS_GID]:-$gid}" == "$gid" ]] ||
    die "Canvas configuration conflicts with the verified persona identity."
  state="$HAVEN_DATA_DIR/canvas_data"

  desired[CANVAS_UID]="$uid" desired[CANVAS_GID]="$gid" desired[CANVAS_ENABLED]=on
  desired[CANVAS_SESSION_KEY]="${current[CANVAS_SESSION_KEY]:-}"
  desired[CANVAS_PASSWORD_HASH]="${current[CANVAS_PASSWORD_HASH]:-}"
  desired[CANVAS_STATE_KEY]="${current[CANVAS_STATE_KEY]:-}"
  if exists "$state/settings-key.recovered"; then
    [[ -n "${desired[CANVAS_STATE_KEY]}" &&
       "$(< "$state/settings-key.recovered")" == "${desired[CANVAS_STATE_KEY]}" ]] ||
      die "Reconcile the recovered Canvas settings key before setup."
  fi
  if [[ -z "${desired[CANVAS_STATE_KEY]}" ]]; then
    entry="$(find "$state/persona" -mindepth 1 -maxdepth 1 -printf x -quit)"
    if [[ "${current[CANVAS_ENABLED]:-}" == on || -n "$entry" ]]; then
      die "Existing Canvas state requires its original settings key."
    fi
    [[ "$mode" == --check ]] || desired[CANVAS_STATE_KEY]="$(openssl rand -base64 32)"
  fi
  if [[ "$mode" != --check ]]; then
    if [[ "$mode" == --rotate || -z "${desired[CANVAS_SESSION_KEY]}" ]]; then
      desired[CANVAS_SESSION_KEY]="$(openssl rand -hex 32)"
    fi
    if [[ "$mode" == --rotate || -z "${desired[CANVAS_PASSWORD_HASH]}" ]]; then
      generated="$(canvas_password_hash)" || exit 1
      desired[CANVAS_PASSWORD_HASH]="$generated"
    fi
  fi

  [[ "${desired[CANVAS_SESSION_KEY]}" =~ ^[a-f0-9]{64}$ &&
     "${desired[CANVAS_STATE_KEY]}" =~ ^[A-Za-z0-9+/]{43}=$ ]] ||
    die "Missing or invalid Canvas key configuration."
  value="$(tls_compose_unescape "${desired[CANVAS_PASSWORD_HASH]}")"
  bcrypt_valid "$value" && [[ "$(tls_compose_escape "$value")" == "${desired[CANVAS_PASSWORD_HASH]}" ]] ||
    die "Missing or invalid Canvas bcrypt configuration."
  for key in "${keys[@]}"; do
    if [[ "${current[$key]:-}" != "${desired[$key]}" ]]; then changed=true; fi
  done
  if [[ "$changed" == true ]]; then
    [[ "$mode" != --check ]] || die "Canvas configuration is incomplete or disabled."
    trap 'if [[ -n "$tmp" ]]; then rm -f -- "$tmp"; fi' EXIT
    tmp="$(mktemp -- "$stack.setup.XXXXXXXX")"
    chown 0:0 -- "$tmp"
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^(CANVAS_(UID|GID|SESSION_KEY|STATE_KEY|PASSWORD_HASH|ENABLED))= ]]; then
        key="${BASH_REMATCH[1]}"
        printf '%s=%s\n' "$key" "${desired[$key]}"
        unset 'desired[$key]'
      else
        printf '%s\n' "$line"
      fi
    done < "$stack" > "$tmp"
    for key in "${keys[@]}"; do
      if [[ -v "desired[$key]" ]]; then printf '%s=%s\n' "$key" "${desired[$key]}" >> "$tmp"; fi
    done
    sync -f -- "$tmp"
    mv -T -- "$tmp" "$stack"
    tmp=''
    sync -f -- "$(dirname -- "$stack")"
  fi
  printf 'Canvas configuration verified for haven-canvas (%s:%s).\n' "$uid" "$gid"
  printf 'Ensure canvas.%s resolves to the existing Haven HTTPS endpoint on the authorized network.\n' "$TLS_DOMAIN"
  printf '%s\n' 'Use the next eligible owner-merge deployment to apply saved settings.' \
    'After activation, enter the authorized inference-provider credential in Canvas.' \
    'Provision any needed GitHub credential separately, scoped to approved repositories and operations.'
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if (( $# < 2 || $# > 3 )) || [[ "$1 $2" != 'canvas canvas' ]] ||
      [[ -n "${3:-}" && "$3" != --check && "$3" != --rotate ]]; then
    die "Usage: setup-persona.sh canvas canvas [--check|--rotate] (persona then application)"
  fi
  (( EUID == 0 )) || die "Run as root."
  [[ "$(realpath -e -- "${BASH_SOURCE[0]}")" == /opt/haven/scripts/setup-persona.sh ]] ||
    die "Run from Haven's canonical system installation."
  # Do not let inherited environment overrides select a different deployment.
  # Keep the mode positional in the clean shell.
  # shellcheck disable=SC2016
  exec env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root bash -c '
    source /opt/haven/scripts/setup-persona.sh
    setup_canvas /opt/haven /etc/haven/haven.env /etc/haven/stack.env "$1" /run/lock
  ' setup-persona "${3:-}"
fi
