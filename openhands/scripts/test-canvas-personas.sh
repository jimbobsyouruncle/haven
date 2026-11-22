#!/usr/bin/env bash
# Qualify the persona launcher boundary with two offline, disposable Canvas runtimes.
set -euo pipefail

image=${1:?Pass the pinned Canvas image used by test-canvas-offline.sh}
podman_local() { podman --remote=false "$@"; }

[[ $(podman_local info --format '{{.Host.Security.Rootless}}') == true ]]

fixture=$(mktemp -d)
containers=()
declare -A identities=()
cleanup() {
  for container in "${containers[@]}"; do
    podman_local rm -f "$container" >/dev/null 2>&1 || true
  done
  podman_local unshare rm -rf -- "$fixture"
}
trap cleanup EXIT

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
program=$(cat "$script_dir/test-canvas-personas.mjs")
for persona in 1000 1001; do
  # Chown is confined to disposable files in rootless Podman's user namespace.
  install -d -m 0700 "$fixture/$persona"
  openssl rand -hex 32 >"$fixture/$persona/repo-token-$persona"
  chmod 0600 "$fixture/$persona/repo-token-$persona"
  podman_local unshare chown -R "$persona:$persona" "$fixture/$persona"
done

start_persona() {
  local persona=$1 peer=$2 container pid effective uid gid
  container=$(podman_local run --detach --pull=never --network none \
    --http-proxy=false --cap-drop ALL --security-opt no-new-privileges \
    --image-volume=ignore --log-driver=none --memory=256m --pids-limit=64 \
    --user "$persona:$persona" --volume "$fixture/$persona:/persona:rw,Z" \
    --entrypoint node "$image" --input-type=module -e "$program" -- "$persona" "$peer")
  containers+=("$container")
  # The mounted state is the only user-supplied host mount.
  [[ $(podman_local inspect --format '{{range .Mounts}}{{.Source}}:{{.Destination}}{{end}}' "$container") == "$fixture/$persona:/persona" ]]
  pid=$(podman_local inspect --format '{{.State.Pid}}' "$container")
  effective=$(ps -o euid=,egid= -p "$pid")
  read -r uid gid <<<"$effective"
  [[ $uid != 0 && $gid != 0 ]]
  [[ "$(stat -c '%u:%g' "$fixture/$persona")" == "$uid:$gid" ]]
  identities[$persona]="$uid:$gid"
}

probe() {
  local container=$1 persona=$2 peer=$3
  podman_local exec "$container" node --input-type=module -e "$program" -- "$persona" "$peer" probe
}

start_persona 1000 1001
start_persona 1001 1000
[[ ${identities[1000]%:*} != "${identities[1001]%:*}" && ${identities[1000]#*:} != "${identities[1001]#*:}" ]]
probe "${containers[0]}" 1000 1001
probe "${containers[1]}" 1001 1000
first_identity=${identities[1000]}
second_identity=${identities[1001]}
podman_local rm -f "${containers[@]}" >/dev/null
containers=()
start_persona 1000 1001
start_persona 1001 1000
[[ ${identities[1000]} == "$first_identity" && ${identities[1001]} == "$second_identity" ]]
probe "${containers[0]}" 1000 1001
probe "${containers[1]}" 1001 1000

printf 'Persona qualification revision %s; host UID:GID %s and %s; own /persona RW mount only.\n' \
  "$(git -C "$script_dir/../.." rev-parse HEAD)" "${identities[1000]}" "${identities[1001]}"
