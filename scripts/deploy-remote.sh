#!/usr/bin/env bash
# Called by deploy-host.py while it holds the deployment locks.
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
if (( $# != 1 )) || [[ ! "$1" =~ ^[0-9a-f]{40}$ || "$(git rev-parse HEAD)" != "$1" ]]; then
  echo 'deploy-remote: checkout does not match the approved commit' >&2
  exit 1
fi

echo "==> Render and reconcile Haven at $1"
HAVEN_DESIRED_DEPLOY=1 bash ./install.sh --non-interactive

echo '==> Verify sandbox firewall policy'
bash ./scripts/sandbox-firewall.sh check

echo '==> Run Doctor'
doctor_rc=0
./doctor.sh --no-cloud || doctor_rc=$?
case "$doctor_rc" in
  0) ;;
  1) echo '::warning::Doctor reported warnings' ;;
  *) echo '::error::Doctor reported failures' >&2; exit "$doctor_rc" ;;
esac
