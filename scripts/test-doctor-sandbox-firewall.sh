#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-doctor-sandbox-firewall.sh
# PURPOSE (plain English):
#   Proves doctor.sh's sandbox-firewall check by RUNNING doctor.sh against a
#   stubbed iptables and a recorded DOCKER-USER chain -- it does not merely
#   grep the text of doctor.sh.
#
#   Offline: real apply generates the complete fixture using stateful stubs.
#   Every individual missing rule, ordering errors, duplicates, unknown tagged
#   rules, bridge discovery failures and unreadable chains must never pass.
#   All checks assert no firewall writes and warning-only doctor semantics.
#
# Usage:
#   bash scripts/test-doctor-sandbox-firewall.sh [path-to-doctor.sh]
#
# The path defaults to doctor.sh at the repository root, resolved from this
# script's own location so the harness runs from anywhere. Exit 0 when every
# assertion passes, 1 otherwise, 2 on usage error.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

DOCTOR="${1:-$REPO_ROOT/doctor.sh}"
if [[ ! -f "$DOCTOR" ]]; then
  echo "FAIL: doctor.sh not found: $DOCTOR" >&2
  exit 2
fi
PARENT_SCRIPT="$REPO_ROOT/scripts/sandbox-firewall.sh"
if [[ ! -f "$PARENT_SCRIPT" ]]; then
  echo "FAIL: scripts/sandbox-firewall.sh not found: $PARENT_SCRIPT" >&2
  exit 2
fi

for t in mktemp python3 timeout date git jq; do
  command -v "$t" >/dev/null 2>&1 || { echo "FAIL: ${t} is required" >&2; exit 2; }
done

WORK="$(mktemp -d)"
if [[ -n "${SBX_KEEP:-}" ]]; then
  trap 'echo "kept: $WORK" >&2' EXIT
else
  trap 'rm -rf "$WORK"' EXIT
fi

PASS=0
FAILURES=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }

REAL_JQ="$(command -v jq)"
export REAL_JQ
BIN="$WORK/bin"
FIXDIR="$WORK/fixtures"
APPD="$WORK/app"
mkdir -p "$BIN" "$FIXDIR" "$APPD/scripts/lib" "$WORK/home" "$WORK/ws" "$WORK/ohstate"

SKIP_RE='sandbox firewall check skipped'
PASS_RE='Sandbox firewall: DOCKER-USER: all 14 current policy rules present'
WARN_RE='Sandbox firewall: current policy not verified'

# --- stubs ------------------------------------------------------------------
# docker: answers just enough that doctor's container, binding and sandbox
# checks pass, so they never move the exit code. hermes-agent is reported absent.
cat > "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == "info" ]] && exit 0; done
tmpl=""; prev=""
for a in "$@"; do
  [[ "$prev" == "-f" ]] && tmpl="$a"
  prev="$a"
done
if [[ "${1:-}" == "network" ]]; then
  [[ "${NETWORK_FAIL:-}" == "1" ]] && exit 1
  case "${*: -1}" in
    haven) echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
    haven-coder) echo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
    *) exit 1 ;;
  esac
  exit 0
fi
[[ "$*" == *"hermes-agent"* ]] && exit 1
[[ "$*" == *"name=oh-agent-server"* ]] && exit 0
case "$tmpl" in
  *".State.Status"*) echo running; exit 0 ;;
  *".State.Health"*) echo none; exit 0 ;;
  *"RestartCount"*)  echo 0; exit 0 ;;
  *"PortBindings"*)  echo '172.17.0.1:3001 '; exit 0 ;;
  *"println ."*)
    # container_env reads one key per line from this; give it consistent wiring.
    printf '%s\n' \
      'SANDBOX_HOST_PORT=3001' \
      'SANDBOX_CONTAINER_URL_PATTERN=http://example.test:{port}' \
      'OH_PERMITTED_CORS_ORIGINS_0=http://localhost:3001' \
      'OH_PERMITTED_CORS_ORIGINS_1=http://127.0.0.1:3001'
    exit 0 ;;
esac
exit 1
EOF

# getfacl: reports the sandbox uid's ACL present, so the workspace check passes.
cat > "$BIN/getfacl" <<'EOF'
#!/usr/bin/env bash
printf 'user:10001:rwx\ndefault:user:10001:rwx\n'
exit 0
EOF

# sleep: no-op, so nothing in doctor.sh can slow the harness down.
cat > "$BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

# restic: only reachable in --no-cloud runs as an optional tool; keep it
# hermetic.
cat > "$BIN/restic" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

# --- host probes -------------------------------------------------------------
# doctor.sh inspects the REAL host (disk free space, boot device, RAM, mesh DNS,
# kernel log). On a shared runner those vary between runs and can flip an
# unrelated check from warn to fail, which would move the exit code the
# comparisons below rely on. Each of these stubs pins one probe to a fixed
# answer so the ONLY thing that can move the exit code is the startup-grace
# fixture.
cat > "$BIN/df" <<'EOF'
#!/usr/bin/env bash
# Low usage, so the disk check passes whatever the runner's / is doing.
printf 'Use%%\n 41%%\n'
EOF

cat > "$BIN/findmnt" <<'EOF'
#!/usr/bin/env bash
# Booted from NVMe: the recommended case, and stable.
echo '/dev/nvme0n1p2'
EOF

cat > "$BIN/nvme" <<'EOF'
#!/usr/bin/env bash
# No endurance reading, so no extra pass/warn line.
exit 1
EOF

cat > "$BIN/lsblk" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

cat > "$BIN/dmesg" <<'EOF'
#!/usr/bin/env bash
# No kernel-log output, so no storage-IO failure (and no permission error).
exit 0
EOF

cat > "$BIN/vcgencmd" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

cat > "$BIN/hostname" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    -I) echo '10.0.0.5 '; exit 0 ;;
  esac
done
echo 'haven-test-host'
EOF

cat > "$BIN/getent" <<'EOF'
#!/usr/bin/env bash
# The pod's MagicDNS name resolves: this is the fallback path of the shared
# resolver. Everything else does not, because OPENHANDS_SANDBOX_HOST is a lab
# name only the operator's PC knows, so doctor warns (never fails) about it the
# same way every run.
case "${1:-}" in
  ahostsv4)
    case "${2:-}" in
      runpod-worker.example.test)
        if [[ "${TS_RESOLVE_MODE:-}" == "out" ]]; then
          echo '203.0.113.10  STREAM'
        else
          echo '100.64.0.9  STREAM'
        fi
        exit 0 ;;
    esac ;;
esac
exit 2
EOF

cat > "$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

cat > "$BIN/journalctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$BIN/ip" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$BIN/nproc" <<'EOF'
#!/usr/bin/env bash
echo 4
EOF

# Optional tools doctor warns about when absent: report them present so their
# pass/warn lines do not depend on what the runner has installed.
for t in sqlite3 rsync; do
  cat > "$BIN/$t" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
done

# tailscale: connected, with no GPU pod in the tailnet. That is a pass plus a
# warning -- stable, and never a fail. `ip -4 <name>` answers for the pod
# MagicDNS name, so the doctor resolve-and-validate check passes.
# TS_RESOLVE_MODE=out answers with an address OUTSIDE the mesh range instead,
# which the doctor must fail on (exit 2).
cat > "$BIN/tailscale" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    status) echo '{"BackendState":"Running","Peer":{}}'; exit 0 ;;
    ip)
      if [[ "${TS_RESOLVE_MODE:-}" == "out" ]]; then
        echo '203.0.113.10'
      else
        echo '100.64.0.9'
      fi
      exit 0 ;;
  esac
done
exit 0
EOF

# curl: the startup-grace search endpoint answers from a fixture and the local
# health endpoints answer so the Services checks pass; everything else fails, as
# a host with nothing else running would. The startup-grace check is not what
# this harness tests, so one healthy row is all it needs.
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
case "$url" in
  *"/api/v1/app-conversations/start-tasks/search"*) cat "$FIXDIR/ok.page1.json"; exit 0 ;;
  *":11434/api/tags") printf '%s' '{"models":[{"name":"llama3.2:3b"}]}'; exit 0 ;;
  *":3000/health") exit 0 ;;
  *":3001/"*) exit 0 ;;
esac
exit 7
EOF

# jq: implements exactly the filters the check uses (presence test, page cursor,
# TSV rows) and falls through to the real jq for anything else.
cat > "$BIN/jq" <<'EOF'
#!/usr/bin/env bash
prog=""
for a in "$@"; do
  case "$a" in
    -*) continue ;;
    *) prog="$a"; break ;;
  esac
done
case "$prog" in
  *'has("items")'*)
    exec python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(4)
sys.exit(0 if isinstance(d, dict) and ("items" in d or "data" in d) else 1)' ;;
  *'@tsv'*)
    exec python3 -c '
import json, sys
d = json.load(sys.stdin)
for it in (d.get("items") or d.get("data") or []):
    st = it.get("status", "")
    ts = it.get("updated_at") or it.get("created_at") or it.get("updated_at_ns") or ""
    err = " ".join(str(it.get(k, "")) for k in ("error", "error_detail", "detail", "message") if it.get(k))
    print(f"{st}\t{ts}\t{err}")' ;;
  *'next_page_id'*)
    exec python3 -c '
import json, sys
pid = json.load(sys.stdin).get("next_page_id") or ""
if pid:
    print(pid)' ;;
  *)
    exec "$REAL_JQ" "$@" ;;
esac
EOF

# uname: Linux by default. UNFAKE_OS makes -s answer something else, which is
# how the non-Linux flavour of the skip path is driven. -m always answers
# aarch64 so the architecture check does not move.
cat > "$BIN/uname" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    -s) echo "${UNFAKE_OS:-Linux}"; exit 0 ;;
    -m) echo 'aarch64'; exit 0 ;;
  esac
done
echo "${UNFAKE_OS:-Linux}"
EOF

# iptables: a STATEFUL stand-in for the DOCKER-USER chain. Rules live one per
# line in $IPT_STATE. `-I` prepends (the parent script always inserts at
# position 1), `-C` matches exactly, and `-S` prints the chain the way real
# iptables does -- `-N` first, then one `-A` line per rule, with the comment
# quoted as iptables quotes it. IPT_MODE drives the failure flavours used by
# the skip-path cases.
cat > "$BIN/iptables" <<'EOF'
#!/usr/bin/env bash
state="${IPT_STATE:?IPT_STATE is not set}"
printf '%s\n' "$*" >> "$state.calls"
args=()
while (( $# )); do
  case "$1" in
    -w) shift; [[ "${1:-}" =~ ^[0-9]+$ ]] && shift ;;
    *) args+=("$1"); shift ;;
  esac
done
op="${args[0]:-}"
chain="${args[1]:-}"
rest=("${args[@]:2}")
case "$op" in
  -S)
    case "${IPT_MODE:-ok}" in
      fail)  echo 'iptables: Permission denied (you must be root).' >&2; exit 4 ;;
      empty) exit 0 ;;
      malformed) echo garbage; exit 0 ;;
    esac
    echo "-N $chain"
    [[ -f "$state" ]] || exit 0
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      printf '%s\n' "-A $chain $line" | sed 's/--comment \([^"][^ ]*\)/--comment "\1"/'
    done < "$state"
    exit 0 ;;
  -C)
    needle="${rest[*]}"
    [[ -f "$state" ]] && grep -Fxq -- "$needle" "$state" && exit 0
    exit 1 ;;
  -I)
    [[ "${rest[0]:-}" == "1" ]] || exit 1
    needle="${rest[*]:1}"
    tmp="${state}.new.$$"
    { printf '%s\n' "$needle"; [[ -f "$state" ]] && cat "$state"; } > "$tmp" && mv "$tmp" "$state"
    exit 0 ;;
esac
exit 1
EOF

chmod +x "$BIN"/*

# doctor.sh runs under `set -o pipefail`, and several checks read a stub through
# `... | grep -q`. grep -q exits at the first match, so the stub can be killed
# by SIGPIPE (exit 141) before it finishes writing; pipefail then reports the
# whole pipeline as failed and flips an unrelated check. That race is a property
# of the stub, not of doctor.sh, so every stub ignores SIGPIPE.
for f in "$BIN"/*; do
  [[ "$(head -n1 "$f")" == '#!/usr/bin/env bash' ]] && sed -i "2i trap '' PIPE" "$f"
done

# --- fixtures ---------------------------------------------------------------
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"items":[{"id":"t-ok","status":"COMPLETED","updated_at":"%s","error":null}],"next_page_id":null}\n' \
  "$NOW_ISO" > "$FIXDIR/ok.page1.json"

# --- scratch app ------------------------------------------------------------
cp "$REPO_ROOT/scripts/lib/haven-env.sh" "$APPD/scripts/lib/"
# doctor.sh resolves the pod MagicDNS name through this shared lib.
cp "$REPO_ROOT/scripts/lib/tailscale-resolve.sh" "$APPD/scripts/lib/"
cp "$PARENT_SCRIPT" "$APPD/scripts/sandbox-firewall.sh"
cp "$DOCTOR" "$APPD/doctor.sh"
chmod +x "$APPD/doctor.sh"

# The baseline: the same doctor.sh with the 5a2 section deleted. Comparing
# against this, rather than against a skip run of the patched file, is what
# makes "the exit code is unchanged" a real statement. It lives beside the
# copy under test so it resolves scripts/lib and the same .env the same way.
awk '/^# 5a2\. Sandbox network containment/ {skip=1}
     /^# 5b\. Agent clone credentials/ {skip=0}
     !skip' "$APPD/doctor.sh" > "$APPD/doctor-base.sh"
chmod +x "$APPD/doctor-base.sh"
if grep -q 'SBX_RESULT' "$APPD/doctor-base.sh"; then
  fail "could not build the baseline: the 5a2 section was not removed"
fi
if ! grep -q 'SBX_RESULT' "$APPD/doctor.sh"; then
  fail "the doctor.sh under test has no sandbox-firewall check (unpatched base)"
fi

( cd "$WORK/ws" && git init -q && touch .keep ) >/dev/null 2>&1
chmod 700 "$WORK/ohstate"

# Minimal env so the Configuration checks pass rather than fail. Values are
# placeholders; none is a real credential and none is printed.
cat > "$APPD/.env" <<EOF
WEBUI_SECRET_KEY=fixture
RUNPOD_API_KEY=fixture
RUNPOD_POD_ID=fixture
RUNPOD_HOST=runpod-worker.example.test
PEER_HOSTNAME=fixture
OPENROUTER_API_KEY=fixture
OPENHANDS_WORKSPACE=$WORK/ws
OPENHANDS_SANDBOX_HOST=example.test
OPENHANDS_STATE_DIR=$WORK/ohstate
EOF
chmod 600 "$APPD/.env"

# --- real coupling: let the parent script build the "present" fixture -------
# scripts/sandbox-firewall.sh is run with the stateful stub on PATH, exactly as
# the privileged deploy path runs it. Whatever chain it records is what the
# doctor check is then asked to accept.
run_parent_apply() { # state-file
  (
    cd "$REPO_ROOT" || exit 1
    env -u OPENHANDS_PORT IPT_STATE="$1" IPT_MODE=ok \
      PATH="$BIN:$PATH" HOME="$WORK/home" \
      bash "$PARENT_SCRIPT" apply
  ) > "$WORK/parent-apply.log" 2>&1
  RC=$?
}

STATE_PRESENT="$FIXDIR/chain.present"
: > "$STATE_PRESENT"
run_parent_apply "$STATE_PRESENT"
if [[ "$RC" != 0 || "$(wc -l < "$STATE_PRESENT")" != 14 ]]; then
  fail "real apply must generate 14 current rules: $(cat "$WORK/parent-apply.log")"
fi
STATE_NONE="$FIXDIR/chain.none"
: > "$STATE_NONE"

# --- doctor runs ------------------------------------------------------------
# The counts, not just the exit code, are compared: this scratch host has a
# couple of unrelated warnings of its own, so the baseline exits 1 rather than
# 0. Comparing counts is what proves the new check moved nothing except its own
# line -- a check that quietly exited early would show the same exit code.
count_of() { # file key -> number from the summary line
  case "$2" in
    passed)       sed -n 's/^ *\([0-9]\+\) passed.*/\1/p' "$1" | tail -1 ;;
    'warning(s)') sed -n 's/^.* \([0-9]\+\) warning(s).*/\1/p' "$1" | tail -1 ;;
    'failure(s)') sed -n 's/^.* \([0-9]\+\) failure(s).*/\1/p' "$1" | tail -1 ;;
  esac
}

run_doctor() { # name doctor-path state-file [extra env assignments...] ; sets RC
  local name="$1" doc="$2" st="$3"
  shift 3
  local before
  before="$(cat "$st")"
  : > "$st.calls"
  (
    cd "$APPD" || exit 1
    env IPT_MODE=ok "$@" IPT_STATE="$st" \
      PATH="$BIN:$PATH" HOME="$WORK/home" SHELL=/bin/bash \
      HAVEN_DATA_DIR="$APPD" HAVEN_LOG_DIR="$APPD" HAVEN_WORK_DIR="$APPD" \
      timeout 120 bash "$doc" --no-cloud
  ) > "$WORK/out.$name" 2>&1
  RC=$?
  if grep -Evq -- '^-w 5 -S DOCKER-USER$' "$st.calls"; then
    fail "$name: doctor invoked a firewall operation other than listing"
  fi
  if [[ "$(cat "$st")" != "$before" ]]; then
    fail "$name: doctor changed the rule set"
  fi
}

# The baseline: no check at all, so nothing here can be attributed to it.
run_doctor base "$APPD/doctor-base.sh" "$STATE_PRESENT"
RC_BASE=$RC

# --- (a) rules present ------------------------------------------------------
run_doctor present "$APPD/doctor.sh" "$STATE_PRESENT"
RC_PRESENT=$RC
if grep -q "$PASS_RE" "$WORK/out.present"; then
  pass "rules present: the check reports a pass naming the DOCKER-USER chain"
else
  fail "rules present: no pass line for the sandbox-firewall check"
fi
if [[ "$RC_PRESENT" == "$RC_BASE" ]]; then
  pass "rules present: exit code matches the baseline without the check (${RC_BASE})"
else
  fail "rules present: exit code ${RC_PRESENT} differs from the baseline (${RC_BASE})"
fi
if [[ "$(count_of "$WORK/out.present" passed)" == "$(( $(count_of "$WORK/out.base" passed) + 1 ))" \
   && "$(count_of "$WORK/out.present" 'warning(s)')" == "$(count_of "$WORK/out.base" 'warning(s)')" \
   && "$(count_of "$WORK/out.present" 'failure(s)')" == "$(count_of "$WORK/out.base" 'failure(s)')" ]]; then
  pass "rules present: exactly one extra pass, and no extra warning or failure"
else
  fail "rules present: the summary counts do not match the baseline plus one pass"
fi

# --- (a2) the pod name resolves OUTSIDE the mesh: a hard fail --------------
# The address is validated, not the name, so a name that resolves off-mesh must
# fail the run (exit 2). The sandbox-firewall check itself is unaffected, so
# this proves the grid check is independent of it.
run_doctor outofmesh "$APPD/doctor.sh" "$STATE_PRESENT" TS_RESOLVE_MODE=out
RC_OUTOFMESH=$RC
if grep -q 'RUNPOD_HOST resolves to an address outside the Tailscale range' "$WORK/out.outofmesh"; then
  pass "out-of-mesh resolution: the doctor fails the run"
else
  fail "out-of-mesh resolution: no failure for an address outside the mesh range"
fi
if [[ "$RC_OUTOFMESH" == "2" ]]; then
  pass "out-of-mesh resolution: exit code is 2"
else
  fail "out-of-mesh resolution: exit code is ${RC_OUTOFMESH}, expected 2"
fi
if ! grep -q 'RUNPOD_HOST resolves inside the Tailscale mesh' "$WORK/out.outofmesh"; then
  pass "out-of-mesh resolution: no pass line for the pod check"
else
  fail "out-of-mesh resolution: the pod check reported a pass anyway"
fi

# --- Missing/partial/corrupt/order cases ------------------------------------
assert_warn() {
  local name="$1" pattern="$2"
  if grep -q "$WARN_RE" "$WORK/out.$name" && grep -q -- "$pattern" "$WORK/out.$name" \
     && ! grep -q "$PASS_RE" "$WORK/out.$name" \
     && [[ "$RC" == 1 ]] && grep -q '0 failure(s)' "$WORK/out.$name" \
     && [[ "$(count_of "$WORK/out.$name" 'warning(s)')" == "$(( $(count_of "$WORK/out.base" 'warning(s)') + 1 ))" ]]; then
    pass "$name: precise warning, no pass or failure, exactly one added warning"
  else
    fail "$name: expected warning matching $pattern (rc=$RC)"
  fi
}
run_doctor none "$APPD/doctor.sh" "$STATE_NONE"
assert_warn none 'missing rule:'
# Each of the 14 rules independently: detects partial sets, not merely counts.
for n in {1..14}; do
  st="$FIXDIR/missing.$n"
  sed "${n}d" "$STATE_PRESENT" > "$st"
  run_doctor "missing.$n" "$APPD/doctor.sh" "$st"
  assert_warn "missing.$n" 'missing rule:'
  expected="$(sed -n "${n}p" "$STATE_PRESENT")"
  if grep -Fq -- "missing rule: $expected" "$WORK/out.missing.$n"; then
    pass "missing.$n identifies the exact missing rule"
  else
    fail "missing.$n did not identify the missing rule"
  fi
done
# Same total count with a duplicate replacing a missing rule cannot pass.
{ head -n 13 "$STATE_PRESENT"; head -n 1 "$STATE_PRESENT"; } > "$FIXDIR/duplicate"
run_doctor duplicate "$APPD/doctor.sh" "$FIXDIR/duplicate"
assert_warn duplicate 'duplicate rule:'
{ tail -n 1 "$STATE_PRESENT"; head -n 13 "$STATE_PRESENT"; } > "$FIXDIR/reordered"
run_doctor reordered "$APPD/doctor.sh" "$FIXDIR/reordered"
assert_warn reordered 'ACCEPT below DROP'
for target in RETURN ACCEPT DROP; do
  { echo "-j $target"; cat "$STATE_PRESENT"; } > "$FIXDIR/foreign.$target"
  run_doctor "foreign.$target" "$APPD/doctor.sh" "$FIXDIR/foreign.$target"
  assert_warn "foreign.$target" 'foreign rule precedes'
done
{ cat "$STATE_PRESENT"; echo '-j RETURN'; } > "$FIXDIR/return-last"
run_doctor return-last "$APPD/doctor.sh" "$FIXDIR/return-last"
if grep -q "$PASS_RE" "$WORK/out.return-last"; then
  pass "foreign RETURN after the policy is accepted"
else
  fail "foreign RETURN after the policy rejected"
fi
{ cat "$STATE_PRESENT"; echo '-i docker0 ! -o docker0 -m comment --comment haven-sandbox-egress -j DROP'; } > "$FIXDIR/legacy"
run_doctor legacy "$APPD/doctor.sh" "$FIXDIR/legacy"
assert_warn legacy 'out-of-policy tagged rule'
# Kernel listing form: implied modules, destination before interface, reversed
# conntrack state order, quoted comment (the stub quotes comments on output).
sed -e 's/-p tcp /-p tcp -m tcp /g' -e 's/-p udp /-p udp -m udp /g' \
    -e 's/ESTABLISHED,RELATED/RELATED,ESTABLISHED/' \
    -e 's/-i docker0 -d \([^ ]*\)/-d \1 -i docker0/' "$STATE_PRESENT" > "$FIXDIR/normalised"
run_doctor normalised "$APPD/doctor.sh" "$FIXDIR/normalised"
if grep -q "$PASS_RE" "$WORK/out.normalised"; then
  pass "kernel-normalised rule listing accepted"
else
  fail "kernel-normalised rule listing rejected"
fi
# Matching ports alone cannot hide a widened ACCEPT.
sed 's/--dport 3000/--dport 3000:3999/' "$STATE_PRESENT" > "$FIXDIR/widened"
run_doctor widened "$APPD/doctor.sh" "$FIXDIR/widened"
assert_warn widened 'missing rule:'

# --- (c) probe unavailable --------------------------------------------------
# Each flavour must print a skip line, stay silent about pass/warn, and leave
# the exit code exactly where the baseline was.
check_skip_flavour() { # name label
  local name="$1" label="$2"
  if grep -q "$SKIP_RE" "$WORK/out.$name"; then
    pass "${label}: a skip line is printed"
  else
    fail "${label}: no skip line printed"
  fi
  if ! grep -q "$PASS_RE" "$WORK/out.$name" && ! grep -q "$WARN_RE" "$WORK/out.$name"; then
    pass "${label}: no pass and no warn from this check"
  else
    fail "${label}: the check counted a pass or a warn it could not justify"
  fi
  if [[ "$RC" == "$RC_BASE" ]]; then
    pass "${label}: exit code is identical to the baseline (${RC_BASE})"
  else
    fail "${label}: exit code ${RC} differs from the baseline (${RC_BASE})"
  fi
  if [[ "$(count_of "$WORK/out.$name" passed)" == "$(count_of "$WORK/out.base" passed)" \
     && "$(count_of "$WORK/out.$name" 'warning(s)')" == "$(count_of "$WORK/out.base" 'warning(s)')" \
     && "$(count_of "$WORK/out.$name" 'failure(s)')" == "$(count_of "$WORK/out.base" 'failure(s)')" ]]; then
    pass "${label}: every summary count matches the baseline (nothing counted)"
  else
    fail "${label}: summary counts differ from the baseline, so the skip counted something"
  fi
}

# (c1) no iptables binary. /usr/sbin and /sbin are dropped from PATH, because a
# runner image usually ships iptables there.
NOMIN_PATH="$BIN:/usr/local/bin:/usr/bin:/bin"
(
  cd "$APPD" || exit 1
  env -u IPT_STATE PATH="$NOMIN_PATH" HOME="$WORK/home" SHELL=/bin/bash \
    HAVEN_DATA_DIR="$APPD" HAVEN_LOG_DIR="$APPD" HAVEN_WORK_DIR="$APPD" \
    timeout 120 bash "$APPD/doctor.sh" --no-cloud
) > "$WORK/out.noiptables" 2>&1
RC=$?
check_skip_flavour noiptables "no iptables binary"
if ! PATH="$NOMIN_PATH" command -v iptables >/dev/null 2>&1; then
  if grep -q 'iptables not installed' "$WORK/out.noiptables"; then
    pass "no iptables binary: the skip reason is the missing binary"
  else
    fail "no iptables binary: skip reason is not the missing binary"
  fi
fi

# (c2) iptables present but the read fails, as an unprivileged run against a
# root-owned chain does.
run_doctor perm "$APPD/doctor.sh" "$STATE_PRESENT" IPT_MODE=fail
check_skip_flavour perm "iptables refuses to read the chain"

# (c3) the listing is empty, which cannot be parsed into rules.
run_doctor empty "$APPD/doctor.sh" "$STATE_PRESENT" IPT_MODE=empty
check_skip_flavour empty "empty DOCKER-USER listing"

# (c4) not a Linux host: no iptables at all on such a system.
run_doctor nonlinux "$APPD/doctor.sh" "$STATE_PRESENT" UNFAKE_OS=Darwin
check_skip_flavour nonlinux "non-Linux host"
if grep -q 'not a Linux host' "$WORK/out.nonlinux"; then
  pass "non-Linux host: the skip reason is the platform"
else
  fail "non-Linux host: skip reason is not the platform"
fi

run_doctor discovery "$APPD/doctor.sh" "$STATE_PRESENT" NETWORK_FAIL=1
check_skip_flavour discovery "bridge discovery unavailable"
run_doctor malformed "$APPD/doctor.sh" "$STATE_PRESENT" IPT_MODE=malformed
check_skip_flavour malformed "unexpected listing"
# The helper itself must not apply when checked: all doctor runs above log -S
# only, and their fixture files are unchanged.

# --- proof that the harness rejects an unpatched doctor.sh -------------------
# A doctor.sh without the check prints neither a pass nor a skip line, so (a)
# and (c) above fail for it. Re-run this harness against the stripped copy and
# require a non-zero exit. Guarded so it cannot recurse further.
if [[ -z "${SBX_HARNESS_NESTED:-}" ]]; then
  env -u IPT_STATE -u IPT_MODE SBX_HARNESS_NESTED=1 \
    bash "$0" "$APPD/doctor-base.sh" > "$WORK/nested.log" 2>&1
  NESTED_RC=$?
  if [[ "$NESTED_RC" != "0" ]]; then
    pass "unpatched doctor.sh: this harness fails against a copy without the check"
  else
    fail "unpatched doctor.sh: the harness passed, so its assertions prove nothing"
  fi
fi

echo "---"
if (( FAILURES != 0 )); then
  echo "FAILURES: ${FAILURES}" >&2
  exit 1
fi
echo "All sandbox-firewall assertions passed (${PASS})."
exit 0
