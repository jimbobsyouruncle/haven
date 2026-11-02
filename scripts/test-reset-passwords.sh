#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-reset-passwords.sh
# PURPOSE (plain English):
#   Offline tests for scripts/reset-passwords.sh.
#
#   Fully offline: NO Docker, NO network, NO real host files. `docker` is a stub
#   on PATH that emulates just the four interactions the script uses (exec,
#   compose up, restart, and the container environment dump), and the Python
#   packages it imports inside the containers (bcrypt, yaml,
#   plugins.dashboard_auth.basic, open_webui.*) are fixtures on PYTHONPATH.
#   Everything happens in a mktemp directory that is removed on exit.
#
# WHAT IS PROVEN:
#   Escape            a `$` value is doubled once, and escaping an already
#                     escaped value never produces `$$$$` (idempotent)
#   Env file          only the HYBRID_AI_AUTH_HASH line changes; every other
#                     line is byte-for-byte preserved, in order, including a
#                     file with no trailing newline
#   Backups           the stack env file and the Hermes config are copied to a
#                     timestamped backup with mode 0600 before being rewritten
#   Auth leg          the hash is made in the auth container, carries cost 12,
#                     is written escaped, and the container is verified to hold
#                     a 60-byte value; only the auth service is recreated
#   Hermes configured password_hash is replaced with the container helper's own
#                     hash, a plaintext password member is removed, and
#                     username/secret stay byte-identical
#   Hermes absent     the file is untouched and the exact skip message is
#                     reported
#   Env override      a HERMES_DASHBOARD_BASIC_AUTH_* variable in the container
#                     environment makes the leg refuse and change nothing
#   Isolation         the password never reaches an argv, a log or any file
#                     under the test tree
#   Failure semantics a failing leg exits non-zero and the other legs still run
#   Generate          --generate prints a 24-character password exactly once in
#                     the summary, and it reaches no argv
#   Mutation failure  a failed install/mv/chmod/chown is reported, the original
#                     file is left intact, and the other legs still run
#   WebUI False       the app helper returning False fails the leg
#   Restart failure   a requested restart that fails marks the leg failed
#                     (config still written) and exits non-zero
#   Empty confirm     an empty confirmation line is refused like a mismatch
#   Scrubbing         a helper that echoes a password or a sentinel hash to
#                     stderr cannot leak it into the script's output
#   Ownership         the replacement carries the original's owner and mode
#
# USAGE:
#   bash scripts/test-reset-passwords.sh
#
# EXIT CODES:
#   0  every case passed
#   1  one or more cases failed
#   2  a required tool is missing, or the script under test is absent
# ---------------------------------------------------------------------------
# Every single-quoted `$` below is a bcrypt or compose-escape fixture that must
# stay literal: expansion is the thing under test.
# shellcheck disable=SC2016
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/hybrid-ai-env.sh
source "${SCRIPT_DIR}/lib/hybrid-ai-env.sh"
# shellcheck source=scripts/lib/tls.sh
source "${SCRIPT_DIR}/lib/tls.sh"

RESET_SCRIPT="${SCRIPT_DIR}/reset-passwords.sh"

if [[ ! -x "$RESET_SCRIPT" ]]; then
  printf 'FATAL: cannot find an executable %s\n' "$RESET_SCRIPT" >&2
  exit 2
fi
for tool in mktemp stat grep cmp python3 install awk sed tr tail chmod chown mv script; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'error: %s is required\n' "$tool" >&2
    exit 2
  fi
done

PASS=0
FAIL=0
ok()   { PASS=$(( PASS + 1 )); printf 'ok   %s\n' "$*"; }
bad()  { FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n' "$*" >&2; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }

WORK="$(mktemp -d)"
if [[ "${KEEP:-0}" == "1" ]]; then
  printf 'keeping %s\n' "$WORK"
else
  trap 'rm -rf -- "$WORK"' EXIT
fi

BIN="${WORK}/bin"
PYSTUB="${WORK}/pystub"
STATE="${WORK}/state"
LOGS="${WORK}/logs"
mkdir -p "$BIN" "$PYSTUB" "$STATE" "$LOGS"

# The fixture password. It contains `$` on purpose: the escape path and the
# stdin-only path both have to survive it.
PASSWORD='Test-Passw0rd!$2b$hunter2'

# ---------------------------------------------------------------------------
# Fixture Python packages (what the containers would import)
# ---------------------------------------------------------------------------
mkdir -p "$PYSTUB/plugins/dashboard_auth" "$PYSTUB/open_webui/models" \
         "$PYSTUB/open_webui/utils"
: > "$PYSTUB/plugins/__init__.py"
: > "$PYSTUB/plugins/dashboard_auth/__init__.py"
: > "$PYSTUB/open_webui/__init__.py"
: > "$PYSTUB/open_webui/models/__init__.py"
: > "$PYSTUB/open_webui/utils/__init__.py"

cat > "$PYSTUB/bcrypt.py" <<'PY'
import hashlib
import os


def gensalt(rounds=12):
    requested = os.environ.get("STUB_BCRYPT_COST", "").strip()
    cost = int(requested) if requested else rounds
    fixed = os.environ.get("STUB_BCRYPT_SALT", "")
    salt = fixed if fixed else os.urandom(16).hex()[:22]
    return ("$2b$%02d$" % cost + salt).encode()


def hashpw(password, salt):
    if isinstance(salt, str):
        salt = salt.encode()
    parts = salt.decode("ascii", "replace").split("$")
    cost = 12
    if len(parts) > 3:
        try:
            cost = int(parts[2])
        except ValueError:
            cost = 12
    if isinstance(password, str):
        password = password.encode()
    if os.environ.get("STUB_BCRYPT_ECHO_PASSWORD"):
        # A hostile double that copies the password it received to stderr.
        import sys
        sys.stderr.write("synthetic stderr: %s\n" % password.decode("utf-8", "replace"))
    digest = hashlib.sha256(salt + password).hexdigest()
    return ("$2b$%02d$" % cost + digest[:53]).encode()
PY

cat > "$PYSTUB/yaml.py" <<'PY'
"""A tiny YAML subset: enough for the fixture configs (nested mappings)."""


def _scalar(token):
    text = token.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in ("'", '"'):
        return text[1:-1]
    if text in ("", "~", "null", "Null", "NULL"):
        return None
    if text in ("true", "True", "yes"):
        return True
    if text in ("false", "False", "no"):
        return False
    return text


def safe_load(stream):
    text = stream.read() if hasattr(stream, "read") else stream
    root = {}
    stack = [(-1, root)]
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        line = raw.strip()
        if ":" not in line:
            continue
        key, _, rest = line.partition(":")
        key = key.strip()
        while len(stack) > 1 and indent <= stack[-1][0]:
            stack.pop()
        parent = stack[-1][1]
        if not rest.strip():
            child = {}
            parent[key] = child
            stack.append((indent, child))
        else:
            parent[key] = _scalar(rest)
    return root


def _emit(node, indent, out):
    for key, value in node.items():
        if isinstance(value, dict):
            out.append(" " * indent + "%s:" % key)
            _emit(value, indent + 2, out)
        elif value is None:
            out.append(" " * indent + "%s: null" % key)
        elif isinstance(value, bool):
            out.append(" " * indent + "%s: %s" % (key, "true" if value else "false"))
        else:
            out.append(" " * indent + "%s: %s" % (key, value))


def safe_dump(data, sort_keys=True, allow_unicode=True):
    out = []
    _emit(data, 0, out)
    return "\n".join(out) + "\n"
PY

cat > "$PYSTUB/plugins/dashboard_auth/basic.py" <<'PY'
import hashlib


def hash_password(password):
    import os
    import sys
    if isinstance(password, bytes):
        password = password.decode("utf-8", "replace")
    if os.environ.get("STUB_HERMES_ECHO_SENTINEL"):
        # A hostile double that copies a sentinel hash to stderr.
        sys.stderr.write("synthetic stderr: %s\n" % os.environ["STUB_HERMES_ECHO_SENTINEL"])
    return "scrypt$fixture$" + hashlib.sha256(password.encode("utf-8")).hexdigest()
PY

cat > "$PYSTUB/open_webui/models/users.py" <<'PY'
import json
import os


class _User:
    def __init__(self, row):
        self.id = row["id"]
        self.email = row["email"]
        self.role = row.get("role", "admin")


class Users:
    @staticmethod
    async def get_users(filter=None):
        with open(os.environ["STUB_WEBUI_USERS"], "r", encoding="utf-8") as handle:
            rows = json.load(handle)
        return {"users": [_User(row) for row in rows], "total": len(rows)}
PY

cat > "$PYSTUB/open_webui/models/auths.py" <<'PY'
import os


class Auths:
    @staticmethod
    async def update_user_password_by_id(user_id, password_hash):
        with open(os.environ["STUB_WEBUI_UPDATE_LOG"], "a", encoding="utf-8") as handle:
            handle.write("user_id=%s hash_len=%d\n" % (user_id, len(password_hash)))
        # Upstream v0.11.4 returns False when no auth row was updated.
        return os.environ.get("STUB_WEBUI_UPDATE_RESULT", "1") != "0"
PY

cat > "$PYSTUB/open_webui/utils/auth.py" <<'PY'
import hashlib


async def get_password_hash(password):
    if isinstance(password, bytes):
        password = password.decode("utf-8", "replace")
    return "fixture-hash$" + hashlib.sha256(password.encode("utf-8")).hexdigest()
PY

# ---------------------------------------------------------------------------
# The docker stub: emulates exactly what the script asks of the daemon
# ---------------------------------------------------------------------------
cat > "$BIN/docker" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail

state="${STUB_STATE:?}"
printf '%s\n' "$@" >> "${state}/argv.log"

if [[ "${1:-}" == "compose" ]]; then
  printf '%s ' "$@" >> "${state}/compose.log"
  printf '\n' >> "${state}/compose.log"
  exit 0
fi

if [[ "${1:-}" == "restart" ]]; then
  printf '%s\n' "${2:-}" >> "${state}/restart.log"
  if [[ -n "${STUB_RESTART_FAIL:-}" ]]; then
    exit 1
  fi
  exit 0
fi

if [[ "${1:-}" != "exec" ]]; then
  printf 'stub docker: unsupported command: %s\n' "$*" >&2
  exit 64
fi
shift

[[ "${1:-}" == "-i" ]] && shift

envs=()
while [[ "${1:-}" == "-e" ]]; do
  envs+=("$2")
  shift 2
done

container="${1:-}"
shift

case "$container" in
  hybrid-ai-auth)
    value=""
    if [[ -f "${STUB_STACK_FILE:-}" ]]; then
      value="$(grep -E '^[[:space:]]*HYBRID_AI_AUTH_HASH=' "$STUB_STACK_FILE" | tail -n 1 || true)"
      value="${value#HYBRID_AI_AUTH_HASH=}"
      value="${value//\$\$/\$}"
    fi
    envs+=("HYBRID_AI_AUTH_HASH=${value}")
    ;;
  open-webui)
    envs+=("STUB_WEBUI_USERS=${state}/webui_users.json")
    envs+=("STUB_WEBUI_UPDATE_LOG=${state}/webui_update.log")
    ;;
  hermes-agent) ;;
  *)
    printf 'stub docker: unexpected container: %s\n' "$container" >&2
    exit 64
    ;;
esac

if [[ "${1:-}" == "sh" && "${2:-}" == "-c" ]]; then
  # The container environment dump. Fixture lines come from hermes_env.
  if [[ -f "${state}/hermes_env" ]]; then
    cat "${state}/hermes_env"
  fi
  exit 0
fi

if [[ "${1:-}" == "python3" || "${1:-}" == "python" ]]; then
  [[ "${2:-}" == "-c" ]] || { printf 'stub docker: expected -c\n' >&2; exit 64; }
  program="${3:-}"
  if [[ -n "${STUB_BCRYPT_COST:-}" ]]; then
    envs+=("STUB_BCRYPT_COST=${STUB_BCRYPT_COST}")
  fi
  if [[ -n "${STUB_BCRYPT_SALT:-}" ]]; then
    envs+=("STUB_BCRYPT_SALT=${STUB_BCRYPT_SALT}")
  fi
  for passthrough in STUB_BCRYPT_ECHO_PASSWORD STUB_HERMES_ECHO_SENTINEL STUB_WEBUI_UPDATE_RESULT; do
    if [[ -n "${!passthrough:-}" ]]; then
      envs+=("${passthrough}=${!passthrough}")
    fi
  done
  exec env "${envs[@]}" PYTHONPATH="${STUB_PY:?}" python3 -c "$program"
fi

printf 'stub docker: unexpected exec payload\n' >&2
exit 64
STUB
chmod 755 "$BIN/docker"

# ---------------------------------------------------------------------------
# Fixture builder
# ---------------------------------------------------------------------------
FX=""

fresh_fixture() { # <name> -> creates FX with an app dir, a data dir and env files
  FX="${WORK}/fx-$1"
  rm -rf -- "$FX"
  mkdir -p "$FX/app" "$FX/data/hermes_data" "$FX/env"
  : > "$FX/app/docker-compose.yml"
  cat > "$FX/env/layout.env" <<EOF
HYBRID_AI_ENV_FILE=${FX}/env/layout.env
HYBRID_AI_STACK_ENV_FILE=${FX}/env/stack.env
EOF
  # A `$`-rich legacy placeholder. It exercises compose escaping and
  # byte-preservation without being a real hash, or even a bcrypt-shaped one, so
  # the generic secret detector has nothing to match and nothing is suppressed.
  LEGACY_FIXTURE_HASH='LEGACY$PLACEHOLDER$HASH$VALUE$000000000000000000000000000000'
  printf '%s\n' "# operator notes, do not reorder" \
    "TLS_DOMAIN=daemonhub.dev" \
    "" \
    "HYBRID_AI_AUTH_USER=owner" \
    "HYBRID_AI_AUTH_HASH=${LEGACY_FIXTURE_HASH}" \
    "AUTH_ENABLED=on" \
    "HYBRID_AI_AUTH_COOKIE_SECRET=fixture-cookie-secret" \
    "WEBUI_AUTH=true" \
    "WEBUI_SECRET_KEY=fixture-webui-secret" \
    'QUOTED="keep  my   spacing"' \
    "LAST_LINE=unchanged" > "$FX/env/stack.env"
  chmod 600 "$FX/env/stack.env"

  printf '%s\n' '[{ "id": "owner-1", "email": "owner-one", "role": "admin" }]' \
    > "${STATE}/webui_users.json"
  : > "$STATE/argv.log"
  : > "$STATE/compose.log"
  : > "$STATE/restart.log"
  : > "$STATE/hermes_env"
  rm -f "$STATE/webui_update.log"
}



hermes_config_with_password() { # <path>
  cat > "$1" <<'EOF'
# Hermes profile config (fixture)
dashboard:
  enabled: true
  port: 8787
  basic_auth:
    username: owner
    password: plaintext-should-be-removed
    secret: fixture-dashboard-secret
webui:
  theme: dark
EOF
  chmod 600 "$1"
}

hermes_config_without_auth() { # <path>
  cat > "$1" <<'EOF'
# Hermes profile config (fixture)
dashboard:
  enabled: true
  port: 8787
webui:
  theme: dark
EOF
  chmod 600 "$1"
}

# run_reset <label> <password-or-empty> [args...]
# Sets RUN_RC. Password lines go on stdin only.
# WRAPBIN, when set, is prepended to PATH ahead of the docker stub so a test can
# wrap one host tool (install, mv, chown) without touching the repo.
run_reset() {
  local label="$1" pw="$2"
  shift 2
  local out="${LOGS}/${label}.out" err="${LOGS}/${label}.err"
  local -a run_env=(
    "PATH=${WRAPBIN:+${WRAPBIN}:}${BIN}:${PATH}"
    "STUB_STATE=$STATE" "STUB_PY=$PYSTUB"
    "STUB_STACK_FILE=${FX}/env/stack.env"
    "STUB_BCRYPT_COST=${STUB_BCRYPT_COST:-}"
    "STUB_BCRYPT_SALT=${STUB_BCRYPT_SALT:-}"
    "STUB_RESTART_FAIL=${STUB_RESTART_FAIL:-}"
    "STUB_BCRYPT_ECHO_PASSWORD=${STUB_BCRYPT_ECHO_PASSWORD:-}"
    "STUB_HERMES_ECHO_SENTINEL=${STUB_HERMES_ECHO_SENTINEL:-}"
    "STUB_WEBUI_UPDATE_RESULT=${STUB_WEBUI_UPDATE_RESULT:-}"
    "HYBRID_AI_ENV_FILE=${FX}/env/layout.env"
    "HYBRID_AI_STACK_ENV_FILE=${FX}/env/stack.env"
    "HYBRID_AI_APP_DIR=${FX}/app"
    "HYBRID_AI_DATA_DIR=${FX}/data"
  )
  set +e
  if [[ -n "$pw" ]]; then
    printf '%s\n%s\n' "$pw" "$pw" | env "${run_env[@]}" \
      "$RESET_SCRIPT" "$@" > "$out" 2> "$err"
    RUN_RC=$?
  else
    env "${run_env[@]}" "$RESET_SCRIPT" "$@" < /dev/null > "$out" 2> "$err"
    RUN_RC=$?
  fi
  set -e
  return 0
}

# run_reset_tty <label> <stdin-file> [args...]
# Runs the script under a real pty (util-linux `script`) so the interactive
# branch is exercised: /dev/tty is available and stdin IS a terminal. The input
# comes from a file so trailing/blank lines survive byte for byte.
run_reset_tty() {
  local label="$1" input_file="$2"
  shift 2
  local out="${LOGS}/${label}.out" err="${LOGS}/${label}.err"
  local -a run_env=(
    "PATH=${WRAPBIN:+${WRAPBIN}:}${BIN}:${PATH}"
    "STUB_STATE=$STATE" "STUB_PY=$PYSTUB"
    "STUB_STACK_FILE=${FX}/env/stack.env"
    "STUB_BCRYPT_COST=${STUB_BCRYPT_COST:-}"
    "STUB_BCRYPT_SALT=${STUB_BCRYPT_SALT:-}"
    "STUB_RESTART_FAIL=${STUB_RESTART_FAIL:-}"
    "STUB_BCRYPT_ECHO_PASSWORD=${STUB_BCRYPT_ECHO_PASSWORD:-}"
    "STUB_HERMES_ECHO_SENTINEL=${STUB_HERMES_ECHO_SENTINEL:-}"
    "STUB_WEBUI_UPDATE_RESULT=${STUB_WEBUI_UPDATE_RESULT:-}"
    "HYBRID_AI_ENV_FILE=${FX}/env/layout.env"
    "HYBRID_AI_STACK_ENV_FILE=${FX}/env/stack.env"
    "HYBRID_AI_APP_DIR=${FX}/app"
    "HYBRID_AI_DATA_DIR=${FX}/data"
  )
  set +e
  timeout "${TTY_TIMEOUT:-25}" env "${run_env[@]}" \
    script -qec "$(printf '%q ' "$RESET_SCRIPT" "$@")" /dev/null \
    < "$input_file" > "$out" 2> "$err"
  RUN_RC=$?
  set -e
  return 0
}

# _wrap_mutator <tool> <FAIL_VAR> <MATCH_VAR>
# Writes $WRAPBIN/<tool> that exits with $<FAIL_VAR> when an argument contains
# $<MATCH_VAR>, and forwards to the real binary otherwise. With <MATCH_VAR>
# unset, the pattern is the empty string and every call with <FAIL_VAR> set
# fails. This lets a test fail exactly ONE mutation without touching the repo.
_wrap_mutator() { # <tool> <fail-var> <match-string>
  local tool="$1" fail_var="$2" match="$3" real
  WRAPBIN="${WORK}/wrap"
  mkdir -p "$WRAPBIN"
  real="$(command -v "$tool")"
  cat > "$WRAPBIN/$tool" <<WRAP
#!/usr/bin/env bash
code="\${${fail_var}:-}"
if [[ -n "\$code" ]]; then
  for a in "\$@"; do
    case "\$a" in
      *"${match}"*) exit "\$code" ;;
    esac
  done
fi
exec "${real}" "\$@"
WRAP
  chmod 755 "$WRAPBIN/$tool"
}

# _wrap_chown_logger: a chown that records its argv, then delegates.
_wrap_chown_logger() {
  WRAPBIN="${WORK}/wrap"
  mkdir -p "$WRAPBIN"
  cat > "$WRAPBIN/chown" <<'WRAP'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_STATE}/chown.log"
exec /usr/bin/chown "$@"
WRAP
  chmod 755 "$WRAPBIN/chown"
}

output_of() { cat "${LOGS}/$1.out" "${LOGS}/$1.err"; }

env_value() { # <file> <key>
  grep -E "^[[:space:]]*$2=" "$1" | tail -n 1 | sed "s/^[[:space:]]*$2=//" || true
}

yaml_value() { # <file> <key>
  grep -E "^[[:space:]]*$2:" "$1" | tail -n 1 | sed -E "s/^[[:space:]]*$2:[[:space:]]*//" || true
}

mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# ---------------------------------------------------------------------------
# 1. Escaping: doubled once, never quadrupled
# ---------------------------------------------------------------------------
echo "== escaping =="
check "a raw \$ is doubled" '$$a$$b$$c' "$(tls_compose_escape '$a$b$c')"
check "escaping is idempotent" \
  "$(tls_compose_escape '$a$b$c')" "$(tls_compose_escape "$(tls_compose_escape '$a$b$c')")"
check "an escaped value never becomes quadrupled" 'no' \
  "$(if [[ "$(tls_compose_escape "$(tls_compose_escape '$2b$12$x')")" == *'$$$$'* ]]; then echo yes; else echo no; fi)"

# ---------------------------------------------------------------------------
# 2. The happy path: all three legs applied
# ---------------------------------------------------------------------------
echo "== configured hermes, one admin =="
STUB_BCRYPT_SALT="abcdef0123456789abcdef"
STUB_BCRYPT_COST=""
export STUB_BCRYPT_SALT
fresh_fixture happy
hermes_config_with_password "${FX}/data/hermes_data/config.yaml"
cp "${FX}/env/stack.env" "${FX}/stack.before"
cp "${FX}/data/hermes_data/config.yaml" "${FX}/hermes.before"

run_reset happy "$PASSWORD" --no-restart
check "exit status is 0" "0" "$RUN_RC"
check "auth leg applied" "yes" "$(grep -q 'auth gate  *applied' "${LOGS}/happy.out" && echo yes || echo no)"
check "webui leg applied" "yes" "$(grep -q 'Open WebUI admin  *applied' "${LOGS}/happy.out" && echo yes || echo no)"
check "hermes leg applied" "yes" "$(grep -q 'Hermes dashboard  *applied' "${LOGS}/happy.out" && echo yes || echo no)"

# --- env file: only the hash line changed, byte for byte -------------------
grep -v -E '^[[:space:]]*HYBRID_AI_AUTH_HASH=' "${FX}/stack.before" > "${WORK}/before-rest.txt"
grep -v -E '^[[:space:]]*HYBRID_AI_AUTH_HASH=' "${FX}/env/stack.env" > "${WORK}/after-rest.txt"
if cmp -s "${WORK}/before-rest.txt" "${WORK}/after-rest.txt"; then
  ok "every other env-file line is byte-for-byte preserved"
else
  bad "the env-file rewrite changed lines other than the hash"
  diff -u "${WORK}/before-rest.txt" "${WORK}/after-rest.txt" >&2 || true
fi
check "AUTH_ENABLED is untouched" "on" "$(env_value "${FX}/env/stack.env" AUTH_ENABLED)"
check "the auth user is untouched" "owner" "$(env_value "${FX}/env/stack.env" HYBRID_AI_AUTH_USER)"
check "the cookie secret is untouched" "fixture-cookie-secret" \
  "$(env_value "${FX}/env/stack.env" HYBRID_AI_AUTH_COOKIE_SECRET)"
check "WEBUI_AUTH is untouched" "true" "$(env_value "${FX}/env/stack.env" WEBUI_AUTH)"
check "WEBUI_SECRET_KEY is untouched" "fixture-webui-secret" \
  "$(env_value "${FX}/env/stack.env" WEBUI_SECRET_KEY)"
check "exactly one hash line is written" "1" \
  "$(grep -c -E '^HYBRID_AI_AUTH_HASH=' "${FX}/env/stack.env" || true)"

written_hash="$(env_value "${FX}/env/stack.env" HYBRID_AI_AUTH_HASH)"
check "the hash is escaped for compose" "yes" \
  "$(if [[ "$written_hash" == *'$$'* ]]; then echo yes; else echo no; fi)"
check "the hash is never quadrupled" "no" \
  "$(if [[ "$written_hash" == *'$$$$'* ]]; then echo yes; else echo no; fi)"
check "cost 12 is in the escaped value" "yes" \
  "$(if [[ "$written_hash" == '$$2b$$12$$'* ]]; then echo yes; else echo no; fi)"
check "unescaping gives back a 60-byte bcrypt hash" "60" \
  "$(tls_compose_unescape "$written_hash" | tr -d '\n' | wc -c | tr -d ' ')"

backups=()
while IFS= read -r path; do
  [[ -n "$path" ]] && backups+=("$path")
done < <(find "${FX}/env" -maxdepth 1 -name 'stack.env.bak.*' -print)
check "the stack env file has one timestamped backup" "1" "${#backups[@]}"
if (( ${#backups[@]} >= 1 )); then
  check "the env backup is mode 0600" "600" "$(mode_of "${backups[0]}")"
  if cmp -s "${backups[0]}" "${FX}/stack.before"; then
    ok "the env backup holds the original bytes"
  else
    bad "the env backup does not match the original"
  fi
fi
check "the rewritten env file stays mode 0600" "600" "$(mode_of "${FX}/env/stack.env")"

# --- compose: only the auth service, with the canonical file set ------------
compose_line="$(tail -n 1 "$STATE/compose.log")"
check "compose recreates only auth" "yes" \
  "$(if [[ "$compose_line" == *"--no-deps --force-recreate auth"* ]]; then echo yes; else echo no; fi)"
check "compose uses the stack env file" "yes" \
  "$(if [[ "$compose_line" == *"--env-file ${FX}/env/stack.env"* ]]; then echo yes; else echo no; fi)"
for overlay in docker-compose.yml openhands/docker-compose.openhands.yml hermes/docker-compose.hermes.yml; do
  check "compose passes -f ${overlay}" "yes" \
    "$(if [[ "$compose_line" == *"-f ${FX}/app/${overlay}"* ]]; then echo yes; else echo no; fi)"
done

# --- Hermes: hash replaced, plaintext gone, everything else identical ------
expected_hermes_hash="scrypt\$fixture\$$(printf '%s' "$PASSWORD" | sha256sum | cut -d' ' -f1)"
check "the dashboard hash came from Hermes's own helper" "$expected_hermes_hash" \
  "$(yaml_value "${FX}/data/hermes_data/config.yaml" password_hash)"
check "the plaintext password member is removed" "0" \
  "$(grep -c '^[[:space:]]*password:' "${FX}/data/hermes_data/config.yaml" || true)"
check "the dashboard username is untouched" "    username: owner" \
  "$(grep -E '^[[:space:]]*username:' "${FX}/data/hermes_data/config.yaml")"
check "the dashboard secret is untouched" "    secret: fixture-dashboard-secret" \
  "$(grep -E '^[[:space:]]*secret:' "${FX}/data/hermes_data/config.yaml")"
check "unrelated config keys survive" "yes" \
  "$(if grep -q '^  theme: dark' "${FX}/data/hermes_data/config.yaml" && grep -q '^  port: 8787' "${FX}/data/hermes_data/config.yaml"; then echo yes; else echo no; fi)"
hermes_backups=()
while IFS= read -r path; do
  [[ -n "$path" ]] && hermes_backups+=("$path")
done < <(find "${FX}/data/hermes_data" -maxdepth 1 -name 'config.yaml.bak.*' -print)
check "the Hermes config has one timestamped backup" "1" "${#hermes_backups[@]}"
if (( ${#hermes_backups[@]} >= 1 )); then
  check "the Hermes backup is mode 0600" "600" "$(mode_of "${hermes_backups[0]}")"
fi
check "the rewritten Hermes config is mode 0600" "600" \
  "$(mode_of "${FX}/data/hermes_data/config.yaml")"

# --- the password itself is nowhere ---------------------------------------
check "the password is not in stdout or stderr" "none" \
  "$(if output_of happy | grep -qF -- "$PASSWORD"; then echo found; else echo none; fi)"
check "the password is not in any captured argv" "none" \
  "$(if grep -qF -- "$PASSWORD" "$STATE/argv.log"; then echo found; else echo none; fi)"
check "the password is not in any file under the test tree" "none" \
  "$(if grep -rIlF -- "$PASSWORD" "$WORK" >/dev/null 2>&1; then echo found; else echo none; fi)"

# --- no restart without consent -------------------------------------------
check "no restart was performed" "none" \
  "$(if [[ -s "$STATE/restart.log" ]]; then echo restart; else echo none; fi)"
check "the exact restart command is printed" "yes" \
  "$(if grep -qF 'docker restart hermes-agent' "${LOGS}/happy.out"; then echo yes; else echo no; fi)"

# --- a second run is safe and byte-stable --------------------------------
cp "${FX}/env/stack.env" "${WORK}/stack.run1"
cp "${FX}/data/hermes_data/config.yaml" "${WORK}/hermes.run1"
run_reset again "$PASSWORD" --no-restart
check "a second run exits 0" "0" "$RUN_RC"
if cmp -s "${WORK}/stack.run1" "${FX}/env/stack.env"; then
  ok "a second run leaves the env file byte-identical"
else
  bad "a second run changed the env file"
  diff -u "${WORK}/stack.run1" "${FX}/env/stack.env" >&2 || true
fi
if cmp -s "${WORK}/hermes.run1" "${FX}/data/hermes_data/config.yaml"; then
  ok "a second run leaves the Hermes config byte-identical"
else
  bad "a second run changed the Hermes config"
fi

# ---------------------------------------------------------------------------
# 3. Hermes not configured: untouched, and the exact message is reported
# ---------------------------------------------------------------------------
echo "== hermes dashboard not configured =="
fresh_fixture skip
hermes_config_without_auth "${FX}/data/hermes_data/config.yaml"
cp "${FX}/data/hermes_data/config.yaml" "${WORK}/hermes-skip.before"
run_reset skip "$PASSWORD" --no-restart
check "exit status is 0" "0" "$RUN_RC"
if cmp -s "${WORK}/hermes-skip.before" "${FX}/data/hermes_data/config.yaml"; then
  ok "the unconfigured Hermes config is byte-identical"
else
  bad "the unconfigured Hermes config was modified"
fi
check "no Hermes backup was written" "0" \
  "$(find "${FX}/data/hermes_data" -maxdepth 1 -name 'config.yaml.bak.*' | wc -l | tr -d ' ')"
check "the exact skip message is reported" "yes" \
  "$(if grep -qF 'Hermes dashboard password not configured — skipped (not enabling)' "${LOGS}/skip.out"; then echo yes; else echo no; fi)"
check "the Hermes leg reports skipped" "yes" \
  "$(if grep -q 'Hermes dashboard  *skipped' "${LOGS}/skip.out"; then echo yes; else echo no; fi)"

# ---------------------------------------------------------------------------
# 4. A container env override: refuse, change nothing
# ---------------------------------------------------------------------------
echo "== hermes env override =="
fresh_fixture override
hermes_config_with_password "${FX}/data/hermes_data/config.yaml"
cp "${FX}/data/hermes_data/config.yaml" "${WORK}/hermes-override.before"
printf '%s\n' "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=owner" > "$STATE/hermes_env"
run_reset override "$PASSWORD" --no-restart
check "exit status is 1" "1" "$RUN_RC"
if cmp -s "${WORK}/hermes-override.before" "${FX}/data/hermes_data/config.yaml"; then
  ok "the overridden Hermes config is byte-identical"
else
  bad "the overridden Hermes config was modified"
fi
check "the override is named in the message" "yes" \
  "$(if grep -qF 'HERMES_DASHBOARD_BASIC_AUTH_USERNAME' "${LOGS}/override.err"; then echo yes; else echo no; fi)"
check "the override leg reports failed" "yes" \
  "$(if grep -q 'Hermes dashboard  *failed' "${LOGS}/override.out"; then echo yes; else echo no; fi)"
check "the auth leg still applied" "yes" \
  "$(if grep -q 'auth gate  *applied' "${LOGS}/override.out"; then echo yes; else echo no; fi)"

# ---------------------------------------------------------------------------
# 5. A failing leg does not abort the others
# ---------------------------------------------------------------------------
echo "== one leg fails, the others still run =="
fresh_fixture twoadmins
hermes_config_with_password "${FX}/data/hermes_data/config.yaml"
printf '%s\n' '[{"id": "a-1", "email": "admin-one", "role": "admin"},' \
  ' {"id": "a-2", "email": "admin-two", "role": "admin"}]' \
  > "$STATE/webui_users.json"
run_reset twoadmins "$PASSWORD" --no-restart
check "exit status is 1" "1" "$RUN_RC"
check "the webui leg reports failed" "yes" \
  "$(if grep -q 'Open WebUI admin  *failed' "${LOGS}/twoadmins.out"; then echo yes; else echo no; fi)"
check "both admin emails are listed" "yes" \
  "$(if grep -qF 'admin-one' "${LOGS}/twoadmins.err" \
        && grep -qF 'admin-two' "${LOGS}/twoadmins.err"; then echo yes; else echo no; fi)"
check "no admin was changed" "0" \
  "$(if [[ -f "$STATE/webui_update.log" ]]; then wc -l < "$STATE/webui_update.log" | tr -d ' '; else echo 0; fi)"
check "the auth leg still applied" "yes" \
  "$(if grep -q 'auth gate  *applied' "${LOGS}/twoadmins.out"; then echo yes; else echo no; fi)"
check "the Hermes leg still applied" "yes" \
  "$(if grep -q 'Hermes dashboard  *applied' "${LOGS}/twoadmins.out"; then echo yes; else echo no; fi)"

# ---------------------------------------------------------------------------
# 6. A weak bcrypt cost is refused before anything is written
# ---------------------------------------------------------------------------
echo "== weak bcrypt cost is refused =="
fresh_fixture weakcost
hermes_config_with_password "${FX}/data/hermes_data/config.yaml"
cp "${FX}/env/stack.env" "${WORK}/stack-weak.before"
STUB_BCRYPT_COST=10
export STUB_BCRYPT_COST
run_reset weakcost "$PASSWORD" --no-restart
STUB_BCRYPT_COST=""
export STUB_BCRYPT_COST
check "exit status is 1" "1" "$RUN_RC"
check "the auth leg reports failed" "yes" \
  "$(if grep -q 'auth gate  *failed' "${LOGS}/weakcost.out"; then echo yes; else echo no; fi)"
check "the refusal names the cost" "yes" \
  "$(if grep -q 'refusing a hash with cost 10' "${LOGS}/weakcost.err"; then echo yes; else echo no; fi)"
if cmp -s "${WORK}/stack-weak.before" "${FX}/env/stack.env"; then
  ok "the env file is untouched after a refused hash"
else
  bad "the env file was written with a refused hash"
fi
check "no env backup was written" "0" \
  "$(find "${FX}/env" -maxdepth 1 -name 'stack.env.bak.*' | wc -l | tr -d ' ')"
check "the Hermes leg still applied" "yes" \
  "$(if grep -q 'Hermes dashboard  *applied' "${LOGS}/weakcost.out"; then echo yes; else echo no; fi)"

# ---------------------------------------------------------------------------
# 7. An env file with no trailing newline keeps that shape
# ---------------------------------------------------------------------------
echo "== env file without a trailing newline =="
fresh_fixture nonewline
hermes_config_with_password "${FX}/data/hermes_data/config.yaml"
printf '%s\n%s\n%s' "TLS_DOMAIN=daemonhub.dev" \
  'HYBRID_AI_AUTH_HASH=$2a$14$LEGACYPLACEHOLDER' "LAST_LINE=no-newline" \
  > "${FX}/env/stack.env"
run_reset nonewline "$PASSWORD" --no-restart
check "exit status is 0" "0" "$RUN_RC"
check "the last line is unchanged" "LAST_LINE=no-newline" \
  "$(tail -n 1 "${FX}/env/stack.env")"
check "the trailing newline is still absent" "no" \
  "$(if [[ "$(tail -c 1 "${FX}/env/stack.env")" == "" ]]; then echo yes; else echo no; fi)"
check "the last line is not merged into the hash line" "yes" \
  "$(if grep -q '^LAST_LINE=no-newline$' "${FX}/env/stack.env"; then echo yes; else echo no; fi)"

# ---------------------------------------------------------------------------
# 8. --generate prints the password exactly once, and never into an argv
# ---------------------------------------------------------------------------
echo "== --generate =="
fresh_fixture generate
hermes_config_with_password "${FX}/data/hermes_data/config.yaml"
run_reset generate "" --generate --no-restart
check "exit status is 0" "0" "$RUN_RC"
generated="$(grep -A3 'Generated password, shown once' "${LOGS}/generate.out" \
  | grep -E '^  \S+$' | tail -n 1 | sed 's/^  //')"
check "the generated password is 24 characters" "24" "${#generated}"
check "it is printed exactly once" "1" "$(grep -cF -- "$generated" "${LOGS}/generate.out" || true)"
check "it is not in any captured argv" "0" \
  "$(grep -cF -- "$generated" "$STATE/argv.log" || true)"
check "the generated value is not stored in the env file" "0" \
  "$(grep -cF -- "$generated" "${FX}/env/stack.env" || true)"

# ---------------------------------------------------------------------------
# 9. A failed install of the rewritten Hermes config is reported, not applied
# ---------------------------------------------------------------------------
echo "== install failure leaves the original intact =="
fresh_fixture installfail
hermes_config_with_password "${FX}/data/hermes_data/config.yaml"
cp "${FX}/data/hermes_data/config.yaml" "${WORK}/hermes-installfail.before"
_wrap_mutator install FAIL_INSTALL config.candidate.yaml
FAIL_INSTALL=23 run_reset installfail "$PASSWORD" --no-restart
WRAPBIN=""
check "exit status is 1" "1" "$RUN_RC"
check "the Hermes leg reports failed" "yes" \
  "$(if grep -q 'Hermes dashboard  *failed' "${LOGS}/installfail.out"; then echo yes; else echo no; fi)"
check "the failure detail names the staging step" "yes" \
  "$(if grep -q 'could not stage the rewritten config.yaml' "${LOGS}/installfail.err"; then echo yes; else echo no; fi)"
if cmp -s "${WORK}/hermes-installfail.before" "${FX}/data/hermes_data/config.yaml"; then
  ok "a failed install leaves the original config.yaml intact"
else
  bad "a failed install still changed config.yaml"
fi
check "the auth leg still applied" "yes" \
  "$(if grep -q 'auth gate  *applied' "${LOGS}/installfail.out"; then echo yes; else echo no; fi)"
check "the webui leg still applied" "yes" \
  "$(if grep -q 'Open WebUI admin  *applied' "${LOGS}/installfail.out"; then echo yes; else echo no; fi)"

# ---------------------------------------------------------------------------
# 10. A failed chmod / rename in the auth leg is reported, not applied
# ---------------------------------------------------------------------------
echo "== auth chmod failure leaves the env file intact =="
fresh_fixture chmodfail
hermes_config_with_password "${FX}/data/hermes_data/config.yaml"
cp "${FX}/env/stack.env" "${WORK}/stack-chmodfail.before"
_wrap_mutator chmod FAIL_CHMOD stack.env.tmp
FAIL_CHMOD=1 run_reset chmodfail "$PASSWORD" --no-restart
WRAPBIN=""
check "exit status is 1" "1" "$RUN_RC"
check "the auth leg reports failed" "yes" \
  "$(if grep -q 'auth gate  *failed' "${LOGS}/chmodfail.out"; then echo yes; else echo no; fi)"
check "the failure detail names the mode step" "yes" \
  "$(if grep -q 'could not set mode 0600' "${LOGS}/chmodfail.err"; then echo yes; else echo no; fi)"
if cmp -s "${WORK}/stack-chmodfail.before" "${FX}/env/stack.env"; then
  ok "a failed chmod leaves the stack env file intact"
else
  bad "a failed chmod still changed the stack env file"
fi
check "the Hermes leg still applied" "yes" \
  "$(if grep -q 'Hermes dashboard  *applied' "${LOGS}/chmodfail.out"; then echo yes; else echo no; fi)"

echo "== auth rename failure leaves the env file intact =="
fresh_fixture renamefail
hermes_config_with_password "${FX}/data/hermes_data/config.yaml"
cp "${FX}/env/stack.env" "${WORK}/stack-renamefail.before"
_wrap_mutator mv FAIL_MV stack.env.tmp
FAIL_MV=1 run_reset renamefail "$PASSWORD" --no-restart
WRAPBIN=""
check "exit status is 1" "1" "$RUN_RC"
check "the auth leg reports failed" "yes" \
  "$(if grep -q 'auth gate  *failed' "${LOGS}/renamefail.out"; then echo yes; else echo no; fi)"
check "the failure detail names the replacement step" "yes" \
  "$(if grep -q 'could not replace' "${LOGS}/renamefail.err"; then echo yes; else echo no; fi)"
if cmp -s "${WORK}/stack-renamefail.before" "${FX}/env/stack.env"; then
  ok "a failed rename leaves the stack env file intact"
else
  bad "a failed rename still changed the stack env file"
fi
check "the Hermes leg still applied" "yes" \
  "$(if grep -q 'Hermes dashboard  *applied' "${LOGS}/renamefail.out"; then echo yes; else echo no; fi)"

# ---------------------------------------------------------------------------
# 11. A failed ownership application fails closed and leaves the original
# ---------------------------------------------------------------------------
echo "== chown failure leaves the original config intact =="
fresh_fixture chownfail
hermes_config_with_password "${FX}/data/hermes_data/config.yaml"
cp "${FX}/data/hermes_data/config.yaml" "${WORK}/hermes-chownfail.before"
_wrap_mutator chown FAIL_CHOWN config.yaml.tmp
FAIL_CHOWN=1 run_reset chownfail "$PASSWORD" --no-restart
WRAPBIN=""
check "exit status is 1" "1" "$RUN_RC"
check "the Hermes leg reports failed" "yes" \
  "$(if grep -q 'Hermes dashboard  *failed' "${LOGS}/chownfail.out"; then echo yes; else echo no; fi)"
check "the failure detail names the ownership step" "yes" \
  "$(if grep -q 'could not preserve the ownership/mode' "${LOGS}/chownfail.err"; then echo yes; else echo no; fi)"
if cmp -s "${WORK}/hermes-chownfail.before" "${FX}/data/hermes_data/config.yaml"; then
  ok "a failed chown leaves the original config.yaml intact"
else
  bad "a failed chown still changed config.yaml"
fi

# ---------------------------------------------------------------------------
# 12. The WebUI helper returning False fails the leg
# ---------------------------------------------------------------------------
echo "== webui helper returns False =="
fresh_fixture webuifalse
hermes_config_with_password "${FX}/data/hermes_data/config.yaml"
cp "${FX}/env/stack.env" "${WORK}/stack-webuifalse.before"
STUB_WEBUI_UPDATE_RESULT=0
export STUB_WEBUI_UPDATE_RESULT
run_reset webuifalse "$PASSWORD" --no-restart
STUB_WEBUI_UPDATE_RESULT=""
export STUB_WEBUI_UPDATE_RESULT
check "exit status is 1" "1" "$RUN_RC"
check "the webui leg reports failed" "yes" \
  "$(if grep -q 'Open WebUI admin  *failed' "${LOGS}/webuifalse.out"; then echo yes; else echo no; fi)"
check "the failure detail names the in-container update" "yes" \
  "$(if grep -q 'the in-container update failed for' "${LOGS}/webuifalse.err"; then echo yes; else echo no; fi)"
check "the auth leg still applied" "yes" \
  "$(if grep -q 'auth gate  *applied' "${LOGS}/webuifalse.out"; then echo yes; else echo no; fi)"
check "the Hermes leg still applied" "yes" \
  "$(if grep -q 'Hermes dashboard  *applied' "${LOGS}/webuifalse.out"; then echo yes; else echo no; fi)"

# ---------------------------------------------------------------------------
# 13. A requested restart that fails is a failed (partial) leg
# ---------------------------------------------------------------------------
echo "== requested restart fails (--restart-hermes) =="
fresh_fixture restartfail
hermes_config_with_password "${FX}/data/hermes_data/config.yaml"
STUB_RESTART_FAIL=1
export STUB_RESTART_FAIL
run_reset restartfail "$PASSWORD" --restart-hermes
STUB_RESTART_FAIL=""
export STUB_RESTART_FAIL
check "exit status is 1" "1" "$RUN_RC"
check "the Hermes leg reports failed" "yes" \
  "$(if grep -q 'Hermes dashboard  *failed' "${LOGS}/restartfail.out"; then echo yes; else echo no; fi)"
check "the detail says the config was written but the restart failed" "yes" \
  "$(if grep -qF 'config written, restart failed' "${LOGS}/restartfail.out"; then echo yes; else echo no; fi)"
check "a restart was attempted" "yes" \
  "$(if [[ -s "$STATE/restart.log" ]]; then echo yes; else echo no; fi)"
check "the config was still written" "yes" \
  "$(if grep -q 'password_hash: scrypt' "${FX}/data/hermes_data/config.yaml"; then echo yes; else echo no; fi)"

echo "== requested restart fails (interactive yes) =="
fresh_fixture restarttty
hermes_config_with_password "${FX}/data/hermes_data/config.yaml"
STUB_RESTART_FAIL=1
export STUB_RESTART_FAIL
printf '%s\n%s\ny\n' "$PASSWORD" "$PASSWORD" > "${WORK}/tty-restarttty.in"
run_reset_tty restarttty "${WORK}/tty-restarttty.in"
STUB_RESTART_FAIL=""
export STUB_RESTART_FAIL
check "exit status is 1" "1" "$RUN_RC"
check "the Hermes leg reports failed" "yes" \
  "$(if grep -q 'Hermes dashboard  *failed' "${LOGS}/restarttty.out"; then echo yes; else echo no; fi)"
check "the detail says the config was written but the restart failed" "yes" \
  "$(if grep -qF 'config written, restart failed' "${LOGS}/restarttty.out"; then echo yes; else echo no; fi)"
check "a restart was attempted" "yes" \
  "$(if [[ -s "$STATE/restart.log" ]]; then echo yes; else echo no; fi)"

echo "== a declined restart is not a failure =="
fresh_fixture restartno
hermes_config_with_password "${FX}/data/hermes_data/config.yaml"
printf '%s\n%s\nn\n' "$PASSWORD" "$PASSWORD" > "${WORK}/tty-restartno.in"
run_reset_tty restartno "${WORK}/tty-restartno.in"
check "exit status is 0" "0" "$RUN_RC"
check "the Hermes leg reports applied" "yes" \
  "$(if grep -q 'Hermes dashboard  *applied' "${LOGS}/restartno.out"; then echo yes; else echo no; fi)"
check "no restart was attempted" "none" \
  "$(if [[ -s "$STATE/restart.log" ]]; then echo restart; else echo none; fi)"

# ---------------------------------------------------------------------------
# 14. A confirmation line that is empty is refused exactly like a mismatch
# ---------------------------------------------------------------------------
echo "== empty confirmation is refused (stdin) =="
fresh_fixture emptysecond
hermes_config_with_password "${FX}/data/hermes_data/config.yaml"
set +e
printf '%s\n\n' "$PASSWORD" | env \
  PATH="${BIN}:${PATH}" STUB_STATE="$STATE" STUB_PY="$PYSTUB" \
  STUB_STACK_FILE="${FX}/env/stack.env" \
  HYBRID_AI_ENV_FILE="${FX}/env/layout.env" \
  HYBRID_AI_STACK_ENV_FILE="${FX}/env/stack.env" \
  HYBRID_AI_APP_DIR="${FX}/app" HYBRID_AI_DATA_DIR="${FX}/data" \
  "$RESET_SCRIPT" --no-restart > "${LOGS}/emptysecond.out" 2> "${LOGS}/emptysecond.err"
RUN_RC=$?
set -e
check "exit status is 2" "2" "$RUN_RC"
check "the mismatch is reported" "yes" \
  "$(if grep -q 'the two passwords do not match' "${LOGS}/emptysecond.err"; then echo yes; else echo no; fi)"
check "nothing was changed" "0" \
  "$(grep -c -E '^(auth gate|Open WebUI admin|Hermes dashboard)' "${LOGS}/emptysecond.out" || true)"

echo "== empty confirmation is refused (interactive) =="
fresh_fixture emptysecondtty
hermes_config_with_password "${FX}/data/hermes_data/config.yaml"
printf '%s\n\n' "$PASSWORD" > "${WORK}/tty-emptysecond.in"
run_reset_tty emptysecondtty "${WORK}/tty-emptysecond.in"
check "exit status is 2" "2" "$RUN_RC"
check "the mismatch is reported" "yes" \
  "$(if output_of emptysecondtty | grep -q 'the two passwords do not match'; then echo yes; else echo no; fi)"

# ---------------------------------------------------------------------------
# 15. Subprocess output is scrubbed: a hostile helper cannot leak a secret
# ---------------------------------------------------------------------------
echo "== a helper that echoes the password to stderr does not leak it =="
fresh_fixture leakpw
hermes_config_with_password "${FX}/data/hermes_data/config.yaml"
STUB_BCRYPT_ECHO_PASSWORD=1
export STUB_BCRYPT_ECHO_PASSWORD
run_reset leakpw "$PASSWORD" --no-restart
STUB_BCRYPT_ECHO_PASSWORD=""
export STUB_BCRYPT_ECHO_PASSWORD
check "exit status is 0" "0" "$RUN_RC"
check "the password is not in the script's stdout or stderr" "none" \
  "$(if output_of leakpw | grep -qF -- "$PASSWORD"; then echo found; else echo none; fi)"
check "the auth leg still applied" "yes" \
  "$(if grep -q 'auth gate  *applied' "${LOGS}/leakpw.out"; then echo yes; else echo no; fi)"
check "the webui leg still applied" "yes" \
  "$(if grep -q 'Open WebUI admin  *applied' "${LOGS}/leakpw.out"; then echo yes; else echo no; fi)"
check "the Hermes leg still applied" "yes" \
  "$(if grep -q 'Hermes dashboard  *applied' "${LOGS}/leakpw.out"; then echo yes; else echo no; fi)"

echo "== a helper that echoes a sentinel hash to stderr does not leak it =="
fresh_fixture leakhash
hermes_config_with_password "${FX}/data/hermes_data/config.yaml"
SENTINEL_HASH='scrypt$sentinel$DO-NOT-LEAK-9f3a'
STUB_HERMES_ECHO_SENTINEL="$SENTINEL_HASH"
export STUB_HERMES_ECHO_SENTINEL
run_reset leakhash "$PASSWORD" --no-restart
STUB_HERMES_ECHO_SENTINEL=""
export STUB_HERMES_ECHO_SENTINEL
check "exit status is 0" "0" "$RUN_RC"
check "the sentinel hash is not in the script's stdout or stderr" "none" \
  "$(if output_of leakhash | grep -qF -- "$SENTINEL_HASH"; then echo found; else echo none; fi)"
check "the Hermes leg still applied" "yes" \
  "$(if grep -q 'Hermes dashboard  *applied' "${LOGS}/leakhash.out"; then echo yes; else echo no; fi)"
check "the auth leg still applied" "yes" \
  "$(if grep -q 'auth gate  *applied' "${LOGS}/leakhash.out"; then echo yes; else echo no; fi)"

# ---------------------------------------------------------------------------
# 16. The replacement carries the original's owner and mode
# ---------------------------------------------------------------------------
echo "== the replacement preserves owner and mode =="
fresh_fixture ownership
hermes_config_with_password "${FX}/data/hermes_data/config.yaml"
orig_uid="$(stat -c '%u' "${FX}/data/hermes_data/config.yaml")"
orig_gid="$(stat -c '%g' "${FX}/data/hermes_data/config.yaml")"
: > "$STATE/chown.log"
_wrap_chown_logger
run_reset ownership "$PASSWORD" --no-restart
WRAPBIN=""
check "exit status is 0" "0" "$RUN_RC"
check "the rewritten config keeps the original mode" "600" \
  "$(mode_of "${FX}/data/hermes_data/config.yaml")"
if [[ -s "$STATE/chown.log" ]]; then
  check "chown was applied to the replacement with the original uid:gid" "yes" \
    "$(if grep -qF "${orig_uid}:${orig_gid}" "$STATE/chown.log"; then echo yes; else echo no; fi)"
  check "the chown targets the staged replacement, not the original" "yes" \
    "$(if grep -qF 'config.yaml.tmp' "$STATE/chown.log"; then echo yes; else echo no; fi)"
else
  printf 'SKIPPED: chown not permitted\n'
  check "the rewritten config keeps the original mode" "600" \
    "$(mode_of "${FX}/data/hermes_data/config.yaml")"
fi
check "the env replacement also carried the original owner" "yes" \
  "$(if grep -qF -- "${FX}/env/stack.env.tmp" "$STATE/chown.log"; then echo yes; else echo no; fi)"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "== Summary =="
printf '  passed: %d\n' "$PASS"
printf '  failed: %d\n' "$FAIL"
if (( FAIL > 0 )); then
  printf 'RESULT: FAIL\n' >&2
  exit 1
fi
printf 'RESULT: PASS\n'
exit 0
