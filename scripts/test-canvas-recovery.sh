#!/usr/bin/env bash
# Exercise the service manager on a disposable CI runner with no Docker or network.
set -euo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
name="haven-canvas-fixture-${work##*.}"
unit="$name.service"
unit_file="/run/systemd/system/$unit"
cleanup() {
  local rc=$?
  if (( rc != 0 )); then journalctl -u "$unit" -o short-monotonic --no-pager || true; fi
  systemctl stop "$unit" || true
  rm -f "$unit_file"
  systemctl daemon-reload
  rm -rf "$work"
}
[[ $EUID == 0 && -d /run/systemd/system ]] || { rm -rf "$work"; exit 2; }
trap cleanup EXIT
mkdir -p "$work"/{bin,lib,status,backup}
printf '  canvas:\n' > "$work/docker-compose.yml"
printf 'import canvas_ingress auth:8080 canvas:8000 canvas\n' > "$work/status/Caddyfile"
printf 'HAVEN_APP_DIR=%q\nHAVEN_DATA_DIR=%q\nHAVEN_STACK_ENV_FILE=%q\n' \
  "$work" "$work" "$work/env" > "$work/lib/haven-env.sh"
printf '_haven_file_get() { echo 1000; }\n' >> "$work/lib/haven-env.sh"
printf 'canvas_check_identity() { :; }\n' > "$work/lib/canvas.sh"
sed -e "s|/opt/haven|$work|g" -e "s|/run/haven-canvas/|/run/$name/|g" \
  -e "s|/run/haven-backup-control/|$work/backup/|g" -e 's/sleep 2$/sleep 0.2/' \
  "$repo/scripts/canvas-runtime.sh" > "$work/canvas-runtime.sh"
sed -e "s|/opt/haven/scripts|$work|g" -e '/docker.service/d' \
  -e "s|RuntimeDirectory=haven-canvas|RuntimeDirectory=$name|" \
  -e 's/RestartSec=30s/RestartSec=2s/' \
  -e "/^\[Service\]/a Environment=PATH=$work/bin:/usr/sbin:/usr/bin:/sbin:/bin CANVAS_FIXTURE=$work CANVAS_GRANT=/run/$name/firewall-ready" \
  "$repo/deploy/haven-canvas.service" > "$unit_file"

cat > "$work/sandbox-firewall.sh" <<'SH'
set -eu
echo "$1" >> "$CANVAS_FIXTURE/trace"
test -f "$CANVAS_FIXTURE/policy-ok"
SH
cat > "$work/bin/docker" <<'SH'
#!/usr/bin/env bash
set -eu
case "$1" in
  compose)
    test -f "$CANVAS_GRANT"
    test -f "$CANVAS_FIXTURE/policy-ok"
    echo start >> "$CANVAS_FIXTURE/trace"
    touch "$CANVAS_FIXTURE/running" ;;
  inspect)
    test -f "$CANVAS_FIXTURE/running"
    case "$3" in
      *Labels*) echo haven:canvas ;;
      '{{.Id}}') echo fixture ;;
      *Health*) printf 'fixture:running:%s\n' "$(< "$CANVAS_FIXTURE/health")" ;;
      *) exit 1 ;;
    esac ;;
  ps) test ! -f "$CANVAS_FIXTURE/running" ;;
  network)
    test ! -e "$CANVAS_GRANT"
    echo disconnect >> "$CANVAS_FIXTURE/trace" ;;
  stop)
    test ! -e "$CANVAS_GRANT"
    echo stop >> "$CANVAS_FIXTURE/trace"
    rm -f "$CANVAS_FIXTURE/running" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$work/bin/docker"
wait_for() {
  local i
  for ((i=0; i<100; i++)); do
    if "$@"; then return 0; fi
    sleep 0.1
  done
  return 1
}
retry_pending() {
  [[ "$(systemctl show -p SubState --value "$unit")" == auto-restart &&
     ! -e "$work/running" && ! -e "/run/$name/firewall-ready" ]]
}
tried_at_least_twice() {
  [[ "$(grep -c '^canvas-apply$' "$work/trace" 2>/dev/null || true)" -ge 2 ]]
}

systemctl daemon-reload
echo starting > "$work/health"
# Cold boot with an unavailable uplink, followed by delayed application readiness.
systemctl start --no-block "$unit"
wait_for retry_pending
wait_for tried_at_least_twice
wait_for retry_pending
if grep -qx start "$work/trace"; then exit 1; fi
touch "$work/policy-ok"
wait_for test -f "$work/running"
[[ "$(systemctl show -p ActiveState --value "$unit")" == activating ]]
echo healthy > "$work/health"
wait_for systemctl is-active --quiet "$unit"

# Loss of the verified topology stops the workload, then recovery rechecks it.
rm "$work/policy-ok"
wait_for retry_pending
grep -qx disconnect "$work/trace"
grep -qx stop "$work/trace"
touch "$work/policy-ok"
wait_for systemctl is-active --quiet "$unit"

# Explicit stop cancels a queued restart even when conditions improve.
rm "$work/policy-ok"
wait_for retry_pending
systemctl stop "$unit"
touch "$work/policy-ok"
sleep 3
[[ "$(systemctl show -p ActiveState --value "$unit")" == inactive ]]
test ! -e "$work/running"
test ! -e "/run/$name/firewall-ready"
echo "Canvas recovery lifecycle passed"
