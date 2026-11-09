# Haven platform migration and evidence gates

This document is a **proposed platform workstream plan**, not a declaration of implementation. The repository rename epic is a distinct operational migration.

## Existing approved rename sequence

[Epic #146](https://github.com/jimbobsyouruncle/hybrid-ai/issues/146): #147 public-source audit is accepted complete; #148 and #149 own compatibility and deployment preparation; #150 alone performs the separately owner-approved repository rename/cutover; #151 verifies post-cutover behavior. Preserve deferred external verification and accepted audit evidence. Do not infer production verification from source CI.

## Candidate platform epics (not yet created)

1. **Security isolation and inference hard gates:** task authorization, rootless workers, egress deny, RunPod-only all-model routing, cross-repo contract and negative tests.
2. **Identity and access:** invite-only OIDC, passkeys/TOTP, persona/project membership, private-admin boundary and revocation.
3. **CISO and credential migration:** existing digest continuity, credential inventory, broker, independent scopes, rotation and rollback.
4. **Agent orchestration and GitHub governance:** Hermes coordinator and proposed PM, Pi/Codex adapters, issue/PR approvals and evidence.
5. **Canonical conversations and memory:** authorized retrieval, key hierarchy, cryptographic erasure and backup restore tests.
6. **RunPod lifecycle and integration:** model API compatibility, budgets, pinned images, fail-closed handling and separate CI.
7. **UI, Matrix and resilience:** access controls, optional E2EE bridge, RPO/RTO and upgrade rollback.

These are planning candidates, not fixed priority commitments. `haven new-epic` must inspect current GitHub issues and PRs, deduplicate work and rank actual security prerequisites and dependencies.

## Epic closure policy

Enumerate **all** child issues, including transferred/deferred work. Verify accepted resolution, epic-wide acceptance criteria, dependencies, relevant merged PRs, final-head CI, and separately designated owner-only operations. Passing CI proves only what ran; skipped checks are not passes. Deferred requirements are nonblocking only when the owner explicitly accepts the deferral and they have a tracked issue, owner and milestone. Present a Closure Card with evidence and proposed GitHub updates; **never close an epic without separate explicit owner approval**. If not complete, select the next unblocked issue and present an Implementation Card.

See [decision register](DECISIONS.md) and [agent instructions](../../AGENTS.md).
