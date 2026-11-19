#!/usr/bin/env bash
# Render installer-owned settings to stdout. The installer owns the private
# temporary file, preserves unowned keys, and installs the result atomically.

installer_render_openhands_grace() {  # SECONDS
  printf 'OPENHANDS_STARTUP_GRACE_SECONDS=%s\n' "${1:-120}"
}

installer_render_prune_settings() {  # ALLOW_LEASE_LESS [RETENTION_DAYS]
  printf 'HAVEN_PRUNE_ALLOW_LEASE_LESS=%s\n' "$1"
  # Explicit empty retention disables deletion. Only an omitted value defaults.
  printf 'HAVEN_PRUNE_QUARANTINE_RETENTION_DAYS=%s\n' "${2-90}"
}
