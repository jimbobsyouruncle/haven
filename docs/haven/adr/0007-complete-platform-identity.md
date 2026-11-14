# ADR-0007 — Complete Haven identity and continuous deployment

Status: owner-approved architectural direction (2026-11-14); detailed transaction
and security design proposed for review. Implementation, deployment authorization
and runtime acceptance remain distinct. This ADR does not activate production.

## Context and supersession

Haven is the canonical platform identity. ADR-0006 intentionally migrated only
the code root and retained legacy state, account, Docker and backup identities.
The owner now explicitly supersedes those retention provisions and its indefinite
manual-only deployment policy. Preserve ADR-0006's exact-SHA provenance,
transaction journal, integrity checks, immutable compatible proxy recovery,
restricted SSH/polkit, exclusive locking, independent backups and mandatory
verification. Keep its historical record and #187's accepted completion intact.

## Decision

Use `/opt/haven`, `/etc/haven/haven.env`, `/etc/haven/stack.env`,
`/var/lib/haven`, `/var/log/haven`, `HAVEN_*`, `haven-*` host units/accounts,
Compose project `haven` and platform-owned Haven container/network/image names.
Vendor/application names, IDs, API variables and application-relative data
directory formats remain their actual contracts. The dependency register defines
each mapping. Legacy names may appear only in historical evidence, immutable
external artifact addresses, bounded migration/recovery readers and tests proving
legacy input handling. No active legacy default or indefinite compatibility mode.

Preparation PRs are inert until the complete migration version is available.
One owner-authorized maintenance transaction activates all coupled identities;
ordinary installation must refuse an unprepared partial layout. It must not
silently create data directories or bootstrap a second stack.

### Transaction and storage

The protected versioned journal records source/target device and inode identities,
safe private integrity metadata, numeric owners/modes, original config hashes,
unit/account/enablement snapshots, Docker mount and image mappings, phase and
requested SHA. Write temporary files, fsync files, atomically rename and fsync
parent directories. Individual changes are atomic; whole-host activation is
recoverable, not globally atomic. Journal updates must support idempotent replay
even when interruption occurs between an operation and its phase update.

Phases: `prepared`, `fenced`, `quiesced`, `storage_staged`, `controls_staged`,
`activating`, `awaiting_verifier`, `accepted`, or `recovery_required`.
Before `activating`, failure restores old controls and re-enables only the old
stack after checking original resource mappings. After any new writer starts,
failure stops automation and requires bounded recovery using current data; never
restore a stale copied data tree. Persist which writers started, even after
partial recreation. Ambiguous journal/resource state refuses both deployment and
cleanup. The same lock protects deploy, accept, recover and retirement.

Quiesce all database, vector, upload, agent and ACME writers before moving binds.
Prefer same-filesystem directory rename preserving inode and numerical ownership.
For cross-filesystem layouts, use separately validated staged copy preserving
ACLs/xattrs/modes/hardlinks, adequate disk capacity, offline consistency and
private content verification. Keep source immutable until acceptance. Conflicting,
symlinked, foreign-owned or populated destinations refuse; never merge trees.
Application data is not renamed internally merely because its parent changes.
No volume deletion, pruning, database restoration or secret rotation as a naming
shortcut. Named volumes discovered at runtime need explicit mappings and verified
existing resources; unknown mounts block cutover.

### Docker and firewall

Recreate the owned stack under canonical Compose labels. `docker rename` cannot
change Compose project ownership. Capture immutable images, effective mount
mapping and recovery configuration privately, then stop old containers before
starting canonical ones. Disable automatic bind path creation on persistent
mounts. Validate expected source existence, resource identity and data before
`up`. Reconcile exactly seven primary services plus explicitly inventoried optional
sandboxes; never use a broad stop/remove selector.

Stage equivalent canonical network firewall drops before connecting new networks.
Keep protection effective through transition and rollback; preserve unrelated
DOCKER-USER rules and host policy. Update selectors, tags, reboot unit and doctor
together. Do not open ports, broaden egress or extend host Docker socket access.
The existing socket risk remains independent of identity consolidation.

### Accounts, configuration and entrypoints

Preserve numeric account/group IDs where possible; refuse name/ID collisions,
unsupported NSS and unknown service overrides. Migrate homes, credential sources,
supplementary groups and polkit with no privilege expansion. Canonical deploy
account accepts exactly `deploy <40-lowercase-hex>` through the forced command;
no forwarding, PTY, shell, journal membership or container-management group.

Fence old SSH and systemd entrypoints, drain existing operations, and acquire
old/new locks in fixed order before switching. Never rename/unlink a live lock
inode and assume exclusivity survived. After cutover old services/accounts cannot
start deployment or backups. A stale dispatcher must fail before mutation.
Migration rollback must keep both entrypoints fenced until one coherent identity
is verified and selected. Retired lock/journal identities are removed only after
the owner-approved recovery window; historical journals are not rewritten.

Translate known environment keys as literal data, preserving unrelated values,
comments as feasible, permissions and credential confidentiality. Reject unequal
old/new key collisions, ambiguous duplicate assignments, unsafe paths and unknown
overrides. Secrets never enter nonsecret layout, logs, PRs or public receipts.
Preserve signing secrets and password hashes; changing the auth cookie name
requires a deliberate re-login, not credential rotation. Restore permission and
credential changes only if hashes still match; never overwrite later rotation.

### Backups and external dependencies

New backups use Haven tags and canonical source paths. Keep old snapshots, tags,
keys and historical manifests intact. Restore/count/retention consumers understand
both eras and exact snapshot IDs; legacy manifests map into canonical staging
with traversal and config-import refusal. Validate old and new restores in
isolated scratch space. Historical environment and units are recovery material,
never directly activated. Keep independent encrypted backups and working access
to the original archive. A Haven-named remote repository/bucket requires a
separately authorized, verified copy; no inferred cloud resource provisioning.

Worker repository remains `runpod-hybrid-worker` until a separate owner decision.
The reviewed dependency plan may propose a Haven-named published artifact and
event-log default in a separate worker task/PR; no API, model, mesh, auth, watchdog
or streaming changes. Immutable existing image references remain historical
recovery inputs. Do not change a consumer until the canonical artifact is
available, reviewed and compatibility-tested. No inferred repository rename.

### Continuous deployment

The owner wants protected-main merges to deploy automatically after canonical
runtime acceptance. This direction is not activation authorization. Prepare a
reviewed inert candidate; retain the current manual path until a separately
authorized activation PR and production enablement. No magic repository variable,
secret or source default can activate the candidate during preparatory merges.

Use the exact validated protected-main commit from trusted workflow provenance,
not a PR/fork artifact or mutable branch checkout. Preserve CI/SAST and image
availability gates, SSH fingerprint pinning, exact host SHA/ancestry checks,
immutable recovery export, one lock, root verification and controlled recovery.
Successful workflow dispatch or unit completion alone cannot mean acceptance.
Do not weaken protected-main rules or require an administrative bypass.

See the [CD specification](../identity/CONTINUOUS-DEPLOYMENT.md) for coalescing,
cancellation, trusted checks and asynchronous acceptance. Missing/failed mandatory
evidence blocks further mutation; recovery remains an explicit owner operation.

## Acceptance, rollback and retirement

Offline tests must cover fresh/canonical/legacy/conflicting layouts, adversarial
paths, permissions and duplicate config, missing/foreign mounts, disk/copy errors,
account collisions, revoked/stale entrypoints, lock races and interruption at each
phase. Security review precedes runtime implementation. CI validates current-head
source, SAST, Compose/Caddy and affected ARM64 images; no skipped mandatory gate
counts as PASS. Changed live boundaries receive specific authorized runtime tests.

Jarvis acceptance requires actual existing data mounted under Haven identities,
application integrity, authentication, firewall, old/new restore, restart and
recovery evidence, canonical-only active wiring, then a protected-main automatic
deploy with matching accepted schema-v2 receipt. Source CI cannot establish this.
The [cutover runbook](../identity/CUTOVER.md) defines phase gates and recovery.
Only after acceptance and separate owner authorization may offline legacy roots,
units/accounts or caches be retired. Persistent data, independent backups and
required recovery information are never cleanup shortcuts.

## Consequences and limits

This requires a bounded service outage and more migration machinery than keeping
aliases indefinitely. Data preservation and recoverable failure take precedence
over cosmetic renaming speed. Historical evidence, actual worker repository URLs
and immutable archive identities remain visible without being active platform
identity. An unknown host layout is a concrete cutover blocker, not permission to
guess or to restart completed work. RPO/RTO and isolation claims remain limited to
their existing evidence; naming changes do not implement the wider Haven design.
