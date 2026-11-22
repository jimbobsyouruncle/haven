# ADR-0006 — Transactional installation root migration

Supersession notice (2026-11-14): [ADR-0007](0007-complete-platform-identity.md)
reopens retained legacy identities and manual-only deployment as new owner scope.
The decision and evidence below remain the historical #187 contract; its
transaction, integrity, recovery and security controls remain required.

Status: accepted. The [current decision below](#current-decision-2026-11-21)
replaces the historical production dispatch policy. The installation and recovery
controls remain in effect.

## Original installation-root decision

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

## Current decision (2026-11-21)

The owner's merge to protected main authorizes production deployment of Haven,
a personal, backed-up POC. This supersedes the historical dispatch-only and
protected-change approval policies above and in ADR-0007. Workflow, bootstrap,
configuration and pinned image changes use the same PR checks and merge path.
Project documentation and generated context maps do not redeploy the application.

The deployment workflow requires a merged PR, exact current main, a tree
matching the up-to-date PR head, and both required checks successful before
merge. The main ruleset requires an up-to-date PR and both checks with no
bypass. Required PR checks retain SAST, source and applicable ARM64 coverage.
The host verifies eligibility in the same active run and attempt, independently
checks main, stages the pinned checkout, and requires runtime health before
accepting. The eligibility job retains the installed bootstrap's expected
job name, so the normal deployment transaction installs the updated verifier. The restricted SSH
command and credentials, network and persona isolation, deployment locks,
transaction journals, previous checkout, recovery images and backups stay in
place. The local verdict supplies operational evidence. Cumulative authorization,
signed deployment receipts and cross-workflow validation are retired.

The owner accepts that a reviewed merge can change privileged deployment code
and that exact-main deployment can be superseded while waiting. Source CI and
local health checks cover different failure modes. Image and mount compatibility,
schema changes and data recovery still need review when applicable. The recovery
archive protects Caddy. Other service image IDs depend on local retention or a
retrievable immutable pin, and an image rollback cannot reverse a data migration.

One explicitly authorized bootstrap maintenance window bridges the old policy.
The [one-time transition](../../../deploy/README.md#one-time-policy-transition) was followed by the successful deployment of [PR #261](https://github.com/jimbobsyouruncle/haven/pull/261) in [run 44944993263](https://github.com/jimbobsyouruncle/haven/actions/runs/44944993263). Direct production operations, destructive data migrations and credential changes require separate owner approval.
