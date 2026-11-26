#!/usr/bin/env bash
# Offline selector tests, including refusals before any consumer side effects.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
unset HAVEN_REPOSITORY_SLUG
# shellcheck source=scripts/lib/repository-identity.sh
source "$SCRIPT_DIR/lib/repository-identity.sh"
[[ "$(haven_repository_slug)" == jimbobsyouruncle/haven ]]
[[ "$(HAVEN_REPOSITORY_SLUG=jimbobsyouruncle/haven haven_repository_slug)" == jimbobsyouruncle/haven ]]
[[ "$(HYBRID_AI_REPOSITORY_SLUG=jimbobsyouruncle/haven bash -c 'source "$1"; haven_repository_slug' _ "$SCRIPT_DIR/lib/repository-identity.sh")" == jimbobsyouruncle/haven ]]

# Keep the embedded compatibility blocks consistent.
python3 - "$SCRIPT_DIR" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
def block(path):
    text = path.read_text()
    return text.split('# BEGIN repository identity selector\n', 1)[1].split(
        '# END repository identity selector', 1)[0]
def aliases(path):
    return path.read_text().split('# BEGIN Haven environment compatibility\n', 1)[1].split(
        '# END Haven environment compatibility', 1)[0]
for relative in ('lib/repository-identity.sh', 'bootstrap.sh'):
    assert aliases(root / relative) == aliases(root / 'lib/haven-env.sh')
PY

mkdir "$WORK/bin"
for command in git curl id useradd systemctl install mkdir; do
  cat > "$WORK/bin/$command" <<'STUB'
#!/usr/bin/env bash
printf 'unexpected side effect\n' >> "${IDENTITY_CALLS:?}"
exit 99
STUB
  chmod +x "$WORK/bin/$command"
done
export IDENTITY_CALLS="$WORK/calls"
count=0
for invalid in '' jimbobsyouruncle/hybrid-ai someone/other jimbobsyouruncle/Haven \
  jimbobsyouruncle/haven.git https://github.com/jimbobsyouruncle/haven \
  jimbobsyouruncle/haven/ jimbobsyouruncle/haven.evil \
  'user:pass@github.com/jimbobsyouruncle/haven' \
  'jimbobsyouruncle/haven?query' 'jimbobsyouruncle/haven#fragment' \
  ' jimbobsyouruncle/haven' $'jimbobsyouruncle/haven\n' \
  $'$(touch SHOULD_NOT_EXIST)' $'`touch SHOULD_NOT_EXIST`'; do
  rc=0
  HAVEN_REPOSITORY_SLUG="$invalid" haven_repository_slug > "$WORK/out" 2> "$WORK/err" || rc=$?
  [[ "$rc" == 2 && ! -s "$WORK/out" ]]
  [[ "$(cat "$WORK/err")" == 'repository identity: HAVEN_REPOSITORY_SLUG must select an approved repository' ]]
  for script in bootstrap.sh; do
    : > "$IDENTITY_CALLS"
    rc=0
    env PATH="$WORK/bin:$PATH" HAVEN_REPOSITORY_SLUG="$invalid" \
      bash "$SCRIPT_DIR/$script" > "$WORK/out" 2> "$WORK/err" || rc=$?
    [[ "$rc" == 2 && ! -s "$WORK/out" && ! -s "$IDENTITY_CALLS" ]]
  done
  count=$((count + 1))
done
printf 'PASS: canonical default and identity, embedded consistency; %s invalid inputs rejected by all consumers before side effects\n' "$count"
