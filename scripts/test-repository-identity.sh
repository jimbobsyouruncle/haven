#!/usr/bin/env bash
# Offline selector tests, including refusals before any consumer side effects.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
unset HYBRID_AI_REPOSITORY_SLUG
# shellcheck source=scripts/lib/repository-identity.sh
source "$SCRIPT_DIR/lib/repository-identity.sh"
[[ "$(hybrid_ai_repository_slug)" == jimbobsyouruncle/hybrid-ai ]]
for slug in jimbobsyouruncle/hybrid-ai jimbobsyouruncle/haven; do
  [[ "$(HYBRID_AI_REPOSITORY_SLUG="$slug" hybrid_ai_repository_slug)" == "$slug" ]]
done

# The installed verifier must run without a checkout/helper beside it.
python3 - "$SCRIPT_DIR" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
def block(path):
    text = path.read_text()
    return text.split('# BEGIN repository identity selector\n', 1)[1].split(
        '# END repository identity selector', 1)[0]
assert block(root / 'lib/repository-identity.sh') == block(root / 'run-post-deploy-verify.sh')
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
for invalid in '' someone/other jimbobsyouruncle/Haven \
  jimbobsyouruncle/haven.git https://github.com/jimbobsyouruncle/haven \
  jimbobsyouruncle/haven/ jimbobsyouruncle/haven.evil \
  'user:pass@github.com/jimbobsyouruncle/haven' \
  'jimbobsyouruncle/haven?query' 'jimbobsyouruncle/haven#fragment' \
  ' jimbobsyouruncle/haven' $'jimbobsyouruncle/haven\n' \
  $'$(touch SHOULD_NOT_EXIST)' $'`touch SHOULD_NOT_EXIST`'; do
  rc=0
  HYBRID_AI_REPOSITORY_SLUG="$invalid" hybrid_ai_repository_slug > "$WORK/out" 2> "$WORK/err" || rc=$?
  [[ "$rc" == 2 && ! -s "$WORK/out" ]]
  [[ "$(cat "$WORK/err")" == 'repository identity: HYBRID_AI_REPOSITORY_SLUG must select an approved repository' ]]
  for script in bootstrap.sh deploy-instance.sh run-post-deploy-verify.sh; do
    : > "$IDENTITY_CALLS"
    rc=0
    env PATH="$WORK/bin:$PATH" HYBRID_AI_REPOSITORY_SLUG="$invalid" \
      bash "$SCRIPT_DIR/$script" > "$WORK/out" 2> "$WORK/err" || rc=$?
    [[ "$rc" == 2 && ! -s "$WORK/out" && ! -s "$IDENTITY_CALLS" ]]
  done
  count=$((count + 1))
done
printf 'PASS: defaults, both identities, embedded consistency; %s invalid inputs rejected by all consumers before side effects\n' "$count"
