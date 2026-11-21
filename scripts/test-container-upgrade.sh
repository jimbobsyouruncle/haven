#!/usr/bin/env bash
# CI smoke: a pinned image replacement preserves data, unrelated services and rollback.
set -Eeuo pipefail
work="$(mktemp -d)"
project="haven-upgrade-${work##*.}"
project="${project,,}"
compose=(docker compose -p "$project" -f "$work/compose.yml")
cleanup() {
  "${compose[@]}" down --volumes >/dev/null 2>&1 || true
  docker image rm "$project:old" "$project:new" >/dev/null 2>&1 || true
  rm -rf -- "$work"
}
trap cleanup EXIT

cat > "$work/Dockerfile" <<'DOCKERFILE'
FROM caddy:2.11.9-alpine@sha256:003a97808e781aa9f7e75cc2f43d34d461099031faf5e20faefb9f61126836f0
ARG REVISION
LABEL org.haven.test-revision=$REVISION
ENTRYPOINT []
CMD ["sleep", "600"]
DOCKERFILE
for revision in old new; do
  docker build --build-arg "REVISION=$revision" --tag "$project:$revision" "$work"
done

render() {
  cat > "$work/compose.yml" <<YAML
services:
  upgraded:
    image: $project:$1
    volumes:
      - data:/fixture
    healthcheck:
      test: ["CMD", "test", "-d", "/fixture"]
      interval: 1s
      timeout: 1s
      retries: 5
  unrelated:
    image: $project:old
volumes:
  data:
YAML
}

start() {
  "${compose[@]}" up -d --remove-orphans --no-build --pull never --wait --wait-timeout 30
}

render old
start
old_container="$("${compose[@]}" ps -q upgraded)"
unrelated="$("${compose[@]}" ps -q unrelated)"
old_image="$(docker inspect -f '{{.Image}}' "$old_container")"
"${compose[@]}" exec -T upgraded sh -c 'echo retained > /fixture/data'

render new
start
new_container="$("${compose[@]}" ps -q upgraded)"
[[ "$new_container" != "$old_container" ]]
[[ "$(docker inspect -f '{{.Image}}' "$new_container")" != "$old_image" ]]
test "$("${compose[@]}" ps -q unrelated)" = "$unrelated"
test "$("${compose[@]}" exec -T upgraded cat /fixture/data)" = retained

render old
start
test "$(docker inspect -f '{{.Image}}' "$("${compose[@]}" ps -q upgraded)")" = "$old_image"
test "$("${compose[@]}" ps -q unrelated)" = "$unrelated"
test "$("${compose[@]}" exec -T upgraded cat /fixture/data)" = retained
