# ADR-0006 — Transactional installation root migration

Supersession notice (2026-11-14): [ADR-0007](0007-complete-platform-identity.md)
reopens retained legacy identities and manual-only deployment as new owner scope.
The decision and evidence below remain the historical #187 contract; its
transaction, integrity, recovery and security controls remain required.

Status: accepted owner decision for implementation. Production deployment remains
an explicit owner action; source changes and CI do not establish runtime migration.

## Decision

Haven is a single-owner, self-hosted home installation. Use automated safety
checks and recoverable transactions rather than recurring operator paperwork.
Deploy the exact full commit SHA from controlled public Git provenance, only on
an explicit owner-initiated production dispatch. Merging does not deploy.

Fresh bootstrap uses `/opt/haven`; existing `/opt/hybrid-ai` installations migrate
through the normal deployment driver. Only the application root changes.
`/etc/hybrid-ai`, `/var/lib/hybrid-ai`, accounts, units, credentials, backups,
persistent data and the Compose project `hybrid-ai` retain their identities.
Never move/delete data or volumes as part of this migration. Refuse repository-local
durable storage, foreign projects, conflicting directories, symlinks, untrusted
ownership and ambiguous service overrides before activation.

Keep the exclusive deployment lock, independently staged exact-SHA checkout,
main-ancestry validation, protected fsynced transaction journal, previous checkout
and original control-file snapshots. Directory renames and individual control-file
replacements are atomic; the whole handoff is recoverable, not globally atomic.
Retain rendered configuration in the previous checkout. A legacy dispatcher that
already reset its checkout can supply only its available configuration and
ORIG_HEAD code, not an untouched pre-reset runtime snapshot.

## Automated proxy recovery preflight

Every transactional deployment verifies a locally available immutable recovery
image, exports it into a unique mode-0600 archive in the protected mode-0700
transaction directory, fsyncs it and records its SHA256 in the journal. This also
protects risky root migrations. Archives survive rollback and subsequent deploys;
cleanup is an explicit owner operation. A failed, empty or corrupt export refuses
activation. No automatic pull, load, build or mutable-tag resolution is allowed.

Default to the running proxy's immutable image reference. If it is unavailable,
the owner can select an existing compatible alternative once in the root-controlled
file `/etc/hybrid-ai/proxy-recovery-image`, containing only `sha256:<64 hex>`.
The selection is durable, not a deployment approval. Each deployment repeats the
automated content and compatibility checks against current inputs.

An index/manifest digest identifies a different object from an image configuration
digest. They need not be equal. Inspect the immutable selection, verify the exported
configuration digest against its archive member name, compare configuration and
ordered root-filesystem digests with local inspection, and hash every exported
filesystem layer against its configuration diff ID. Retain both selected and
configuration identities with the archive checksum. A digest mismatch within the
same object type remains corruption and must refuse deployment.

Preflight compares the recovery image's Linux architecture with the Docker host,
executes its Caddy binary in disposable isolated containers, compares the running
Caddy version, requires the Cloudflare and RFC2136 DNS modules, and validates the
installed Caddyfile using the running proxy's effective environment. These checks
publish no environment/configuration contents or subprocess output. Validation
containers have no network, published ports, persistent-data mounts or Docker
socket; the configuration and required DNS credential bind are read-only,
data/config are temporary, all capabilities except NET_BIND_SERVICE are dropped
and resource limits apply. The retained Caddy executable needs that capability
even for isolated validation; this does not change production security settings. This does not replace the running proxy.

Per-deployment approval/evidence JSON, 24-hour expiration, hashed manual receipts,
repeated recovery rehearsals and redundant host authorization checkpoints are
removed. The manual production dispatch still explicitly selects and authorizes
the exact main SHA. Existing SSH grammar, polkit restrictions, secrets handling
and project checks remain.

## Failure, verification and rollback

Restore saved control files/root after synchronous failure and retain the failed
checkout. Recover an interrupted activation on the next owner-initiated deploy.
An asynchronous verification that is missing or unsuccessful blocks subsequent
deployment. Acceptance requires matching requested/installed SHA, canonical wiring
and successful mandatory health gates from the root verifier. Scheduling a check
is not acceptance; WARN/SKIPPED is not PASS for a mandatory gate.

Explicit rollback under the same lock restores saved control files and the prior
checkout, reloads systemd and retains recovery artifacts. It neither restarts
containers nor restores databases. Refuse rollback over subsequently changed
control files, including rotated secrets. If services have been recreated,
runtime recovery requires an owner-selected bounded procedure with retained code,
configuration and checksum-verified immutable images. Never infer that restoring
code restored running services. See the [deployment procedure](../../../deploy/README.md).

## Rationale and accepted residual risks

Root already controls deployment code and Docker; extra root-written attestations
provide little additional protection for a single trusted owner. Automated
preflight gives repeatable evidence at the point of use while reducing stale
paperwork and operator mistakes. Existing successful recovery evidence can be
reused without another manual rehearsal when its contract is unchanged.

Archive integrity and Caddy validation establish content and bounded compatibility,
not a complete disaster-recovery rehearsal or future service health. Disk/host
failure can destroy local checkpoints; independent encrypted backups remain
necessary. Network-disabled validation can refuse configurations needing external
resources; investigate the specific refusal rather than bypass checks. Runtime
rollback may need operator intervention and service recreation. Retained archives
consume disk until owner cleanup. Version equality deliberately refuses untested
version substitutions. These limits are accepted; protecting persistent data,
credentials, the working proxy and recoverability remains mandatory.

Offline tests cover first migration, repeated canonical deployment, identity types,
archive corruption/export failure, compatibility refusals, interruption, control
rollback, secret/data preservation and mandatory verification. CI adds source,
security, Caddy and Compose checks. Worker contracts are unchanged; no fresh live
RunPod test is required. Production acceptance and issue closure require actual
sanitized runtime evidence and the owner's separate closure decision.
