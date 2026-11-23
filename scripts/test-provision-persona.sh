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
