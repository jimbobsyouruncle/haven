#!/usr/bin/env bash
# Run as root in a disposable environment. Account mutations use only fixtures.
set -euo pipefail
umask 077

(( EUID == 0 )) || { echo 'This fixture needs root for directory ownership.' >&2; exit 1; }
scripts="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
scratch="$(mktemp -d /tmp/haven-provision-test.XXXXXXXX)"
trap 'rm -rf -- "$scratch"' EXIT
export FIXTURE="$scratch/nss"
export HAVEN_ENV_FILE="$scratch/layout.env"
data="$scratch/data"
mkdir "$FIXTURE" "$data" "$scratch/bin"
printf 'HAVEN_DATA_DIR=%s\n' "$data" > "$HAVEN_ENV_FILE"
: > "$FIXTURE/passwd"
: > "$FIXTURE/group"
: > "$FIXTURE/shadow"
printf 'occupied:x:999:998::/nonexistent:/usr/sbin/nologin\n' > "$FIXTURE/passwd"
printf 'occupied:x:998:\n' > "$FIXTURE/group"

cat > "$scratch/bin/getent" <<'STUB'
#!/usr/bin/env bash
set -eu
db="$1"
if (( $# == 1 )); then cat "$FIXTURE/$db"; exit; fi
awk -F: -v key="$2" -v db="$db" '
  $1 == key || (db != "shadow" && $3 == key) {print; found=1}
  END {if (!found) exit 2}
' "$FIXTURE/$db"
STUB

cat > "$scratch/bin/groupadd" <<'STUB'
#!/usr/bin/env bash
set -eu
[[ "$1 $2 $4" == '--system --gid --' ]]
printf '%s:x:%s:\n' "$5" "$3" >> "$FIXTURE/group"
STUB

cat > "$scratch/bin/useradd" <<'STUB'
#!/usr/bin/env bash
set -eu
[[ "$1 $2 $4 $6 $7 $8 $9 ${10} ${11} ${12}" == \
  '--system --uid --gid --no-user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin --' ]]
printf '%s:x:%s:%s::%s:%s\n' "${13}" "$3" "$5" "$9" "${11}" >> "$FIXTURE/passwd"
printf '%s:!:::::::\n' "${13}" >> "$FIXTURE/shadow"
STUB

cat > "$scratch/bin/id" <<'STUB'
#!/usr/bin/env bash
set -eu
case "$1" in
  -u) field=3 ;;
  -g|-G) field=4 ;;
  *) exit 2 ;;
esac
getent passwd "$2" | cut -d: -f"$field"
STUB

chmod +x "$scratch/bin/"*
export PATH="$scratch/bin:$PATH"
provision() { "$scripts/provision-persona.sh" "$@"; }
reject() {
  local expected="$1"
  shift
  if provision "$@" > "$scratch/error" 2>&1; then
    printf 'Unexpected success for %s\n' "$*" >&2
    exit 1
  fi
  grep -F -- "$expected" "$scratch/error" || { cat "$scratch/error" >&2; exit 1; }
}

reject 'no identity reservation' canvas --check
[[ ! -e "$data/.persona-identities" && ! -e "$data/canvas_data" ]]
expected="persona=canvas uid=997 gid=997 data_dir=$data"
result="$(provision canvas)"
[[ "$result" == "$expected" ]]
[[ "$(stat -c '%u:%g:%a' "$data/.persona-identities")" == 0:0:600 ]]
grep -qx 'canvas:997:997' "$data/.persona-identities"
# shellcheck source=scripts/lib/canvas.sh
source "$scripts/lib/canvas.sh"
canvas_check_identity "$data/canvas_data" 997 997
printf 'keep this\n' > "$data/canvas_data/projects/existing"
before="$(stat -c '%i:%z' "$data/.persona-identities" "$data/canvas_data/"{,persona,projects})"
[[ "$(provision canvas)" == "$expected" && "$(provision canvas --check)" == "$expected" ]]
[[ "$(stat -c '%i:%z' "$data/.persona-identities" "$data/canvas_data/"{,persona,projects})" == "$before" ]]
[[ "$(cat "$data/canvas_data/projects/existing")" == 'keep this' ]]
[[ "$(wc -l < "$FIXTURE/passwd")" == 2 && "$(wc -l < "$FIXTURE/group")" == 2 ]]

ln -s -- "$data" "$scratch/link"
HAVEN_DATA_DIR="$scratch/link" reject 'symlink' canvas --check
ln -s -- "$data/canvas_data" "$data/symlink_data"
reject 'has no reservation' symlink
mv -- "$data/canvas_data/persona" "$scratch/persona"
ln -s -- "$scratch/persona" "$data/canvas_data/persona"
reject 'Unsafe persona child directory' canvas --check
rm -- "$data/canvas_data/persona"
mv -- "$scratch/persona" "$data/canvas_data/persona"
chown 999:998 "$data/canvas_data/persona"
reject 'Unsafe persona child directory' canvas
[[ "$(stat -c '%u:%g' "$data/canvas_data/persona")" == 999:998 ]]
chown 997:997 "$data/canvas_data/persona"
touch "$data/canvas_data/.unexpected"
reject 'Unexpected entry' canvas --check
rm -- "$data/canvas_data/.unexpected"

printf 'conflict:999:996\n' >> "$data/.persona-identities"
reject 'UID/GID is occupied' conflict
printf 'other:996:998\n' >> "$data/.persona-identities"
reject 'UID/GID is occupied' other
printf 'retired:995:995\n' >> "$data/.persona-identities"
[[ "$(provision secondary)" == "persona=secondary uid=994 gid=994 data_dir=$data" ]]
[[ "$(provision retired)" == "persona=retired uid=995 gid=995 data_dir=$data" ]]
# Recreate an interrupted provisioning using the reserved identity and the
# remaining child directory.
rmdir "$data/retired_data/persona"
reject 'provisioning is incomplete' retired --check
provision retired
provision retired --check
provision first > "$scratch/first" &
first=$!
provision second > "$scratch/second" &
second=$!
wait "$first"
wait "$second"
[[ "$(cut -d' ' -f2 "$scratch/first")" != "$(cut -d' ' -f2 "$scratch/second")" ]]
printf 'Persona provisioning fixtures passed.\n'

# Exercise the wrapper against the same synthetic identity and an installed
# layout fixture. Use the real terminal interface and bcrypt utility.
export SETUP_APP="$scratch/app" SETUP_STACK="$scratch/stack.env" SETUP_LOCKS="$scratch/locks"
export SETUP_SCRIPT="$scripts/setup-persona.sh"
mkdir "$SETUP_APP" "$SETUP_LOCKS"
touch "$SETUP_LOCKS/"{hybrid-ai-deploy,haven-deploy}.lock
chmod 644 "$HAVEN_ENV_FILE"
printf 'HAVEN_APP_DIR=%s\nHAVEN_STACK_ENV_FILE=%s\n' "$SETUP_APP" "$SETUP_STACK" >> "$HAVEN_ENV_FILE"
cat > "$SETUP_STACK" <<'STACK'
TLS_ENABLED=yes
TLS_DOMAIN=example.org
TLS_VALIDATION=tlsalpn
ACME_EMAIL=operator@example.org
AUTH_ENABLED=on
HAVEN_AUTH_USER=operator
HAVEN_AUTH_HASH=$$2y$$12$$01234567890123456789012345678901234567890123456789012
HAVEN_AUTH_COOKIE_SECRET=0000000000000000000000000000000000000000000000000000000000000000
UNRELATED='preserve $ literally'
STACK

cat > "$scratch/run-setup" <<'RUN'
#!/usr/bin/env bash
# shellcheck disable=SC1090
source "$SETUP_SCRIPT"
setup_canvas "$SETUP_APP" "$HAVEN_ENV_FILE" "$SETUP_STACK" "${1:-}" "$SETUP_LOCKS"
RUN
chmod +x "$scratch/run-setup"

setup_reject() {
  local expected="$1"
  shift
  if "$scratch/run-setup" "$@" > "$scratch/error" 2>&1; then
    echo 'Unexpected Canvas setup success.' >&2
    exit 1
  fi
  grep -Fq -- "$expected" "$scratch/error"
}

setup_terminal() {
  python3 - "$scratch/run-setup" "$@" <<'PYTEST'
import os
import pty
import select
import sys
import termios
import time

password = b'synthetic fixture password!'
pid, terminal = pty.fork()
if pid == 0:
    os.execv(sys.argv[1], sys.argv[1:])
output = b''
for prompt in (b'New Canvas password:', b'Confirm Canvas password:'):
    while prompt not in output:
        assert select.select([terminal], [], [], 10)[0], 'password prompt timed out'
        output += os.read(terminal, 4096)
    deadline = time.monotonic() + 10
    while termios.tcgetattr(terminal)[3] & termios.ECHO:
        assert time.monotonic() < deadline, 'terminal echo was not disabled'
        time.sleep(0.01)
    os.write(terminal, password + b'\n')
while select.select([terminal], [], [], 10)[0]:
    try:
        output += os.read(terminal, 4096)
    except OSError:
        break
else:
    raise AssertionError('setup timed out')
_, status = os.waitpid(pid, 0)
assert password not in output, 'password exposed through terminal'
assert os.waitstatus_to_exitcode(status) == 0, output.decode()
PYTEST
}

cp "$SETUP_STACK" "$scratch/before-setup"
setup_reject 'Missing or invalid Canvas key' --check
cmp "$SETUP_STACK" "$scratch/before-setup"
setup_terminal
grep -Fxq "UNRELATED='preserve \$ literally'" "$SETUP_STACK"
[[ "$(stat -c '%u:%g:%a:%h' "$SETUP_STACK")" == 0:0:600:1 ]]
sed -n 's/^CANVAS_PASSWORD_HASH=/canvas:/p' "$SETUP_STACK" | sed 's/[$][$]/$/g' > "$scratch/htpasswd"
printf '%s\n' 'synthetic fixture password!' | htpasswd -vi "$scratch/htpasswd" canvas >/dev/null
cp "$SETUP_STACK" "$scratch/after-setup"
inode="$(stat -c %i "$SETUP_STACK")"
"$scratch/run-setup" --check
"$scratch/run-setup"
cmp "$SETUP_STACK" "$scratch/after-setup"
[[ "$(stat -c %i "$SETUP_STACK")" == "$inode" ]]
setup_terminal --rotate
for name in CANVAS_SESSION_KEY CANVAS_PASSWORD_HASH; do
  [[ "$(grep "^$name=" "$SETUP_STACK")" != "$(grep "^$name=" "$scratch/after-setup")" ]]
done
[[ "$(grep '^CANVAS_STATE_KEY=' "$SETUP_STACK")" == "$(grep '^CANVAS_STATE_KEY=' "$scratch/after-setup")" ]]

(
  flock -x 9
  setup_reject 'another setup is in progress'
) 9<"$SETUP_LOCKS/haven-deploy.lock"
printf '%s\n' 'mismatched fixture key' > "$data/canvas_data/settings-key.recovered"
setup_reject 'Reconcile the recovered Canvas settings key' --check
rm "$data/canvas_data/settings-key.recovered"

sed -i 's/^CANVAS_UID=.*/CANVAS_UID=980/' "$SETUP_STACK"
setup_reject 'conflicts with the verified persona identity' --check
cp "$scratch/after-setup" "$SETUP_STACK"
sed -i 's/^AUTH_ENABLED=.*/AUTH_ENABLED=off/' "$SETUP_STACK"
setup_reject 'requires TLS and Haven authentication' --check
cp "$scratch/after-setup" "$SETUP_STACK"
printf ' export CANVAS_ENABLED=off\n' >> "$SETUP_STACK"
setup_reject 'Duplicate or noncanonical Canvas setting' --check
mv "$SETUP_STACK" "$scratch/symlink-target"
ln -s "$scratch/symlink-target" "$SETUP_STACK"
setup_reject 'Unsafe configuration path' --check
printf 'Canvas setup fixtures passed.\n'
