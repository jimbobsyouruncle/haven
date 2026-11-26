# ADR-0002 — Persona credentials and legacy migration

**Status:** Proposed implementation of recorded isolation requirement; no live credential operation approved.

## Context and proposed decision

Existing Hermes profiles may use profile-local environment credentials. Inventory only **names, scopes, consumers, owners, expiry and dependencies**, never values. Classify CISO, Coder, shared infrastructure and other. Preserve integrations while moving to independent, short-lived, broker-issued persona/task leases, revocation, rotation and recovery. Prefer repo-scoped GitHub App tokens. CISO email uses recipient allowlists; Coder has no CISO email rights. DNS, backup and host-admin keys stay infrastructure-owned.

## Alternatives and tradeoffs

Shared legacy tokens are simple but defeat independent revocation. Immediate rotation without a consumer inventory risks outages. A broker adds availability and recovery requirements.

## Acceptance

Verify actual host profile configuration without disclosing secrets, run negative cross-persona authorization tests, test rotation/rollback and get separate owner approval before any live credential migration.

## Incremental delivery clarification — 2026-11-26

The approved [single-owner persona MVP (#294)](https://github.com/jimbobsyouruncle/haven/issues/294) does **not** require implementing the proposed broker-issued leases or a new secrets system before personas are usable. Use Haven's existing protected configuration/credential delivery mechanisms with distinct persona-scoped credentials and least-privilege grants. The infrastructure's backup, DNS, deploy and host-admin credentials stay outside all agent-accessible persona mounts. Separate personas must never inherit each other's token files, environment or accessible credential paths. Preserve existing working credentials and data rather than rotate or migrate them speculatively; credential migrations/rotation remain separately authorized.

The broker in this ADR remains a **proposal**, not a deployed or prerequisite capability. Test one representative negative cross-persona credential-access case with synthetic secrets. Existing single-owner Haven authentication is allowed for this MVP; this does **not** provide per-human access separation or approve sharing credentials with future users. A later multi-login authorization design must address that independently.
