#!/usr/bin/env bash
set -Eeuo pipefail
# ---------------------------------------------------------------------------
# FILE: scripts/deploy-forced-command.sh
# PURPOSE (plain English):
#   The forced-command SSH entrypoint for the dedicated `haven-deploy`
#   account. The account's authorized_keys line pins this script as its
#   command, so the key can do exactly ONE thing and nothing else: ask the
#   SYSTEM systemd manager to start the instantiated unit
#   haven-deploy@<sha>.service, where <sha> is a full 40-character
#   lowercase hex commit.
#
#   It reads the command the client sent from SSH_ORIGINAL_COMMAND. It accepts
#   EXACTLY:
#
#       deploy <40-lowercase-hex>
#
#   Anything else -- extra arguments, another verb, shell metacharacters, an
#   empty command -- is refused (exit 2) and nothing is run.
#
#   The deployment itself is the unit's job. This script never runs git, never
#   touches the tree, and never calls a user manager. It only asks the system
#   manager to start one pre-existing, root-owned unit, then reads back that
#   unit's result and the run log the unit wrote.
#
#   WHY THE LOG IS READ FROM A FILE, NOT THE JOURNAL:
#     The deploy account is deliberately NOT in the systemd-journal group, so
#     it cannot read journald. The unit writes its output to
#     $HAVEN_LOG_DIR/deploy/<sha>.log with mode 0640 and group
#     haven-deploy (see scripts/deploy-instance.sh), so this account can
#     read the log without any journal access.
#
#   THIS IS THE LIVE CONTROL PLANE DEPLOY ENTRYPOINT:
#     The cutover has landed. .github/workflows/deploy.yml drives this forced
#     command, which is the live Control Plane deploy entrypoint; the host
#     pieces are installed by scripts/bootstrap.sh and one authorized_keys line.
#     It stays a single fixed entrypoint: exactly `deploy <40-lowercase-hex>`,
#     the system manager only, never a user manager.
#
#   LAYOUT-FILE-ONLY ENVIRONMENT:
#     This account is allowed to read ONLY the 0644 LAYOUT file, and it needs
#     only layout paths. HAVEN_STACK_ENV_FILE is pinned at the layout file
#     UNCONDITIONALLY, so an inherited value can never point it back at the
#     root-only 0600 secrets file. Below, export HAVEN_STACK_ENV_FILE is
#     given no :- fallback and never consults the incoming environment.
#
# USAGE:
#   Invoked by sshd as the forced command, with SSH_ORIGINAL_COMMAND set.
#
# EXIT CODES:
#   0  the unit started and finished successfully
#   2  the command was refused (not exactly `deploy <40-lowercase-hex>`)
#   3  the unit was started but did not finish successfully
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Resolve host paths the SAME way the unit does: point at the same system env
# file the unit names, unless the account's environment already sets one. This
# is what makes this script and the unit agree on $HAVEN_LOG_DIR (and so on
# the run-log path). The helper only ever PARSES the file, never sources it.
export HAVEN_ENV_FILE="${HAVEN_ENV_FILE:-/etc/haven/haven.env}"
# This account reads only the 0644 layout file. It needs only layout paths
# ($HAVEN_LOG_DIR), never a secret. Pin STACK_ENV_FILE at the layout file
# UNCONDITIONALLY (no :- fallback) so an inherited value cannot point it back
# at the root-only secrets file.
export HAVEN_STACK_ENV_FILE="$HAVEN_ENV_FILE"
# Reporting must follow canonical layout, never an inherited workspace log
# override. Missing layout/log configuration must not fall back to /opt/haven.
[[ -f "$HAVEN_ENV_FILE" && -r "$HAVEN_ENV_FILE" ]] || exit 2
unset HAVEN_LOG_DIR HYBRID_AI_LOG_DIR
# shellcheck source=scripts/lib/haven-env.sh
source "${SCRIPT_DIR}/lib/haven-env.sh"

layout_log="$(_haven_file_get "$HAVEN_ENV_FILE" HAVEN_LOG_DIR)"
[[ -n "$layout_log" ]] || { printf 'deploy-forced-command: layout log directory missing\n' >&2; exit 2; }
LOG_DIR="${HAVEN_LOG_DIR}/deploy"

# Refuse everything that is not the one accepted command. Nothing is run.
refuse() {
  printf 'deploy-forced-command: %s\n' "$*" >&2
  exit 2
}

COMMAND="${SSH_ORIGINAL_COMMAND:-}"

# Accept exactly one space between the verb and the sha, a 40-character
# lowercase hex sha, and nothing after it. The anchored pattern rejects extra
# arguments, another verb, shell metacharacters (they cannot be [0-9a-f], a
# space, or the literal 'deploy ') and an empty command.
if [[ ! "$COMMAND" =~ ^deploy\ ([0-9a-f]{40})$ ]]; then
  refuse "refused: only 'deploy <40-lowercase-hex-commit>' is accepted"
fi

SHA="${BASH_REMATCH[1]}"
UNIT="haven-deploy@${SHA}.service"

# Start the SYSTEM manager's unit. No --user flag: this unit is a system unit,
# and the polkit rule grants this account `start` of exactly this unit shape.
START_RC=0
systemctl start "$UNIT" || START_RC=$?

# Read back the unit's own result. `systemctl show -p Result` prints the last
# run outcome (`success`, `exit-code`, `signal`, `timeout`, ...).
RESULT="$(systemctl show -p Result --value "$UNIT" 2>/dev/null || true)"
printf 'unit: %s\n' "$UNIT"
printf 'result: %s\n' "${RESULT:-unknown}"

# Print the run log the unit wrote, when it exists and is readable.
LOG_FILE="${LOG_DIR}/${SHA}.log"
if [[ -r "$LOG_FILE" ]]; then
  printf -- '--- run log: %s ---\n' "$LOG_FILE"
  cat -- "$LOG_FILE"
  printf -- '--- end run log ---\n'
else
  printf 'run log unavailable: %s\n' "$LOG_FILE"
fi

if (( START_RC != 0 )) || [[ "$RESULT" != "success" ]]; then
  printf 'deploy-forced-command: unit %s did not finish successfully (start rc=%d, result=%s)\n' \
    "$UNIT" "$START_RC" "${RESULT:-unknown}" >&2
  exit 3
fi

exit 0
