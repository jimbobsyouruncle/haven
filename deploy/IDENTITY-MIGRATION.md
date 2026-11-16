# Coordinated Haven identity cutover

PR preparation does not authorize this procedure. Automatic deployment remains
inactive until PR 3. Merge, production cutover, recovery execution and cleanup
are separate owner decisions. This uses `install-root.py` and its ADR-0006
checkpoint, immutable Caddy recovery export, main ancestry check and verifier.
It does not change the RunPod worker, remote Restic repository or credentials.

## Supported boundary and authorization

After review and merge, the owner selects the full main SHA, outage window and
root-controlled checkout of that reviewed revision. The source/CI evidence is
not a claim that production has migrated. Obtain an independent encrypted backup
using the existing backup procedure and confirm historical restore access before
cutover. Retain the recorded recovery image/export and previous code checkout.

The supported source is the system-mode bootstrap layout: `/opt/haven` (or the
retained `/opt/hybrid-ai` root), `/etc/hybrid-ai`, `/var/lib/hybrid-ai`, sibling
agent/repository/deploy/backup directories, and the platform log/cache paths
listed explicitly in `Transaction.mapping()`. Local passwd/group entries must
match NSS, preserve UID/GID and supplementary groups, and have the expected homes.
Unknown overrides, path conflicts, symlinks, foreign consumers, named/anonymous
volumes, nested host mounts and cross-filesystem moves refuse. Host mount replay
needs a separately reviewed fstab/mount-unit mapping; a live rename is insufficient. A refusal requires a concrete reviewed
mapping; do not bypass it, create replacement data, or copy filesystem trees.

The sole bind-path alias exception is the existing status/OpenHands Docker API
mount at destination `/var/run/docker.sock`. Its source must be exactly
`/var/run/docker.sock` (with root-owned `/var/run` pointing directly to `/run`)
or `/run/docker.sock`. Trusted parents and a root-owned Unix socket with no
other-user permissions are required. Device/inode, owner/group and mode are
checkpointed and rechecked before activation, forward recovery and acceptance.
Only these two source spellings are equivalent during Docker inspection;
destinations and read/write flags must still match, with no duplicate destinations.
Socket replacement or metadata drift refuses and needs operator review; do not
restart Docker or edit the journal to bypass this check. Other symlinks remain
unsupported, including persistent-data binds and a symlinked socket itself.

For a refusal during identity preflight, before any new transaction is published,
retain the existing journals and recovery artifacts. Confirm privately that no
unaccepted transaction or partially migrated layout requires recovery. After the
correction is reviewed and merged, prepare a separate root-controlled checkout
of the **new approved full main SHA**, verify its HEAD and clean tracked contents,
and invoke that checkout's driver with the same SHA:

```sh
sudo python3 "$reviewed_checkout/scripts/install-root.py" migrate "$approved_sha"
```

Do not retry the old failing SHA or use an old driver with a new target. The driver
repeats all preflight, locking, immutable recovery and mandatory verification gates.
If a protected journal instead shows activation/writers possible, follow the
matching-SHA recovery procedure below; a fresh migration is not a recovery bypass.
Record sanitized requested/installed SHA, protected journal phase and mandatory
gate results. A preflight correction or successful command exit alone establishes
no runtime acceptance. Execution still requires owner production authorization.

Stop scheduling manual restore/backup/prune/deploy operations during the window.
Run the cutover from a root operator session, outside the deploy account and its
unit. The service accounts must have no remaining processes after their writers
are stopped. An SSH session as the old deploy account is a writer and refuses
account rename; do not kill it to force an in-flight workflow to succeed.

An older installed driver cannot enforce the new post-activation boundary.
`deploy-remote.sh` rejects that parent before installation. For the first cutover,
invoke the **reviewed revision of the existing driver** from the root-controlled
checkout; do not use the old SSH dispatcher or replace its executable in place:

```sh
sudo python3 "$reviewed_checkout/scripts/install-root.py" migrate "$approved_sha"
```

`migrate` requires root, validates a full SHA, takes the unchanged legacy lock
and then the canonical lock, stages public main independently and validates
ancestry/exact HEAD. Both lock inodes remain in place. Old SSH/polkit/unit/timer
entrypoints are fenced and jobs drained before data moves. Docker restart policies
are disabled before stopping exact owned IDs. The journal records original
controls, unit enablement, account IDs/groups, bind mounts/images, and each
move's device/inode **before** mutation. Directory renames preserve ownership,
ACLs, xattrs and database/WAL/upload/vector/ACME contents. Secret files are parsed
as data; only known keys/path locators and local platform images are translated.

Empty canonical networks receive ownership labels, then equivalent firewall
protection is applied and checked before containers attach. Both legacy and
canonical bridges are covered; no unrelated rule or legacy network is removed.
Long-form Compose binds set `create_host_path: false`. Only the original stopped
owned container IDs are removed to allow Compose label/name recreation; data,
volumes and old images are never deleted. Application service identities remain
Ollama, Open WebUI, Hermes and OpenHands; published sandbox artifacts stay pinned.

## Durable recovery boundary

The protected mode-0700 journal directory is `/var/lib/haven-install-root` after
cutover begins. Historical journals and immutable image archives remain at their
recorded old locations. The driver can discover the old journal if interruption
occurs before the first canonical journal publication. Do not edit either journal.

* **Before activation:** `identity.boundary=pre_activation`. Recorded inodes resolve
  interruptions between a rename and publication. Automatic synchronous recovery
  restores paths, account names, saved controls and unit enablement; containers and
  timers remain stopped for explicit operator inspection/resumption. Changed
  translated controls/credentials refuse overwrite. Recovery never copies data.
* **Activation possible:** the driver fsyncs `writers_possible=true` and
  `identity.boundary=post_activation` **before** removing old containers or invoking
  the installer. Even a crash just before startup is treated as possibly written.
  `rollback` refuses checkpoint control restoration, including after acceptance.
  A synchronous failure records `recovery_required`; an abrupt interruption may
  leave `awaiting_verifier`. Both block another deployment.

After a pre-activation interruption, use the same reviewed driver under the same
locks with `rollback <sha>`, inspect the retained state, then explicitly decide
when to resume the old runtime. Code-root rollback alone never establishes a
running service. Restart only the selected old stack against its original binds;
never enable both sets of timers/entrypoints.

After activation is possible, preserve current canonical data and config. The
bounded current-data recovery is:

```sh
sudo python3 "$reviewed_checkout/scripts/install-root.py" recover "$approved_sha"
```

It requires the matching journal/current HEAD, canonical wiring and recorded data
inodes, removes only any remaining original legacy IDs, and reruns that revision's
installer against **current** canonical controls/data. It does not restore old
config, credentials, databases or a stale data copy. If a code/image compatibility
problem requires another revision, stop and review a specific current-data recovery
procedure with the retained immutable artifacts; do not force old root rollback.
Database restore remains a separately authorized owner operation.

## Retry after a completed pre-activation rollback

The reported failure at `e875522822f11b777fe6444fbaffb3885984d07a`
ended `rolled_back`, `pre_activation`, without writers possible. The owner
reports the original `f67c5f0ee4c08afaa7ab7559083b8acec26bdc1d`
installation restored and seven core containers running. These are supplied
observations, not independent production verification. Twelve journal moves are
preflight intentions; seventeen units are sampled states. Neither count proves
an operation completed. Zero translated controls places the likely failure
between fencing and the first configuration translation, including timer/service
commands, Docker drain, path moves, account changes and layout rename/read.

A demonstrated defect was attempting system-manager stop/disable for absent
units, including user-mode backup templates on a system-mode installation.
The corrected driver skips only a successful `LoadState=not-found` lookup;
manager failures, unexpected states and failures stopping present units still
abort. All service names remain fenced. Absent fence destinations are included
in the original control checkpoint so rollback removes newly created fences.
The old journal cannot establish whether this defect caused that production
failure; no stderr or operation checkpoint survived in its supplied summary.

The driver now checkpoints `operation.stage` and `operation.item` before each
preparation operation. Items are one-based positions in the corresponding unit,
container, move or account list; configuration items 1 and 2 mean layout and stack.
`failure` preserves the failing stage/item, fixed error kind and numeric command
return code or filesystem errno. `rollback_failure`, when present, separately
records failed recovery. Safe terminal diagnostics omit command arguments,
exception messages, paths, stdout/stderr and control contents. An operation is
an intention, not proof of success, and never changes the activation boundary.
Older journals remain readable. Keep full journals private: existing checkpoint
controls can contain credentials.

After this fix merges, the **owner**, with separate exact-SHA production approval:

1. Retain both journal locations, failed candidate, previous checkout, independent
   backup and immutable recovery exports. Privately confirm the latest transaction
   is still `rolled_back` / `pre_activation` with `writers_possible` absent/false,
   original layout/accounts/binds restored and the original core stack running.
   If state differs, stop and use the matching-SHA recovery section above.
2. Pause scheduled/manual deployment, backup, prune and restore work for the outage
   window. Use a root operator session outside the service accounts. Prepare a
   separate clean root-controlled checkout of the new approved full main SHA
   containing this fix, with trusted parents. Set `reviewed_checkout` and
   `approved_sha` to that checkout and its authorized 40-character SHA.
3. Verify and invoke the matching driver (do not use the retained failed driver):

   ```sh
   test "$(sudo git -C "$reviewed_checkout" rev-parse HEAD)" = "$approved_sha" &&
     test -z "$(sudo git -C "$reviewed_checkout" status --porcelain)" &&
     sudo python3 "$reviewed_checkout/scripts/install-root.py" migrate "$approved_sha"
   ```

   Leave the recovery-image selection and every preflight gate enforced. A stale
   selection needs the existing reviewed immutable-image procedure, never a bypass.
4. On failure, retain artifacts and record only the fixed operation/item/kind/code
   diagnostic and sanitized phase/boundary/writers state. A completed pre-activation
   rollback leaves stopped writers for explicit owner inspection/resumption;
   do not assume the old stack was restarted. A rollback failure requires recovery
   review. Any writers-possible state requires current-data forward recovery.
5. On success, wait for matching requested/installed full SHA, protected journal
   `accepted`, and all required schema-v2 receipt gates `PASS`. Record sanitized
   evidence in #200. Do not infer acceptance from exit status. Keep backup/restore
   runtime checks at their existing operator stage; cleanup and automatic
   deployment activation still require their separate approvals.

## Acceptance and later cleanup

Wait for the existing root verifier's receipt, matching requested/installed SHA,
and the protected transaction's `accepted` state. Scheduling is not acceptance.
The existing installation-root gate additionally checks canonical account/group
IDs, original bind correspondence/inodes, one complete owned stack, fenced legacy
units, the exact canonical polkit rule, and effective firewall policy. Existing
mandatory health/backup/socket/receipt gates retain their PASS requirements.

Use `backup/restore.sh --test --snapshot <exact-id>` to restore one affected old-era
and one new-era snapshot to isolated scratch. New snapshots use `haven`; lookup
and retention include both tags without rewriting snapshots. Historical env and
Compose overrides are retained for review, never automatically activated. Keep the
same remote bucket, repository password, keys and encrypted snapshot history.
Record sanitized outcomes, full SHA and CI/receipt links in #195–#198/#200.
Runtime backup/restore, restart and cutover evidence remain owner-stage gates.

No cleanup is performed by preparation or acceptance. Follow the exact operator
checklist in `docs/haven/identity/CUTOVER.md` only after successful cutover and
separate cleanup authorization. Preserve data, snapshots, keys, previous roots,
legacy networks/rules and immutable recovery archives until that decision.
