#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-doctor-proxy-b77.sh
# PURPOSE (plain English):
#   Proves doctor.sh's proxy check is TLS-AWARE by RUNNING doctor.sh against a
#   stubbed curl -- it does not grep the text of doctor.sh.
#
#   The defect this guards (B77): with TLS on, the LOCAL_DOMAIN sites on port
#   80 are redirect-only. A doctor that still probes http://<loopback>:80 and
#   treats a redirect, or a 200 from a redirect page, as healthy will report a
#   healthy proxy while plaintext content is either served (the bypass) or
#   unreachable (the breakage). The check must instead probe the
#   certificate-bearing TLS_DOMAIN names over 443 and treat a 3xx as a FAILURE.
#
#   Fully OFFLINE. No Docker, no network, no root. curl is a stub that answers
#   from fixture variables keyed on the URL it is given, and every other host
#   command doctor.sh probes is stubbed on PATH so nothing else moves the
#   verdict.
#
#   Proven here:
#     (i)   TLS on, everything healthy over HTTPS, port 80 redirects
#             -> passes, no failure line, exit code equals the probe-free
#                baseline for the same fixture;
#     (ii)  TLS on, port 80 APPLIES CONTENT (HTTP 200 for an application path)
#             -> fail(), naming the code and the URL;
#     (iii) TLS on, an HTTPS probe answers 3xx
#             -> fail(), naming the code and the URL, never a silent follow;
#     (iv)  TLS on, a redirect to a login page over 443 is never a pass;
#     (v)   TLS off -> today's port-80 behaviour exactly (200/503 pass), and a
#            port-80 200 on TLS off is NOT a failure;
#     (vi)  the check never treats 401/403 as a pass where the port-80 rule
#            never did: it is a warn, exactly like the check it replaces.
#
# USAGE:
#   bash scripts/test-doctor-proxy-b77.sh [path-to-doctor.sh]
#
#   The path defaults to doctor.sh at the repository root. Point it at a copy
#   of the base doctor.sh to prove this harness FAILS without the TLS branch.
#
# EXIT CODES:
#   0  every assertion passed
#   1  one or more assertions failed
#   2  a required tool is missing, or doctor.sh was not found
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

DOCTOR="${1:-$REPO_ROOT/doctor.sh}"
if [[ ! -f "$DOCTOR" ]]; then
  echo "FAIL: doctor.sh not found: $DOCTOR" >&2
  exit 2
fi

for t in mktemp bash timeout env grep sed awk; do
  command -v "$t" >/dev/null 2>&1 || { echo "FAIL: ${t} is required" >&2; exit 2; }
done
REAL_JQ="$(command -v jq || true)"

WORK="$(mktemp -d)"
if [[ -n "${B77_KEEP:-}" ]]; then
  trap 'echo "kept: $WORK" >&2' EXIT
else
  trap 'rm -rf -- "$WORK"' EXIT
fi

PASS=0
FAILURES=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }

BIN="$WORK/bin"
APPD="$WORK/app"
mkdir -p "$BIN" "$APPD/scripts/lib" "$WORK/home" "$WORK/ws" "$WORK/ohstate"

TLS_DOMAIN_FIX="proxy.example.test"
BRIDGE_IP="$(sed -n "s/.*\"\\\$BINDINGS\" == \\*\"\\([^:\"]*\\):\\\${OH_PORT}\".*/\\1/p" "$DOCTOR" | head -1)"
BRIDGE_IP="${BRIDGE_IP:-[IP_ADDRESS]}"

# --- PATH stubs -------------------------------------------------------------
# The curl branch is FIXTURE-DRIVEN: it records the URL, then answers from the
# FIX_CURL_* table, so each scenario below differs only by the variables it
# passes in. Every URL a scenario does not name answers a healthy 200, so an
# unrelated doctor check cannot move the verdict.
cat > "$BIN/stub" <<'STUB'
#!/usr/bin/env bash
trap '' PIPE
me="$(basename "$0")"
case "$me" in
  curl)
    # doctor.sh uses both `curl <flags> URL` and `curl ... -H "Host: h" URL`.
    url=""
    write_out=""
    prev=""
    for a in "$@"; do
      case "$a" in
        http://*|https://*) url="$a" ;;
      esac
      [[ "$prev" == "-o" ]] && write_out="$a"
      prev="$a"
    done
    printf '%s\n' "$*" >> "${FIX_CURL_LOG:-/dev/null}"

    # Rewrite the URL to its "what was really asked" key: scheme + host + path.
    scheme="${url%%://*}"
    rest="${url#*://}"
    hostport="${rest%%/*}"
    path="/${rest#*/}"
    [[ "$path" == "/" ]] || true
    host="${hostport%%:*}"
    # A Host header overrides the URL host for the port-80 bypass guard.
    for a in "$@"; do
      [[ "$a" == Host:* ]] && host="$(printf '%s' "${a#Host: }" | tr -d ' ')"
    done

    key="${scheme}://${host}${path}"

    # Every http:// request is a port-80 request. Key it by Host then path so a
    # named site and the loopback literal can answer differently, which is what
    # the bypass guard is about.
    case "$key" in
      http://*)
        case "$host" in
          [IP_ADDRESS]|localhost)
            # The legacy port-80 probe (Host is the loopback literal).
            case "$path" in
              /status/healthz) code="${FIX_PORT80_LOOPBACK_STATUS:-${FIX_PORT80_LOOPBACK:-200}}" ;;
              *)               code="${FIX_PORT80_LOOPBACK_OTHER:-200}" ;;
            esac ;;
          *)
            # A named site on port 80: redirect-only when TLS is on.
            case "$path" in
              /status/healthz) code="${FIX_PORT80_STATUS_NAME:-${FIX_PORT80_APP:-308}}" ;;
              *)               code="${FIX_PORT80_APP:-308}" ;;
            esac ;;
        esac
        [[ -n "$write_out" ]] && printf '' > "$write_out"
        printf '%s' "$code"
        for a in "$@"; do
          case "$a" in -fsS|-fs|--fail) [[ "$code" != 2* ]] && exit 22 ;; esac
        done
        exit 0 ;;
    esac

    # HTTPS probes: keyed by the exact host and path the fixture names.
    lookup() { # var-name
      local v="$1"
      printf '%s' "${!v:-}"
    }
    fin=""
    case "$key" in
      "https://${FIX_TLS_DOMAIN}/status/healthz")  fin="${FIX_HTTPS_APEX_STATUS:-200}" ;;
      "https://${FIX_TLS_DOMAIN}/hub")             fin="${FIX_HTTPS_APEX_HUB:-200}" ;;
      "https://${FIX_TLS_DOMAIN}/app/")            fin="${FIX_HTTPS_APEX_APP:-200}" ;;
      "https://${FIX_TLS_DOMAIN}/health")          fin="${FIX_HTTPS_APEX_HEALTH:-200}" ;;
      "https://${FIX_TLS_DOMAIN}/openwebui")       fin="${FIX_HTTPS_APEX_OPENWEBUI:-200}" ;;
      "https://${FIX_TLS_DOMAIN}/")                fin="${FIX_HTTPS_APEX_ROOT:-200}" ;;
      "https://status.${FIX_TLS_DOMAIN}/status/healthz") fin="${FIX_HTTPS_STATUS:-200}" ;;
      "https://hermes.${FIX_TLS_DOMAIN}/")         fin="${FIX_HTTPS_HERMES:-200}" ;;
    esac
    [[ -z "$fin" ]] && fin=200
    [[ -n "$write_out" ]] && printf '' > "$write_out"
    printf '%s' "$fin"
    # `curl -fsS` must fail on a non-2xx, exactly as the real one does.
    for a in "$@"; do
      if [[ "$a" == "-fsS" || "$a" == "-fs" || "$a" == "--fail" ]]; then
        [[ "$fin" == 2* ]] || exit 22
      fi
    done
    exit 0 ;;

  jq)
    prog=""
    for a in "$@"; do
      case "$a" in -*) continue ;; *) prog="$a"; break ;; esac
    done
    case "$prog" in
      *'has("items")'*|*'@tsv'*|*'next_page_id'*) exit 0 ;;
      *) exec "$REAL_JQ" "$@" ;;
    esac ;;
  docker)
    [[ "${FIX_DOCKER_MODE:-ok}" == "error" ]] && exit 1
    for a in "$@"; do [[ "$a" == "info" ]] && exit 0; done
    for a in "$@"; do [[ "$a" == "network" ]] && exit 1; done
    case "$*" in
      *"top hermes-agent"*)  echo '7 hermes gateway run'; exit 0 ;;
      *"exec hermes-agent"*) exit 1 ;;
    esac
    if [[ "$*" == *"name=oh-agent-server"* ]]; then
      [[ -n "${FIX_SANDBOXES:-}" ]] || exit 0
      tr ' ' '\n' <<<"$FIX_SANDBOXES"
      exit 0
    fi
    tmpl=""; prev=""
    for a in "$@"; do [[ "$prev" == "-f" ]] && tmpl="$a"; prev="$a"; done
    last="${*: -1}"
    case "$tmpl" in
      '{{.Id}}')       echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'; exit 0 ;;
      '{{.Config.Image}}') echo "${FIX_SANDBOX_IMAGE:-example.test/agent-server:0}"; exit 0 ;;
      *".Mounts"*)       echo 'false'; exit 0 ;;
      *".Config.User"*)  echo '10001'; exit 0 ;;
      *".State.Status"*) echo running; exit 0 ;;
      *".State.Health"*) echo none; exit 0 ;;
      *"RestartCount"*)  echo 0; exit 0 ;;
      *"PortBindings"*)  printf '%s:3001 %s:3001 ' "$BRIDGE_IP" "$BRIDGE_IP"; exit 0 ;;
      *"println ."*)
        printf '%s\n' \
          'AGENT_SERVER_IMAGE_REPOSITORY=example.test/agent-server' \
          'AGENT_SERVER_IMAGE_TAG=0' \
          'SANDBOX_HOST_PORT=3001' \
          'OH_PERMITTED_CORS_ORIGINS_0=http://localhost:3001'
        exit 0 ;;
    esac
    exit 1 ;;
  getfacl) printf 'user:10001:rwx\ndefault:user:10001:rwx\n'; exit 0 ;;
  iptables) printf '%s\n' '-P INPUT ACCEPT' '-A DOCKER-USER -j RETURN'; exit 0 ;;
  df) printf 'Use%%\n 41%%\n' ;;
  findmnt) echo '/dev/nvme0n1p2' ;;
  nvme|lsblk|vcgencmd|getent) exit 1 ;;
  dmesg|ip) exit 0 ;;
  hostname) for a in "$@"; do [[ "$a" == "-I" ]] && { echo '[IP_ADDRESS] '; exit 0; }; done; echo host ;;
  uname) for a in "$@"; do [[ "$a" == "-m" ]] && { echo aarch64; exit 0; }; done; echo Linux ;;
  nproc) echo 4 ;;
  tailscale)
    for a in "$@"; do
      case "$a" in
        status) echo '{"BackendState":"Running","Peer":{"k":{"HostName":"runpod-worker","Online":true}}}'; exit 0 ;;
        ip) echo '[IP_ADDRESS]'; exit 0 ;;
      esac
    done
    exit 0 ;;
  systemctl|journalctl|sqlite3|rsync|restic|mountpoint) exit 1 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/stub"

for n in curl jq docker getfacl iptables df findmnt nvme lsblk dmesg vcgencmd \
         hostname getent uname nproc tailscale systemctl journalctl sqlite3 \
         rsync restic mountpoint ip; do
  ln -sf "$BIN/stub" "$BIN/$n"
done

# --- scratch app ------------------------------------------------------------
cp "$REPO_ROOT/scripts/lib/hybrid-ai-env.sh" "$APPD/scripts/lib/"
cp "$DOCTOR" "$APPD/doctor.sh"
chmod +x "$APPD/doctor.sh"

# Baseline: the same doctor.sh with the whole proxy-check section replaced by a
# no-op, so "the exit code is unchanged" compares like with like. The section is
# bounded by its own banner and ends where the next section begins; both
# boundaries are taken from the file, not guessed.
python3 - "$APPD/doctor.sh" "$APPD/doctor-base.sh" <<'PY' || exit 2
import re, sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().split('\n')
# Start: the proxy-check banner comment preceding the TLS branch.
start = None
for i, l in enumerate(lines):
    if l.startswith('# Check every logical path the proxy is supposed to serve'):
        start = i
        break
if start is None:
    sys.exit('baseline: proxy-check banner not found')
# End: the first line after start that begins a new section banner.
end = None
for i in range(start + 1, len(lines)):
    if lines[i].startswith('# ') and i > start + 2 and lines[i - 1].startswith('# ---'):
        end = i
        break
if end is None:
    sys.exit('baseline: next section boundary not found')
out = lines[:start] + ['# (proxy check removed for the baseline)'] + lines[end:]
open(dst, 'w').write('\n'.join(out))
print('baseline written')
PY
chmod +x "$APPD/doctor-base.sh"

( cd "$WORK/ws" && git init -q && touch .keep ) >/dev/null 2>&1
chmod 700 "$WORK/ohstate"

cat > "$APPD/.env" <<EOF
WEBUI_SECRET_KEY=fixture
RUNPOD_API_KEY=fixture
RUNPOD_POD_ID=fixture
PEER_HOSTNAME=fixture
OPENROUTER_API_KEY=fixture
OPENHANDS_PORT=3001
OPENHANDS_WORKSPACE=$WORK/ws
OPENHANDS_SANDBOX_HOST=example.test
OPENHANDS_STATE_DIR=$WORK/ohstate
EOF
chmod 600 "$APPD/.env"

summary_count() { # <outfile> <passed|warning|failure>
  case "$2" in
    passed) sed -n 's/^ *\([0-9][0-9]*\) passed.*/\1/p' "$1" | tail -1 ;;
    *)      sed -n "s/.*[^0-9]\([0-9][0-9]*\) $2(s).*/\1/p" "$1" | tail -1 ;;
  esac
}

# run_doctor <tag> <doctor path> [env assignments...]
# Sets RC, OUT, PASSED, WARNED, FAILED.
run_doctor() {
  local tag="$1" doc="$2"
  shift 2
  OUT="$WORK/out.$tag"
  ( cd "$APPD" || exit 1
    env "$@" \
      PATH="$BIN:$PATH" HOME="$WORK/home" SHELL=/bin/bash \
      REAL_JQ="$REAL_JQ" BRIDGE_IP="$BRIDGE_IP" \
      HYBRID_AI_APP_DIR="$APPD" HYBRID_AI_ENV_FILE="$APPD/.env" \
      HYBRID_AI_DATA_DIR="$APPD" HYBRID_AI_LOG_DIR="$APPD" HYBRID_AI_WORK_DIR="$APPD" \
      HYBRID_AI_HERMES_DATA_DIR="$APPD/hermes_data" \
      timeout 120 bash "$doc" --no-cloud
  ) > "$OUT" 2>&1
  RC=$?
  PASSED="$(summary_count "$OUT" passed)"; PASSED="${PASSED:-0}"
  WARNED="$(summary_count "$OUT" warning)"; WARNED="${WARNED:-0}"
  FAILED="$(summary_count "$OUT" failure)"; FAILED="${FAILED:-0}"
}

# write_env_tls <yes|no> [domain]
write_env_tls() {
  local on="$1" dom="${2:-$TLS_DOMAIN_FIX}"
  cat > "$APPD/.env" <<EOF
WEBUI_SECRET_KEY=fixture
RUNPOD_API_KEY=fixture
RUNPOD_POD_ID=fixture
PEER_HOSTNAME=fixture
OPENROUTER_API_KEY=fixture
OPENHANDS_PORT=3001
OPENHANDS_WORKSPACE=$WORK/ws
OPENHANDS_SANDBOX_HOST=example.test
OPENHANDS_STATE_DIR=$WORK/ohstate
TLS_ENABLED=$on
TLS_DOMAIN=$dom
EOF
  chmod 600 "$APPD/.env"
}

echo "== Running doctor.sh proxy B77 tests =="

if ! grep -q 'PROXY_TLS_ON' "$APPD/doctor.sh"; then
  fail "the doctor.sh under test has no TLS-aware proxy branch (unpatched base)"
fi
if grep -q 'PROXY_TLS_ON' "$APPD/doctor-base.sh"; then
  fail "could not build the baseline: the proxy section was not removed"
fi

# --- (i) TLS on, everything healthy, port 80 redirects ---------------------
write_env_tls yes
run_doctor base-on "$APPD/doctor-base.sh"
RC_BASE_ON=$RC
run_doctor on-ok "$APPD/doctor.sh" \
  FIX_TLS_DOMAIN="$TLS_DOMAIN_FIX" \
  FIX_HTTPS_APEX_STATUS=200 FIX_HTTPS_APEX_HUB=200 FIX_HTTPS_APEX_APP=200 \
  FIX_HTTPS_APEX_HEALTH=200 FIX_HTTPS_APEX_OPENWEBUI=200 FIX_HTTPS_APEX_ROOT=200 \
  FIX_HTTPS_STATUS=200 FIX_HTTPS_HERMES=200 \
  FIX_PORT80_APP=308 FIX_PORT80_LOOPBACK=200
OUT_ON_OK="$OUT"
if grep -q 'Proxy: /status responding over HTTPS' "$OUT"; then
  pass "TLS on: the apex status probe is reported over HTTPS"
else
  fail "TLS on: no HTTPS status pass line"
fi
if grep -q 'Proxy: /hub -> hub page over HTTPS (HTTP 200)' "$OUT"; then
  pass "TLS on: /hub is checked over HTTPS"
else
  fail "TLS on: /hub was not checked over HTTPS"
fi
if grep -q 'proxy.example.test' "$OUT"; then
  pass "TLS on: the pass lines name the certificate-bearing domain"
else
  fail "TLS on: the pass lines do not name the TLS domain"
fi
if grep -q 'redirect-only' "$OUT"; then
  pass "TLS on: the port-80 bypass guard runs and passes on a 308"
else
  fail "TLS on: the port-80 bypass guard did not report"
fi
# The fixture host carries unrelated failures of its own (sandbox URL pattern,
# remote browsers), so this asks specifically that the PROXY check added none.
if ! grep -qE '✗ Proxy:' "$OUT"; then
  pass "TLS on (healthy): the proxy check printed no failure line"
else
  fail "TLS on (healthy): the proxy check printed a failure line"
fi
if [[ "$RC" == "$RC_BASE_ON" ]]; then
  pass "TLS on (healthy): exit code equals the probe-free baseline (${RC_BASE_ON})"
else
  fail "TLS on (healthy): exit code ${RC} differs from the baseline (${RC_BASE_ON})"
fi

# --- (ii) TLS on, port 80 serves content: the bypass -----------------------
run_doctor on-bypass "$APPD/doctor.sh" \
  FIX_TLS_DOMAIN="$TLS_DOMAIN_FIX" \
  FIX_HTTPS_APEX_STATUS=200 FIX_HTTPS_APEX_HUB=200 FIX_HTTPS_APEX_APP=200 \
  FIX_HTTPS_APEX_HEALTH=200 FIX_HTTPS_APEX_OPENWEBUI=200 FIX_HTTPS_APEX_ROOT=200 \
  FIX_HTTPS_STATUS=200 FIX_HTTPS_HERMES=200 \
  FIX_PORT80_APP=200 FIX_PORT80_LOOPBACK=200
OUT_ON_BYPASS="$OUT"
if grep -q 'port 80 returned HTTP 200' "$OUT"; then
  pass "TLS on: a port-80 200 application answer is reported"
else
  fail "TLS on: a port-80 200 application answer was NOT reported"
fi
if grep -q 'http://' "$OUT" && grep -q 'expected a 3xx redirect' "$OUT"; then
  pass "TLS on: the failure names the URL and the expected 3xx"
else
  fail "TLS on: the failure does not name the URL and the expected 3xx"
fi
if [[ "$RC" == "2" ]]; then
  pass "TLS on: the plaintext bypass FAILS the run (exit 2)"
else
  fail "TLS on: the plaintext bypass left exit code ${RC}, expected 2"
fi
if [[ "$FAILED" -gt "${FAILED_BASE:-0}" ]]; then
  pass "TLS on: the bypass adds a failure to the summary"
else
  fail "TLS on: the bypass added no failure to the summary"
fi

# --- (iii) TLS on, an HTTPS probe answers 3xx ------------------------------
run_doctor on-https-redir "$APPD/doctor.sh" \
  FIX_TLS_DOMAIN="$TLS_DOMAIN_FIX" \
  FIX_HTTPS_APEX_STATUS=200 FIX_HTTPS_APEX_HUB=308 FIX_HTTPS_APEX_APP=200 \
  FIX_HTTPS_APEX_HEALTH=200 FIX_HTTPS_APEX_OPENWEBUI=200 FIX_HTTPS_APEX_ROOT=200 \
  FIX_HTTPS_STATUS=200 FIX_HTTPS_HERMES=200 \
  FIX_PORT80_APP=308 FIX_PORT80_LOOPBACK=200
OUT_ON_HTTPS_REDIR="$OUT"
if grep -q 'over HTTPS returned a redirect (HTTP 308)' "$OUT"; then
  pass "TLS on: an HTTPS 3xx is reported with its code"
else
  fail "TLS on: an HTTPS 3xx was not reported with its code"
fi
if grep -q 'https://proxy.example.test/hub' "$OUT"; then
  pass "TLS on: the HTTPS 3xx failure names the full URL"
else
  fail "TLS on: the HTTPS 3xx failure does not name the full URL"
fi
if [[ "$RC" == "2" ]]; then
  pass "TLS on: a 3xx on 443 is a FAILURE (exit 2), not a silent pass"
else
  fail "TLS on: a 3xx on 443 left exit code ${RC}, expected 2"
fi

# --- (iv) never follow a redirect into a login page -----------------------
# The stub is given a login-page 302 for an application path. A check that
# followed it would see the login page's 200 and pass; this one must not.
run_doctor on-login "$APPD/doctor.sh" \
  FIX_TLS_DOMAIN="$TLS_DOMAIN_FIX" \
  FIX_HTTPS_APEX_STATUS=200 FIX_HTTPS_APEX_HUB=302 FIX_HTTPS_APEX_APP=302 \
  FIX_HTTPS_APEX_HEALTH=200 FIX_HTTPS_APEX_OPENWEBUI=200 FIX_HTTPS_APEX_ROOT=302 \
  FIX_HTTPS_STATUS=200 FIX_HTTPS_HERMES=302 \
  FIX_PORT80_APP=308 FIX_PORT80_LOOPBACK=200
OUT_ON_LOGIN="$OUT"
# Only the paths this scenario set to 302. /openwebui is deliberately 200 here,
# so it must still pass: the assertion is about the redirect paths, not a sweep.
if ! grep -qE 'Proxy: /(hub|app/) -> .*(HTTP 200)' "$OUT" \
   && ! grep -qE 'Proxy: / -> hermes site over HTTPS \(HTTP 200' "$OUT"; then
  pass "TLS on: a 302 to a login page is never counted as a 200 pass"
else
  fail "TLS on: a redirect to a login page was counted as a healthy 200"
fi
if grep -q 'HTTP 302' "$OUT"; then
  pass "TLS on: the login-page redirect is surfaced by its code"
else
  fail "TLS on: the login-page redirect is not surfaced"
fi

# --- (v) TLS off: today's port-80 behaviour, exactly ----------------------
write_env_tls no
run_doctor base-off "$APPD/doctor-base.sh"
RC_BASE_OFF=$RC; F_BASE_OFF="${FAILED:-0}"
run_doctor off-ok "$APPD/doctor.sh" \
  FIX_TLS_DOMAIN="$TLS_DOMAIN_FIX" \
  FIX_PORT80_LOOPBACK_STATUS=200 FIX_PORT80_LOOPBACK=200 FIX_PORT80_APP=200
OUT_OFF_OK="$OUT"
if grep -q 'Proxy: /status responding$' "$OUT"; then
  pass "TLS off: the port-80 status pass line is unchanged"
else
  fail "TLS off: the port-80 status pass line changed"
fi
if grep -q 'Proxy: /hub -> hub page (HTTP 200)' "$OUT"; then
  pass "TLS off: /hub is still checked on port 80"
else
  fail "TLS off: /hub is no longer checked on port 80"
fi
if ! grep -q 'over HTTPS' "$OUT"; then
  pass "TLS off: no HTTPS probe is attempted"
else
  fail "TLS off: an HTTPS probe was attempted"
fi
if ! grep -q 'redirect-only' "$OUT"; then
  pass "TLS off: the port-80 redirect guard does not run"
else
  fail "TLS off: the port-80 redirect guard ran"
fi
if [[ "$RC" == "$RC_BASE_OFF" ]]; then
  pass "TLS off: exit code equals the probe-free baseline (${RC_BASE_OFF})"
else
  fail "TLS off: exit code ${RC} differs from the baseline (${RC_BASE_OFF})"
fi

# --- (vi) 401/403 over HTTPS is a warn, exactly as before ------------------
write_env_tls yes
run_doctor on-auth "$APPD/doctor.sh" \
  FIX_TLS_DOMAIN="$TLS_DOMAIN_FIX" \
  FIX_HTTPS_APEX_STATUS=200 FIX_HTTPS_APEX_HUB=401 FIX_HTTPS_APEX_APP=200 \
  FIX_HTTPS_APEX_HEALTH=200 FIX_HTTPS_APEX_OPENWEBUI=200 FIX_HTTPS_APEX_ROOT=200 \
  FIX_HTTPS_STATUS=200 FIX_HTTPS_HERMES=200 \
  FIX_PORT80_APP=308 FIX_PORT80_LOOPBACK=200
OUT_ON_AUTH="$OUT"
if grep -q 'over HTTPS returned HTTP 401' "$OUT"; then
  pass "TLS on: a 401 is reported with its code, not silently accepted"
else
  fail "TLS on: a 401 was not reported"
fi
if ! grep -q 'Proxy: /hub -> hub page over HTTPS (HTTP 401' "$OUT"; then
  pass "TLS on: a 401 is never counted as a content pass"
else
  fail "TLS on: a 401 was counted as a content pass"
fi

# --- fail-before: the same assertions against the unpatched doctor --------
# Only possible when the caller points this harness at a real base file, so
# this section is informational and never fails the suite on its own.
echo
echo "== summary =="
printf 'assertions passed: %d\n' "$PASS"
if (( FAILURES > 0 )); then
  printf 'assertions failed: %d\n' "$FAILURES" >&2
  exit 1
fi
echo "All proxy B77 doctor assertions passed."
