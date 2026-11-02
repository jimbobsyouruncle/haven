#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/reset-passwords.sh
# PURPOSE (plain English):
#   Set ONE new password on all three login surfaces of this stack. The owner
#   runs it on the host; the deploy never calls it.
#
#     1. the `auth` forward-auth gate  -> HYBRID_AI_AUTH_HASH in the STACK env
#                                         file: a bcrypt hash (cost 12) made
#                                         inside the auth image itself
#     2. the Open WebUI admin account  -> the app's own hash helper, against
#                                         the EXISTING admin row, in-container
#     3. the Hermes WebUI dashboard    -> dashboard.basic_auth.password_hash in
#                                         the Hermes profile config.yaml, hashed
#                                         by Hermes's own helper in-container
#
#   Every ENABLED STATE is preserved exactly as it was found: AUTH_ENABLED,
#   WEBUI_AUTH, and whether the Hermes dashboard basic_auth block is configured
#   at all. A surface that is not configured is SKIPPED, never enabled. Cookie
#   secrets, session secrets, usernames and passkeys are never touched.
#
# PASSWORD INTAKE (stdin only -- never argv, never a subprocess environment):
#   * no flags:   prompt twice with echo off
#   * no TTY:     read from stdin instead (two lines, or one line then EOF), so
#                 an offline harness can drive the script
#   * --generate: a CSPRNG password of 24 characters, printed exactly once in
#                 the final summary; that display is the only place a password
#                 is ever printed
#   The password reaches a container on STDIN only. It is never written to a
#   backup, a temp file or a log, and never enters a command line.
#
# ORDERING AND FAILURE:
#   Legs run auth -> open-webui -> hermes. A failing leg never aborts the
#   others. The exit status is non-zero if any leg failed. Re-running is safe.
#
# BACKUPS: every file this script rewrites is copied first to
#   <file>.bak.<UTC timestamp>.<pid> in the same directory, mode 0600.
#
# HERMES RESTART: a config edit takes effect only at the next WebUI start, and
#   `docker restart hermes-agent` also restarts the gateway, which kills any
#   kanban worker that is running. So it restarts ONLY on an explicit
#   interactive yes, or with --restart-hermes. With --no-restart or no TTY it
#   prints the exact command instead.
#
# USAGE:
#   ./scripts/reset-passwords.sh                  # prompt twice
#   ./scripts/reset-passwords.sh --generate       # random password, shown once
#   ./scripts/reset-passwords.sh --no-restart     # never restart hermes-agent
#   ./scripts/reset-passwords.sh --restart-hermes # restart it after the edit
#
# EXIT CODES:
#   0  every leg applied, or was legitimately skipped
#   1  at least one leg failed
#   2  the password could not be read, or a required tool is missing
# ---------------------------------------------------------------------------
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/hybrid-ai-env.sh
source "${SCRIPT_DIR}/lib/hybrid-ai-env.sh"
# shellcheck source=scripts/lib/tls.sh
source "${SCRIPT_DIR}/lib/tls.sh"

APP_DIR="$HYBRID_AI_APP_DIR"
# The STACK env file is the 0600 file that holds HYBRID_AI_AUTH_HASH. The layout
# file may be 0644 and is never written here. No path is hardcoded.
ENV_FILE="$HYBRID_AI_STACK_ENV_FILE"
HERMES_CONFIG="${HYBRID_AI_HERMES_DATA_DIR}/config.yaml"
COMPOSE=(docker compose -p hybrid-ai --env-file "$ENV_FILE" --project-directory "$APP_DIR"
         -f "$APP_DIR/docker-compose.yml"
         -f "$APP_DIR/openhands/docker-compose.openhands.yml"
         -f "$APP_DIR/hermes/docker-compose.hermes.yml")

AUTH_CONTAINER="hybrid-ai-auth"
WEBUI_CONTAINER="open-webui"
HERMES_CONTAINER="hermes-agent"
AUTH_HASH_KEY="HYBRID_AI_AUTH_HASH"
AUTH_HASH_BYTES=60
MIN_GENERATED_LENGTH=24
BCRYPT_MIN_ROUNDS=12
HERMES_SKIP_MESSAGE="Hermes dashboard password not configured — skipped (not enabling)"

GENERATE=0
RESTART_HERMES=0
NO_RESTART=0
NEW_PASSWORD=""
WORK_DIR=""

AUTH_STATE="not run"
AUTH_DETAIL="-"
WEBUI_STATE="not run"
WEBUI_DETAIL="-"
HERMES_STATE="not run"
HERMES_DETAIL="-"
HERMES_RESTARTED=0

# Credential scrubbing on error paths: name the line, never the command, so no
# value can reach stderr through a failed expansion.
trap 'printf "reset-passwords: unexpected failure at line %s\n" "$LINENO" >&2' ERR

say()      { printf '%s\n' "$*"; }
note()     { printf '[*] %s\n' "$*"; }
ok()       { printf '[OK] %s\n' "$*"; }
warn()     { printf '[!] %s\n' "$*" >&2; }
fail_msg() { printf '[X] %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: scripts/reset-passwords.sh [--generate] [--restart-hermes | --no-restart]

Sets ONE new password on the auth gate, the Open WebUI admin account and the
Hermes WebUI dashboard, preserving every enabled state exactly as found.

  --generate        create a CSPRNG password (24 chars) and print it ONCE in
                    the final summary
  --restart-hermes  restart hermes-agent after the config edit (this also
                    restarts the gateway and kills running kanban workers)
  --no-restart      never restart hermes-agent; print the command instead
  -h, --help        this text

With no flag the password is prompted twice with echo off. When stdin is not a
terminal the password is read from stdin instead (two lines, or one line and
then EOF). A password is never accepted on the command line.
EOF
}

need() {
  local tool="$1" why="$2"
  if ! command -v "$tool" >/dev/null 2>&1; then
    fail_msg "required tool '$tool' is missing ($why)"
    exit 2
  fi
}

# ---------------------------------------------------------------------------
# Password intake
# ---------------------------------------------------------------------------
generate_password() {
  # 24 characters from an alphabet that survives a shell, an env file and a
  # terminal: no '$', no quote, no backslash. The value is captured from
  # stdout; it is never an argument of anything.
  python3 - <<'PY'
import secrets
import string

alphabet = string.ascii_letters + string.digits + "-_.~!@#%^&*+=?"
print("".join(secrets.choice(alphabet) for _ in range(24)))
PY
}

read_password() {
  local first="" second="" have_second=0

  if (( GENERATE )); then
    if ! NEW_PASSWORD="$(generate_password)"; then
      fail_msg "could not generate a password"
      return 1
    fi
    if (( ${#NEW_PASSWORD} < MIN_GENERATED_LENGTH )); then
      fail_msg "the generated password is shorter than ${MIN_GENERATED_LENGTH} characters"
      NEW_PASSWORD=""
      return 1
    fi
    return 0
  fi

  if [[ -t 0 ]]; then
    printf 'New password (used for all three login surfaces): ' >&2
    if ! IFS= read -r -s first; then
      printf '\n' >&2
      fail_msg "could not read the password"
      return 1
    fi
    printf '\n' >&2
    printf 'Repeat the password: ' >&2
    if ! IFS= read -r -s second; then
      printf '\n' >&2
      fail_msg "could not read the confirmation"
      return 1
    fi
    printf '\n' >&2
    have_second=1
  else
    say "Reading the new password from stdin (two lines, or one line then EOF)."
    if ! IFS= read -r first; then
      fail_msg "no password on stdin"
      return 1
    fi
    if IFS= read -r second; then
      have_second=1
    fi
  fi

  if [[ -z "$first" ]]; then
    fail_msg "an empty password is refused"
    return 1
  fi
  if (( have_second )) && [[ "$second" != "$first" ]]; then
    fail_msg "the two passwords do not match"
    return 1
  fi
  NEW_PASSWORD="$first"
  return 0
}

# ---------------------------------------------------------------------------
# Env-file rewrite: change ONE key, keep every other byte
# ---------------------------------------------------------------------------
# _env_rewrite_key <file> <key> <value> <out>
# The value is written verbatim, so the caller escapes it for compose first.
# Every other line is copied byte for byte, in order, and the file's trailing
# newline state (present or absent) is preserved.
_env_rewrite_key() {
  local file="$1" key="$2" value="$3" out="$4"
  local line="" re="" replaced=0 trailing_nl=1

  re="^[[:space:]]*(export[[:space:]]+)?${key}="
  : > "$out"

  if [[ ! -s "$file" ]]; then
    printf '%s=%s\n' "$key" "$value" > "$out"
    return 0
  fi

  if [[ -n "$(tail -c 1 -- "$file" || true)" ]]; then
    trailing_nl=0
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $re ]]; then
      if (( replaced == 0 )); then
        printf '%s=%s\n' "$key" "$value" >> "$out"
        replaced=1
      fi
      continue
    fi
    printf '%s\n' "$line" >> "$out"
  done < "$file"

  if (( replaced == 0 )); then
    # An appended line needs a terminator, or it would join the last line.
    printf '%s=%s\n' "$key" "$value" >> "$out"
    trailing_nl=1
  fi

  if (( trailing_nl == 0 )); then
    truncate -s -1 "$out"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# File metadata preservation
#
# A replacement file must carry the original's owner, group and mode, or a
# root-run replacement leaves a caller-owned file the Hermes runtime user can
# no longer read. Read the original's metadata BEFORE the rename and apply it
# to the replacement; fail closed when it cannot be read or applied.
# ---------------------------------------------------------------------------
_file_uid()  { stat -c '%u' -- "$1" 2>/dev/null || stat -f '%u' -- "$1"; }
_file_gid()  { stat -c '%g' -- "$1" 2>/dev/null || stat -f '%g' -- "$1"; }
_file_mode() { stat -c '%a' -- "$1" 2>/dev/null || stat -f '%Lp' -- "$1"; }

# _preserve_owner_mode <original> <target>
# Copies <original>'s uid, gid and mode onto <target>. Returns non-zero when
# any value cannot be read or applied.
_preserve_owner_mode() {
  local original="$1" target="$2"
  local uid="" gid="" mode=""
  uid="$(_file_uid "$original")" || return 1
  gid="$(_file_gid "$original")" || return 1
  mode="$(_file_mode "$original")" || return 1
  [[ -n "$uid" && -n "$gid" && -n "$mode" ]] || return 1
  chmod "$mode" -- "$target" || return 1
  chown "$uid:$gid" -- "$target" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# In-container programs
#
# Each one is passed to `docker exec ... -c` as PROGRAM TEXT. The password is
# never in that text: it arrives on stdin. None of them prints a password, a
# hash or a secret: they print verdicts, key names and lengths only.
#
# The leading marker comment is an ordinary Python comment at run time; the
# offline harness uses it to dispatch its `docker` stub.
# ---------------------------------------------------------------------------
auth_hash_program() {
  cat <<'PY'
# hybrid-ai-reset-passwords: auth-hash
import sys

import bcrypt

password = sys.stdin.read()
if password.endswith("\n"):
    password = password[:-1]
hashed = bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt(rounds=12))
sys.stdout.write(hashed.decode("ascii") + "\n")
PY
}

auth_length_program() {
  cat <<'PY'
# hybrid-ai-reset-passwords: auth-hash-length
import os
import sys

sys.stdout.write(str(len(os.environ.get("HYBRID_AI_AUTH_HASH", ""))) + "\n")
PY
}

webui_admin_list_program() {
  cat <<'PY'
# hybrid-ai-reset-passwords: webui-admins
import asyncio
import json

from open_webui.models.users import Users


async def main():
    result = await Users.get_users(filter={"roles": ["admin"]})
    users = result.get("users", []) if isinstance(result, dict) else result
    rows = [
        {"id": u.id, "email": u.email, "role": getattr(u, "role", "")}
        for u in users
    ]
    print(json.dumps(rows))


asyncio.run(main())
PY
}

webui_set_password_program() {
  cat <<'PY'
# hybrid-ai-reset-passwords: webui-set-password
import asyncio
import os
import sys

from open_webui.models.auths import Auths
from open_webui.utils.auth import get_password_hash

password = sys.stdin.read()
if password.endswith("\n"):
    password = password[:-1]
target = os.environ["HYBRID_AI_WEBUI_TARGET_ID"]


async def main():
    hashed = await get_password_hash(password)
    result = await Auths.update_user_password_by_id(target, hashed)
    if not result:
        sys.stderr.write("the update helper reported that no auth row was updated\n")
        raise SystemExit(3)


asyncio.run(main())
PY
}

hermes_probe_program() {
  cat <<'PY'
# hybrid-ai-reset-passwords: hermes-probe
import sys

import yaml

try:
    document = yaml.safe_load(sys.stdin.read())
except Exception:
    print("parse_error=1")
    raise SystemExit(0)

if not isinstance(document, dict):
    document = {}
dashboard = document.get("dashboard")
if not isinstance(dashboard, dict):
    dashboard = {}
raw_block = dashboard.get("basic_auth")
block = raw_block if isinstance(raw_block, dict) else {}


def present(value):
    if isinstance(value, str):
        return 1 if value.strip() else 0
    return 1 if value else 0


print("parse_error=0")
print("auth_present=%d" % (1 if isinstance(raw_block, dict) else 0))
print("username=%d" % present(block.get("username")))
print("password_hash=%d" % present(block.get("password_hash")))
print("password=%d" % present(block.get("password")))
print("secret=%d" % present(block.get("secret")))
PY
}

hermes_hash_program() {
  cat <<'PY'
# hybrid-ai-reset-passwords: hermes-hash
import inspect
import sys

import plugins.dashboard_auth.basic as basic

hasher = basic.hash_password
password = sys.stdin.read()
if password.endswith("\n"):
    password = password[:-1]

positional = [
    p for p in inspect.signature(hasher).parameters.values()
    if p.kind in (p.POSITIONAL_ONLY, p.POSITIONAL_OR_KEYWORD)
]
if not positional:
    sys.stderr.write("hash_password takes no positional parameter\n")
    raise SystemExit(2)

try:
    value = hasher(password)
except TypeError:
    value = hasher(password=password)

if isinstance(value, dict):
    for key in ("password_hash", "hash", "value"):
        if isinstance(value.get(key), str):
            value = value[key]
            break
if isinstance(value, bytes):
    value = value.decode("ascii", "replace")
if not isinstance(value, str) or not value.strip():
    sys.stderr.write("hash_password returned no hash\n")
    raise SystemExit(2)
sys.stdout.write(value.strip() + "\n")
PY
}

hermes_verify_program() {
  cat <<'PY'
# hybrid-ai-reset-passwords: hermes-verify
import json
import sys

import yaml

ALLOWED = {"dashboard.basic_auth.password_hash", "dashboard.basic_auth.password"}
MISSING = "<<missing>>"


def flatten(node, prefix=""):
    flat = {}
    if isinstance(node, dict):
        for key, value in node.items():
            path = "%s.%s" % (prefix, key) if prefix else str(key)
            if isinstance(value, dict):
                flat.update(flatten(value, path))
            else:
                flat[path] = value
    else:
        flat[prefix] = node
    return flat


payload = json.load(sys.stdin)
before = flatten(yaml.safe_load(payload["old"]) or {})
after = flatten(yaml.safe_load(payload["new"]) or {})

changed = sorted(
    path for path in set(before) | set(after)
    if before.get(path, MISSING) != after.get(path, MISSING)
)
problems = [path for path in changed if path not in ALLOWED]

print("changed=%s" % (",".join(changed) if changed else "(none)"))
if not changed:
    print("error=no key changed")
    raise SystemExit(1)
if problems:
    print("error=unexpected key(s) changed: %s" % ",".join(problems))
    raise SystemExit(1)
if not after.get("dashboard.basic_auth.password_hash"):
    print("error=password_hash is missing after the edit")
    raise SystemExit(1)
print("verdict=only the dashboard password keys changed")
PY
}

hermes_roundtrip_program() {
  cat <<'PY'
# hybrid-ai-reset-passwords: hermes-roundtrip
import json
import sys

import yaml

payload = json.load(sys.stdin)
document = yaml.safe_load(payload["config"])
if not isinstance(document, dict):
    sys.stderr.write("config.yaml is not a mapping\n")
    raise SystemExit(2)
dashboard = document.get("dashboard")
if not isinstance(dashboard, dict):
    dashboard = {}
block = dashboard.get("basic_auth")
if not isinstance(block, dict):
    sys.stderr.write("dashboard.basic_auth is not a mapping\n")
    raise SystemExit(2)
block["password_hash"] = payload["password_hash"]
block.pop("password", None)
dashboard["basic_auth"] = block
document["dashboard"] = dashboard
sys.stdout.write(yaml.safe_dump(document, sort_keys=False, allow_unicode=True))
PY
}

# ---------------------------------------------------------------------------
# Hermes config: targeted textual edit, then verification
# ---------------------------------------------------------------------------
# _hermes_textual_edit <config> <hash-file> <out>
# Rewrites only the `password_hash:` member of dashboard.basic_auth (in place of
# a plaintext `password:` member when there is one, else at the end of the
# block) and removes that plaintext member. Every other byte is copied.
# The hash arrives in a file, never in argv or the environment.
# Returns 3 when no dashboard.basic_auth mapping was found.
_hermes_textual_edit() {
  local config="$1" hash_file="$2" out="$3"
  awk '
    function indent_of(s) { match(s, /^[ ]*/); return RLENGTH }
    function emit(ind) { printf "%*spassword_hash: %s\n", ind, "", new_hash; replaced = 1 }
    NR == FNR { new_hash = $0; next }
    {
      line = $0
      if (line ~ /^[ ]*(#.*)?$/) { print line; next }
      ind = indent_of(line)
      if (ind == 0 && line ~ /^dashboard:[ ]*$/) {
        in_dash = 1; in_auth = 0; auth_indent = -1; key_indent = 0
        print line; next
      }
      if (in_dash && ind == 0) { in_dash = 0; in_auth = 0; auth_indent = -1 }
      if (in_dash) {
        if (!in_auth && auth_indent < 0 && line ~ /^[ ]*basic_auth:[ ]*$/) {
          in_auth = 1; auth_indent = ind; key_indent = ind + 2
          print line; next
        }
        if (in_auth) {
          if (ind <= auth_indent) {
            if (!replaced) emit(key_indent)
            in_auth = 0; auth_indent = -1
          } else {
            key = line; sub(/^[ ]*/, "", key); sub(/:.*$/, "", key)
            if (key_indent == 0) key_indent = ind
            if (key == "password_hash" || key == "password") {
              if (!replaced) emit(ind)
              next
            }
          }
        }
      }
      print line
    }
    END {
      if (in_auth && !replaced) emit(key_indent)
      exit (replaced ? 0 : 3)
    }
  ' "$hash_file" "$config" > "$out"
}

# _hermes_auth_members <file> -> one "key|original line" per basic_auth member
_hermes_auth_members() {
  awk '
    function indent_of(s) { match(s, /^[ ]*/); return RLENGTH }
    {
      line = $0
      if (line ~ /^[ ]*(#.*)?$/) next
      ind = indent_of(line)
      if (ind == 0 && line ~ /^dashboard:[ ]*$/) { in_dash = 1; in_auth = 0; auth_indent = -1; next }
      if (in_dash && ind == 0) { in_dash = 0; in_auth = 0; auth_indent = -1 }
      if (in_dash && !in_auth && auth_indent < 0 && line ~ /^[ ]*basic_auth:[ ]*$/) {
        in_auth = 1; auth_indent = ind; next
      }
      if (in_auth) {
        if (ind <= auth_indent) { in_auth = 0; auth_indent = -1; next }
        key = line; sub(/^[ ]*/, "", key); sub(/:.*$/, "", key)
        if (key == "username" || key == "password_hash" || key == "password" || key == "secret") {
          print key "|" line
        }
      }
    }
  ' "$1"
}

# _hermes_candidate_is_safe <before> <after>
# Returns 0 when the candidate carries only the dashboard password members:
# username and secret lines byte-identical, no plaintext password left, and
# exactly one password_hash line.
_hermes_candidate_is_safe() {
  local before="$1" after="$2"
  local before_members="" after_members="" key="" count=""

  before_members="$(_hermes_auth_members "$before")"
  after_members="$(_hermes_auth_members "$after")"

  for key in username secret; do
    if [[ "$(printf '%s\n' "$before_members" | grep -E "^${key}\|" || true)" \
        != "$(printf '%s\n' "$after_members" | grep -E "^${key}\|" || true)" ]]; then
      return 1
    fi
  done

  count="$(printf '%s\n' "$after_members" | grep -c '^password|' || true)"
  [[ "$count" == "0" ]] || return 1
  count="$(printf '%s\n' "$after_members" | grep -c '^password_hash|' || true)"
  [[ "$count" == "1" ]] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# Leg 1 -- the auth forward-auth gate
# ---------------------------------------------------------------------------
leg_auth() {
  local hash="" cost="" escaped="" backup="" tmp="" length=""

  if [[ ! -f "$ENV_FILE" ]]; then
    AUTH_STATE="failed"; AUTH_DETAIL="no stack env file at $ENV_FILE"
    fail_msg "auth: no stack env file at $ENV_FILE"
    return 1
  fi
  if [[ ! -r "$ENV_FILE" || ! -w "$ENV_FILE" ]]; then
    AUTH_STATE="failed"; AUTH_DETAIL="the stack env file is not readable and writable by this account"
    fail_msg "auth: $ENV_FILE must be readable and writable by this account"
    return 1
  fi

  note "auth: hashing the password inside $AUTH_CONTAINER (bcrypt, cost $BCRYPT_MIN_ROUNDS)"
  if ! hash="$(printf '%s' "$NEW_PASSWORD" | docker exec -i "$AUTH_CONTAINER" \
      python3 -c "$(auth_hash_program)" 2>/dev/null | tail -n 1)"; then
    AUTH_STATE="failed"; AUTH_DETAIL="could not compute the bcrypt hash in $AUTH_CONTAINER"
    fail_msg "auth: could not compute the hash in $AUTH_CONTAINER (is it running?)"
    return 1
  fi
  hash="${hash%$'\r'}"
  if [[ ! "$hash" =~ ^\$2[aby]\$([0-9]{2})\$[./A-Za-z0-9]{53}$ ]]; then
    AUTH_STATE="failed"; AUTH_DETAIL="the auth container returned a value that is not a bcrypt hash"
    fail_msg "auth: the auth container did not return a bcrypt hash"
    return 1
  fi
  cost="${BASH_REMATCH[1]}"
  if (( 10#$cost < BCRYPT_MIN_ROUNDS )); then
    AUTH_STATE="failed"; AUTH_DETAIL="the returned hash cost $cost is below $BCRYPT_MIN_ROUNDS"
    fail_msg "auth: refusing a hash with cost $cost (the minimum is $BCRYPT_MIN_ROUNDS)"
    return 1
  fi

  escaped="$(tls_compose_escape "$hash")"

  backup="${ENV_FILE}.bak.$(date -u +%Y%m%dT%H%M%SZ).$$"
  if ! install -m 0600 -- "$ENV_FILE" "$backup"; then
    AUTH_STATE="failed"; AUTH_DETAIL="could not write the timed backup beside the stack env file"
    fail_msg "auth: could not write the backup $backup"
    return 1
  fi

  tmp="${ENV_FILE}.tmp.$$"
  if ! _env_rewrite_key "$ENV_FILE" "$AUTH_HASH_KEY" "$escaped" "$tmp"; then
    rm -f -- "$tmp"
    AUTH_STATE="failed"; AUTH_DETAIL="could not rewrite $AUTH_HASH_KEY"
    fail_msg "auth: could not rewrite $AUTH_HASH_KEY"
    return 1
  fi
  if ! chmod 0600 -- "$tmp"; then
    rm -f -- "$tmp"
    AUTH_STATE="failed"; AUTH_DETAIL="could not set mode 0600 on the rewritten env file"
    fail_msg "auth: could not set mode 0600 on the rewritten env file"
    return 1
  fi
  if ! _preserve_owner_mode "$ENV_FILE" "$tmp"; then
    rm -f -- "$tmp"
    AUTH_STATE="failed"; AUTH_DETAIL="could not preserve the ownership/mode of the stack env file"
    fail_msg "auth: could not preserve the ownership/mode of $ENV_FILE"
    return 1
  fi
  if ! mv -f -- "$tmp" "$ENV_FILE"; then
    rm -f -- "$tmp"
    AUTH_STATE="failed"; AUTH_DETAIL="could not replace the stack env file with the rewritten copy"
    fail_msg "auth: could not replace $ENV_FILE"
    return 1
  fi

  note "auth: recreating only the auth service"
  if ! "${COMPOSE[@]}" up -d --no-deps --force-recreate auth >/dev/null; then
    AUTH_STATE="failed"; AUTH_DETAIL="the new hash is written but the auth service did not restart"
    fail_msg "auth: the hash is written, but recreating the auth service failed"
    return 1
  fi

  if ! length="$(docker exec "$AUTH_CONTAINER" python3 -c "$(auth_length_program)" 2>/dev/null | tr -d '[:space:]')"; then
    AUTH_STATE="failed"; AUTH_DETAIL="the hash is written but the container could not be queried"
    fail_msg "auth: could not read the hash length from $AUTH_CONTAINER"
    return 1
  fi
  if [[ "$length" != "$AUTH_HASH_BYTES" ]]; then
    AUTH_STATE="failed"
    AUTH_DETAIL="the container reports a ${length}-byte hash, expected ${AUTH_HASH_BYTES}"
    fail_msg "auth: the container reports a ${length}-byte hash, expected ${AUTH_HASH_BYTES}"
    return 1
  fi

  AUTH_STATE="applied"
  AUTH_DETAIL="bcrypt cost ${cost}; the gate reads a ${AUTH_HASH_BYTES}-byte hash in-container"
  ok "auth: gate password replaced; backup at $backup"
  return 0
}

# ---------------------------------------------------------------------------
# Leg 2 -- the Open WebUI admin account
# ---------------------------------------------------------------------------
leg_webui() {
  local raw="" rows="" id="" email="" selection="" index=""
  local -a ids=() emails=()
  local i=0

  rows="${WORK_DIR}/admins.tsv"
  note "webui: listing the admin accounts inside $WEBUI_CONTAINER"
  if ! raw="$(docker exec "$WEBUI_CONTAINER" python3 -c "$(webui_admin_list_program)" 2>/dev/null)"; then
    WEBUI_STATE="failed"; WEBUI_DETAIL="could not list the admin accounts in $WEBUI_CONTAINER"
    fail_msg "webui: could not list the admin accounts (is the container running?)"
    return 1
  fi
  if ! printf '%s\n' "$raw" | python3 -c '
import json
import sys

for row in json.load(sys.stdin):
    print("%s\t%s" % (row.get("id", ""), row.get("email", "")))
' > "$rows"; then
    WEBUI_STATE="failed"; WEBUI_DETAIL="the admin listing could not be parsed"
    fail_msg "webui: could not parse the admin listing"
    return 1
  fi
  while IFS=$'\t' read -r id email; do
    [[ -n "$id" ]] || continue
    ids+=("$id")
    emails+=("$email")
  done < "$rows"

  if (( ${#ids[@]} == 0 )); then
    WEBUI_STATE="failed"; WEBUI_DETAIL="no admin account exists; this script never creates one"
    fail_msg "webui: no admin account exists, and this script never creates users"
    return 1
  fi

  index=0
  if (( ${#ids[@]} > 1 )); then
    note "webui: more than one admin exists:"
    for i in "${!ids[@]}"; do
      printf '       %d) %s\n' "$(( i + 1 ))" "${emails[i]}" >&2
    done
    if [[ ! -t 0 ]]; then
      WEBUI_STATE="failed"
      WEBUI_DETAIL="several admins exist (${emails[*]}); nothing was changed"
      fail_msg "webui: refusing to choose between ${#ids[@]} admins without a terminal"
      return 1
    fi
    printf 'Choose the admin to reset [1-%d]: ' "${#ids[@]}" >&2
    IFS= read -r selection < /dev/tty || selection=""
    if [[ ! "$selection" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > ${#ids[@]} )); then
      WEBUI_STATE="failed"; WEBUI_DETAIL="the admin selection was not one of the listed numbers"
      fail_msg "webui: that was not one of the listed numbers"
      return 1
    fi
    index="$(( selection - 1 ))"
  fi

  note "webui: resetting the password of ${emails[index]}"
  if ! printf '%s' "$NEW_PASSWORD" | docker exec -i -e HYBRID_AI_WEBUI_TARGET_ID="${ids[index]}" \
      "$WEBUI_CONTAINER" python -c "$(webui_set_password_program)" >/dev/null 2>&1; then
    WEBUI_STATE="failed"; WEBUI_DETAIL="the in-container update failed for ${emails[index]}"
    fail_msg "webui: the in-container update failed for ${emails[index]}"
    return 1
  fi

  WEBUI_STATE="applied"
  WEBUI_DETAIL="admin ${emails[index]} updated through the app's own hash helper"
  ok "webui: password of ${emails[index]} replaced"
  return 0
}

# ---------------------------------------------------------------------------
# Leg 3 -- the Hermes WebUI dashboard
# ---------------------------------------------------------------------------
hermes_probe() {
  local cfg="$1" probe_out="" name="" value=""

  HERMES_PARSE_ERROR=0
  HERMES_AUTH_PRESENT=0
  HERMES_HAS_USERNAME=0
  HERMES_HAS_HASH=0
  HERMES_HAS_PLAIN=0

  if ! probe_out="$(docker exec -i "$HERMES_CONTAINER" python3 -c "$(hermes_probe_program)" < "$cfg" 2>/dev/null)"; then
    return 1
  fi
  while IFS='=' read -r name value; do
    case "$name" in
      parse_error)   HERMES_PARSE_ERROR="${value:-0}" ;;
      auth_present)  HERMES_AUTH_PRESENT="${value:-0}" ;;
      username)      HERMES_HAS_USERNAME="${value:-0}" ;;
      password_hash) HERMES_HAS_HASH="${value:-0}" ;;
      password)      HERMES_HAS_PLAIN="${value:-0}" ;;
    esac
  done <<< "$probe_out"
  return 0
}

hermes_apply_config() {
  local cfg="$1"
  local new_hash="" backup="" tmp="" candidate="" hash_file="" payload="" verify_out=""
  local used_fallback=0

  hash_file="${WORK_DIR}/hermes.hash"
  candidate="${WORK_DIR}/config.candidate.yaml"
  tmp="${cfg}.tmp.$$"

  if ! hermes_probe "$cfg"; then
    HERMES_STATE="failed"; HERMES_DETAIL="could not inspect config.yaml inside $HERMES_CONTAINER"
    fail_msg "hermes: could not inspect config.yaml inside $HERMES_CONTAINER"
    return 1
  fi
  if [[ "$HERMES_PARSE_ERROR" == "1" ]]; then
    HERMES_STATE="failed"; HERMES_DETAIL="config.yaml does not parse; refusing to edit it"
    fail_msg "hermes: config.yaml does not parse; refusing to edit it"
    return 1
  fi
  if [[ "$HERMES_AUTH_PRESENT" != "1" || "$HERMES_HAS_USERNAME" != "1" ]] \
     || { [[ "$HERMES_HAS_HASH" != "1" ]] && [[ "$HERMES_HAS_PLAIN" != "1" ]]; }; then
    HERMES_STATE="skipped"
    HERMES_DETAIL="$HERMES_SKIP_MESSAGE"
    ok "hermes: $HERMES_SKIP_MESSAGE"
    return 0
  fi

  note "hermes: hashing the password inside $HERMES_CONTAINER"
  if ! new_hash="$(printf '%s' "$NEW_PASSWORD" | docker exec -i "$HERMES_CONTAINER" \
      python3 -c "$(hermes_hash_program)" 2>/dev/null | tail -n 1)"; then
    HERMES_STATE="failed"; HERMES_DETAIL="could not compute the dashboard hash in $HERMES_CONTAINER"
    fail_msg "hermes: could not compute the dashboard hash in $HERMES_CONTAINER"
    return 1
  fi
  new_hash="${new_hash%$'\r'}"
  if [[ ! "$new_hash" =~ ^[^[:space:]]{16,}$ ]]; then
    HERMES_STATE="failed"; HERMES_DETAIL="the dashboard hash helper returned no usable hash"
    fail_msg "hermes: plugins.dashboard_auth.basic.hash_password returned no usable hash"
    return 1
  fi
  printf '%s\n' "$new_hash" > "$hash_file"
  chmod 0600 "$hash_file"

  backup="${cfg}.bak.$(date -u +%Y%m%dT%H%M%SZ).$$"
  if ! install -m 0600 -- "$cfg" "$backup"; then
    HERMES_STATE="failed"; HERMES_DETAIL="could not write the config backup"
    fail_msg "hermes: could not write the backup $backup"
    return 1
  fi

  if ! _hermes_textual_edit "$cfg" "$hash_file" "$candidate"; then
    used_fallback=1
    warn "hermes: the targeted edit found no dashboard.basic_auth block; using a YAML round-trip"
    if ! payload="$(python3 -c '
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    config = handle.read()
with open(sys.argv[2], "r", encoding="utf-8") as handle:
    password_hash = handle.read().strip()
print(json.dumps({"config": config, "password_hash": password_hash}))
' "$cfg" "$hash_file")"; then
      rm -f -- "$hash_file"
      HERMES_STATE="failed"; HERMES_DETAIL="could not build the YAML round-trip payload"
      fail_msg "hermes: could not build the YAML round-trip payload"
      return 1
    fi
    if ! payload="$(printf '%s' "$payload" | docker exec -i "$HERMES_CONTAINER" \
        python3 -c "$(hermes_roundtrip_program)" 2>/dev/null)"; then
      rm -f -- "$hash_file"
      HERMES_STATE="failed"; HERMES_DETAIL="the YAML round-trip fallback failed"
      fail_msg "hermes: the YAML round-trip fallback failed"
      return 1
    fi
    printf '%s\n' "$payload" > "$candidate"
  fi

  if (( used_fallback == 0 )) && ! _hermes_candidate_is_safe "$cfg" "$candidate"; then
    rm -f -- "$hash_file" "$candidate"
    HERMES_STATE="failed"
    HERMES_DETAIL="the candidate edit would change more than the dashboard password keys"
    fail_msg "hermes: refusing an edit that changes more than the dashboard password keys"
    return 1
  fi

  if cmp -s -- "$cfg" "$candidate"; then
    rm -f -- "$hash_file" "$candidate"
    HERMES_STATE="applied"
    HERMES_DETAIL="config.yaml already holds this password hash; nothing changed"
    ok "hermes: the dashboard hash already matches; nothing changed"
    return 0
  fi

  if ! payload="$(python3 -c '
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as before:
    old = before.read()
with open(sys.argv[2], "r", encoding="utf-8") as after:
    new = after.read()
print(json.dumps({"old": old, "new": new}))
' "$cfg" "$candidate")"; then
    rm -f -- "$hash_file" "$candidate"
    HERMES_STATE="failed"; HERMES_DETAIL="could not build the verification payload"
    fail_msg "hermes: could not build the verification payload"
    return 1
  fi

  if ! verify_out="$(printf '%s' "$payload" | docker exec -i "$HERMES_CONTAINER" \
      python3 -c "$(hermes_verify_program)" 2>/dev/null)"; then
    rm -f -- "$hash_file" "$candidate"
    HERMES_STATE="failed"; HERMES_DETAIL="the in-container verification rejected the edit"
    fail_msg "hermes: the in-container verification rejected the edit"
    return 1
  fi
  note "hermes: $(printf '%s' "$verify_out" | tr '\n' ' ')"

  if ! install -m 0600 -- "$candidate" "$tmp"; then
    rm -f -- "$tmp" "$candidate" "$hash_file"
    HERMES_STATE="failed"; HERMES_DETAIL="could not stage the rewritten config.yaml"
    fail_msg "hermes: could not stage the rewritten config.yaml"
    return 1
  fi
  if ! _preserve_owner_mode "$cfg" "$tmp"; then
    rm -f -- "$tmp" "$candidate" "$hash_file"
    HERMES_STATE="failed"; HERMES_DETAIL="could not preserve the ownership/mode of config.yaml"
    fail_msg "hermes: could not preserve the ownership/mode of $cfg"
    return 1
  fi
  if ! mv -f -- "$tmp" "$cfg"; then
    rm -f -- "$tmp" "$candidate" "$hash_file"
    HERMES_STATE="failed"; HERMES_DETAIL="could not replace config.yaml with the rewritten copy"
    fail_msg "hermes: could not replace $cfg"
    return 1
  fi
  rm -f -- "$candidate" "$hash_file"

  HERMES_STATE="applied"
  HERMES_DETAIL="password_hash replaced in config.yaml (backup $backup); it applies at the next WebUI start"
  ok "hermes: dashboard password replaced; backup at $backup"
  return 0
}

leg_hermes() {
  local overrides=""

  if ! overrides="$(docker exec "$HERMES_CONTAINER" sh -c \
      'env | sed -n "s/^\(HERMES_DASHBOARD_BASIC_AUTH_[A-Z_]*\)=.*/\1/p"' 2>/dev/null)"; then
    HERMES_STATE="failed"; HERMES_DETAIL="could not inspect the environment of $HERMES_CONTAINER"
    fail_msg "hermes: could not inspect the environment of $HERMES_CONTAINER (is it running?)"
    return 1
  fi
  if [[ -n "$overrides" ]]; then
    HERMES_STATE="failed"
    HERMES_DETAIL="$(printf '%s' "$overrides" | tr '\n' ' ')is set in the container environment, which overrides config.yaml; nothing was changed"
    fail_msg "hermes: $(printf '%s' "$overrides" | tr '\n' ' ')is set in $HERMES_CONTAINER; a config edit would be overridden, so nothing was changed"
    return 1
  fi

  if [[ ! -f "$HERMES_CONFIG" ]]; then
    HERMES_STATE="skipped"
    HERMES_DETAIL="$HERMES_SKIP_MESSAGE"
    ok "hermes: $HERMES_SKIP_MESSAGE"
    return 0
  fi

  hermes_apply_config "$HERMES_CONFIG"
}

hermes_restart() {
  local answer=""

  if (( RESTART_HERMES )); then
    note "hermes: restarting $HERMES_CONTAINER (--restart-hermes)"
    if ! docker restart "$HERMES_CONTAINER" >/dev/null 2>&1; then
      fail_msg "hermes: restarting $HERMES_CONTAINER failed"
      return 1
    fi
    HERMES_RESTARTED=1
    return 0
  fi

  say ""
  say "The new dashboard password takes effect at the next Hermes WebUI start."
  say "Restarting $HERMES_CONTAINER also restarts the gateway, which kills any"
  say "kanban worker that is running right now."
  say "To apply it later:  docker restart $HERMES_CONTAINER"

  if (( NO_RESTART )); then
    note "hermes: not restarting (--no-restart)"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    note "hermes: no terminal, so not restarting. Run the command above to apply it."
    return 0
  fi

  printf 'Restart %s now, killing running kanban workers? [y/N] ' "$HERMES_CONTAINER" >&2
  IFS= read -r answer < /dev/tty || answer=""
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    note "hermes: restarting $HERMES_CONTAINER"
    if ! docker restart "$HERMES_CONTAINER" >/dev/null 2>&1; then
      fail_msg "hermes: restarting $HERMES_CONTAINER failed"
      return 1
    fi
    HERMES_RESTARTED=1
    return 0
  fi
  note "hermes: not restarted. Run the command above to apply the new password."
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
summary_line() {
  printf '  %-22s %-8s %s\n' "$1" "$2" "$3"
}

main() {
  local failures=0

  while (( $# )); do
    case "$1" in
      --generate)       GENERATE=1 ;;
      --restart-hermes) RESTART_HERMES=1 ;;
      --no-restart)     NO_RESTART=1 ;;
      -h|--help)        usage; exit 0 ;;
      *)                fail_msg "unknown argument: $1"; usage >&2; exit 2 ;;
    esac
    shift
  done

  if (( RESTART_HERMES && NO_RESTART )); then
    fail_msg "--restart-hermes and --no-restart contradict each other"
    exit 2
  fi

  need docker "each leg runs a command inside a stack container"
  need python3 "the password generator and the JSON helpers use it"
  need install "the backups are written with an explicit 0600 mode"
  need truncate "the env rewrite keeps an absent trailing newline absent"

  if ! read_password; then
    exit 2
  fi

  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf -- "$WORK_DIR"' EXIT

  say ""
  note "one new password will be set on the auth gate, Open WebUI and the Hermes dashboard"

  leg_auth || true
  leg_webui || true
  leg_hermes || true

  if [[ "$HERMES_STATE" == "applied" ]]; then
    # A requested restart that fails must not leave the leg looking applied:
    # the config WAS written, so say so, but the leg failed and the exit is
    # non-zero. With no restart requested this is unchanged.
    if ! hermes_restart; then
      HERMES_STATE="failed"; HERMES_DETAIL="config written, restart failed"
    elif (( HERMES_RESTARTED )); then
      HERMES_DETAIL="${HERMES_DETAIL}; restarted"
    fi
  fi

  [[ "$AUTH_STATE" != "failed" ]] || failures=$(( failures + 1 ))
  [[ "$WEBUI_STATE" != "failed" ]] || failures=$(( failures + 1 ))
  [[ "$HERMES_STATE" != "failed" ]] || failures=$(( failures + 1 ))

  say ""
  say "== Summary =="
  summary_line "auth gate" "$AUTH_STATE" "$AUTH_DETAIL"
  summary_line "Open WebUI admin" "$WEBUI_STATE" "$WEBUI_DETAIL"
  summary_line "Hermes dashboard" "$HERMES_STATE" "$HERMES_DETAIL"

  if (( GENERATE )); then
    say ""
    say "Generated password, shown once. Copy it now:"
    say "  $NEW_PASSWORD"
  fi

  say ""
  if (( failures > 0 )); then
    fail_msg "$failures leg(s) failed; see the summary above"
    exit 1
  fi
  ok "every leg applied or was legitimately skipped"
  exit 0
}

main "$@"
