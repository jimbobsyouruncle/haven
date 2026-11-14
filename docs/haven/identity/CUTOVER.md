# Production cutover, acceptance and retirement

**Planning runbook — not executable cutover authorization.** Runtime migration
code and the final sanitized Jarvis verification script must be implemented and
reviewed under the dependent issues before this runbook can become executable.
Do not substitute manual search/replace, directory moves, `docker compose up` or
account commands for the reviewed transaction. No production access occurs in
the discovery PR. Any private host evidence stays on its approved private route.

## Readiness gates

| Stage | Gate | Current disposition | Clearing evidence |
| --- | --- | --- | --- |
| Baseline | #187 completion and original eight mandatory gates | VERIFIED by accepted owner report and closed #187; retained | Existing issue evidence; do not repeat solely for a new review |
| Runtime implementation | Architecture/security review of ADR-0007 and exact migration threat model | REQUIRED NOW before changing runtime controls | Independent review disposition attached to architecture PR |
| Cutover | All dependent implementation PRs reviewed/merged and current revision validated | REQUIRED LATER | Source/CI evidence with full SHAs and applicable ARM64 images |
| Cutover | Explicit bounded production authorization | REQUIRED LATER | Owner authorization of revision, maintenance window and recovery procedure |
| Cutover | Private host layout/resource mapping, recovery and independent backup available | REQUIRED LATER | Root preflight PASS; sanitized summary only |
| Automatic deployment | Canonical runtime acceptance and separate activation authorization | REQUIRED LATER | Accepted cutover receipt then explicit activation approval |
| Retirement | Runtime, restore, restart, recovery and automatic merge acceptance | REQUIRED LATER | Sanitized acceptance record and separate owner cleanup approval |

No immediate production owner action or new RunPod test is requested. The
architecture/security review is the next implementation-stage boundary.

## Owner-authorized execution sequence

1. Select the full reviewed main SHA and immutable images. Verify exact public
   provenance, applicable checks, disk capacity and compatible retained proxy
   export. Keep independent encrypted backup and recovery credentials available
   outside the host. Do not print archive manifests or credentials publicly.
2. Enter maintenance. Freeze automatic/manual deployment entrypoints and drain
   current deployment, verifier, backups, restores, pruning and agent work.
   Acquire old and canonical deployment locks in fixed order. Record private
   account/unit/firewall/config/mount state and protected checksums in the journal.
3. Run read-only transaction preflight. Refuse two populated source/target trees,
   symlinks, missing mounts, stale/unaccepted transaction, foreign Docker labels,
   unsupported volumes/NSS/drop-ins or unsafe ownership. Present the exact refusal;
   do not improvise around it. Confirm current data identity and application
   consistency baseline before downtime; SQLite checks alone do not cover uploads
   or Chroma binary indices.
4. Fence legacy SSH/unit entrypoints and timers. Quiesce all application writers,
   including optional agent sandboxes and Caddy. Checkpoint private recovery state
   and advance journal. A writer that cannot stop blocks storage migration.
5. Stage/move data and config using the reviewed mapping. Preserve numerical IDs,
   ACLs/xattrs/modes, config values and secrets. Validate all expected data trees
   before activating any container. Translate historical restore/config inputs
   through the reviewed importer; never source old environment files.
6. Stage canonical accounts, forced command, exact polkit rules, units, timers,
   logrotate, firewall selectors, layout and runtime scripts. Reload managers only
   at the journaled boundary. Remove old grants from active authorization before
   enabling the new account. Keep rollback material root-protected and offline.
7. Install effective canonical network drops before attaching canonical containers.
   Remove only checkpointed owned old containers; preserve all persistent resources.
   Create one canonical stack with validated explicit existing mounts. No volume
   prune, `down -v`, implicit empty bind creation or simultaneous stacks.
8. Run the final reviewed sanitized verification script and mandatory root
   post-deployment verifier; wait for acceptance, not merely scheduling. Record
   requested/installed SHA, image identities, transaction state, receipt schema,
   required gate outcomes and time. Failure holds deployment fenced.
9. Perform authorized isolated old/new snapshot restore and backup checks, restart
   and recovery tests. Confirm canonical-only wiring after boot. Accept the
   identity cutover separately from automatic deployment and cleanup.
10. After separate authorization, activate the reviewed CD workflow and demonstrate
    a protected-main merge. Keep manual recovery available. Only after acceptance
    begin the separately approved retirement procedure below.

## Interruption and rollback

The journal controls restart; do not infer phase from a directory name. Recovery
acquires the same locks and checks resource identity/config hashes before acting.
An operation may have completed before its journal update: inspect actual
resource state and either finish idempotently or refuse ambiguity.

Before new writers start: restore original units/config/account metadata and
mount paths coherently, restore effective firewall protection, verify the original
stack mapping and enable only its entrypoint. Preserve failed candidate and
recovery archive. For a same-filesystem move, reversing the move must first prove
the target is the original resource and no writer is active.

After new writers start: do not copy stale originals back over new data. Stop
both automation paths, preserve current data, and select a compatible old/new
code/config/image set against those current resources. If schema compatibility
is unknown, stay stopped and request a bounded recovery decision. Data restore
is a separate destructive decision. Changed credentials/config hashes block
automatic overwrite. A code-root rollback alone does not restore running services.

Cancelled runner or disconnected SSH does not mean the host transaction stopped.
Reconcile its journal and root acceptance before retrying. Failed/missing
mandatory verifier gates block later deployment; no automatic repeated retries
of an unaccepted host transaction. Retain checksummed immutable recovery images,
private manifests and original config until the recovery window is closed.

## Final Jarvis verification script contract

The final script belongs to the runtime acceptance issue, after stable canonical
interfaces exist. It must be read-only by default, use bounded subprocesses,
avoid source/config evaluation, refuse unsafe receipt paths and output only fixed
gate IDs, PASS/FAIL/NOT VERIFIED, SHA, schema and non-sensitive timestamps. No raw
`docker inspect`, environment, journal, firewall dump, account path, host identity,
endpoint, tokens, application content or database counts in public output.
Private detailed evidence may remain in a mode-0600 root report.

| Gate | Required observations |
| --- | --- |
| ID-PATH | Active units/drop-ins, timer targets, executable paths, process cwd/open files, bind mounts and declared config paths use canonical roots; restricted `/proc` visibility is NOT VERIFIED, not absence proof. No broad raw process argument output. |
| ID-ENTRY | Old deploy/backup/maintenance units and user timers inactive/disabled; old SSH entrypoint cannot authenticate or start deployment; canonical key command and polkit exact scope; no extra group grants. |
| ID-DOCKER | Exactly the intended primary services under project `haven`; optional sandboxes reconciled; network/firewall mapping correct; every persistent mount matches private preflight mapping; no old stack running. |
| ID-DATA | Existing resource continuity plus offline consistency; uploads/vector metadata and binary files preserved; expected application access succeeds without disclosing content. An empty healthy database is a failure. |
| ID-AUTH | Authenticated access succeeds; unauthorized, expired/tampered cookie and invalid deploy commands fail; TLS/ACME data/module access survives; cookie transition is deliberate. |
| ID-BACKUP | New canonical capture/upload/integrity checks succeed; isolated restore of exact old and new snapshot IDs passes database and file verification with correct canonical mapping and no old config activation. Backups tile alone is insufficient. |
| ID-FIREWALL | Effective canonical drops, forbidden egress/host/LAN probes, allowed intended traffic, idempotence and boot replay; unrelated rules preserved. |
| ID-WORKER | Existing API/stream/model/auth/mesh contracts preserved; test only the specific newly changed artifact/log/hostname boundary if any. No source-only claim of live worker reachability. |
| ID-DEPLOY | Full requested SHA equals installed SHA, fresh root acceptance and schema-v2 receipt, all eight mandatory gates PASS; stale public receipt cannot establish acceptance. |
| ID-CD | Separately authorized protected-main merge automatically reaches accepted exact SHA; overlap/cancellation tests and explicit manual redeploy work. |
| ID-RECOVER | Authorized restart and interrupted transaction/recovery tests retain the correct data and only one active entrypoint/stack. |

Optional or skipped evidence never satisfies a mandatory gate. Link evidence by
full tested/deployed SHA, non-sensitive environment, time, coverage and outcome.
Record precise failed criteria, minimal action and clearing evidence; do not
repeat previously accepted unrelated backup/worker tests merely for reassurance.

## Owner-executed legacy retirement procedure

This procedure remains unavailable until runtime acceptance and explicit cleanup
authorization. The implementation must generate a private, exact-path retirement
manifest with object type, ownership, mount/inode identity, dependencies, size,
retention deadline and recovery reference. Never use a `hybrid*` glob for deletion.

1. Confirm accepted canonical deployment, protected-main automatic deployment,
   independent backups, both-era restores, restart/recovery evidence and expired
   owner-approved recovery window. Preserve original Git/issues/snapshots.
2. Re-run canonical active-dependency checks while deployment is fenced. Check
   system and affected user managers, lingering timers, SSH, mounts, open files,
   NSS IDs, firewall references and Docker resources. Any dependency or visibility
   gap stops cleanup of the affected object.
3. Archive required immutable recovery images, journal/config mappings and rollback
   instructions privately; validate independent recovery without the old code
   root. Hold deployment lock and ensure no unaccepted transaction exists.
4. Owner reviews the concrete manifest. First disable remaining inert legacy units
   and grants; daemon-reload and prove they cannot restart. Retire obsolete login
   accounts only after numeric ownership and all consumers have migrated. Never
   recursively delete an account home that contains unclassified material.
5. Remove only approved unused code roots, unit/rule files, caches and logrotate
   stubs one at a time with identity checks. Re-run verification after each class.
   Retain required recovery information and independent backup access. Persistent
   application data, Docker volumes and old backup snapshots are excluded from
   automatic cleanup; any later disposal requires its own explicit decision.
6. Record a sanitized result per object class and final canonical acceptance.
   Unexpected owner/mount/hash or newly opened dependency aborts retirement.

No destructive shell commands are supplied before the private runtime manifest
exists. The final owner script must bind to that reviewed manifest, support a
default dry run and refuse unlisted or changed objects. Reverting source cannot
undo a deletion; this is a separate irreversible operation.
