#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-tls-installer-render.sh
# PURPOSE (plain English):
#   Self-test for the TLS installer renderer in scripts/lib/tls.sh. It copies
#   the two managed-region templates into a throwaway APP_DIR, renders the
#   TLS-off and TLS-on variants, and checks three things:
#     1. the TLS-off render is byte-identical to the tracked status/Caddyfile
#        and docker-compose.yml,
#     2. rendering twice produces byte-identical files (idempotency),
#     3. the TLS-on render keeps the controls section 9 requires.
#   It never touches the real files and never needs root, Docker or Caddy.
#
# HOW TO RUN IT:
#   ./scripts/test-tls-installer-render.sh
# ---------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/haven-env.sh
source "${SCRIPT_DIR}/lib/haven-env.sh"
if ! haven_env_load; then
  printf 'FATAL: haven_env_load failed; cannot resolve the repository directory.\n' >&2
  exit 2
fi
# shellcheck source=scripts/lib/tls.sh
source "${HAVEN_APP_DIR}/scripts/lib/tls.sh"

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

APP_DIR="$WORK/app"
mkdir -p "$APP_DIR/status" "$APP_DIR/openhands"
cp "${HAVEN_APP_DIR}/status/Caddyfile.tmpl" "$APP_DIR/status/Caddyfile.tmpl"
cp "${HAVEN_APP_DIR}/docker-compose.yml.tmpl" "$APP_DIR/docker-compose.yml.tmpl"
cp "${HAVEN_APP_DIR}/openhands/canvas-ingress.caddyfile" "$APP_DIR/openhands/"

FAILED=0
pass() { printf '[ OK ] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; FAILED=1; }

# Probe classification takes only curl's status, redirect URL, and the apex.
if tls_https_login_gate 200 '' example.test &&
   tls_https_login_gate 302 'https://example.test/auth/login?next=%2F' example.test; then
  pass "HTTPS health accepts a successful response or the apex login redirect"
else
  fail "HTTPS health refused a successful response or the apex login redirect"
fi
if tls_https_login_gate 308 'https://example.test/auth/login' example.test ||
   tls_https_login_gate 302 'https://example.test.invalid/auth/login' example.test ||
   tls_https_login_gate 302 'https://example.test/auth/login/extra' example.test; then
  fail "HTTPS health accepted an unexpected redirect"
else
  pass "HTTPS health refuses other redirect codes, hosts and paths"
fi

render() {  # VARIANTS OUTDIR
  local variants="$1" out="$2"
  mkdir -p "$out"
  tls_prepare_render_values "$variants"
  tls_render_to_file "$APP_DIR/status/Caddyfile.tmpl" "$variants" "$out/Caddyfile"
  tls_render_to_file "$APP_DIR/docker-compose.yml.tmpl" "$variants" "$out/docker-compose.yml"
}

render "on auth canvas" "$WORK/canvas"
if rg -Fq 'import canvas_ingress auth:8080 canvas:8000 canvas' "$WORK/canvas/Caddyfile" &&
   rg -Fq '(canvas_ingress) {' "$WORK/canvas/Caddyfile" &&
   ! rg -Fq '%CANVAS_INGRESS_SNIPPET%' "$WORK/canvas/Caddyfile" &&
   rg -Fq 'com.docker.network.bridge.gateway_mode_ipv4: isolated' "$WORK/canvas/docker-compose.yml"; then
  pass "Canvas candidate shares the qualified authenticated ingress on an isolated bridge"
else
  fail "Canvas ingress or private bridge is missing from the candidate"
fi
if (render "on canvas" "$WORK/unauthenticated") >/dev/null 2>&1; then
  fail "Canvas candidate rendered without Haven authentication"
else
  pass "Canvas candidate requires Haven authentication"
fi

# --- TLS off ---------------------------------------------------------------
LOCAL_DOMAIN="jarvis.lan"
TLS_ENABLED="no"
render off "$WORK/off1"
render off "$WORK/off2"

if cmp -s -- "${HAVEN_APP_DIR}/status/Caddyfile" "$WORK/off1/Caddyfile"; then
  pass "TLS-off Caddyfile render is byte-identical to the tracked file"
else
  fail "TLS-off Caddyfile render differs from the tracked file"
  diff -u "${HAVEN_APP_DIR}/status/Caddyfile" "$WORK/off1/Caddyfile" >&2 || true
fi

if cmp -s -- "${HAVEN_APP_DIR}/docker-compose.yml" "$WORK/off1/docker-compose.yml"; then
  pass "TLS-off compose render is byte-identical to the tracked file"
else
  fail "TLS-off compose render differs from the tracked file"
  diff -u "${HAVEN_APP_DIR}/docker-compose.yml" "$WORK/off1/docker-compose.yml" >&2 || true
fi

if cmp -s -- "$WORK/off1/Caddyfile" "$WORK/off2/Caddyfile" \
   && cmp -s -- "$WORK/off1/docker-compose.yml" "$WORK/off2/docker-compose.yml"; then
  pass "TLS-off render is idempotent (two runs identical)"
else
  fail "TLS-off render is not idempotent"
fi

# Caddy /data isolation: the proxy bind source must be a sibling of webui_data
# (${HAVEN_DATA_DIR}/caddy), so once TLS is enabled ACME private keys land
# OUTSIDE the tree the status container mounts read-only.
off_compose="$WORK/off1/docker-compose.yml"
if python3 - "$off_compose" <<'PYBINDS'
import re
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
proxy = text.split('  proxy:', 1)[1]
status = text.split('  status:', 1)[1].split('  proxy:', 1)[0]
prefix = '${HAVEN_DATA_DIR:?HAVEN_DATA_DIR must be set - run ./install.sh}'
assert re.search(re.escape('source: ' + prefix + '/caddy') +
                 r'\n        target: /data\n        bind:\n          create_host_path: false', proxy)
assert re.search(re.escape('source: ' + prefix + '/webui_data') +
                 r'\n        target: /data/webui_data\n        read_only: true\n        bind:\n          create_host_path: false', status)
assert 'webui_data/caddy' not in text
PYBINDS
then
  pass "Caddy state stays outside read-only status data; both binds refuse missing sources"
else
  fail "Caddy/status persistence boundary or bind-source creation control changed"
fi

# --- TLS on ----------------------------------------------------------------
TLS_ENABLED="yes"
TLS_DOMAIN="daemonhub.dev"
ACME_EMAIL="admin@daemonhub.dev"
TLS_VALIDATION="dns"
ACME_DNS_PROVIDER="cloudflare"
ACME_CA="$TLS_CA_STAGING_URL"
render "on dns" "$WORK/on1"
render "on dns" "$WORK/on2"

if cmp -s -- "$WORK/on1/Caddyfile" "$WORK/on2/Caddyfile" \
   && cmp -s -- "$WORK/on1/docker-compose.yml" "$WORK/on2/docker-compose.yml"; then
  pass "TLS-on render is idempotent (two runs identical)"
else
  fail "TLS-on render is not idempotent"
fi

# Exactly one managed region produces exactly one HTTPS site block.
n_https="$(grep -c '^https://' "$WORK/on1/Caddyfile" || true)"
if [[ "$n_https" == "4" ]]; then
  pass "TLS-on Caddyfile has exactly 4 https:// sites"
else
  fail "TLS-on Caddyfile has ${n_https} https:// sites (expected 4)"
fi

for snippet in '(trusted_only)' '(secure_headers)'; do
  if diff -q <(awk -v s="$snippet" 'index($0,s)==1{f=1} f{print} f&&/^}/{exit}' "${HAVEN_APP_DIR}/status/Caddyfile") \
             <(awk -v s="$snippet" 'index($0,s)==1{f=1} f{print} f&&/^}/{exit}' "$WORK/on1/Caddyfile") >/dev/null; then
    pass "${snippet} is byte-for-byte unchanged in the TLS-on render"
  else
    fail "${snippet} changed in the TLS-on render"
  fi
done

# Named-matcher placement invariant. (trusted_only) defines the named matcher
# @untrusted, and Caddy allows a named matcher to be defined only once per site,
# so a site that imports the snippet BOTH at site level and inside its handles is
# rejected outright ("matcher is defined more than once"). The rule: one level
# per site -- site level only when the block has no handle/handle_path children,
# per handle otherwise. (auth) follows the same rule for uniformity.
check_named_matcher_placement() {  # FILE
  local file="$1" out name handles snippet site nested problems=""
  out="$(awk '
    BEGIN { n = split("trusted_only auth", S, " ") }
    /^https?:\/\// {
      inblock = 1
      name = $1
      handles = 0
      split("", site)
      split("", nested)
      next
    }
    inblock {
      line = $0
      match(line, /^\t*/)
      tabs = RLENGTH
      if (line ~ /(^|[ \t])handle(_path)?[ \t]/) handles++
      if (line ~ /^[ \t]*import (trusted_only|auth)$/) {
        if (tabs == 1) site[$NF]++
        else if (tabs >= 2) nested[$NF]++
      }
      if (line ~ /^}/) {
        for (i = 1; i <= n; i++) {
          printf "%s|%d|%s|%d|%d\n", name, handles, S[i], site[S[i]] + 0, nested[S[i]] + 0
        }
        inblock = 0
      }
    }
  ' "$file")"
  while IFS='|' read -r name handles snippet site nested; do
    [[ -z "$name" ]] && continue
    if (( site > 0 && nested > 0 )); then
      problems+=" ${name} defines ${snippet} twice (site level and per handle);"
    elif (( handles > 0 && site > 0 )); then
      problems+=" ${name} imports ${snippet} at site level but has handles;"
    elif (( handles == 0 && nested > 0 )); then
      problems+=" ${name} imports ${snippet} per handle but has no handle;"
    fi
  done <<< "$out"
  if [[ -n "$problems" ]]; then
    printf '%s\n' "$problems" >&2
    return 1
  fi
  return 0
}

if check_named_matcher_placement "$WORK/on1/Caddyfile"; then
  pass "every named-matcher snippet is imported at exactly one level per site (never site level plus handles)"
else
  fail "a named-matcher snippet is imported at two levels in one site (Caddy: matcher defined more than once)"
fi

expect() {  # FILE PATTERN MESSAGE
  if grep -q -- "$2" "$1"; then pass "$3"; else fail "$3"; fi
}
reject() {  # FILE PATTERN MESSAGE
  if grep -q -- "$2" "$1"; then fail "$3"; else pass "$3"; fi
}

expect "$WORK/on1/Caddyfile" '100\.64\.0\.0/10 fd7a:115c:a1e0::/48' \
  "allowlist (RFC1918 + mesh /10 + fd7a:115c:a1e0::/48) preserved"
expect "$WORK/on1/Caddyfile" '127\.0\.0\.1/8 ::1' "loopback allowlist entry preserved"
expect "$WORK/on1/Caddyfile" $'^\tadmin localhost:2019$' \
  "TLS-on Caddyfile binds admin on in-container loopback"
expect "$WORK/off1/Caddyfile" 'admin off' "TLS-off Caddyfile keeps admin off"

# B1: `auto_https off` disables Caddy's certificate management, so a DNS-01
# install would "succeed" and issue no certificate. The explicit http:// block
# is the 308 redirect, so disable_redirects is the correct value.
expect "$WORK/on1/Caddyfile" '^[[:space:]]*auto_https disable_redirects$' \
  "TLS-on DNS-01 Caddyfile keeps certificate management (auto_https disable_redirects)"
reject "$WORK/on1/Caddyfile" 'auto_https off' \
  "TLS-on DNS-01 Caddyfile does not disable certificate management (no auto_https off)"

expect "$WORK/on1/docker-compose.yml" '^      - "443:443"$' "TLS-on compose publishes 443"
reject "$WORK/off1/docker-compose.yml" '"443:443"' "TLS-off compose does not publish 443"
expect "$WORK/on1/docker-compose.yml" '^secrets:' "TLS-on compose declares a file-backed secret"
expect "$WORK/on1/docker-compose.yml" 'file: .*HAVEN_TLS_TOKEN_FILE' \
  "TLS-on compose secret is file-backed, not environment-backed"
reject "$WORK/off1/docker-compose.yml" '^secrets:' "TLS-off compose has no secrets: block"
reject "$WORK/on1/docker-compose.yml" '2019:2019' "admin port is never published"
expect "$WORK/on1/docker-compose.yml" 'no-new-privileges:true' \
  "container hardening preserved in the TLS-on compose"
expect "$WORK/on1/docker-compose.yml" 'mem_limit: 128m' \
  "proxy memory cap preserved in the TLS-on compose"

# The TLS-on render points the proxy at a local build context. If that context
# or its Dockerfile is missing, `docker compose build` fails at install time --
# after the render, deep in the build phase. Catch it here instead.
if awk '/^  proxy:/{p=1} p&&/^    build:/{b=1} b&&/context: .\/caddy$/{c=1} b&&/dockerfile: Dockerfile$/{d=1} p&&/^  [a-z]/&&!/^  proxy:/{exit} END{exit !(c&&d)}' \
     "$WORK/on1/docker-compose.yml"; then
  pass "TLS-on compose proxy declares build context ./caddy and Dockerfile Dockerfile"
else
  fail "TLS-on compose proxy does not declare build context ./caddy with Dockerfile"
fi
if [[ -f "${HAVEN_APP_DIR}/caddy/Dockerfile" ]]; then
  pass "the proxy build context ./caddy/Dockerfile exists in the tree"
else
  fail "the proxy build context ./caddy/Dockerfile is MISSING from the tree"
fi
reject "$WORK/off1/docker-compose.yml" 'context: ./caddy' \
  "TLS-off compose proxy has no build stanza (stock image path unchanged)"

# --- TLS on, RFC 2136 + HTTP-01 variants render too ------------------------
ACME_DNS_PROVIDER="rfc2136"
RFC2136_KEY_NAME="acme-daemonhub"
RFC2136_SERVER="ns1.daemonhub.dev:53"
render "on dns" "$WORK/rfc2136"
expect "$WORK/rfc2136/Caddyfile" 'dns rfc2136 {' "rfc2136 solver block renders"
expect "$WORK/rfc2136/docker-compose.yml" 'rfc2136_key_secret' "rfc2136 secret name renders"

ACME_DNS_PROVIDER="cloudflare"
TLS_VALIDATION="http"
render "on dns" "$WORK/http01"
expect "$WORK/http01/Caddyfile" 'redir https://{host}{uri} 308' \
  "http-01 render keeps the HTTP->HTTPS redirect"
expect "$WORK/http01/Caddyfile" '^[[:space:]]*auto_https disable_redirects$' \
  "http-01 render keeps certificate management (auto_https disable_redirects)"
reject "$WORK/http01/Caddyfile" 'auto_https off' \
  "http-01 render does not disable certificate management"

# --- TLS-ALPN-01: the other non-http mode keeps certificate management ------
TLS_VALIDATION="tlsalpn"
ACME_DNS_PROVIDER="cloudflare"
render "on" "$WORK/tlsalpn"
expect "$WORK/tlsalpn/Caddyfile" '^[[:space:]]*auto_https disable_redirects$' \
  "tls-alpn-01 render keeps certificate management (auto_https disable_redirects)"
reject "$WORK/tlsalpn/Caddyfile" 'auto_https off' \
  "tls-alpn-01 render does not disable certificate management"

# --- B3: the completion output names a staging issuer and the fix ----------
TLS_VALIDATION="dns"
ACME_DNS_PROVIDER="cloudflare"
ACME_CA="$TLS_CA_STAGING_URL"
TLS_CA_URL="$(tls_validate_ca "$ACME_CA")"
staging_banner="$(tls_print_ca_caution 2>&1 || true)"
if [[ "$staging_banner" == *STAGING* ]] \
   && [[ "$staging_banner" == *"--tls-acme-ca production"* ]] \
   && [[ "$staging_banner" == *"ACME_CA=production"* ]]; then
  pass "staging CA completion output warns about untrusted certificates and names the fix"
else
  fail "staging CA completion output did not warn about untrusted certificates and the fix"
fi

ACME_CA="$TLS_CA_PRODUCTION_URL"
TLS_CA_URL="$(tls_validate_ca "$ACME_CA")"
production_banner="$(tls_print_ca_caution 2>&1 || true)"
if [[ -z "$production_banner" ]]; then
  pass "production CA completion output carries no staging warning"
else
  fail "production CA completion output printed a staging warning"
fi

# --- M1: RFC 2136 values are validated BEFORE interpolation ----------------
# tls__die exits the current shell, so every probe runs in a subshell.
# The payload is the audit finding: a newline plus `}` closes the dns block and
# injects an arbitrary directive. It must be refused, not rendered.
try_prepare() {  # -> 0 accepted, non-zero refused; stderr kept in $WORK/inject.err
  ( tls_prepare_render_values "on dns" ) >/dev/null 2>"$WORK/inject.err"
}

ACME_DNS_PROVIDER="rfc2136"
TLS_VALIDATION="dns"
ENV_FILE="fixture.env"
RFC2136_KEY_NAME="acme-daemonhub"
RFC2136_SERVER=$'ns1.daemonhub.dev:53\n\t}\n\tadmin off\n\tx {'
if try_prepare; then
  fail "RFC2136_SERVER newline-injection payload was accepted"
else
  pass "RFC2136_SERVER newline-injection payload is rejected"
fi
if grep -q 'RFC2136_SERVER' "$WORK/inject.err"; then
  pass "the injection refusal names RFC2136_SERVER"
else
  fail "the injection refusal does not name RFC2136_SERVER"
fi

RFC2136_SERVER="ns1.daemonhub.dev:53"
RFC2136_KEY_NAME=$'acme\n\t} admin off\nx {'
if try_prepare; then
  fail "RFC2136_KEY_NAME newline-injection payload was accepted"
else
  pass "RFC2136_KEY_NAME newline-injection payload is rejected"
fi

RFC2136_KEY_NAME="acme-daemonhub"
RFC2136_SERVER="ns1.daemonhub.dev;rm -rf /"
if try_prepare; then
  fail "RFC2136_SERVER with a shell metacharacter was accepted"
else
  pass "RFC2136_SERVER with a shell metacharacter is rejected"
fi

RFC2136_SERVER="[::1]:53"
if try_prepare; then
  pass "RFC2136_SERVER accepts an IP literal with a port"
else
  fail "RFC2136_SERVER refused a valid IP literal with a port"
fi


# --- B77: port 80 is redirect-only when TLS is on -------------------------
# The non-TLS render must keep serving content on port 80. The TLS render must
# serve ONLY redirects there, to certificate-bearing TLS_DOMAIN names, and must
# never redirect to a LOCAL_DOMAIN name (no certificate exists for it). These
# assertions are textual: the dynamic proof runs in CI with a real Caddy.
off_caddy="$WORK/off1/Caddyfile"
on_caddy="$WORK/on1/Caddyfile"

for site in "http://{\$LOCAL_DOMAIN}" "http://hermes.{\$LOCAL_DOMAIN}" "http://status.{\$LOCAL_DOMAIN}"; do
  if [[ "$(grep -Fxc -- "${site} {" "$off_caddy")" == "1" ]]; then
    pass "TLS-off keeps the content site ${site}"
  else
    fail "TLS-off lost the content site ${site}"
  fi
  if [[ "$(grep -Fxc -- "${site} {" "$on_caddy")" == "1" ]]; then
    pass "TLS-on keeps a port-80 site block for ${site}"
  else
    fail "TLS-on lost the port-80 site block for ${site}"
  fi
done

# Pull one site block out of a render, so assertions below cannot accidentally
# match a neighbour's directive.
site_block() {  # FILE SITE
  awk -v s="$2 {" 'index($0,s)==1 {f=1} f {print} f && /^}/ {exit}' "$1"
}

# TLS-on: exact 308 targets, and no application content on port 80 at all.
check_redir() {  # SITE EXPECTED_LOCATION
  local site="$1" want="$2" block
  block="$(site_block "$on_caddy" "$site")"
  if [[ "$block" == *"redir ${want} 308"* ]] \
     && [[ "$block" == *'import trusted_only'* ]] \
     && [[ "$block" != *'reverse_proxy'* ]] \
     && [[ "$block" != *'handle'* ]]; then
    pass "TLS-on ${site} is redirect-only to ${want} with trusted_only"
  else
    fail "TLS-on ${site} is not a bare 308 redirect to ${want} (fail-closed allowlist kept)"
  fi
}
check_redir "http://{\$LOCAL_DOMAIN}"        "https://{\$TLS_DOMAIN}{uri}"
check_redir "http://hermes.{\$LOCAL_DOMAIN}" "https://hermes.{\$TLS_DOMAIN}{uri}"
check_redir "http://status.{\$LOCAL_DOMAIN}" "https://status.{\$TLS_DOMAIN}{uri}"

# No redirect may target a LOCAL_DOMAIN name: jarvis.lan has no certificate.
if grep -Eq "redir https://[^ {]*\\{\\$LOCAL_DOMAIN\\}" "$on_caddy"; then
  fail "TLS-on redirects to a LOCAL_DOMAIN name, which has no certificate"
else
  pass "TLS-on never redirects to a LOCAL_DOMAIN name"
fi

# The existing TLS_DOMAIN -> HTTPS redirect site is untouched by this change.
if [[ "$(grep -Fxc -- "http://{\$TLS_DOMAIN}, http://*.{\$TLS_DOMAIN} {" "$on_caddy")" == "1" ]] \
   && [[ "$(site_block "$on_caddy" "http://{\$TLS_DOMAIN}, http://*.{\$TLS_DOMAIN}")" == *'redir https://{host}{uri} 308'* ]]; then
  pass "the existing TLS_DOMAIN 308 redirect site is unchanged"
else
  fail "the existing TLS_DOMAIN 308 redirect site changed"
fi

# TLS-off must keep the application routes on port 80 (content preserved).
off_apex="$(site_block "$off_caddy" "http://{\$LOCAL_DOMAIN}")" 
for route in '/status*' '/hub*' '/health' '/ollama/*' '/openwebui*' '/chat*'; do
  if [[ "$off_apex" == *"handle ${route} {"* ]] || [[ "$off_apex" == *"handle_path ${route} {"* ]]; then
    pass "TLS-off port 80 still routes ${route}"
  else
    fail "TLS-off port 80 no longer routes ${route}"
  fi
done
if [[ "$off_apex" == *'reverse_proxy open-webui:8080'* ]]; then
  pass "TLS-off port 80 still serves the catch-all content route"
else
  fail "TLS-off port 80 lost the catch-all content route"
fi

# The non-TLS render must not contain ANY redirect-only site (the change must
# not leak into the TLS-off variant).
if [[ "$(grep -c 'redir https://' "$off_caddy" || true)" == "0" ]]; then
  pass "TLS-off render contains no HTTPS redirect (content behaviour unchanged)"
else
  fail "TLS-off render gained an HTTPS redirect"
fi

if (( FAILED )); then
  printf '\nsome checks failed\n' >&2
  exit 1
fi
printf '\nall render checks passed\n'
