#!/usr/bin/env bash
# Root ExecStartPost: resolve the existing log override and bound verification.
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/haven-env.sh
source "${SCRIPT_DIR}/lib/haven-env.sh"
exec >>"$HAVEN_POST_DEPLOY_VERIFY_LOG" 2>&1
exec /usr/bin/timeout --kill-after=30s 10m \
  "$SCRIPT_DIR/run-post-deploy-verify.sh" --wait-for "$1"
