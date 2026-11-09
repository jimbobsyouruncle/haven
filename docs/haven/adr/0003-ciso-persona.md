# ADR-0003 — Independent CISO persona

**Status:** Proposed implementation of recorded CISO continuity requirement; runtime profile unverified.

## Context and proposed decision

Migrate the existing Hermes CISO profile into a separate Haven persona while preserving its **daily security digest schedule, recipients, format and research sources**. Verify those settings on the actual host first. CISO gets scoped read-only security research and an email broker with a recipient allowlist, but no default GitHub write, merge or deploy. Coder does not inherit CISO mail permissions. Memory, credentials and inference policy remain scoped.

## Alternatives and consequences

Combining CISO and Coder reduces setup but violates least privilege; separate personas add scheduling and monitoring overhead.

## Acceptance

Confirm the baseline digest with the owner, test delivery using safe fixtures, negative privilege tests, schedule continuity and rollback. Email transport and scheduler implementation remain open.
