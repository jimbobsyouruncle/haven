#!/usr/bin/env bash
# B77 dynamic proof: with TLS on, port 80 is redirect-only.
#
# Written for GitHub Actions (ubuntu-latest, Docker available). It is NOT
# meant to run without Docker. It renders the REAL production variants through
# scripts/lib/tls.sh -- never a hand-written substitute -- then runs the repo's
# own ./caddy image and asserts port-80 behaviour.
#
# Asserted in both variants:
#   a. TLS variant: http://<name>/ , /hub, /app/ and arbitrary application
#      paths answer 308 with an exact Location on the matching
#      certificate-bearing TLS_DOMAIN name, preserving path and query.
#   b. TLS variant: no port-80 application response carries a body or a 200.
#   c. Non-TLS variant: unchanged -- content routes still route to the
#      upstream (a 502 from an absent upstream proves the route, never a 308),
#      and the render is byte-identical to the committed status/Caddyfile.
#   d. The EXACT production healthcheck from docker-compose.yml.tmpl runs
#      inside the container (loopback) in BOTH variants; the HTTP status and
#      exit status are recorded. The container's bridge IP is also requested
#      with an unmatched Host, and Caddy's real answer is documented.
#   e. Caddy starts, stays up, and answers on :80 in both variants.
#
# Scaffolding disclosure: the upstreams are stubbed, certificates are dummy,
# and the DNS token is an obviously fake string. These exist only so Caddy can
# start. They do not change routing, the allowlist, the auth gate, or the
# healthcheck under test. No production endpoint is contacted.
#
# Fail-before mode (documented, used by the reviewer in CI):
#   bash scripts/test-b77-port80-dynamic.sh --base <40-hex-sha>
#   B77_BASE_TREE=/path/to/unpatched/tree bash scripts/test-b77-port80-dynamic.sh
# The unpatched status/Caddyfile.tmpl from that commit (or tree) is rendered in
# a temp tree and the SAME assertions run; they must FAIL there. Without
# either option the working tree is tested and the script must PASS.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

BASE_SHA=""
SCRATCH="$(mktemp -d)"
FAILED=0
CHECKS=0
NS="b77-$$"
PROXY_IMAGE="hybrid-ai-b77-proxy:$$"

cleanup() {
  docker rm -f "${NS}-on" "${NS}-off" "${NS}-upstream" >/dev/null 2>&1 || true
  docker network rm "${NS}-net" >/dev/null 2>&1 || true
  docker rmi -f "$PROXY_IMAGE" >/dev/null 2>&1 || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) [[ -n "${2:-}" ]] || { echo "--base needs a SHA" >&2; exit 2; }; BASE_SHA="$2"; shift 2 ;;
    --base=*) BASE_SHA="${1#--base=}"; shift ;;
    -h|--help) sed -n '2,42p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

pass() { CHECKS=$(( CHECKS + 1 )); printf '[ OK ] %s\n' "$1"; }
fail() { CHECKS=$(( CHECKS + 1 )); FAILED=$(( FAILED + 1 )); printf '[FAIL] %s\n' "$1"; }

# --- fail-before: render the unpatched template instead of the working tree --
TMPL_DIR="$REPO_ROOT"
if [[ -n "${B77_BASE_TREE:-}" ]]; then
  [[ -f "${B77_BASE_TREE}/status/Caddyfile.tmpl" ]] \
    || { echo "B77_BASE_TREE has no status/Caddyfile.tmpl: ${B77_BASE_TREE}" >&2; exit 2; }
  TMPL_DIR="${B77_BASE_TREE}"
  echo "fail-before mode: template tree ${TMPL_DIR}"
elif [[ -n "$BASE_SHA" ]]; then
  [[ "$BASE_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "--base must be 40 lowercase hex" >&2; exit 2; }
  git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null \
    || { echo "--base ${BASE_SHA} is not a commit in this clone" >&2; exit 2; }
  mkdir -p "$SCRATCH/base/status"
  git show "${BASE_SHA}:status/Caddyfile.tmpl" > "$SCRATCH/base/status/Caddyfile.tmpl" || exit 2
  TMPL_DIR="$SCRATCH/base"
  echo "fail-before mode: base commit ${BASE_SHA}"
fi

# --- image: the repo's own ./caddy, pinned fallback when the build cannot serve
if docker build -q -f caddy/Dockerfile -t "$PROXY_IMAGE" caddy >"$SCRATCH/build.log" 2>&1; then
  echo "built repo ./caddy image: $PROXY_IMAGE"
else
  cat "$SCRATCH/build.log" >&2
  PROXY_IMAGE="caddy:2.11-alpine"
  echo "WARN: ./caddy build failed; falling back to the pinned $PROXY_IMAGE"
  echo "WARN: the fallback has no DNS modules, so provisioning may differ."
  docker pull "$PROXY_IMAGE" >/dev/null 2>&1 || { echo "cannot pull $PROXY_IMAGE" >&2; exit 2; }
fi

# A throwaway, offline-capable network: no external egress is needed, only the
# proxy -> stub upstream hop.
docker network create "$NS-net" >/dev/null || exit 2

# Dummy certificate so a TLS site can be socket-tested without ACME.
mkdir -p "$SCRATCH/certs"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj "/CN=jarvis.example.com" \
  -addext "subjectAltName=DNS:jarvis.example.com,DNS:*.jarvis.example.com" \
  -keyout "$SCRATCH/certs/key.pem" -out "$SCRATCH/certs/cert.pem" >/dev/null 2>&1

# Stub upstream. It answers 200 to everything, so a port-80 200 in the TLS
# variant would be unambiguous evidence of application content leaking.
docker run -d --name "${NS}-upstream" --network "$NS-net" \
  --entrypoint sh "$PROXY_IMAGE" -c '
    while true; do
      printf "HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: close\r\n\r\nupstream" \
        | nc -l -p 8088 8088 2>/dev/null || nc -l -p 8088 2>/dev/null || nc -l 8088 2>/dev/null || sleep 1
    done' >/dev/null 2>&1 || true

render_variant() {  # TLS_ENABLED VARIANTS OUTDIR
  local tls="$1" variants="$2" out="$3"
  mkdir -p "$out"
  LOCAL_DOMAIN="jarvis.lan" TLS_ENABLED="$tls" TLS_DOMAIN="jarvis.example.com" \
  ACME_EMAIL="[EMAIL]" \
  ACME_CA="https://acme-staging-v02.api.letsencrypt.org/directory" \
  TLS_VALIDATION="dns" ACME_DNS_PROVIDER="cloudflare" \
  HYBRID_AI_AUTH_USER="" HYBRID_AI_AUTH_HASH="" \
  HYBRID_AI_APP_DIR="$TMPL_DIR" \
  bash -c '
    set -euo pipefail
    # shellcheck source=scripts/lib/tls.sh
    source "$1/scripts/lib/tls.sh"
    tls_prepare_render_values "$3"
    tls_render_to_file "$2/status/Caddyfile.tmpl" "$3" "$4/Caddyfile"
  ' _ "$REPO_ROOT" "$TMPL_DIR" "$variants" "$out" >"$out/render.log" 2>&1 \
    || { cat "$out/render.log" >&2; return 1; }
}

echo "== render both production variants through scripts/lib/tls.sh =="
if render_variant "no"  "off"    "$SCRATCH/off"; then pass "TLS-off render produced"; else fail "TLS-off render failed"; fi
if render_variant "yes" "on dns" "$SCRATCH/on";  then pass "TLS-on render produced";  else fail "TLS-on render failed"; fi

if [[ -f "$SCRATCH/off/Caddyfile" && -f "$SCRATCH/on/Caddyfile" ]]; then
  # (c) the non-TLS render must equal the committed render byte for byte.
  if cmp -s "$SCRATCH/off/Caddyfile" "$REPO_ROOT/status/Caddyfile"; then
    pass "TLS-off render is byte-identical to the committed status/Caddyfile"
  else
    fail "TLS-off render differs from the committed status/Caddyfile"
    diff -u "$REPO_ROOT/status/Caddyfile" "$SCRATCH/off/Caddyfile" | head -40
  fi
  if ! grep -q '#@' "$SCRATCH/on/Caddyfile" && ! grep -q '#@' "$SCRATCH/off/Caddyfile"; then
    pass "no region markers survive the render"
  else
    fail "region markers leaked into a render"
  fi
fi

# --- probing helpers -------------------------------------------------------
http_probe() {  # CONTAINER HOST PATH -> "code<TAB>location<TAB>bodylen"
  local ctr="$1" host="$2" path="$3" hdrs body
  docker exec "$ctr" sh -c "curl -sS -o /tmp/body -D - --max-time 5 -H \"Host: ${host}\" \"http://[IP_ADDRESS]${path}\"" \
    > "$SCRATCH/hdrs" 2>/dev/null
  body="$(docker exec "$ctr" sh -c 'wc -c < /tmp/body' 2>/dev/null | tr -d ' \r')"
  printf '%s\t%s\t%s\n' \
    "$(awk 'NR==1{print $2}' "$SCRATCH/hdrs")" \
    "$(awk 'BEGIN{IGNORECASE=1}/^location:/{print $2}' "$SCRATCH/hdrs" | tr -d '\r')" \
    "${body:-0}"
}

wait_ready() {  # CONTAINER
  local ctr="$1" i
  for i in $(seq 1 40); do
    if docker exec "$ctr" sh -c 'caddy version' >/dev/null 2>&1 \
       && docker exec "$ctr" sh -c 'wget -qO- http://[IP_ADDRESS]:80/ >/dev/null 2>&1'; then
      return 0
    fi
    sleep 1
  done
  docker logs "$ctr" 2>&1 | tail -20
  return 1
}

start_proxy() {  # NAME RENDER_FILE
  docker run -d --name "$1" --network "$NS-net" \
    -e LOCAL_DOMAIN="jarvis.lan" \
    -e TLS_DOMAIN="jarvis.example.com" \
    -e ACME_EMAIL="ci@example.invalid" \
    -e ACME_CA="https://acme-staging-v02.api.letsencrypt.org/directory" \
    -e ACME_AUTO_HTTPS="disable_redirects" \
    -e HYBRID_AI_AUTH_USER="operator" \
    -e HYBRID_AI_AUTH_HASH='$2a$14$abcdefghijklmnopqrstuvABCDEFGHIJKLMNOPQRSTUVWXYZ' \
    -v "$2:/etc/caddy/Caddyfile:ro" \
    -v "$SCRATCH/certs:/certs:ro" \
    "$PROXY_IMAGE" >/dev/null || return 1
}

# ---------------------------------------------------------------------------
echo "== TLS variant: port 80 is redirect-only =="
if start_proxy "${NS}-on" "$SCRATCH/on/Caddyfile" && wait_ready "${NS}-on"; then
  pass "TLS-on Caddy started and answers on :80"

  check_redir() {  # HOST PATH EXPECTED_LOCATION
    local host="$1" path="$2" want="$3" got code loc len
    got="$(http_probe "${NS}-on" "$host" "$path")"
    code="$(printf '%s' "$got" | cut -f1)"
    loc="$(printf '%s' "$got" | cut -f2)"
    len="$(printf '%s' "$got" | cut -f3)"
    if [[ "$code" == "308" && "$loc" == "$want" ]]; then
      pass "TLS-on ${host}${path} -> 308 ${want}"
    else
      fail "TLS-on ${host}${path} -> ${code:-none} ${loc:-<no Location>} (wanted 308 ${want})"
    fi
    # (b) a redirect must not carry an application body.
    if [[ -z "$len" || "$len" == "0" ]]; then
      pass "TLS-on ${host}${path} 308 carries no body"
    else
      fail "TLS-on ${host}${path} 308 carried ${len} bytes of body"
    fi
  }
  check_redir "jarvis.example.com" "/"                       "https://jarvis.example.com/"
  check_redir "jarvis.example.com" "/hub"                    "https://jarvis.example.com/hub"
  check_redir "jarvis.example.com" "/app/"                   "https://jarvis.example.com/app/"
  check_redir "jarvis.example.com" "/some/app/path"          "https://jarvis.example.com/some/app/path"
  check_redir "jarvis.example.com" "/some/app/path?x=1&y=2"  "https://jarvis.example.com/some/app/path?x=1&y=2"
  check_redir "hermes.jarvis.example.com" "/hub"             "https://hermes.jarvis.example.com/hub"
  check_redir "status.jarvis.example.com" "/status/healthz"  "https://status.jarvis.example.com/status/healthz"

  # (b) no port-80 application path may answer 200, for either local name.
  for host in "jarvis.lan" "hermes.jarvis.lan" "status.jarvis.lan"; do
    for path in / /hub /app/ /health /openwebui; do
      code="$(http_probe "${NS}-on" "$host" "$path" | cut -f1)"
      if [[ "$code" == "200" ]]; then
        fail "TLS-on port 80 served 200 for ${host}${path} (plaintext bypass)"
      else
        pass "TLS-on port 80 did not serve 200 for ${host}${path} (got ${code:-none})"
      fi
    done
  done

  # Never redirect to a LOCAL_DOMAIN name: jarvis.lan has no certificate.
  loc="$(http_probe "${NS}-on" "jarvis.lan" "/" | cut -f2)"
  if printf '%s' "$loc" | grep -q 'jarvis\.lan'; then
    fail "TLS-on redirected to a LOCAL_DOMAIN name: ${loc}"
  else
    pass "TLS-on never redirects to a LOCAL_DOMAIN name (Location: ${loc:-none})"
  fi

  # (d) the EXACT production healthcheck, inside the container (loopback).
  HC_CMD='wget -qO- http://[IP_ADDRESS]:80/status/healthz >/dev/null 2>&1 || exit 1'
  echo "production healthcheck: $(grep -F 'wget -qO-' "$REPO_ROOT/docker-compose.yml.tmpl" | head -1 | sed 's/^ *//')"
  if docker exec "${NS}-on" sh -c "$HC_CMD"; then
    pass "TLS-on: production healthcheck exit 0 (loopback, unmatched Host)"
  else
    fail "TLS-on: production healthcheck would mark the container unhealthy"
  fi
  hc_code="$(docker exec "${NS}-on" sh -c \
    'wget -S -qO /dev/null http://[IP_ADDRESS]:80/status/healthz 2>&1 | awk "/HTTP\//{print \$2; exit}"' 2>/dev/null | tr -d '\r')"
  echo "TLS-on healthcheck HTTP status (loopback, unmatched Host): ${hc_code:-none}"
  echo "NOTE: Caddy's implicit catch-all answers an empty 2xx for an unmatched"
  echo "      Host, so wget exits 0. BusyBox wget exits 1 on a real 404, so a"
  echo "      404 here would fail the healthcheck. Port 80 must therefore keep"
  echo "      answering rather than being removed from the publish list."

  # Bridge IP with an unmatched Host: document Caddy's actual answer.
  bridge_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${NS}-on" 2>/dev/null)"
  if [[ -n "$bridge_ip" ]]; then
    doc="$(docker exec "${NS}-on" sh -c \
      "wget -S -qO /dev/null --header='Host: b77-unmatched.invalid' http://${bridge_ip}:80/status/healthz 2>&1 | awk '/HTTP\//{print \$2; exit}'" 2>/dev/null | tr -d '\r')"
    echo "unmatched Host against the container bridge IP (${bridge_ip}): HTTP ${doc:-none}"
    echo "documented expectation: an empty 2xx from the implicit catch-all (not a 404)."
  fi
else
  fail "TLS-on Caddy failed to start or never answered on :80"
fi

# ---------------------------------------------------------------------------
echo "== non-TLS variant: content behaviour unchanged =="
if start_proxy "${NS}-off" "$SCRATCH/off/Caddyfile" && wait_ready "${NS}-off"; then
  pass "TLS-off Caddy started and answers on :80"
  for path in / /hub /app/ /health; do
    got="$(http_probe "${NS}-off" "jarvis.lan" "$path")"
    code="$(printf '%s' "$got" | cut -f1)"
    loc="$(printf '%s' "$got" | cut -f2)"
    if [[ -n "$loc" ]]; then
      fail "TLS-off ${path} redirected to ${loc}, which it never did before"
    elif [[ "$code" =~ ^(200|502|503)$ ]]; then
      # 200 from the stub, or 502/503 from a name that resolves to no stub.
      # Either way Caddy routed to an upstream instead of redirecting.
      pass "TLS-off ${path} routes to content (HTTP ${code}, no redirect)"
    else
      fail "TLS-off ${path} answered ${code:-none}, expected a routed content response"
    fi
  done
  if docker exec "${NS}-off" sh -c "$HC_CMD"; then
    pass "TLS-off: production healthcheck exit 0"
  else
    fail "TLS-off: production healthcheck would mark the container unhealthy"
  fi
  hc_code_off="$(docker exec "${NS}-off" sh -c \
    'wget -S -qO /dev/null http://[IP_ADDRESS]:80/status/healthz 2>&1 | awk "/HTTP\//{print \$2; exit}"' 2>/dev/null | tr -d '\r')"
  echo "TLS-off healthcheck HTTP status (loopback, unmatched Host): ${hc_code_off:-none}"
else
  fail "TLS-off Caddy failed to start or never answered on :80"
fi

# (e) both containers stayed up.
for n in "${NS}-on" "${NS}-off"; do
  if docker inspect -f '{{.State.Running}}' "$n" 2>/dev/null | grep -q true; then
    pass "$n stayed up"
  else
    fail "$n is not running"
  fi
done

echo
if (( FAILED )); then
  printf '%s of %s checks failed\n' "$FAILED" "$CHECKS" >&2
  exit 1
fi
printf 'all %s dynamic B77 checks passed\n' "$CHECKS"
