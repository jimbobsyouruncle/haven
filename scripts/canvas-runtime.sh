#!/usr/bin/env bash
# This is the sole normal start path for the Canvas Compose profile.
set -Eeuo pipefail
stop_canvas() {
  local owner
  owner="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}:{{index .Config.Labels "com.docker.compose.service"}}' haven-canvas 2>/dev/null)" ||
    return 0
  [[ "$owner" == haven:canvas ]] || return 1
  timeout 10 docker network disconnect -f haven-canvas-egress haven-canvas 2>/dev/null || true
  timeout 10 docker stop --time 5 haven-canvas >/dev/null
}
if [[ ${1:-} == stop ]]; then
  rm -f /run/haven-canvas/firewall-ready
  stop_canvas
  exit
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/haven-env.sh
source "$script_dir/lib/haven-env.sh"
# shellcheck source=scripts/lib/canvas.sh
source "$script_dir/lib/canvas.sh"

app_dir="$HAVEN_APP_DIR"
[[ "$app_dir" == /opt/haven ]] || exit 1
enabled() {
  grep -Fxq '  canvas:' "$app_dir/docker-compose.yml" &&
    grep -Fq 'import canvas_ingress auth:8080 canvas:8000 canvas' "$app_dir/status/Caddyfile"
}
compose=(docker compose -p haven --env-file "$HAVEN_STACK_ENV_FILE"
         --project-directory "$app_dir" -f "$app_dir/docker-compose.yml"
         --profile canvas)
firewall() {
  bash "$script_dir/sandbox-firewall.sh" "canvas-$1"
}

rm -f /run/haven-canvas/firewall-ready
stop_canvas
enabled
canvas_check_identity "$HAVEN_DATA_DIR/canvas_data" \
  "$(_haven_file_get "$HAVEN_STACK_ENV_FILE" CANVAS_UID)" \
  "$(_haven_file_get "$HAVEN_STACK_ENV_FILE" CANVAS_GID)"
firewall apply
trap 'rm -f /run/haven-canvas/firewall-ready; stop_canvas' EXIT
trap 'exit 0' TERM INT
install -m 0444 /dev/null /run/haven-canvas/firewall-ready
"${compose[@]}" up -d --force-recreate --no-deps --no-build --pull never canvas
container="$(docker inspect -f '{{.Id}}' haven-canvas)"

deadline=$(( SECONDS + 180 ))
ready=0
while enabled && firewall check; do
  state="$(docker inspect -f '{{.Id}}:{{.State.Status}}:{{.State.Health.Status}}' haven-canvas)"
  case "$state" in
    "$container":running:healthy)
      if (( ! ready )); then
        systemd-notify --ready
        ready=1
      fi
      ;;
    "$container":running:starting)
      (( ready || SECONDS < deadline )) || exit 1
      ;;
    *) exit 1 ;;
  esac
  sleep 2
done
exit 1
