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

## Approved amendment for #249

For canonical upgrades, checkpoint the running proxy's immutable image and
retain its rendered configuration in the previous checkout. Keep the verified
archive through activation, acceptance and any rollback window. Preserve the
optional local selection for explicit root or identity migrations and leave
existing selections and archives in place. A missing running image blocks a
routine upgrade until the owner restores and verifies the exact image.

The owner approved bounded automatic proxy recovery for #249. Before replacing
the proxy, validate the exact locally resolved candidate and rendered
configuration with read-only inputs, restricted capabilities and no network
or persistent-data mounts. A separate isolated HTTP startup probe uses
synthetic configuration without credential mounts. Require the deployed proxy
to answer a local status request before transaction acceptance.

The canonical verifier may recreate only the proxy after it confirms a
nonzero process exit in the candidate it identifies by transaction label,
container ID, image ID and Compose identity. It holds the deployment locks
and journals recovery intent before acting. Route failures in a running
proxy can originate in DNS, certificates or a backend, so those failures,
restart races, missing evidence and changes to recovery inputs require
operator diagnosis. A previously healthy proxy with unchanged inputs is
retained. If the candidate has already recovered or identification changes,
leave it in place.
Remove an exited candidate by its exact container ID without force. If it
has restarted, Docker refuses removal. Compose is instructed to leave any
concurrent replacement alone.

Recovery uses the checked archive configuration ID and retained rendered
Compose/Caddy configuration. It reattaches the existing Docker-managed
`/config` volume when present, and preserves the persistent `/data` bind.
It performs no pulls, builds, dependent service starts or changes to live
secrets. A missing local image may
be reloaded from the checked archive. A dead candidate can remain unavailable
if archive load, recreation or health verification fails. Even verified
recovery leaves the deployment failed and fenced for owner reconciliation
because other services and the installed code may still be at the candidate
revision. Interrupted recovery is never retried automatically. The explicit
control rollback and disaster recovery procedures above still apply.

## Approved amendment for #252

The installed, root-owned canonical bootstrap holds both deployment locks and
authorizes the requested SHA before staging or running candidate code. It uses
the installed copy of the same provenance policy used by the post-deploy
verifier. The policy requires one qualifying active GitHub deployment run and
successful validation for its exact SHA and applicable attempt. The requested
SHA must match current main in the GitHub API and in the subsequent Git fetch.
An absent or inconsistent response fails closed. The runner's event and
production gates, SSH command grammar, systemd boundary and final verifier
remain in place. The bootstrap uses anonymous reads of the existing public
repository API.

After checking ancestry, detached HEAD and ownership of the staged tree, the
bootstrap invokes that tree's fixed checkpoint preflight with the inherited
locks. The preflight validates and exports the exact running proxy image. The
installed bootstrap checks the returned archive and retains responsibility for
the protected journal, prior executable and control snapshots, code switch and
rollback. A failed handoff leaves the previous checkout and accepted checkpoint
in place. The earlier installer continues to handle explicit root and identity
migrations. Routine upgrades still require separate operator authorization to
load a missing image from an archive.

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

## Owner-approved direction (2026-11-21): simplify deployment policy

Status: **approved architectural direction; implementation not yet verified or deployed**.
This section supersedes the historical manual-only deployment policy in this
ADR for routine merges. It does not waive existing production safeguards or
constitute authorization to deploy a particular revision. The detailed
implementation and removal of legacy paths require a reviewed change.

Haven uses **automatic deployment by default** for owner-authorized merges to
protected main that affect applications, container image pins, or ordinary
runtime configuration. Documentation-only changes that do not alter deployable
artifacts or operational configuration do not need a production deployment.
Changes to deployment authorization, security policy, privileged execution,
trusted bootstrap, or deployment infrastructure require **separate explicit
owner authorization** before production activation. Classify protected changes
using a small, auditable, fail-closed set of paths and semantic exceptions;
ambiguous classifications must be reviewed, not silently treated as routine.
A protected change may merge after required PR checks but must not auto-deploy.

Both automatic and explicitly authorized deployments must converge on the
**same canonical deployment transaction**. Preserve the exact validated commit,
trusted main provenance, SSH forced-command and systemd restrictions, Tailscale
transport, least privilege, secrets boundaries, deployment locks, durable
journal, previous known-good checkout and proxy recovery artifacts, mandatory
health verification, and safe rollback/fail-closed behavior. Manual authorization
is an additional gate, not a second installer or alternate recovery path.
Do not interpret a successful merge or scheduled verification as production
acceptance. The recorded deployed SHA and runtime checks determine acceptance.

Reduce redundant evidence queries, duplicate SHA assertions, transitional
bootstrap handoffs and operator preparation steps **only where equivalence of
security and recovery behavior is demonstrated by tests**. The installed Jarvis
bootstrap remains authoritative during transition; do not replace it or remove
legacy compatibility paths before a reversible cutover is qualified. Preserve
the approved #249 proxy recovery and #252 trusted handoff boundaries until a
reviewed implementation provides equivalent guarantees.

### Cumulative classification

The installed classifier starts from the private accepted journal's SHA,
which must match the active checkout and appear on the target's first-parent
main history. It examines every intervening commit and merge transition, so
subsequent documentation or routine commits cannot clear a protected change.
Markdown additions and edits in recognized documentation paths are docs-only.
Version changes to recognized application images are routine when all other
configuration bytes match. Unknown changes, deletions, mode changes and
changes to the classifier itself are protected.

The trusted bootstrap uses the installed classifier before checking out
candidate files or running candidate preflight. A protected deployment
requires a manual deployment run and owner approval for the exact accepted
baseline and target SHA. Existing exact-main, validation, transaction and
acceptance checks still apply.

Deployment outcomes must distinguish protected-policy refusal, provenance or
preparation failure, activation failure, health verification failure, and
recovery failure. Intentional policy refusals should be clearly labeled as
requiring authorization rather than presented as unexplained runtime crashes.
Keep `doctor.sh` focused on operational health; it is not a security gate.
Reuse commit-specific PR validation where trustworthy, while independently
checking deployment-time conditions that PR CI cannot establish.

For #257, an authorized deployment with a reuse miss requests fresh exact-SHA
validation in the existing Security & SAST workflow, outside the production
environment. The workflow gates its scans on the requesting deployment run and
attempt and on exact main. It uses no production credentials or tailnet access.
Only the dedicated CodeQL job can write security events. Deployment reads the
completed validation attempt and its required jobs and rechecks that evidence
after the image wait. Invalid, failed or ambiguous evidence blocks deployment.
The installed bootstrap remains the authority for cumulative protected changes
and their exact baseline and target approval.

Implementation should be incremental and independently testable, with an
explicit cutover and rollback plan. No new orchestrator or persistent control
plane is justified solely by this simplification. The RunPod worker interface
is unchanged unless a concrete compatibility dependency is found. Production
acceptance requires evidence for routine auto-deploy, protected manual-deploy,
documentation-only no-op, failed candidate containment/recovery, and clear
operator diagnostics.
