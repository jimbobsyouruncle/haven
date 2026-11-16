#!/usr/bin/env bash
# Source-only repository identity selection. Process environment only: never
# read layout/secret files or infer identity from an untrusted remote.
# The verifier embeds the marked block because install.sh installs it alone.
# scripts/test-repository-identity.sh checks that both copies remain identical.

# BEGIN Haven environment compatibility
# Transitional process aliases for installed controls. Values are data; diagnostics
# name keys only. Keep this block identical in the standalone verifier.
for _haven_import_suffix in AGENT_CONTEXT_GENERATOR ALERT_WEBHOOK_URL APP_DIR AUTH_COOKIE_MAX_AGE AUTH_COOKIE_SECRET AUTH_HASH \
  AUTH_RATE_LIMIT AUTH_RATE_WINDOW AUTH_USER BACKUP_CHECK_TIMER_UNIT BACKUP_CRED_DIR BACKUP_JOURNAL_SCOPE \
  BACKUP_MODE BACKUP_SERVICE_UNIT BACKUP_STAGING_DIR BACKUP_SYSTEMCTL_SCOPE BACKUP_TIMER_UNIT BOOTSTRAP_ROOT \
  BUILD_CACHE_CAP CADDY_CERT_ROOT CADDY_DATA_DIR DATA_DIR DEFAULT_REPO_DIR DEPLOY_LOCK_FILE \
  DEPLOY_PUBLIC_REMOTE DEPLOY_VERDICT_DIR DRY_RUN ENV_FILE ENV_FILE_FALLBACK ENV_FILE_FALLBACK_DEFAULT \
  EXPLICIT_SETTINGS GID HERMES_DATA_DIR HERMES_HOME_DIR INSTALL_LOG INSTALL_ROOT_HANDOFF \
  LAYOUT_AGENT_REPOS_DIR LAYOUT_GID LAYOUT_OPENHANDS_STATE_DIR LAYOUT_OPENHANDS_WORKSPACE LAYOUT_UID LIB \
  LIB_DIR LOG_DIR OLLAMA_DATA_DIR POLKIT_RULES_DIR POST_DEPLOY_VERIFY_CMD POST_DEPLOY_VERIFY_LOG \
  PRUNE_AGE_SECONDS PRUNE_ALLOW_LEASE_LESS PRUNE_GRACE_SECONDS PRUNE_MAX_MOVES PRUNE_QUARANTINE_BASE PRUNE_QUARANTINE_RETENTION_DAYS \
  REPOSITORY_SLUG RESTORE_WORK_DIR SBIN_DIR STACK_ENV_FILE SYSTEMD_UNIT_DIR TLS_TOKEN_FILE \
  UID UNINSTALL_ROOT VERIFY_BACKUP_GATES VERIFY_INSTALL_ROOT WEBUI_DATA_DIR WEBUI_TARGET_ID \
  WORK_DIR; do
  _haven_import_canonical="HAVEN_${_haven_import_suffix}"
  _haven_import_legacy="HYBRID_AI_${_haven_import_suffix}"
  if [[ -v "$_haven_import_canonical" && -v "$_haven_import_legacy" && "${!_haven_import_canonical}" != "${!_haven_import_legacy}" ]]; then
    printf 'haven-env: conflicting aliases for %s; refusing configuration\n' "$_haven_import_canonical" >&2
    exit 2
  fi
  if [[ ! -v "$_haven_import_canonical" && -v "$_haven_import_legacy" ]]; then
    printf -v "$_haven_import_canonical" '%s' "${!_haven_import_legacy}"
    export "${_haven_import_canonical?}"
  fi
done
unset _haven_import_suffix _haven_import_canonical _haven_import_legacy
# END Haven environment compatibility

# BEGIN repository identity selector
haven_repository_slug() {
  case "${HAVEN_REPOSITORY_SLUG-jimbobsyouruncle/haven}" in
    jimbobsyouruncle/haven)
      printf '%s' "${HAVEN_REPOSITORY_SLUG-jimbobsyouruncle/haven}"
      ;;
    *)
      printf 'repository identity: HAVEN_REPOSITORY_SLUG must select an approved repository\n' >&2
      return 2
      ;;
  esac
}
# END repository identity selector
