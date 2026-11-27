#!/usr/bin/env bash
# Manage one provisioned Hermes Compose project from a trusted operator declaration.
set -euo pipefail
export LC_ALL=C

if [[ $# != 1 || ( "$1" != up && "$1" != down ) ]]; then
  printf 'Usage: persona-hermes.sh <up|down> < persona.env\n' >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
identity="$("$script_dir/provision-persona.sh" --declaration --check)"
if [[ "$identity" == 'persona='*' disabled' ]]; then
  printf '%s\n' "$identity"
  exit 0
fi

if [[ ! "$identity" =~ ^persona=([a-z][a-z0-9-]*)\ uid=([1-9][0-9][0-9])\ gid=([1-9][0-9][0-9])\ data_dir=(/.+)$ ]]; then
  printf 'Could not read the verified persona identity.\n' >&2
  exit 1
fi

persona="${BASH_REMATCH[1]}"
compose=(
  env -i PATH="$PATH"
  PERSONA_UID="${BASH_REMATCH[2]}"
  PERSONA_GID="${BASH_REMATCH[3]}"
  PERSONA_DATA_DIR="${BASH_REMATCH[4]}"
  docker --host unix:///var/run/docker.sock compose
  --env-file /dev/null
  --project-name "haven-persona-$persona"
  --file "$script_dir/../hermes/docker-compose.persona.yml"
)
case "$1" in
  up) exec "${compose[@]}" up --build --detach hermes ;;
  down) exec "${compose[@]}" down ;;
esac
