#!/usr/bin/env bash
# Provision and verify a dedicated Haven persona identity and storage as root.
set -euo pipefail
export LC_ALL=C
umask 077

die() { printf 'provision-persona: %s\n' "$*" >&2; exit 1; }

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/persona-reservations.sh
source "$script_dir/lib/persona-reservations.sh"

if (( $# < 1 || $# > 2 )) || [[ "${2---check}" != --check ]]; then
  die "Usage: provision-persona.sh <persona|--declaration> [--check]"
fi
(( EUID == 0 )) || die "Run as root."

persona="$1"
if [[ "$persona" == --declaration ]]; then
  # Read literal settings from stdin. Never evaluate an operator declaration as shell.
  declaration="$(awk -F= '
    NR == 1 && /^PERSONA_ID=[a-z][a-z0-9-]*$/ { id = $2; next }
    NR == 2 && /^PERSONA_APPS=(hermes(,files)?)?$/ { apps = $2; next }
    NR == 3 && /^PERSONA_INTERNET=(true|false)$/ { internet = $2; next }
    { exit 1 }
    END {
      if (NR < 2 || id == "") exit 1
      printf "%s:%s:%s\n", id, apps, internet
    }
  ')" || die "Expected PERSONA_ID and PERSONA_APPS, with optional PERSONA_INTERNET=true or false."
  IFS=: read -r persona apps internet <<< "$declaration"
  printf -v declaration_input 'PERSONA_ID=%s\nPERSONA_APPS=%s' "$persona" "$apps"
  if [[ -n "$internet" ]]; then declaration_input+=$'\n'"PERSONA_INTERNET=$internet"; fi
  [[ "$persona" != canvas ]] || die "Use the existing setup path for Canvas."
fi
persona_valid_name "$persona" || die "Use a non-reserved lowercase persona name."
if [[ "$1" == --declaration && -z "$apps" ]]; then
  printf 'persona=%s disabled\n' "$persona"
  exit 0
fi

account="haven-$persona"
check="${2:-}"
# shellcheck source=scripts/lib/haven-env.sh
source "$script_dir/lib/haven-env.sh"
raw_data="$_HAVEN_DATA_DIR_RAW"
data="$HAVEN_DATA_DIR"
[[ "$data" != / && "$raw_data" == "$data" ]] ||
  die "HAVEN_DATA_DIR resolves through a symlink."
# Check each original component as well, including links that resolve back to
# the same lexical destination. Require root control of every ancestor.
path="$raw_data"
while [[ "$path" != / ]]; do
  [[ -d "$path" && ! -L "${path%/}" && "${path##*/}" != . && "${path##*/}" != .. ]] ||
    die "HAVEN_DATA_DIR must be an existing directory with a symlink-free path."
  read -r owner mode < <(stat -c '%u %a' -- "${path%/}")
  if [[ "$owner" != 0 ]] || (( (8#$mode & 022) != 0 && (8#$mode & 01000) == 0 )); then
    die "HAVEN_DATA_DIR and its ancestors must be controlled by root."
  fi
  path="$(dirname -- "$path")"
done
mode="$(stat -c '%a' -- "$data")"
(( (8#$mode & 022) == 0 )) || die "HAVEN_DATA_DIR must be writable only by root."

exec {lock}<"$data"
if [[ -n "$check" ]]; then
  flock -s "$lock"
else
  flock -x "$lock"
fi

ledger="$data/.persona-identities"
state="$data/${persona}_data"
uid='' gid=''
declare -A used_uid=() used_gid=()
exists() { [[ -e "$1" || -L "$1" ]]; }
require_unmounted() {
  local result=0
  mountpoint -q -- "$1" || result=$?
  (( result == 32 )) || die "Persona storage is a mount point or could not be inspected."
}
metadata() { stat -c '%u:%g:%a' -- "$1"; }
lookup() {
  local rc=0
  getent "$@" || rc=$?
  (( rc == 0 || rc == 2 )) || die "Identity database lookup failed."
}
if exists "$ledger"; then
  [[ -f "$ledger" && ! -L "$ledger" && "$(stat -c '%u:%g:%a:%h' -- "$ledger")" == 0:0:600:1 ]] ||
    die "Unsafe persona reservation record."
  persona_validate_reservations "$ledger" || die "Invalid persona reservation record."
  while IFS=: read -r name reserved_uid reserved_gid; do
    used_uid[$reserved_uid]=1 used_gid[$reserved_gid]=1
    if [[ "$name" == "$persona" ]]; then
      uid="$reserved_uid" gid="$reserved_gid"
    fi
  done < "$ledger"
fi

user="$(lookup passwd "$account")"
group="$(lookup group "$account")"
passwd_entries="$(lookup passwd)"
group_entries="$(lookup group)"
[[ -n "$passwd_entries" && -n "$group_entries" ]] || die "Could not enumerate local identities."
while IFS=: read -r _ _ _ primary_gid _; do
  used_gid[$primary_gid]=1
done <<< "$passwd_entries"
reserved="$uid"
if [[ -z "$reserved" ]]; then
  [[ -z "$check" ]] || die "Persona has no identity reservation."
  if [[ -n "$user$group" ]] || exists "$state"; then
    die "Existing identity or data has no reservation. Review it before provisioning."
  fi
  # Use the low Linux system-ID range. Test both NSS namespaces and both
  # reservation columns before choosing a shared numeric UID/GID.
  for ((candidate=999; candidate>=100; candidate--)); do
    if [[ -v 'used_uid[$candidate]' || -v 'used_gid[$candidate]' ]]; then continue; fi
    candidate_user="$(lookup passwd "$candidate")"
    candidate_group="$(lookup group "$candidate")"
    if [[ -z "$candidate_user$candidate_group" ]]; then
      uid="$candidate" gid="$candidate"
      break
    fi
  done
  [[ -n "$uid" ]] || die "No unused system UID/GID pair is available."
fi

# Use direct NSS lookups and enumeration to catch aliases and other primary
# group users. Validate existing accounts before any mutation.
numeric_user="$(lookup passwd "$uid")"
numeric_group="$(lookup group "$gid")"
[[ "$numeric_user" == "$user" && "$numeric_group" == "$group" ]] ||
  die "Reserved UID/GID is occupied or the named identity has different IDs."
if ! awk -F: -v name="$account" -v uid="$uid" -v gid="$gid" \
  '($3 == uid || $4 == gid) && $1 != name {exit 1}' <<< "$passwd_entries" ||
   ! awk -F: -v name="$account" -v gid="$gid" \
  '$3 == gid && $1 != name {exit 1}' <<< "$group_entries"; then
  die "Reserved UID/GID is shared by another identity."
fi

shell=/usr/sbin/nologin
[[ -x "$shell" ]] || die "Missing $shell."
! exists /nonexistent || die "The configured no-home path exists."
if [[ -n "$group" ]]; then
  [[ "$group" == "$account":*:"$gid": ]] || die "Invalid persona group or unexpected group members."
fi
if [[ -n "$user" ]]; then
  IFS=: read -r name _ actual_uid actual_gid _ home login_shell <<< "$user"
  shadow="$(lookup shadow "$account")"
  IFS=: read -r _ password _ <<< "$shadow"
  [[ "$name" == "$account" && "$actual_uid" == "$uid" && "$actual_gid" == "$gid" &&
     "$home" == /nonexistent && "$login_shell" == "$shell" &&
     ( "$password" == '!'* || "$password" == '*'* ) &&
     "$(id -G "$account")" == "$gid" && -n "$group" ]] ||
    die "Persona account has unexpected identity, login, home or groups."
fi

if exists "$state"; then
  [[ -d "$state" && ! -L "$state" && "$(metadata "$state")" == 0:0:700 ]] ||
    die "Unsafe persona data directory."
  require_unmounted "$state"
  shopt -s nullglob dotglob
  for entry in "$state"/*; do
    case "${entry##*/}" in
      persona|projects|files)
        [[ -d "$entry" && ! -L "$entry" && "$(metadata "$entry")" == "$uid:$gid:700" ]] ||
          die "Unsafe persona child directory."
        require_unmounted "$entry"
        ;;
      settings-key.recovered)
        [[ "$persona" == canvas && -f "$entry" && ! -L "$entry" &&
           "$(stat -c '%u:%g:%a:%h' -- "$entry")" == 0:0:600:1 ]] ||
          die "Unexpected entry in persona data directory."
        ;;
      *) die "Unexpected entry in persona data directory." ;;
    esac
  done
fi

if [[ -n "$check" ]]; then
  [[ -n "$user" && -n "$group" && -d "$state/persona" && -d "$state/projects" ]] ||
    die "Persona provisioning is incomplete."
  if [[ "${apps:-}" == hermes,files && ! -d "$state/files" ]]; then
    die "FileBrowser storage is missing. Provision this declaration first."
  fi
else
  stage=""
  cleanup() {
    if [[ -n "$stage" ]]; then rm -rf -- "$stage"; fi
  }
  trap cleanup EXIT
  make_stage() {
    stage="$(mktemp -d -- "$data/.persona-provision.XXXXXXXX")"
    chown -- 0:0 "$stage"
    chmod -- 00700 "$stage"
  }
  if [[ -z "$reserved" ]]; then
    make_stage
    {
      if exists "$ledger"; then cat -- "$ledger"; fi
      printf '%s:%s:%s\n' "$persona" "$uid" "$gid"
    } > "$stage/reservations"
    # Persist the reservation before creating accounts or assigning ownership.
    sync -f -- "$stage"
    mv -T -- "$stage/reservations" "$ledger"
    sync -f -- "$data"
  fi
  if [[ -z "$group" ]]; then groupadd --system --gid "$gid" -- "$account"; fi
  if [[ -z "$user" ]]; then
    useradd --system --uid "$uid" --gid "$gid" --no-user-group --no-create-home \
      --home-dir /nonexistent --shell "$shell" -- "$account"
  fi
  directories=("$state" "$state/persona" "$state/projects")
  if [[ "${apps:-}" == hermes,files ]]; then directories+=("$state/files"); fi
  for entry in "${directories[@]}"; do
    if ! exists "$entry"; then
      [[ -n "$stage" ]] || make_stage
      mkdir -m 0700 -- "$stage/directory"
      if [[ "$entry" != "$state" ]]; then chown -- "$uid:$gid" "$stage/directory"; fi
      mv -T -- "$stage/directory" "$entry"
    fi
  done
  # Re-open in check mode after dropping the exclusive directory lock.
  cleanup
  exec {lock}<&-
  if [[ "$1" == --declaration ]]; then
    exec bash "$script_dir/provision-persona.sh" --declaration --check <<< "$declaration_input"
  fi
  exec bash "$script_dir/provision-persona.sh" "$persona" --check
fi
printf 'persona=%s uid=%s gid=%s' "$persona" "$uid" "$gid"
if [[ "${apps:-}" == hermes,files ]]; then printf ' apps=hermes,files'; fi
if [[ "$1" == --declaration && -n "$internet" ]]; then
  printf ' internet=%s' "$internet"
fi
printf ' data_dir=%s\n' "$data"
