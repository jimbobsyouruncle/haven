# Haven platform migration and evidence gates

This document is a **proposed platform workstream plan**, not a declaration of implementation. The repository rename epic is a distinct operational migration.

## Deployment during modernization

Owner merge authorizes automatic deployment after scope-relevant CI and SAST under [ADR-0006](adr/0006-installation-root.md#current-decision-2026-11-21). Direct cutover, destructive data migration and credential operations require separate approval.

## Component migration checks

- Reuse the existing Caddy and Cloudflare DNS-01 certificate flow. Add routes in the source templates and test renewal instead of adding a second certificate manager.
- Preserve the RunPod wake, readiness and streaming contracts and Tailscale endpoint checks when adding deployment management or routing. Existing Compose includes Ollama; the Haven target uses cloud inference.
- Preserve Restic/R2 recovery. Independent destroyable project keys are a prerequisite to claiming cryptographic erasure of backed-up project data. The recovery targets are RPO up to four hours and RTO up to eight hours. Validate with an actual restore.
- Treat the current `auth/app.py` gate as single-user. The target is OIDC with passkeys and password plus TOTP fallback.
- For a rootless runtime migration, validate isolation, networking, Caddy reachability, volumes and recovery on ARM64 before replacing the existing runtime. Upgrade to compatible stable components after validation. Preserve the existing deployment until its replacement is verified.

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
