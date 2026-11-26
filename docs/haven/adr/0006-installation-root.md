# ADR-0006 — Canonical installation and desired-state deployment

**Status** — Accepted. Supersedes the transactional deployment portions of ADR-0006 and related historical guidance.

## Current decision (2026-11-21)

The owner's merge to protected main authorizes normal deployment. The eligible commit must match the reviewed PR tree, with the required checks passing before merge. The host independently checks the exact main commit and active deployment attempt. The workflow preserves pinned images, Tailscale, host-key verification and the restricted SSH and systemd entry point. Documentation-only merges skip deployment.

## Desired-state deployment (2026-11-26)

Jarvis is a single host with encrypted backups. Install the approved application checkout at `/opt/haven`, validate generated configuration, reconcile the existing Compose project, and check service health, TLS/authentication and sandbox firewall policy. The deployment locks cover this entire operation. Normal reconciliation allows Compose to keep unchanged services running.

Persona directories and UID/GID, application volumes, databases, service credentials, project worktrees and encrypted backups are persistent. Their paths remain separate from the application checkout. The existing installer, firewall and persona isolation controls remain in force.

The transaction journal, acceptance receipts, retained code checkpoints and proxy archives made later deployments depend on historical state. The new path fails the current attempt on a required error and allows the next authorized attempt to reconcile. The host may be partially updated until repaired. There is no automatic application rollback or database restore. Restore compatible data from encrypted backups when needed, following the [deployment and recovery runbook](../../../deploy/README.md). An incompatible storage or schema change requires its own backup and restore decision.

The runbook documents an owner-run bootstrap from the approved checkout for the currently blocked installation. It does not read or amend the old journal. Direct production operations, destructive migrations and credential changes still require separate owner approval.
