#!/usr/bin/env bash
# Run only on a disposable CI Docker host. The firewall remains until teardown
# of the runner, and the synthetic published listener is removed on exit.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && $EUID == 0 ]] || {
  printf 'This fixture needs a disposable GitHub Actions runner and root.\n' >&2
  exit 1
}
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
image='caddy:2.11.9-alpine@sha256:003a97808e781aa9f7e75cc2f43d34d461099031faf5e20faefb9f61126836f0'
alpha="haven-persona-test-a-$$"
beta="haven-persona-test-b-$$"
client="client-$$"
server="server-$$"
peer="peer-$$"
published="published-$$"

cleanup() {
  docker rm -f "$client" "$server" "$peer" "$published" >/dev/null 2>&1 || true
  docker network rm "$alpha" "$beta" >/dev/null 2>&1 || true
}
trap cleanup EXIT

launch_http() {
  docker run -d --name "$1" "${@:2}" --entrypoint /bin/sh "$image"     -c 'mkdir -p /tmp/www && echo ready >/tmp/www/index.html && exec caddy file-server --listen :8080 --root /tmp/www' >/dev/null
}
launch_client() {
  docker run -d --name "$client" --network "$alpha" --dns 1.1.1.1 --dns 1.0.0.1     --entrypoint /bin/sh "$image" -c 'exec sleep 120' >/dev/null
}
request() {
  docker exec "$client" wget -q -T 4 -O /dev/null "$1"
}
deny() {
  if request "$1"; then
    printf 'Unexpected access to %s\n' "$1" >&2
    exit 1
  fi
}
same_persona() {
  for _ in {1..5}; do
    if request "http://$server:8080"; then return 0; fi
    sleep 1
  done
  return 1
}

docker pull "$image" >/dev/null
python3 -B "$script_dir/persona-firewall.py" "$alpha" true
python3 -B "$script_dir/persona-firewall.py" "$beta" true
launch_http "$server" --network "$alpha"
launch_http "$peer" --network "$beta"
launch_http "$published" -p 8080
launch_client
same_persona
request "https://github.com/"
peer_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$peer")"
gateway="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}' "$client")"
published_port="$(docker inspect -f '{{(index (index .NetworkSettings.Ports "8080/tcp") 0).HostPort}}' "$published")"
docker run --rm --network "$beta" --entrypoint wget "$image" -q -T 4 -O /dev/null "http://$peer:8080"
curl --fail --silent --retry 3 --retry-connrefused "http://127.0.0.1:$published_port/" >/dev/null
deny "http://$peer_ip:8080"
deny "http://$gateway:$published_port"

docker rm -f "$client" "$server" >/dev/null
python3 -B "$script_dir/persona-firewall.py" "$alpha" false
launch_http "$server" --network "$alpha"
launch_client
same_persona
deny "https://github.com/"
deny 'http://1.1.1.1/'
deny "http://$peer_ip:8080"
