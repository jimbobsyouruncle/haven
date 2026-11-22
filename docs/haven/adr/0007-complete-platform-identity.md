# ADR-0007 — Complete Haven identity and restore automatic deployment

Status: approved simplified architecture, owner direction 2026-11-14.
Implementation details below are proposals; this documentation revision implements
no migration code and authorizes no production operations.

The [2026-11-21 decision in ADR-0006](0006-installation-root.md#current-decision-2026-11-21) governs current deployment authorization. The original identity decision and host-transition procedures below remain historical context.

## Context and decision

Haven is a personal, single-owner Raspberry Pi platform. Reuse ADR-0006's
implemented installation-root transaction, deployment locking, backup mechanisms
and recovery procedures. Extend those mechanisms only for the specific Haven
identity handoff. No generalized filesystem migration framework, new orchestration
service, elaborate transaction phase model or second comprehensive verifier.

This supersedes ADR-0006's indefinite retention of active legacy platform names
and manual-only deployment direction. It preserves its security, integrity,
immutable proxy recovery/export checks, interrupted recovery, credential isolation,
restricted SSH/polkit, exclusive locking and mandatory post-deployment verification.
Its historical record and accepted #187 completion remain intact.

## Identity and compatibility boundary

Canonicalize Haven-owned paths, environment/helper namespaces, accounts, units,
Compose project, platform resource identifiers and firewall selectors. Target
`/opt/haven`, `/etc/haven`, `/var/lib/haven`, `/var/log/haven`, `HAVEN_*` and
platform-owned `haven-*` resources. The dependency register specifies bounded
mappings; spelling alone never establishes ownership.

Keep Ollama, Open WebUI, Hermes, OpenHands and other third-party application names,
service/API contracts, vendor variables and application-relative data formats.
A platform Compose project can become `haven` while service keys and containers
named `ollama`, `open-webui` and `hermes-agent` retain application identities.
Preserve existing published third-party compatibility artifacts and digests.

`jimbobsyouruncle/runpod-hybrid-worker` is excluded from this initiative. Read-only
compatibility analysis is permitted. No worker source, repository, image, log,
configuration, API contract, deployment or infrastructure change is a dependency,
deliverable or acceptance criterion of #193 or #194–#200. Haven must use the worker
exactly as deployed. Any desired worker-side rename/change is an optional future
proposal requiring separate owner approval; it cannot block this initiative.

## Bounded migration proposal

Extend the existing transaction with only the explicit config/account/data/Docker
mapping and recovery information needed by the supported host layout. Retain its
protected journal, saved controls, fsync/integrity checks and immutable recovery
exports. Do not introduce a replacement transaction engine or speculative phases.
Prefer quiesced same-filesystem renames preserving numeric ownership and metadata.
An unsupported cross-filesystem layout stops preflight for a concrete reviewed
procedure; it does not justify a generalized copy engine now.

Fence and drain old deployment/backup entrypoints before handoff. Preserve mutual
exclusion while changing lock paths: hold old and new locks in fixed order until
old entrypoints are disabled, never rename a live lock inode as a locking strategy.
Reject conflicting paths/accounts, symlinks, unknown overrides and foreign stacks.
Translate only known platform config keys as literal data, refusing ambiguous
aliases while preserving secrets, unrelated keys and permissions.

Stop writers before moving persistent paths. Verify existing data mounts before
Compose recreation; refuse automatic empty bind creation and unknown volumes.
Recreate only owned resources to change Compose project labels. Preserve app data,
UID/GID ownership, credentials and effective firewall protection throughout.
Install equivalent canonical firewall selectors before attaching new networks;
never flush unrelated rules or broaden privileges. Keep independent backups and
historical restore access; do not rename/copy remote buckets or rewrite snapshots.

Before new writers start, recover original coherent controls and paths using the
existing recovery procedure. After new writes, retain current data and recover
compatible code/config/images; never overwrite it with a stale copy. A code-root
rollback does not itself restore running services. Ambiguous or failed acceptance
blocks further deployment until bounded recovery under the same lock.

## Deployment and acceptance

Restore automation in the existing GitHub Actions deployment workflow and host
mechanism. Require trusted main-branch validation, exact-SHA deployment, shared
serialized execution, host locking and successful existing root post-deployment
verification. Retain manual recovery. See the [CD plan](../identity/CONTINUOUS-DEPLOYMENT.md).
No reconciliation service, recurring manual approval stage or separate activation
PR is required. The current ADR-0006 decision makes owner merges the production
authorization after the one-time host transition.

Extend existing health/security/data/deployment checks only at changed boundaries.
Keep the root acceptance gates and operational verdict. Reuse accepted
evidence where its contract is unchanged; no fresh worker/GPU test solely for a
name change. See [cutover and cleanup](../identity/CUTOVER.md). Replace the proposed
retirement-manifest engine with an exact operator-reviewed checklist. Preserve
backups and recovery artifacts until successful cutover and cleanup authorization.

## Delivery, authorization and risks

Approximately three cohesive implementation PRs: canonical source/config (#194),
coordinated host/accounts/data/Docker and security (#195–#198, #200 acceptance),
then automatic deployment preparation/activation (#199, #200 deployment evidence).
Adjust boundaries only for safe atomic deployment or reviewability. Issues retain
traceability, not seven independent PR dependencies. Already authorized bounded
implementation PR preparation needs no repeated permission request.

Exact commands, supported host mappings and trigger wiring remain implementation
proposals requiring normal security review and current-head tests. Production
cutover, configuration changes, activation, cleanup, merge and issue closure remain
separate owner actions; none occurs in this revision. Principal risks are a bounded
outage, stale entrypoints, wrong mounts, interrupted handoff and asynchronous
verification. Existing safeguards plus targeted negative/interruption tests address
these; source CI cannot establish runtime acceptance or new isolation guarantees.
