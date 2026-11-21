#!/usr/bin/env bash
set -euo pipefail

candidate="$(sed -n 's/.*image: [$]{OLLAMA_IMAGE:-\(.*\)}/\1/p' docker-compose.yml)"
baseline=ollama/ollama:0.34.4@sha256:8262851b2846b87c649eddf3e76beb270c52f4d1bc94559f47efde16b0841551
container=haven-ollama-qualification
store=haven-ollama-qualification-data
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm "$store" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker volume create "$store" >/dev/null
printf 'Haven synthetic model blob\n' > "$RUNNER_TEMP/ollama-blob"
digest="sha256:$(sha256sum "$RUNNER_TEMP/ollama-blob" | cut -d' ' -f1)"

start() {
  docker run -d --name "$container" --memory 8g --cpus 3.5 \
    --security-opt no-new-privileges --cap-drop ALL \
    -p 127.0.0.1::11434 --mount "type=volume,source=$store,target=/root/.ollama" "$1" >/dev/null
  api="http://$(docker port "$container" 11434/tcp)"
  for ((attempt=0; attempt<60; attempt++)); do
    if curl -fsS "$api/api/version" > "$RUNNER_TEMP/ollama-version"; then
      jq -e --arg version "$2" '.version == $version' "$RUNNER_TEMP/ollama-version"
      curl -fsS "$api/api/tags" | jq -e '.models | type == "array"'
      # Some releases serialize the empty model list as null.
      curl -fsS "$api/v1/models" | jq -e '.object == "list" and (.data == null or (.data | type == "array"))'
      return
    fi
    sleep 1
  done
  docker logs "$container"
  return 1
}

start "$baseline" 0.34.4
curl -fsS --data-binary "@$RUNNER_TEMP/ollama-blob" "$api/api/blobs/$digest"
docker rm -f "$container" >/dev/null
start "$candidate" 0.40.16
curl -fsSI "$api/api/blobs/$digest"
docker stats --no-stream "$container"
docker rm -f "$container" >/dev/null
start "$baseline" 0.34.4
curl -fsSI "$api/api/blobs/$digest"
