#!/usr/bin/env bash
# FILE: scripts/test-haven-launcher.sh
# Offline launcher mode and prompt smoke tests.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash -n "$ROOT/scripts/haven"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home/development/haven/hybrid-ai/.git" "$tmp/bin"
cat > "$tmp/bin/git" <<'GIT'
#!/usr/bin/env bash
case "$*" in
 "symbolic-ref --quiet --short HEAD"|"branch --show-current") echo feature/test ;;
 "status --porcelain") echo " M README.md" ;;
 "status -sb") echo "## feature/test" ;;
 *) echo "Unexpected git operation: $*" >&2; exit 10 ;;
esac
GIT
cat > "$tmp/bin/codex" <<'CODEX'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$CAPTURE"
CODEX
chmod +x "$tmp/bin/git" "$tmp/bin/codex"
export HOME="$tmp/home" PATH="$tmp/bin:$PATH" CAPTURE="$tmp/prompt"
"$ROOT/scripts/haven" help | grep -q new-epic
"$ROOT/scripts/haven" status | grep -q feature/test
"$ROOT/scripts/haven" next 146 >/dev/null
grep -q 'EPIC CLOSURE GATE' "$CAPTURE"
grep -q 'Awaiting approval to close epic #146' "$CAPTURE"
"$ROOT/scripts/haven" next 999 >/dev/null
grep -q 'epic #999' "$CAPTURE"
"$ROOT/scripts/haven" new-epic >/dev/null
grep -q 'PRIORITIZED shortlist' "$CAPTURE"
grep -q 'Awaiting approval to create proposed epic and issues' "$CAPTURE"
if "$ROOT/scripts/haven" next abc >/dev/null 2>&1; then exit 1; fi
if "$ROOT/scripts/haven" new-epic extra >/dev/null 2>&1; then exit 1; fi
echo "Haven launcher smoke tests passed."
