#!/usr/bin/env bash
set -euo pipefail

baseline=ghcr.io/open-webui/open-webui:v0.11.4
candidate="$(cut -d= -f2 tests/qualification/open-webui.env)"
container=haven-webui-qualification
network=haven-webui-qualification
fixtures="$RUNNER_TEMP/haven-webui"
mkdir -p "$fixtures/live" "$fixtures/backup" "$fixtures/restore"
cleanup() {
  local result=$?
  if (( result != 0 )); then
    docker logs "$container" || true
  fi
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker pull "$baseline"
docker pull "$candidate"
test "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$candidate")" = linux/arm64
docker network create --internal "$network"

start_webui() {
  docker run -d --name "$container" --network "$network" --cap-drop ALL \
    --security-opt no-new-privileges --memory 3g --cpus 2 \
    --mount "type=bind,source=$1,target=/app/backend/data" \
    -e WEBUI_SECRET_KEY=fixture-only-signing-key-not-for-production \
    -e DEFAULT_USER_ROLE=user -e ENABLE_SIGNUP=true -e WEBUI_AUTH=true \
    -e OFFLINE_MODE=true -e HF_HUB_OFFLINE=1 \
    -e ENABLE_OLLAMA_API=false -e ENABLE_OPENAI_API=false \
    -e ENABLE_WEBSOCKET_SUPPORT=true -e ENABLE_TOOL_SERVERS=true \
    -e ENABLE_IMAGE_GENERATION=false -e IMAGE_GENERATION_ENGINE=openai \
    -e IMAGES_OPENAI_API_BASE_URL=http://fixture.invalid/v1 "$2" >/dev/null
  docker inspect "$container" | jq -e '
    .[0] | .HostConfig.Privileged == false and
    (.HostConfig.PortBindings | length) == 0 and
    (.Mounts | map(.Destination)) == ["/app/backend/data"]
  '
}

probe() {
  local phase="$1" pipe
  pipe="$(base64 -w0 openwebui/runpod_pipe.py)"
  docker exec -i -e "QUALIFICATION_PHASE=$phase" -e "QUALIFICATION_PIPE=$pipe" \
    "$container" python - < tests/qualification/open-webui.py
}

start_webui "$fixtures/live" "$baseline"
probe seed
docker stop "$container"
docker rm "$container"
cp -a "$fixtures/live/." "$fixtures/backup/"
start_webui "$fixtures/live" "$candidate"
probe migrate
docker stop "$container"
docker rm "$container"
cp -a "$fixtures/backup/." "$fixtures/restore/"
start_webui "$fixtures/restore" "$baseline"
probe restore
