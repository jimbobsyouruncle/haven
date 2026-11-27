#!/usr/bin/env bash
# Run only on a disposable CI Docker host. The firewall remains until teardown
# of the runner, and the synthetic published listener is removed on exit.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && $EUID == 0 ]] || {
  printf 'This fixture needs a disposable GitHub Actions runner and root.\n' >&2
  exit 1
}
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
caddy_image='caddy:2.11.9-alpine@sha256:003a97808e781aa9f7e75cc2f43d34d461099031faf5e20faefb9f61126836f0'
alpha="haven-persona-test-a-$$"
beta="haven-persona-test-b-$$"
client="client-$$"
server="server-$$"
peer="peer-$$"
published="published-$$"
proxy="proxy-$$"
auth="auth-$$"
proxy_net="haven-persona-proxy"
auth_net="auth-net-$$"
scratch="$(mktemp -d)"

cleanup() {
  docker rm -f "$client" "$server" "$peer" "$published" "$proxy" "$auth" >/dev/null 2>&1 || true
  docker network rm "$alpha" "$beta" "$proxy_net" "$auth_net" >/dev/null 2>&1 || true
  rm -rf -- "$scratch"
}
trap cleanup EXIT

launch_http() {
  docker run -d --name "$1" "${@:2}" --entrypoint /bin/sh "$caddy_image"  \
    -c 'mkdir -p /tmp/www && echo ready >/tmp/www/index.html && exec caddy file-server --listen :8080 --root /tmp/www' >/dev/null
}
launch_client() {
  docker run -d --name "$client" --network "$alpha" --dns 1.1.1.1 --dns 1.0.0.1  \
    --entrypoint /bin/sh "$caddy_image" -c 'exec sleep 120' >/dev/null
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

docker pull "$caddy_image" >/dev/null
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
docker run --rm --network "$beta" --entrypoint wget "$caddy_image" -q -T 4 -O /dev/null "http://$peer:8080"
curl --fail --silent --retry 3 --retry-connrefused "http://127.0.0.1:$published_port/" >/dev/null
deny "http://$peer_ip:8080"
deny "http://$gateway:$published_port"

docker rm -f "$client" "$server" >/dev/null
backend="$(python3 -B "$script_dir/persona-firewall.py" "$alpha" false 900)"
cat > "$scratch/backend.caddy" <<'EOF'
:8080 {
	header +Set-Cookie "haven_auth=blocked; Domain=fixture.test; Path=/; Secure; HttpOnly"
	header +Set-Cookie "filebrowser_quantum_jwt=kept; Path=/; Secure"
	respond "upstream cookies: {http.request.header.Cookie}"
}
EOF
docker run -d --name "$server" --network "$alpha" --ip "$backend" \
  -v "$scratch/backend.caddy:/etc/caddy/Caddyfile:ro" "$caddy_image" >/dev/null
launch_client
same_persona
deny "https://github.com/"
deny 'http://1.1.1.1/'
deny "http://$peer_ip:8080"

if docker exec "$peer" wget -q -T 4 -O /dev/null "http://$backend:8080"; then
  printf 'Peer reached the internet-off FileBrowser endpoint\n' >&2
  exit 1
fi

# Reuse the production wildcard route and cookie handling. The fixture issues
# its own wildcard certificate and uses a real Haven auth verifier.
repo="$(dirname "$script_dir")"
(
  # shellcheck source=scripts/lib/tls.sh
  source "$script_dir/lib/tls.sh"
  tls_render_to_file "$repo/status/Caddyfile.tmpl" "on auth" "$scratch/rendered"
)
for section in trusted_only secure_headers auth persona_files; do
  sed -n "/^(${section}) {$/,/^}$/p" "$scratch/rendered"
done > "$scratch/proxy.caddy"
cat >> "$scratch/proxy.caddy" <<'EOF'
(tls_dns) {
	tls internal
}
EOF
# shellcheck disable=SC2016 # Match the literal Caddy environment placeholder.
sed -n '/^https:\/\/\*\.{$TLS_DOMAIN} {$/,/^}$/p' "$scratch/rendered" >> "$scratch/proxy.caddy"
mkdir "$scratch/routes"
printf 'import persona_files test %s\n' "$backend" > "$scratch/routes/test.caddy"

docker network create "$auth_net" >/dev/null
docker network create --ipv6=false --subnet 10.231.32.0/29 \
  --opt com.docker.network.bridge.name=haven-files-in "$proxy_net" >/dev/null
docker build -q -t haven-auth:persona-fixture "$repo/auth" >/dev/null
docker run -d --name "$auth" --network "$auth_net" --network-alias auth \
  -e TLS_DOMAIN=fixture.test -e HAVEN_AUTH_USER=fixture \
  -e HAVEN_AUTH_HASH=unused -e HAVEN_AUTH_COOKIE_SECRET=persona-fixture \
  haven-auth:persona-fixture >/dev/null
session="$(docker exec "$auth" python3 -c 'import app, time; print(app.sign_expiry(b"persona-fixture", int(time.time()) + 300))')"
docker run -d --name "$proxy" \
  --network "name=$proxy_net,ip=10.231.32.2,gw-priority=1" --network "$auth_net" \
  -p 127.0.0.1::443 -e TLS_DOMAIN=fixture.test \
  -v "$scratch/proxy.caddy:/etc/caddy/Caddyfile:ro" \
  -v "$scratch/routes:/data/persona-files:ro" "$caddy_image" >/dev/null
port="$(docker port "$proxy" 443/tcp | cut -d: -f2)"
curl_args=(--silent --show-error --insecure --noproxy '*' --max-time 5
  --resolve "test-files.fixture.test:$port:127.0.0.1"
  "https://test-files.fixture.test:$port/")
status="$(curl "${curl_args[@]}" --retry 5 --retry-all-errors --output /dev/null --write-out '%{http_code}')"
[[ "$status" == 302 ]]
curl "${curl_args[@]}" --fail \
  --cookie "first=kept; haven_auth=$session; filebrowser_quantum_jwt=fixture" \
  --dump-header "$scratch/headers" --output "$scratch/body"
[[ "$(cat "$scratch/body")" == 'upstream cookies: first=kept; filebrowser_quantum_jwt=fixture' ]]
! grep -i '^set-cookie:.*haven_auth' "$scratch/headers" || exit 1
grep -qi '^set-cookie: filebrowser_quantum_jwt=kept' "$scratch/headers"
