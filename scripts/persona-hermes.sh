#!/usr/bin/env bash
# Manage one provisioned Hermes Compose project from a trusted operator declaration.
set -euo pipefail
export LC_ALL=C

if [[ $# != 1 || ! "$1" =~ ^(up|down|internet-on|internet-off)$ ]]; then
  printf 'Usage: persona-hermes.sh {up|down|internet-on|internet-off} < persona.env\n' >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
identity="$("$script_dir/provision-persona.sh" --declaration --check)"
if [[ "$identity" == 'persona='*' disabled' ]]; then
  printf '%s\n' "$identity" >&2
  exit 1
fi

identity_pattern='^persona=([a-z][a-z0-9-]*) uid=([1-9][0-9][0-9]) gid=([1-9][0-9][0-9])( internet=(true|false))? data_dir=(/.+)$'
if [[ ! "$identity" =~ $identity_pattern ]]; then
  printf 'Could not read the verified persona identity.\n' >&2
  exit 1
fi

persona="${BASH_REMATCH[1]}"
uid="${BASH_REMATCH[2]}"
gid="${BASH_REMATCH[3]}"
internet="${BASH_REMATCH[5]:-true}"
data_dir="${BASH_REMATCH[6]}/${persona}_data"
network="haven-persona-$persona"

case "$1" in
  internet-on) printf 'PERSONA_ID=%s\nPERSONA_APPS=hermes\nPERSONA_INTERNET=true\n' "$persona"; exit ;;
  internet-off) printf 'PERSONA_ID=%s\nPERSONA_APPS=hermes\nPERSONA_INTERNET=false\n' "$persona"; exit ;;
esac

exec {lock}>/run/haven-persona-network.lock
flock -x "$lock"
local_env=(env -i PATH="$PATH")
compose=(
  "${local_env[@]}"
  PERSONA_UID="$uid" PERSONA_GID="$gid" PERSONA_DATA_DIR="$data_dir" PERSONA_NETWORK="$network"
  # Interpolate only verified persona values. The legacy stack env holds credentials.
  COMPOSE_DISABLE_ENV_FILE=1
  docker --host unix:///var/run/docker.sock compose
  --project-name "$network"
  --file "$script_dir/../hermes/docker-compose.persona.yml"
)
"${compose[@]}" down
if [[ "$1" == up ]]; then
  "${local_env[@]}" python3 -B "$script_dir/persona-firewall.py" "$network" "$internet"
  exec "${compose[@]}" up --build --detach hermes
fi
