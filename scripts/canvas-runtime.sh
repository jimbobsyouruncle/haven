#!/usr/bin/env bash
# This is the sole normal start path for the Canvas Compose profile.
set -Eeuo pipefail
fail() {
  printf 'Canvas supervisor: %s\n' "$1" >&2
  exit 1
}

stop_canvas() {
  local owner containers
  if ! owner="$(timeout 10 docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}:{{index .Config.Labels "com.docker.compose.service"}}' haven-canvas 2>/dev/null)"; then
    containers="$(timeout 10 docker ps -a --filter 'name=^/haven-canvas$' --format '{{.Names}}' 2>/dev/null)" ||
      return 1
    [[ -z "$containers" ]]
    return
  fi
  [[ "$owner" == haven:canvas ]] || return 1
  timeout 10 docker network disconnect -f haven-canvas-egress haven-canvas 2>/dev/null || true
  timeout 10 docker stop --time 5 haven-canvas >/dev/null 2>&1
}
if [[ ${1:-} == stop ]]; then
  rm -f /run/haven-canvas/firewall-ready
  stop_canvas || fail "could not confirm Canvas stopped"
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
check_hold() {
  [[ ! -e /run/haven-backup-control/canvas-hold && ! -L /run/haven-backup-control/canvas-hold ]] ||
    fail "startup blocked by backup or restore hold"
}

rm -f /run/haven-canvas/firewall-ready
check_hold
stop_canvas || fail "could not confirm Canvas stopped"
enabled || fail "Canvas configuration or ingress is disabled"
canvas_check_identity "$HAVEN_DATA_DIR/canvas_data" \
  "$(_haven_file_get "$HAVEN_STACK_ENV_FILE" CANVAS_UID)" \
  "$(_haven_file_get "$HAVEN_STACK_ENV_FILE" CANVAS_GID)"
recovered_key="$HAVEN_DATA_DIR/canvas_data/settings-key.recovered"
if [[ -e "$recovered_key" || -L "$recovered_key" ]]; then
  if [[ -L "$recovered_key" || ! -f "$recovered_key" ||
        "$(stat -c '%u:%a' -- "$recovered_key")" != 0:600 ||
        "$(< "$recovered_key")" != "$(_haven_file_get "$HAVEN_STACK_ENV_FILE" CANVAS_STATE_KEY)" ]]; then
    echo "Canvas requires the recovered settings key before startup." >&2
    exit 1
  fi
fi
firewall apply || fail "startup firewall gate failed"
trap 'rm -f /run/haven-canvas/firewall-ready; stop_canvas || fail "could not confirm Canvas stopped"' EXIT
trap 'exit 0' TERM INT
check_hold
install -m 0444 /dev/null /run/haven-canvas/firewall-ready
"${compose[@]}" up -d --force-recreate --no-deps --no-build --pull never canvas
container="$(docker inspect -f '{{.Id}}' haven-canvas 2>/dev/null)" ||
  fail "could not identify the started container"

deadline=$(( SECONDS + 180 ))
ready=0
while true; do
  enabled || fail "Canvas configuration or ingress is disabled"
  firewall check || fail "active firewall verification failed"
  state="$(docker inspect -f '{{.Id}}:{{.State.Status}}:{{.State.Health.Status}}' haven-canvas 2>/dev/null)" ||
    fail "could not inspect container health"
  case "$state" in
    "$container":running:healthy)
      if (( ! ready )); then
        systemd-notify --ready
        ready=1
      fi
      ;;
    "$container":running:starting|"$container":running:unhealthy)
      (( ! ready )) || fail "container lost readiness"
      (( SECONDS < deadline )) || fail "startup health probe timed out"
      ;;
    *) fail "container stopped or its identity or health state changed" ;;
  esac
  sleep 2
done
