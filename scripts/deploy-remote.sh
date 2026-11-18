#!/usr/bin/env bash
set -Eeuo pipefail

# Every host path comes from the ONE shared helper. With no settings, the
# resolved paths are exactly today's.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# An older parent transaction cannot honor the post-write recovery boundary.
# Refuse before install/identity mutation; its code-root rollback remains safe.
if [[ "$SCRIPT_DIR" == /opt/haven/scripts &&
      "${HAVEN_INSTALL_ROOT_HANDOFF:-}" == 1 && "${HAVEN_IDENTITY_DRIVER:-}" != 1 ]]; then
  echo '::error::reviewed identity-aware root driver required before installation'
  exit 6
fi
# Resolve before layout reads or host activity; the transient unit inherits
# the systemd manager's environment rather than this process's environment.
# shellcheck source=scripts/lib/repository-identity.sh
source "${SCRIPT_DIR}/lib/repository-identity.sh"
REPO_SLUG="$(haven_repository_slug)" || exit 2
# The previously installed dispatcher can enter this new script from the legacy
# root after its reset. Enter the same journaled handoff as newer dispatchers.
# Custom developer checkouts retain the existing offline/local behavior.
if [[ "${HAVEN_INSTALL_ROOT_HANDOFF:-}" != 1 &&
      ( "$SCRIPT_DIR" == /opt/hybrid-ai/scripts || "$SCRIPT_DIR" == /opt/haven/scripts ) ]]; then
  exec python3 "${SCRIPT_DIR}/install-root.py" deploy "${1:-}"
fi
# shellcheck source=scripts/lib/haven-env.sh
source "${SCRIPT_DIR}/lib/haven-env.sh"
APP_DIR="$HAVEN_APP_DIR"
ENV_FILE="$HAVEN_STACK_ENV_FILE"
COMPOSE=(docker compose -p haven --env-file "$ENV_FILE" --project-directory "$APP_DIR"
         -f "$APP_DIR/docker-compose.yml"
         -f "$APP_DIR/openhands/docker-compose.openhands.yml"
         -f "$APP_DIR/hermes/docker-compose.hermes.yml")

# ---------------------------------------------------------------------------
# FILE: scripts/deploy-remote.sh
# PURPOSE (plain English):
#   The remote half of the automated deploy. The GitHub workflow verifies and
#   resets the Pi to the commit CI validated, then runs this script with that
#   commit SHA as its single argument. The script re-asserts the revision as
#   its first action so the deployed tree can never drift from the validated
#   one, then reprovisions and gates on doctor.sh.
#
#   It is separated from the inline workflow script because the builder token
#   has no permission to edit .github/workflows/. The workflow only calls it.
#
# WHY THE REVISION ARGUMENT EXISTS:
#   CI validates one commit (github.sha). If the deploy reset to origin/main
#   instead, and main moved after validation, the Pi would run an unvalidated
#   revision. Resetting to the exact SHA and asserting HEAD re-closes that gap.
#
# WHY doctor.sh IS A GATE:
#   doctor.sh exits 0 healthy, 1 warnings only, 2 one or more failures. The old
#   inline script ran it with `|| true`, so a failing host still reported a
#   green deploy. Here, exit 2 (or any unexpected code) turns the deploy red.
#
# USAGE:
#   ./scripts/deploy-remote.sh <full-40-hex-commit-sha>
#
# EXIT CODES:
#   0  deploy healthy (doctor.sh reported OK, or warnings only)
#   non-zero  bad argument, revision mismatch, health failure, or doctor.sh
#             reported failures
# ---------------------------------------------------------------------------

if [[ $# -ne 1 ]]; then
  echo "::error::deploy-remote.sh requires exactly one argument: the expected full commit SHA (got $#)."
  exit 2
fi

EXPECTED_SHA="$1"
if [[ ! "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error::deploy-remote.sh: '$EXPECTED_SHA' is not a full 40-character lowercase hex commit SHA."
  exit 2
fi

# --- Revision assert: the first real action ---------------------------------
# Fail before anything mutates the host if the tree is not the validated one.
CURRENT_SHA="$(git rev-parse HEAD)"
if [[ "$CURRENT_SHA" != "$EXPECTED_SHA" ]]; then
  echo "::error::deploy-remote.sh: HEAD is $CURRENT_SHA but the validated revision is $EXPECTED_SHA. Refusing to deploy an unvalidated revision."
  exit 3
fi
# HEAD alone does not detect a stale, locally modified or redirected entrypoint.
for restore_source in backup/restore.sh scripts/lib/haven-env.sh; do
  if [[ ! -f "$restore_source" || -L "$restore_source" ]] ||
     [[ "$(git hash-object -- "$restore_source")" != "$(git rev-parse "${EXPECTED_SHA}:${restore_source}")" ]]; then
    echo "::error::restore entrypoint identity mismatch: $restore_source"
    exit 3
  fi
done
echo "==> Deploying validated revision $EXPECTED_SHA"

# --- Reprovision ------------------------------------------------------------
# install.sh chmods the rest itself, but it cannot run if it is not executable.
chmod +x install.sh

echo "==> Reprovisioning (non-interactive; existing .env preserved)"
./install.sh --non-interactive

# Give the containers a grace period to settle before the health poll starts.
sleep 20

echo "==> Post-deploy verification"
"${COMPOSE[@]}" ps

# --- Sandbox firewall --------------------------------------------------------
# Docker has created DOCKER-USER by now (the stack is up), so the sandbox drops
# can be re-applied. This deploy path runs as root, so the script is called
# directly; it needs no sudo. The script is idempotent, so a host that already
# carries the rules (the boot unit put them there) changes nothing.
echo "==> Applying sandbox firewall rules"
firewall_rc=0
if [[ -x "${APP_DIR}/scripts/sandbox-firewall.sh" ]]; then
  "${APP_DIR}/scripts/sandbox-firewall.sh" apply || firewall_rc=$?
else
  echo "::warning::scripts/sandbox-firewall.sh is missing or not executable; the sandbox drops were not applied."
  firewall_rc=127
fi
case "$firewall_rc" in
  0)
    ;;
  4)
    echo "::warning::DOCKER-USER does not exist yet; haven-firewall.service applies the sandbox drops at boot."
    ;;
  *)
    echo "::warning::sandbox-firewall.sh exited ${firewall_rc}; sandbox ports may still be reachable on the LAN."
    ;;
esac

# Poll the health endpoint for up to two minutes. If it never comes back, dump
# the last 50 log lines so the failure is diagnosable from the Actions output.
for i in $(seq 1 12); do
  if curl -fsS http://localhost:3000/health >/dev/null 2>&1; then
    echo "Open WebUI healthy."
    break
  fi
  echo "waiting for Open WebUI... ($i/12)"
  sleep 10
  if [ "$i" -eq 12 ]; then
    echo "::error::Open WebUI failed its health check."
    "${COMPOSE[@]}" logs --tail 50 open-webui
    exit 1
  fi
done

# --- Doctor gate ------------------------------------------------------------
# Run doctor.sh WITHOUT masking its exit code. `set +e` around the call keeps
# `set -e` from aborting before we have read the code.
echo "==> Health report"
doctor_rc=0
if [[ -x ./doctor.sh ]]; then
  set +e
  ./doctor.sh --no-cloud
  doctor_rc=$?
  set -e
else
  echo "::error::doctor.sh is missing or not executable; the post-deploy health gate cannot run."
  doctor_rc=2
fi

# --- Informational steps (always run, even when doctor.sh failed) -----------
echo "==> Persistent data intact:"
du -sh "$HAVEN_WEBUI_DATA_DIR" "$HAVEN_OLLAMA_DATA_DIR" 2>/dev/null || true

# Backups are a data-loss control; a deploy that silently disables them is
# worth flagging even though it is not a failure. The shared helper resolves
# which units and which systemctl scope apply for the configured mode.
BACKUP_TIMER_UNIT="$HAVEN_BACKUP_TIMER_UNIT"
BACKUP_SYSTEMCTL_SCOPE="$HAVEN_BACKUP_SYSTEMCTL_SCOPE"
if systemctl "$BACKUP_SYSTEMCTL_SCOPE" is-active "$BACKUP_TIMER_UNIT" >/dev/null 2>&1; then
  echo "Backup timer active. Next run:"
  systemctl "$BACKUP_SYSTEMCTL_SCOPE" list-timers "$BACKUP_TIMER_UNIT" --no-pager 2>/dev/null | head -3 || true
else
  echo "::warning::Backup timer is not active on this host."
fi

# --- Doctor verdict last, after the report and informational steps ----------
case "$doctor_rc" in
  0)
    echo "doctor.sh: healthy."
    ;;
  1)
    echo "::warning::doctor.sh reported warnings"
    ;;
  *)
    echo "::error::doctor.sh reported failures"
    exit 4
    ;;
esac

# Canonical transactions use the unit's ExecStartPost verifier, after this
# process releases the deployment locks. SSH waits for the whole unit result.
if [[ "${HAVEN_DEPLOY_SYNCHRONOUS_VERIFY:-0}" == 1 ]]; then
  echo 'Root verification is required by haven-deploy@.service ExecStartPost.'
  exit 0
fi

# POST-DEPLOY VERIFICATION, in its OWN transient unit.
# A waiter started as a child of this deploy would be killed when the deploy
# unit exits: deploy/haven-deploy@.service is Type=oneshot with the default
# KillMode=control-group, so systemd kills everything left in the unit's cgroup
# at exit -- setsid escapes the session, NOT the cgroup. That is exactly the
# defect the host showed as a 0-byte log whose mtime matched unit exit.
#
# So the verifier runs in a transient systemd-run unit named
#   haven-post-deploy-verify-<sha12>-<pid>
# which outlives this unit and appends to the resolved log. --service-type=exec
# is deliberate: it waits for exec() to succeed, so a launch failure is loud
# instead of silently lost (--no-block would suppress exactly that). --collect
# lets the finished unit be garbage-collected.
#
# Scheduling is mandatory. Final acceptance is asynchronous because the
# verifier waits for this deployment's workflow to finish; its root-owned
# transaction state blocks progression until all mandatory gates pass.
if [ -x "$HAVEN_POST_DEPLOY_VERIFY_CMD" ]; then
  # --setenv carries the resolved APP_DIR and repository into the transient
  # unit rather than relying on the manager's environment or verifier defaults.
  systemd-run --collect \
    --unit="haven-post-deploy-verify-${EXPECTED_SHA:0:12}-$$" \
    --service-type=exec \
    --setenv=HAVEN_APP_DIR="$APP_DIR" \
    --setenv=HAVEN_REPOSITORY_SLUG="$REPO_SLUG" \
    --setenv=HAVEN_VERIFY_INSTALL_ROOT="${HAVEN_VERIFY_INSTALL_ROOT:-0}" \
    --property="StandardOutput=append:${HAVEN_POST_DEPLOY_VERIFY_LOG}" \
    --property="StandardError=append:${HAVEN_POST_DEPLOY_VERIFY_LOG}" \
    "$HAVEN_POST_DEPLOY_VERIFY_CMD" --wait-for "$EXPECTED_SHA" \
    || { echo "::error::post-deploy verification could not be scheduled"; exit 5; }
else
  echo "::error::post-deploy verification script is absent: ${HAVEN_POST_DEPLOY_VERIFY_CMD}"
  exit 5
fi
