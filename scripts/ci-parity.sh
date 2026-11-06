#!/usr/bin/env bash
# Replay the repository-owned static gates from CI, locally, before you push.
#
# WHY THIS EXISTS
#   PR #139 reached an open pull request with a repo-gate finding. The builder
#   had run ShellCheck, Semgrep and `bash -n` by hand, which is a DIFFERENT set
#   of checks from the ones the repository owns. This runner exists so that
#   "what CI will say" is one command, resolved from the workflow files
#   themselves rather than from memory.
#
# WHAT IT RUNS (resolved by reading these files, never a hardcoded command list)
#   .github/workflows/validate.yml        the reusable PR/deploy validate job
#   .github/workflows/agent-context.yml   the PR agent-context map job
#
#   Default mode replays, in workflow order, executing each step's own `run:`
#   body verbatim (so a workflow edit cannot drift away from this runner):
#
#     validate.yml
#       :36-46   Shell syntax check            `git ls-files '*.sh'` + `bash -n`
#       :53-61   Python syntax check           `git ls-files '*.py'` + py_compile
#       :63-67   Generated pipe is in sync with its sources
#       :863-892 Assert proxy allowlist is intact
#       :894-988 Assert secure_headers coverage
#       :990-1003 Assert Hermes gateway autostart is pinned to the default profile
#       :1005-1029 Assert the WebUI is pinned to the /opt agent and fails closed
#       :1031-1048 Assert no secrets are tracked
#       :1050-1054 Assert no display-masked literals in code
#                 -> bash scripts/check-no-masked-literals.sh
#       :1056-1059 Report IP literals in code (warn only)
#                 -> bash scripts/check-no-ip-literals.sh
#     agent-context.yml
#       :28-29   Check the maps are fresh
#                 -> bash scripts/check-agent-context.sh <generated generator>
#
#   Any step in either workflow that invokes a tracked `scripts/*.sh` check is
#   picked up automatically, so a new repo check script becomes a local gate as
#   soon as validate.yml calls it.
#
# --full
#   Additionally runs every `scripts/test-*.sh` suite that validate.yml runs.
#   These are the 46 fixture suites; they are slow and are NOT part of the
#   default run.
#
# CI-OWNED GATES (cannot be evaluated without CI-only infrastructure)
#   Listed explicitly, announced loudly at run time, never skipped silently:
#     Install test dependency (httpx)          pip install from the network
#     Install auth test dependency (bcrypt)    pip install from the network
#     Pipe behavioural tests                   needs the httpx install above
#     Auth service tests                       needs the bcrypt install above
#     Status deploy-verification tile tests    python suite outside test-*.sh
#     GPU pod wake-readiness tile tests        python suite outside test-*.sh
#     Validate rendered Caddyfiles with real Caddy (TLS x auth matrix)
#                                              builds ./caddy and runs docker
#     Compose schema check                     requires `docker compose`
#     Validate status/Caddyfile parses         runs caddy:2.11-alpine in docker
#     Validate TLS-on render with real Caddy   docker build + real Caddy
#   CodeQL and ShellCheck/Semgrep live in sast-checks.yml, not here; they are
#   not repo gates and are not replayed by this runner.
#
# FAIL CLOSED
#   * A gate that exits non-zero fails the run (exit 1) and is named.
#   * A step this runner cannot classify is NOT skipped: it fails the run with
#     "UNCLASSIFIED GATE" until someone classifies it.
#   * There is no `|| true` path anywhere in this script.
#
# USAGE
#   bash scripts/ci-parity.sh [--root DIR] [--generator PATH] [--full]
#
#   --root DIR        run the gates against the git work tree at DIR
#                     (default: .). Used by scripts/test-ci-parity.sh to point
#                     at a throwaway fixture tree. It never relaxes a gate: the
#                     workflows and check scripts are read from DIR.
#   --generator PATH  the pinned agent-context generate.py. Resolution order:
#                     this flag, HYBRID_AI_AGENT_CONTEXT_GENERATOR, then
#                     <root>/.shared-actions/agent-context/generate.py (the
#                     checkout path agent-context.yml uses). The generator is
#                     NEVER fetched from the network.
#   --full            also run every scripts/test-*.sh suite validate.yml runs.
#
# PREREQUISITES: git, bash, python, python3 (validate.yml:59 uses `python -m
# py_compile`), and the pinned agent-context generator. Clone it outside the
# tree, at the ref agent-context.yml pins:
#   git clone https://github.com/jimbobsyouruncle/shared-actions /tmp/shared-actions
#   git -C /tmp/shared-actions checkout 3156ad16725e149a9baebeb71862a8d1d341418c
#   bash scripts/ci-parity.sh --generator /tmp/shared-actions/agent-context/generate.py
#
# EXIT CODES
#   0  every evaluated gate passed (CI-owned gates announced, not evaluated)
#   1  at least one gate failed, or a step could not be classified
#   2  usage error or a missing prerequisite (workflow file, generator, tool)
set -Eeuo pipefail

SHARED_CHECKOUT_REL=".shared-actions/agent-context/generate.py"

usage() {
  cat >&2 <<'EOF'
usage: bash scripts/ci-parity.sh [--root DIR] [--generator PATH] [--full]

  --root DIR        git work tree to check (default: .)
  --generator PATH  pinned agent-context generate.py
  --full            also run every scripts/test-*.sh suite validate.yml runs
EOF
}

ROOT="."
GENERATOR=""
FULL=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      if [ "$#" -lt 2 ]; then
        usage
        exit 2
      fi
      ROOT="$2"
      shift 2
      ;;
    --root=*)
      ROOT="${1#*=}"
      shift
      ;;
    --generator)
      if [ "$#" -lt 2 ]; then
        usage
        exit 2
      fi
      GENERATOR="$2"
      shift 2
      ;;
    --generator=*)
      GENERATOR="${1#*=}"
      shift
      ;;
    --full)
      FULL=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [ ! -d "$ROOT" ]; then
  echo "error: root directory not found: $ROOT" >&2
  exit 2
fi

ROOT_ABS="$(cd "$ROOT" && pwd)"

if ! git -C "$ROOT_ABS" rev-parse --git-dir >/dev/null 2>&1; then
  echo "error: not a git work tree: $ROOT_ABS" >&2
  echo "The repo gates read tracked files, so they need a real work tree." >&2
  exit 2
fi

for tool in git bash python python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: missing prerequisite: $tool is not on PATH" >&2
    exit 2
  fi
done

VALIDATE_WF="$ROOT_ABS/.github/workflows/validate.yml"
AGENT_WF="$ROOT_ABS/.github/workflows/agent-context.yml"
for wf in "$VALIDATE_WF" "$AGENT_WF"; do
  if [ ! -f "$wf" ]; then
    echo "error: missing prerequisite: workflow file not found: $wf" >&2
    exit 2
  fi
done

if [ -z "$GENERATOR" ] && [ -n "${HYBRID_AI_AGENT_CONTEXT_GENERATOR:-}" ]; then
  GENERATOR="$HYBRID_AI_AGENT_CONTEXT_GENERATOR"
fi
if [ -z "$GENERATOR" ] && [ -f "$ROOT_ABS/$SHARED_CHECKOUT_REL" ]; then
  GENERATOR="$ROOT_ABS/$SHARED_CHECKOUT_REL"
fi
if [ -z "$GENERATOR" ] || [ ! -f "$GENERATOR" ]; then
  echo "error: missing prerequisite: agent-context generator not found." >&2
  echo "Pass --generator PATH, set HYBRID_AI_AGENT_CONTEXT_GENERATOR, or check" >&2
  echo "the pinned generator out to $SHARED_CHECKOUT_REL inside the tree." >&2
  echo "Get it with:" >&2
  echo "  git clone https://github.com/jimbobsyouruncle/shared-actions /tmp/shared-actions" >&2
  echo "  git -C /tmp/shared-actions checkout 3156ad16725e149a9baebeb71862a8d1d341418c" >&2
  exit 2
fi
GENERATOR_ABS="$(cd "$(dirname "$GENERATOR")" && pwd)/$(basename "$GENERATOR")"

PYCACHE_DIR="$(mktemp -d)"
trap 'rm -rf "${PYCACHE_DIR:-}"' EXIT
export PYTHONPYCACHEPREFIX="$PYCACHE_DIR"

# Emit each step that carries a `run:` body as name<NUL>body<NUL>, in file order.
parse_steps() {
  python3 - "$1" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    lines = handle.read().splitlines()

steps = []
name = None
body = None
i = 0
while i < len(lines):
    line = lines[i]
    m = re.match(r"^\s*-\s+name:\s*(.*?)\s*$", line)
    if m:
        name = m.group(1).strip().strip('"').strip("'")
        body = None
        i += 1
        continue
    m = re.match(r"^(\s*)run:\s*(.*)$", line)
    if m and name is not None:
        key_indent = len(m.group(1))
        rest = m.group(2).strip()
        if rest in ("|", ">", "|-", ">-", "|+", ">+"):
            block = []
            j = i + 1
            while j < len(lines):
                raw = lines[j]
                if raw.strip() == "":
                    block.append("")
                    j += 1
                    continue
                if len(raw) - len(raw.lstrip()) <= key_indent:
                    break
                block.append(raw)
                j += 1
            indents = [len(b) - len(b.lstrip()) for b in block if b.strip()]
            cut = min(indents) if indents else 0
            body = "\n".join(b[cut:] if b.strip() else "" for b in block)
            i = j
        else:
            body = rest
            i += 1
        steps.append((name, body.rstrip("\n")))
        name = None
        continue
    i += 1

out = sys.stdout
for step_name, step_body in steps:
    out.write(step_name)
    out.write("\0")
    out.write(step_body)
    out.write("\0")
PY
}

# Echo, space separated, the tracked scripts a step body invokes.
invoked_scripts() {
  local body="$1"
  local found=""
  local script
  while IFS= read -r script; do
    case "$body" in
      *"$script"*) found="$found $script" ;;
    esac
  done < <(git -C "$ROOT_ABS" ls-files 'scripts/*.sh')
  printf '%s' "${found# }"
}

only_test_suites() {
  local list="$1" script
  [ -n "$list" ] || return 1
  for script in $list; do
    case "$script" in
      scripts/test-*.sh) : ;;
      *) return 1 ;;
    esac
  done
  return 0
}

has_non_test_script() {
  local list="$1" script
  for script in $list; do
    case "$script" in
      scripts/test-*.sh) : ;;
      *) return 0 ;;
    esac
  done
  return 1
}

ci_owned_reason() {
  case "$1" in
    "Install test dependency (httpx)")
      printf '%s' "pip install from the network"
      ;;
    "Install auth test dependency (bcrypt)")
      printf '%s' "pip install from the network"
      ;;
    "Pipe behavioural tests")
      printf '%s' "needs the httpx install above"
      ;;
    "Auth service tests")
      printf '%s' "needs the bcrypt install above"
      ;;
    "Status deploy-verification tile tests")
      printf '%s' "python suite outside scripts/test-*.sh, not in the --full set"
      ;;
    "GPU pod wake-readiness tile tests")
      printf '%s' "python suite outside scripts/test-*.sh, not in the --full set"
      ;;
    "Validate rendered Caddyfiles with real Caddy (TLS x auth matrix)")
      printf '%s' "builds ./caddy and needs the docker engine"
      ;;
    "Compose schema check")
      printf '%s' "requires docker compose"
      ;;
    "Validate status/Caddyfile parses")
      printf '%s' "runs caddy:2.11-alpine in docker"
      ;;
    "Validate TLS-on render with real Caddy")
      printf '%s' "docker build plus a real Caddy container"
      ;;
    *)
      return 1
      ;;
  esac
}

# Steps with no repo script and no "Assert" name that are still static and
# offline. Line numbers are quoted in the header above.
default_extra_reason() {
  case "$1" in
    "Shell syntax check")
      printf '%s' "git ls-files '*.sh' + bash -n (validate.yml:36-46)"
      ;;
    "Python syntax check")
      printf '%s' "git ls-files '*.py' + py_compile (validate.yml:53-61)"
      ;;
    "Generated pipe is in sync with its sources")
      printf '%s' "python3 openwebui/build_pipe.py --check (validate.yml:63-67)"
      ;;
    *)
      return 1
      ;;
  esac
}

GATE_FAILURES=0
GATE_COUNT=0

run_gate() {
  local label="$1" body="$2"
  local rc=0
  echo "==> GATE: $label"
  ( cd "$ROOT_ABS" && bash -Eeuo pipefail -c "$body" ) || rc=$?
  GATE_COUNT=$((GATE_COUNT + 1))
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: gate '$label' exited $rc" >&2
    GATE_FAILURES=$((GATE_FAILURES + 1))
    return 1
  fi
  echo "PASS: gate '$label'"
  return 0
}

handle_steps() {
  local wf="$1"
  local gate_name="" gate_body=""

  while IFS= read -r -d '' gate_name && IFS= read -r -d '' gate_body; do
    local scripts="" reason="" label=""

    # agent-context.yml checks out the generator into the tree; point the gate
    # at wherever this run actually resolved it.
    gate_body="${gate_body//$SHARED_CHECKOUT_REL/$GENERATOR_ABS}"

    scripts="$(invoked_scripts "$gate_body")"

    if reason="$(ci_owned_reason "$gate_name")"; then
      echo "CI-OWNED: $gate_name -- $reason"
      continue
    fi

    if only_test_suites "$scripts"; then
      if [ "$FULL" -eq 1 ]; then
        label="step '$gate_name' -> $scripts"
      else
        echo "DEFERRED (--full): $gate_name -> $scripts"
        continue
      fi
    elif reason="$(default_extra_reason "$gate_name")"; then
      label="step '$gate_name' -- $reason"
    elif [ -n "$scripts" ] && has_non_test_script "$scripts"; then
      label="step '$gate_name' -> $scripts"
    elif [ "${gate_name#Assert }" != "$gate_name" ]; then
      label="step '$gate_name'"
    else
      echo "UNCLASSIFIED GATE: $gate_name ($wf)" >&2
      echo "This runner refuses to skip a gate it cannot place. Either it is" >&2
      echo "CI-only (add it to the CI-OWNED table in this script with a reason)" >&2
      echo "or it is static (add it to the default set in this script)." >&2
      GATE_FAILURES=$((GATE_FAILURES + 1))
      continue
    fi

    run_gate "$label" "$gate_body" || true
  done < <(parse_steps "$wf")
}

echo "ci-parity: root=$ROOT_ABS"
echo "ci-parity: validate workflow=$VALIDATE_WF"
echo "ci-parity: agent-context workflow=$AGENT_WF"
echo "ci-parity: generator=$GENERATOR_ABS"

handle_steps "$VALIDATE_WF"
handle_steps "$AGENT_WF"

echo "ci-parity: evaluated $GATE_COUNT gate(s), $GATE_FAILURES failure(s)"

if [ "$GATE_FAILURES" -ne 0 ]; then
  echo "FAIL: $GATE_FAILURES gate(s) failed or were unclassified; CI would reject this tree." >&2
  exit 1
fi

echo "OK: every evaluated repo gate passed. CI-owned gates were announced above."
exit 0
