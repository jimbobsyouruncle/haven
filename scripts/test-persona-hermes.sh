#!/usr/bin/env bash
# Run on the disposable ARM runner beside the existing Hermes smoke container.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && $EUID == 0 ]]
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
scratch="$(mktemp -d)"
export HAVEN_ENV_FILE="$scratch/haven.env"
persona="hermes-ci"
project="haven-persona-$persona"
declaration="$scratch/persona.env"
printf 'HAVEN_DATA_DIR=%s\n' "$scratch" > "$HAVEN_ENV_FILE"
printf 'PERSONA_ID=%s\nPERSONA_APPS=hermes,files\nPERSONA_INTERNET=false\n' "$persona" > "$declaration"

cleanup() {
  "$script_dir/persona-hermes.sh" down < "$declaration" || true
  docker network rm "$project" >/dev/null 2>&1 || true
  rm -rf -- "$scratch"
}
trap cleanup EXIT

identity="$("$script_dir/provision-persona.sh" --declaration < "$declaration")"
expected_uid="$(sed -E 's/^persona=[^ ]+ uid=([0-9]+) .*/\1/' <<< "$identity")"

wait_for_webui() {
  local target="${2:-http://127.0.0.1:8501/}"
  for _ in {1..30}; do
    if docker exec "$1" curl --fail --silent --max-time 2 "$target" >/dev/null; then
      return 0
    fi
    [[ "$(docker inspect -f '{{.State.Running}}' "$1")" == true ]] || break
    sleep 2
  done
  printf 'WebUI %s was unavailable from %s\n' "$target" "$1" >&2
  return 1
}
verify_mounts() {
  docker inspect "$1" | jq -e --arg base "$scratch/${persona}_data" '
    .[0].Mounts | sort_by(.Destination) | map([.Type, .Source, .Destination]) ==
    [
      ["bind", ($base + "/persona"), "/root/.hermes"],
      ["bind", ($base + "/projects"), "/root/workspace"]
    ]' >/dev/null
}

container_id() {
  docker ps -q --filter "label=com.docker.compose.project=$project" \
    --filter "label=com.docker.compose.service=$1"
}

"$script_dir/persona-hermes.sh" up < "$declaration"
first="$(container_id hermes)"
files="$(container_id files)"
[[ -n "$files" ]]
wait_for_webui "$first"
wait_for_webui "$first" http://files:8080/health
wait_for_webui hermes-nonroot-smoke
verify_mounts "$first"
[[ "$(docker exec "$first" id -u)" == "$expected_uid" ]]
docker exec "$first" sh -c 'printf retained >/root/.hermes/persona-smoke'
docker exec "$first" sh -c 'printf shared >/root/workspace/persona-shared'
[[ "$(docker exec "$files" cat /folder/persona-shared)" == shared ]]
docker exec "$files" sh -c 'printf companion >/folder/persona-shared'
[[ "$(docker exec "$first" cat /root/workspace/persona-shared)" == companion ]]
docker exec hermes-nonroot-smoke test ! -e /root/.hermes/persona-smoke
"$script_dir/persona-hermes.sh" up < "$declaration"
second="$(container_id hermes)"
[[ -n "$second" && "$first" != "$second" ]]
wait_for_webui "$second"
verify_mounts "$second"
[[ "$(docker exec "$second" cat /root/.hermes/persona-smoke)" == retained ]]
[[ "$(docker exec "$(container_id files)" cat /folder/persona-shared)" == companion ]]
wait_for_webui hermes-nonroot-smoke
