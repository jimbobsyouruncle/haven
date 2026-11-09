# ADR-0002 — Persona credentials and legacy migration

**Status:** Proposed implementation of recorded isolation requirement; no live credential operation approved.

## Context and proposed decision

Existing Hermes profiles may use profile-local environment credentials. Inventory only **names, scopes, consumers, owners, expiry and dependencies**, never values. Classify CISO, Coder, shared infrastructure and other. Preserve integrations while moving to independent, short-lived, broker-issued persona/task leases, revocation, rotation and recovery. Prefer repo-scoped GitHub App tokens. CISO email uses recipient allowlists; Coder has no CISO email rights. DNS, backup and host-admin keys stay infrastructure-owned.

## Alternatives and tradeoffs

Shared legacy tokens are simple but defeat independent revocation. Immediate rotation without a consumer inventory risks outages. A broker adds availability and recovery requirements.

## Acceptance

Verify actual host profile configuration without disclosing secrets, run negative cross-persona authorization tests, test rotation/rollback and get separate owner approval before any live credential migration.
