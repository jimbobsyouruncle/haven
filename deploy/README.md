# deploy/ — headless deploy (one commit, one unit)

Owner merges to main authorize production deployment. Application and workflow
changes follow the same path. Jarvis verifies the exact SHA and accepts the
transaction before SSH reports success. See the [CI guide](../.github/CICD.md).

## One-time policy transition

Historical runbook for [PR #261](https://github.com/jimbobsyouruncle/haven/pull/261), accepted by [deployment run 44944993263](https://github.com/jimbobsyouruncle/haven/actions/runs/44944993263). Routine deploys skip this transition.

Use one explicitly authorized maintenance window for the host running the old
cumulative policy. Have the reviewed PR and its successful required checks
available. Keep its merge until the preparation below is complete.

1. Pause automatic deployments by clearing `HAVEN_AUTOMATIC_DEPLOYMENT`. Confirm
   GitHub has no pending or running production deploy and Jarvis has no active
   deployment unit. Privately verify `/opt/haven` HEAD and the protected journal
   agree on an accepted SHA. Check health, recent backup evidence and available
   recovery artifacts. Reconcile an unresolved transaction before proceeding.
2. Take the existing root-controlled deployment locks in order
   (`/run/lock/hybrid-ai-deploy.lock`, then `/run/lock/haven-deploy.lock`).
   Under both locks, take root-only copies of
   `/opt/haven/scripts/install-root.py` and `deploy-provenance.py`. Inspect whether
   `/var/lib/haven-install-root/deployment-authorization.json` exists. If present,
   archive it in the same private recovery directory and remove it from the
   active path. Retain the old signing key privately for rollback. Atomically
   replace only the two bootstrap scripts with the versions from the verified
   PR tree. Keep checkout HEAD, units and running services intact. The files
   need root ownership and must be writable only by root.
3. Confirm production secrets are scoped to the `production` environment,
   restricted to `main`, and that it has no required reviewer. Remove the
   duplicate repository-wide `PI_TAILSCALE_FULL_DOMAIN` after checking its
   environment copy. Enable
   `HAVEN_AUTOMATIC_DEPLOYMENT=enabled`, then merge the reviewed PR. Its push
   follows the normal workflow and replaces the temporary bootstrap copies
   through the regular transaction. Confirm the Actions result and Jarvis's
   accepted full SHA before releasing the maintenance window.

Before activation, restore the two saved scripts under the same locks if
preparation is aborted. Re-enable the old workflow only as a deliberate owner
decision. If the merge reached host activation, pause and drain first, then use
[transaction rollback](#rollback) or proxy/current-data recovery as indicated by
the journal. The previous checkout during this migration contains the bootstrap
overlay. Restore the original script pair from the private copies only after
the rollback has returned to the verified old SHA. Keep the original journal,
image archives and backup snapshots. Keep the old authorization archived and
record any future recovery approval for the exact applicable state.

## Routine image updates

Change the image version or digest in the source template, Compose overlay or
Dockerfile. Prefer immutable digests for recovery and reproducibility. Update
generated outputs using the existing render path. Dependabot can propose
supported Dockerfile updates. Review template defaults, host image overrides,
coordinated Caddy pins and the sandbox image's publish tag separately.

Compose reconciles the existing project without a forced recreate. Matching
containers and mounts stay in place. A changed image or service configuration
can recreate that service and any dependencies Compose needs to reconcile. The
root verifier checks each configured service is running and that its Docker
health check, where provided, passes. This is local liveness/readiness. In
particular, OpenHands needs a task-launch smoke for a compatibility change and a
Hermes upgrade can need a gateway or agent smoke beyond container liveness.

The retained checkout contains previous pins and rendered controls. The root
journal records the previous service image IDs and keeps a verified Caddy image
archive. Keep those local images through the rollback window. An image ID alone
cannot recover an image removed from the host. Revert the pin through a PR for a
healthy, reversible replacement, or recover the failed transaction first. For a
release that upgrades SQLite or other persisted state, verify downgrade
compatibility and have a current restorable backup before merging. Preserve
post-upgrade writes and review a data recovery plan before reverting the image.
A host image override takes precedence over a repository pin.

## Installation root migration

Fresh bootstrap uses `/opt/haven`. Existing canonical installations update by owner merge. Legacy installations need a separately authorized root migration.
Do not move the directory manually or rerun bootstrap over an existing legacy
installation. See [ADR-0006](../docs/haven/adr/0006-installation-root.md) and
[implementation issue #187](https://github.com/jimbobsyouruncle/haven/issues/187).

The dispatcher holds its existing exclusive lock while `scripts/install-root.py`
fetches public main into a fresh staging checkout, verifies the exact requested
SHA and ancestry, journals original control files, and activates `/opt/haven`.
SSH keys/options and service/Compose identities are retained. Secrets and durable
FHS storage keep their existing paths; repository-local persistent paths require
separate preparation and cause a safe refusal. Symlinked/untrusted/foreign roots,
conflicting directories and legacy-path systemd overrides also cause refusal.

Before activation, preflight selects the running immutable proxy image.
Explicit migrations can use the digest in the optional root-controlled
`/etc/haven/proxy-recovery-image`. Preflight retains a private checksum-verified export,
verifies configuration and all filesystem layers, checks host architecture,
Caddy version and required DNS modules, and validates the installed configuration
in isolated temporary containers. No pull/build/load or running-proxy replacement
occurs. Index and configuration digests are distinct identities, not an equality
test. Missing/incompatible/corrupt/unexportable images refuse before activation.
There are no per-deployment approval/evidence files or expiration window.

### #249 cutover and verification

The canonical driver checkpoints the running image regardless of
the optional selection. Preserve the selection for explicit migrations, and
keep older archives and journals. The scheduled Docker cleanup remains
build-cache-only. Keep the current rollback archive and previous rendered
checkout through acceptance and until the owner clears that checkpoint.

The canonical transaction stages the reviewed main revision and uses its
driver for preflight. During verification, check that the pre-deploy running
image matches the recorded recovery image, the private archive checksum matches
the journal, the previous rendered checkout is available and the requested SHA
reaches `accepted` after runtime health passes.

The verifier requires the proxy to answer a local status request. If it
identifies the activated candidate and confirms the process exited with an
error, it may restore only the previous proxy using the checked archive and
retained configuration. It uses the existing locks and verifies the restored
proxy's image, binds, configuration checksum and health. No whole-stack
recovery is attempted. If a running proxy fails a route probe, or identity or
recovery evidence is ambiguous, inspect the failure on the host.

Both `proxy_recovery_required` and `proxy_recovered` fence subsequent
deployments. The latter means proxy health was verified after runtime recovery.
The deployment remains failed. Inspect the protected journal and current
service and data state. Use the separately authorized control rollback and
targeted recovery procedure below as appropriate. Reconcile the proxy with
the canonical Compose configuration before the next deploy. See the
[approved ADR amendment](../docs/haven/adr/0006-installation-root.md#approved-amendment-for-249).

### Recover a missing local proxy image

Read the fixed refusal category first. Docker command failures can leave the
latest stderr in the root-only `proxy-preflight.log` in the installation
checkpoint directory (normally `/var/lib/haven-install-root`). Keep it and the
journal on the host.

- `RECOVERY_DOCKER` calls for checking daemon health and access in the root deployment context.
- A missing `RECOVERY_IMAGE` in a routine deploy calls for restoring the exact
  running image from its checked archive. Explicit migrations can also choose
  an already-local, approved immutable alternative.
- `RECOVERY_ARTIFACT` calls for checking free space and the local image store.
  Preserve the last checked archive if a new export fails integrity checks.
- `RECOVERY_COMPATIBILITY` or `RECOVERY_CONFIGURATION` calls for checking the
  host platform, running Caddy version, DNS modules and installed configuration
  before retrying with a compatible candidate.

Perform recovery as root under the existing deployment lock. Use the archive
path and SHA-256 from the protected journal. Verify the archive is a root-owned
mode-0600 regular file at its recorded path and check its SHA-256 before
`docker image load --input "$ARCHIVE"`. Inspect the **exact selected digest**
after loading and compare platform and layers with the checked archive. An
indexed image can resolve by the selected reference even if Docker cannot
inspect the configuration digest separately. Leave the selection in place when
that reference resolves. Investigate a checksum or identity mismatch before
retrying. Loading the archive requires separate operator authorization.

For an explicit migration, to select a different approved local image under the same lock, first inspect
its full `sha256:…` reference and verify its platform, Caddy version and both DNS
modules. Preserve the previous selection with the rollback evidence. Write
only the verified digest and newline to a root-owned mode-0600 temporary file
in `/etc/haven`, then atomically rename it to `proxy-recovery-image`. Release
the lock before retrying the authorized migration, which checks the
archive and validates the installed Caddy configuration in isolation.

For disk cleanup on an active Haven host, keep the running proxy image, the
selected recovery image and the checked archive for every transaction still
needed for rollback. Remove images by reviewed exact reference only. Retire a
superseded recovery image or archive only after its replacement passes preflight,
the replacement deployment is accepted, and the older transaction is cleared
for rollback cleanup. Keep build-cache cleanup cache-only. The legacy remote
deploy path previously pruned dangling images, while canonical transactions
skipped that step. The incident evidence does not establish which operation
removed the local references.

The next eligible owner merge follows the automatic deployment path. Resolve any fenced transaction with the owner before retrying.

### Legacy installation-root migration

The original procedure and validation evidence are retained in
[ADR-0006](../docs/haven/adr/0006-installation-root.md). The old Actions dispatch
and driver-copy steps are retired. A legacy host needs an owner-approved
migration plan for its installed controls, data paths, backup and rollback.

### Rollback

For a healthy, reversible change, merge a reviewed revert. If a failed deployment
leaves an unresolved host transaction, pause deployment and obtain owner approval
for direct recovery. An interrupted `activating` journal is recovered by the next
deployment. An interrupted runtime handoff stays fenced for operator diagnosis.

For control-plane rollback, use the retained script and the failed full SHA:

```bash
python3 <retained-root>/scripts/install-root.py rollback <deployment-SHA>
```

This restores code/control files and reloads systemd, without database/volume
changes or container restarts. A refusal after later control/secret edits requires
owner reconciliation; never overwrite a rotated secret to force rollback.
If services were recreated, control rollback alone does not recover runtime.
Keep the working proxy running while inspecting the protected journal locally.
For a necessary runtime recovery, verify the retained archive's SHA256 against
`proxy_recovery.archive_sha256` before `docker image load --input <archive>`.
Use the recorded `configuration_id` from the verified archive (not a mutable tag
or an assumed index/config equality) in a private Compose override for proxy
`image`, and use the retained previous root's rendered Compose/Caddyfile with
`-p haven` and the existing protected stack env. Owner-run targeted Compose
`up -d --no-build --pull never proxy` with that override recreates only the proxy;
do not run a whole-stack rebuild, restore databases or delete volumes. First
confirm the retained rendered configuration matches the intended runtime; an
old pre-reset dispatcher cannot reconstruct missing historical configuration.
Other unhealthy services require their own known-good retained images; the Caddy
archive is not a whole-stack image backup. Verify health after recovery.

The root-only journal is `/var/lib/haven-install-root/current.json`; it may
contain saved secrets and key material, so **never publish its contents**. Earlier
journals/checkouts are retained. Previous canonical code roots use unique
`/opt/.haven-previous-*` names; failed candidates use `/opt/.haven-failed-*`.
The initial legacy checkout remains a checkpoint. No permanent symlink, volume
deletion, database move or automatic artifact cleanup is performed.

The canonical path verifies wiring, health and the exact SHA synchronously before
recording acceptance. Legacy paths may use the
[asynchronous verifier](#legacy-and-local-asynchronous-verification).

The first legacy dispatcher had already reset code before entering this new
script: its recorded ORIG_HEAD is revision evidence, not an untouched prior
rendered checkout or proof of runtime recoverability.

Uninstall resolves the selected layout root, retains data/secrets by default,
and leaves legacy/previous/failed checkpoints and migration journals for explicit
owner cleanup. No production migration is established by source tests or CI.

This directory holds the in-repo pieces of a **headless deploy**. A dedicated,
unprivileged `haven-deploy` account gets a forced-command SSH entrypoint
that can do exactly one thing: start the systemd unit
`haven-deploy@<sha>.service`, which deploys the 40-character commit `<sha>`.
The account cannot run git, read the journal, use sudo, or touch any other unit.

On a fresh host, `scripts/bootstrap.sh` installs the account, unit, polkit rule and forced-command key before the GitHub workflow can deploy.

---

## Canonical Haven repository identity

Bootstrap, deployment fetch and the standalone post-deploy verifier select only
`jimbobsyouruncle/haven`. The optional process setting `HAVEN_REPOSITORY_SLUG`
defaults to that identity; the legacy variable spelling is a transitional import
for installed controls. Empty values, the former slug, arbitrary repositories and
URL syntax are rejected. The selector is not read from layout/stack files.
Canonical clone URLs use `https://github.com/jimbobsyouruncle/haven.git`;
verification uses the matching GitHub API path for the requested SHA.

`deploy-remote.sh` validates the process selector before layout reads or host
activity and explicitly forwards the canonical value to the transient verifier
with `systemd-run --setenv=HAVEN_REPOSITORY_SLUG=jimbobsyouruncle/haven`.
The systemd manager's environment cannot silently select a different verifier
repository. Bootstrap still requires an exact canonical HTTPS origin and never
rewrites a remote. See the [configuration handoff](../docs/haven/identity/CONFIGURATION.md)
for key imports, conflict refusal and the deliberate auth re-login.

The [accepted cutover handoff](https://github.com/jimbobsyouruncle/haven/issues/151)
records owner-attested alignment of the existing deployment service and clone.
This is bounded evidence for that installation, not automatic configuration of
another host. For a separately approved installation or configuration change,
review the root service's process environment and existing drop-ins/overrides,
record prior state, and explicitly set
`Environment=HAVEN_REPOSITORY_SLUG=jimbobsyouruncle/haven` under `[Service]`
in a root-owned drop-in for `haven-deploy@.service`. The direct host change and daemon reload require owner approval. Bootstrap's invocation
must independently select the same identity. Editing the layout file or
exporting a variable in the SSH client does not perform this activation.

`HAVEN_DEPLOY_PUBLIC_REMOTE` is accepted only when it equals the canonical
HTTPS clone URL above. It does not configure bootstrap or verification. Align
old redirected or custom overrides before deployment;
foreign repositories, deceptive hosts, userinfo and query strings refuse before
fetch. The former selector/default and custom remote behavior are historical.

Host paths, system accounts, unit names, backup identities and image packages
retain their compatibility names. API redirects remain errors; the verifier
does not follow them or turn failed/skipped runs into passes. No live Pi,
RunPod, restore, registry or external integration check follows from offline
fixtures. See [compatibility evidence and cutover handoff](../docs/haven/rename/COMPATIBILITY.md).

Feature-branch/PR validation does not deploy. Main-branch automation must be
reviewed before publication or merge; a documentation PR does not authorize
host changes or deployment. Rollback of documentation is a reviewed revert;
direct host recovery requires separate approval and verified recovery artifacts. A reversible image change can roll back through a reviewed revert.

The [readiness runbook](../docs/haven/rename/READINESS.md) preserves historical
preparation and evidence. Current accepted lifecycle decisions and remaining
post-cutover gates are recorded in [#151](https://github.com/jimbobsyouruncle/haven/issues/151).
Reuse accepted backup/restore and unchanged worker evidence within its recorded
scope. New-path runtime verifier propagation requires matching deployment-time evidence; source forwarding support alone is not a runtime PASS.

---

## What bootstrap installs (once per host)

Card F is one idempotent, root-run script, `scripts/bootstrap.sh`. It installs
the account, the files and the SSH key line on a host in a single command, and
migrates the current Pi to the same layout:

```sh
sudo env HAVEN_REPOSITORY_SLUG=jimbobsyouruncle/haven ./scripts/bootstrap.sh --deploy-pubkey <key.pub> [--from <legacy-dir>]
```

Everything after the bootstrap runs from the forced command and the unit. The
bootstrap is the manual, one-time step; `install.sh` never runs it and never
calls `sudo`.

1. **The account** — a system account `haven-deploy` (uid below `UID_MIN`).
   It has `/bin/sh` and a locked password, because sshd runs the forced command
   through the account's login shell; a nologin shell would refuse it.
   (`systemd` runs the unit as root, so the account is only the SSH identity.)
2. **The forced-command script** — `/opt/haven/scripts/deploy-forced-command.sh`
   and its helpers under `/opt/haven/scripts/`, readable and executable by
   the account. `/opt/haven` is a root-owned clone of the public https
   remote at `origin/main`.
3. **The unit** — `deploy/haven-deploy@.service`, copied to
   `/etc/systemd/system/haven-deploy@.service` (root-owned), then
   `systemctl daemon-reload`. It is an instantiated unit started explicitly; it
   is never enabled. `scripts/bootstrap.sh` installs it on a fresh device, and
   **`install.sh` re-applies it on every deploy**, so a change to the tracked
   file reaches the host through the normal deploy instead of a by-hand copy. A
   deploy re-applies it while running inside the unit: the running instance
   keeps its loaded configuration, so the new content is effective from the
   next instantiation.
4. **The polkit rule** — `deploy/50-haven-deploy.rules`, copied to
   `/etc/polkit-1/rules.d/50-haven-deploy.rules` (or the distro's polkit
   rules directory, e.g. `/usr/share/polkit-1/rules.d/`), root-owned, then
   reload polkit. It grants the account `start` of a matching unit and nothing
   else. Like the unit, the bootstrap installs it on a fresh device and
   `install.sh` re-applies it, byte-identical, on every deploy, followed by
   `systemctl reload polkit`. The bootstrap refuses to run when polkitd is
   absent or predates `.rules` (JavaScript) support.
5. **The env file** — `/etc/haven/haven.env`, root-owned, mode `0644`.
   It is the LAYOUT file: it holds path and identity settings only, never a
   secret, so both `haven-deploy` and `haven-backup` can read it. (The
   stack's secrets live in `/etc/haven/stack.env`, mode `0600`.) The unit
   passes its path by name only:
   `Environment=HAVEN_ENV_FILE=/etc/haven/haven.env`. A bare
   invocation that does not name the layout file still finds it: when
   `HAVEN_ENV_FILE` is unset and `$HAVEN_APP_DIR/.env` is absent, the
   helper falls back to `HAVEN_ENV_FILE_FALLBACK` (default
   `/etc/haven/haven.env`) when that file exists.
6. **The SSH key line** — one line in the account's `~/.ssh/authorized_keys`,
   restricted to the forced command (see below).

### The authorized_keys line

The key is pinned to the forced command and reduced to no forwarding of any
kind with the `restrict` option:

```
restrict,command="/opt/haven/scripts/deploy-forced-command.sh" <key>
```

`restrict` disables PTY, X11, agent, and port forwarding. The `command=` option
makes sshd run the forced command no matter what the client asks for, with the
requested command placed in `SSH_ORIGINAL_COMMAND`. Because the forced command
accepts only `deploy <40-lowercase-hex>`, the key can start one matching deploy
unit — nothing more.

---

## Least privilege

The `haven-deploy` account holds:

- **No login shell beyond the forced command.** sshd runs
  `deploy-forced-command.sh` for every connection, regardless of the requested
  command. Nothing else is reachable.
- **No sudo.** It is in no `sudoers` rule and needs none.
- **Not in the `docker` group.** It cannot talk to the Docker socket.
- **Not in the `systemd-journal` group.** It cannot read journald. Instead the
  unit writes each run's log to `$HAVEN_LOG_DIR/deploy/<sha>.log` with mode
  `0640` and group `haven-deploy`, so the account reads the log for its own
  run without any journal access.
- **Read access to the layout env file, and only that file.** The forced command
  resolves the host paths the same way the unit does, by reading
  `/etc/haven/haven.env` (parsed, never sourced). That file is mode
  `0644`, owned by root, so the `haven-deploy` account AND the
  `haven-backup` account both read it. It holds paths and names only. (An
  earlier draft used mode `0640` group `haven-deploy`; that would have
  locked the backup account out, so it is `0644`.) The forced command pins
  `HAVEN_STACK_ENV_FILE` at this layout file unconditionally, so it never
  reads the `0600` secrets file `/etc/haven/stack.env` and an inherited
  value cannot point it back at that file. The account is never granted read
  access to `stack.env`, by mode, group or ACL.
- **One polkit action, one verb, one unit shape.** The polkit rule returns
  `polkit.Result.YES` only for `subject.user == "haven-deploy"`,
  `action.id == "org.freedesktop.systemd1.manage-units"`, `verb == "start"`, and
  a unit matching `^haven-deploy@[0-9a-f]{40}\.service$`. Everything else is
  the default deny.
- **A public fetch with no credentials.** `scripts/deploy-instance.sh` fetches
  main only from the public https remote, with git hooks disabled and credential
  helpers cleared, and refuses a credential-bearing origin.

The unit runs as root because it resets the program tree and reprovisions the
host. The commit it deploys is re-validated inside `scripts/deploy-instance.sh`,
refused unless it is an ancestor of `origin/main`, and its `HEAD` is asserted
after the reset.

---

## How a deploy flows

1. The GitHub deploy job runs `scripts/deploy-trigger.sh "$GITHUB_SHA"`. That
   client validates the sha, fetches the Pi's host key with `ssh-keyscan`,
   compares its SHA256 fingerprint with `PI_SSH_HOST_KEY`, then connects as
   `haven-deploy` and sends exactly `deploy <40-hex>`.
2. sshd runs `deploy-forced-command.sh` with `SSH_ORIGINAL_COMMAND="deploy <40-hex>"`.
3. The script refuses anything but that exact form (exit 2), then asks the
   **system** manager to start `haven-deploy@<sha>.service`.
4. The unit runs `scripts/deploy-instance.sh <sha>` as root. The script
   delegates to the locked root transaction. It verifies same-run validation,
   stages the exact current main checkout and retains recovery artifacts before
   calling the installer.
5. `scripts/deploy-remote.sh` re-asserts `HEAD`, runs `install.sh`, and gates on
   `doctor.sh`. `install.sh` rebuilds the Hermes image only when its build
   inputs changed, and prints a per-phase duration summary
   (see `docs/TROUBLESHOOTING.md`, "The build phase of a deploy").
6. The forced command reads back the unit's result and prints the run log from
   `$HAVEN_LOG_DIR/deploy/<sha>.log`.

---

## Legacy and local asynchronous verification

Legacy and local paths without the synchronous unit use a transient verifier. In those paths, `scripts/deploy-remote.sh` starts
`/usr/local/sbin/run-post-deploy-verify.sh` and lets it finish afterwards.

What it does: poll `GET /repos/<selected-slug>/actions/runs?head_sha=<sha>`
with `jimbobsyouruncle/haven` explicitly selected for the canonical repository,
anonymously every 30 s for up to 60 minutes (curl and jq only, no token), wait
until every run for that commit is `completed`, require every conclusion to be
`success`, then compare `git -C <resolved deployment directory> rev-parse HEAD`
with the deployed sha.
It writes one `waiting for <sha> at <UTC>` line up front, then exactly one
result line -- `PASS`, `FAIL: ...` or `TIMEOUT: ...`.

It also writes that verdict as one JSON file per deploy sha at
`${HAVEN_DATA_DIR}/hermes_data/deploy-verdicts/<sha>.json` (default
`/var/lib/haven/hermes_data/deploy-verdicts/`), which the container sees at
`/root/.hermes/deploy-verdicts/`. The host log is not mounted in the container,
so this file is how container-side checks read the verdict. A failure to write
it is a warning on stderr only: it never changes the result line or the exit
code.

**`doctor.sh` reads that back.** The log is appended across deploys, so the
doctor check takes the last `waiting for` line as the run of interest and reads
the first verdict line after it. It surfaces that verdict in the next deploy's
run log: a `PASS` becomes a pass line naming the short sha and the waiting
timestamp, `FAIL` and `TIMEOUT` become a warning quoting the verdict, and a
waiting line with no verdict becomes a warning only once it is more than 65
minutes old -- a younger one is simply still running. There is no mtime
comparison with the deployed commit, because `doctor` runs before the current
deploy's verifier can have written. See
[`docs/TROUBLESHOOTING.md`](../docs/TROUBLESHOOTING.md#post-deploy-verification).

The deployment directory resolves in this order:

1. `HAVEN_APP_DIR` from the environment. The deploy hook passes this
   explicitly with `systemd-run --setenv=HAVEN_APP_DIR=<resolved APP_DIR>`,
   because a transient unit inherits the systemd manager's environment, not the
   deploy script's.
2. else `HAVEN_APP_DIR` parsed line by line from the layout file named by
   `${HAVEN_ENV_FILE_FALLBACK:-/etc/haven/haven.env}`, when that file
   exists and is readable. The file is read as data (`KEY=VALUE`), never sourced,
   and no value from it is printed. An unreadable existing file fails closed. The
   value must be an absolute path with no whitespace, `:` or `,`.
3. else `/workspace`.

**It runs in its own transient unit**, not as a child of the deploy:

```
systemd-run --collect --unit=haven-post-deploy-verify-<sha12>-<pid> ...
```

`deploy/haven-deploy@.service` is `Type=oneshot` with the default
`KillMode=control-group`, so systemd kills everything left in the unit's cgroup
when it exits. An in-cgroup waiter is therefore killed at unit exit --
`setsid` escapes the session, not the cgroup. That was the original defect: a
0-byte log whose mtime matched unit exit. This is why the unit file must never
grow a `KillMode=` override: the transient unit is the fix, and a relaxed kill
mode would hide the class of bug instead of fixing it.

Paths (both resolved in `scripts/lib/haven-env.sh`):

| Path | Default |
|---|---|
| Verifier | `/usr/local/sbin/run-post-deploy-verify.sh`, installed root:root 0755 by `install.sh` |
| Log | `/var/log/haven-post-deploy-verify.log`, appended by the transient unit |
| Verdict JSON | `${HAVEN_DATA_DIR}/hermes_data/deploy-verdicts/<sha>.json`, owned by configured numeric `HAVEN_UID:HAVEN_GID` (legacy default `0:0`), 0644 in a 0755 dir; the container reads it at `/root/.hermes/deploy-verdicts/`. Publication failure produces WARN unless already FAIL/TIMEOUT; no host `hermes` account is required. |

After the tree check the verifier also runs the **Backups tile gate**. It reads
`BACKUP_LOG` and `BACKUP_GROUP_GID` from process settings or the layout as data.
It asserts the log is a regular non-empty file and probes readability **as the
status container's identity** by dropping from root with `setpriv` (configured
status UID/primary GID and supplementary `BACKUP_GROUP_GID`, with legacy
defaults); a root read is never claimed as a pass. The live tile state comes from
`${HAVEN_DATA_DIR}/status-verifier/backup.sock`: a mode-0600 Unix socket in
a status-owned mode-0700 directory provisioned by the installer. The directory
is the only new writable status mount, and Compose refuses to auto-create it.
The socket exposes only the Backups name/state from the existing probe logic.
Browser authentication and Caddy routes remain unchanged. No credential, TCP
port or Docker API access is needed by the verifier, and no domain/stack-file
lookup or fallback to the browser route occurs.

Directory/socket ownership, types and modes must agree with the configured
status UID before the verifier makes a bounded, proxy-free local request. Only
HTTP 200 and the minimal validated JSON shape are accepted; redirect/auth/error
responses, missing sockets, timeouts and malformed results cannot pass. It FAILs
(exit 1) when the tile is `warn` while the writer's log holds
`event=backup_success`, when the tile fails, or when the log is missing/empty.
A probe it cannot run records SKIPPED and prints a fixed `skip:` diagnostic.
All three backup probes are mandatory in system mode; user mode may require
them explicitly. Missing or warning required coverage fails closed. Optional
SKIPPED/WARN coverage produces overall WARN/exit 0, never a clean PASS. These
probes do not execute a backup, integrity check or restore. See the canonical
[coverage and ownership policy](../backup/README.md#post-deploy-verification-coverage-and-receipt-ownership)
for identity resolution and receipt details, and the
[Haven evidence guide](../docs/haven/evidence-completion.md) for issue completion.

The hook must schedule successfully. Scheduling failure or a missing script
produces `::error::` and deployment exit 5. A successfully scheduled verifier
outlives the synchronous deploy and its receipt controls installation-root
acceptance; scheduling alone is not a successful verification result.

`--service-type=exec` is deliberate: it waits for `exec()` to succeed, so a
launch failure is reported instead of lost. `--no-block` would suppress exactly
that. `--collect` and `append:` are supported by the host's systemd 252.

Reading the log and the units: see
[`docs/TROUBLESHOOTING.md`](../docs/TROUBLESHOOTING.md#post-deploy-verification).

---

## Timeouts

The unit's `TimeoutStartSec=` is 45 min and the workflow's `Trigger deploy` step
is 60 min. The step must stay strictly longer than the unit, so the unit gives
up first and the step is still alive to report the real `Result=`. Do not invert
them.

---

## Exit codes

`scripts/deploy-trigger.sh` (the client the deploy job runs; it maps the remote
command's exit code to the job's exit code):

| Code | Meaning |
|---|---|
| `0` | Remote exit 0: the unit started and finished successfully; the job is green |
| `1` | Remote exit 2 (forced command refused the request), remote exit 3 (the unit failed), or any other non-zero remote code. Each prints an `::error::` line |
| `2` | Bad usage: the argument is missing, or is not a 40-lowercase-hex commit; nothing was sent |
| `3` | A local prerequisite failed (missing env, or the host key could not be fetched) |
| `4` | The Pi's host-key fingerprint did not match `PI_SSH_HOST_KEY`; ssh was never invoked |

`scripts/deploy-forced-command.sh`:

| Code | Meaning |
|---|---|
| `0` | The unit started and finished successfully |
| `2` | The command was refused (not exactly `deploy <40-lowercase-hex>`); nothing was run |
| `3` | The unit was started but did not finish successfully |

`scripts/deploy-instance.sh` (the unit's own exit codes; `exec` propagates
`deploy-remote.sh`'s code when it gets that far):

| Code | Meaning |
|---|---|
| `0` | Handed off to `deploy-remote.sh` (its exit code propagates through `exec`) |
| `2` | Missing argument, or not a 40-lowercase-hex commit |
| `3` | Another deploy holds the lock |
| `4` | The origin remote carries a credential (userinfo in its URL) |
| `5` | The public remote is unsafe (not https, or carries userinfo) |
| `6` | Fetching main from the public remote failed |
| `7` | The commit is not an ancestor of `origin/main` |
| `8` | `HEAD` is not the commit after `git reset --hard` |

These are also listed in [`docs/TROUBLESHOOTING.md`](../docs/TROUBLESHOOTING.md).

---

## Conversation prune units

Two units run the conversation quarantine sweep. They are ordinary system units,
not part of the headless deploy, and `haven-prune.service` names
`/opt/haven/deploy/README.md` as its `Documentation=` target — this section.

| Unit | What it does |
|---|---|
| `haven-prune.service` | `Type=oneshot`, `User=root`, `ExecStart=/opt/haven/scripts/prune-conversations.sh` |
| `haven-prune.timer` | `OnCalendar=*-*-* 04:20:00`, `Persistent=true`, `Unit=haven-prune.service` |

It runs as root because the conversations tree under the OpenHands workspace is
owned by root and by the stack's own users; a non-root run could not move those
directories.

`install.sh` installs and enables both units **unconditionally** — not gated on
`HAVEN_BACKUP_MODE`, because pruning is unrelated to whether backups are
configured. It warns and records an event rather than failing if it is not root,
if `systemctl` is unavailable, or if a unit template is missing, so the schedule
can never fail a deploy. It also runs the service once at deploy time as
**catch-up only**, for a host that was off or had not re-deployed for a while; a
missing script there is a warning too. The timer is the primary mechanism.

`haven-prune.service` carries no `Restart=` line at all, deliberately. A
failing prune must not loop; the failure stays visible in
`systemctl status haven-prune`. For the same reason neither unit sets
filesystem sandboxing directives (`ProtectSystem=`, `PrivateTmp=`,
`ReadOnlyPaths=`, `InaccessiblePaths=`): the service has to move directories
under the workspace, and those flags would break the move.

The prune MOVES, it does not shred: every swept directory lands in the
date-stamped quarantine root and a plain `mv` back restores it. The only deletion
is confined to `<YYYYMMDD>` run directories directly inside that quarantine root
and only once they are older than
`HAVEN_PRUNE_QUARANTINE_RETENTION_DAYS` (default `90`; an explicitly empty
or `0` value opts out and restores the never-delete behaviour). Deletion happens only
after the sweep's backup assertion passes, so a quarantine root inside a captured
tree is never touched.

A directory with no `owner_lease.json` is refused on every run by the fail-safe,
so the sweep moves nothing for it. `HAVEN_PRUNE_ALLOW_LEASE_LESS` is the
default-OFF opt-in that lets such a directory move once its own mtime is past
`HAVEN_PRUNE_AGE_SECONDS`; `doctor.sh` warns with the count when any exist.
The knobs and the inspection and restore steps are in the root `README.md` and
[`../docs/TROUBLESHOOTING.md`](../docs/TROUBLESHOOTING.md#the-disk-keeps-filling-with-conversation-directories).

## Docker build-cache prune units

Two more units cap the Docker build cache, installed by the same
`install_prune_scheduler()` step and named, like their sibling, by this README
through the service's `Documentation=` target.

| Unit | What it does |
|---|---|
| `haven-docker-prune.service` | `Type=oneshot`, `User=root`, `EnvironmentFile=-/opt/haven/.env`, `After=docker.service`, `ExecStart=/opt/haven/scripts/prune-docker-cache.sh` |
| `haven-docker-prune.timer` | `OnCalendar=*-*-* 04:35:00`, `Persistent=true`, `Unit=haven-docker-prune.service` |

The timer caps the Docker build cache at 15 GB (override
`HAVEN_BUILD_CACHE_CAP`) daily at 04:35; it removes build cache only and
never touches images, containers, volumes or bind-mounted data. The service
carries no `Restart=` line, deliberately: a failing prune must not loop.
`scripts/prune-docker-cache.sh` probes `docker builder prune --help` at run time
and passes `--max-used-space` when the local Docker lists it, `--keep-storage`
otherwise, and logs and exits 0 when it lists neither, so an unknown Docker
never turns the timer into a hard failure.

---

## No retry policy

`haven-deploy@.service` has **no `Restart=` policy at all**. An earlier
backup upload unit used `Restart=on-failure`, and its retry loop stopped
`hermes-agent` every 15 minutes (incident B1). A failed deploy must never be
retried automatically: a retry could reset the tree again and disturb the
running stack. A failed deploy stays failed and is diagnosed from its log.

---

## Tests

`scripts/test-deploy-trigger.sh`, `scripts/test-deploy-forced-command.sh` and
`scripts/test-deploy-instance.sh` cover all three halves offline — `ssh`,
`ssh-keyscan`, `ssh-keygen`, `systemctl`, `git` and `deploy-remote.sh` are stubbed
on `PATH`, so no Docker, no network and no root are needed. The trigger test
proves the exact command string and login name, the malformed-sha refusals, the
host-key mismatch refusal, the exit-code mapping, key-file removal on success and
failure, and that no weakened host-key option appears. The other two check the
unit has no `Restart=` line and that the polkit rule contains the exact user,
action, verb and unit regex. `scripts/test-bootstrap.sh` covers the host
bootstrap that installs the account, the unit, the polkit rule and the SSH key
line, entirely offline.

### Private Backups transport rollout and rollback

Deploy installer, Compose, status app and standalone verifier together only
after owner approval. The installer creates/assigns only the dedicated socket
directory; no by-hand chmod, host account, login session or Caddy exception is
needed. Existing backup/restore evidence remains valid. After approved rollout,
inspect the matching receipt's required gate results; source fixtures and CI
are not live verification. The owner's #168 receipt on `jarvis` at
2026-11-11T16:09:33Z was FAIL because required tile coverage was SKIPPED; owner
read-only probes confirmed HTTP 308 to HTTPS, then HTTP 302 to the login page.
This correction does not retroactively convert that result to PASS.

Rollback requires a reviewed source revert and separately approved deployment
of the matching installer/Compose/app/verifier revision. The old verifier may
again fail its authenticated browser-route probe; do not suppress that failure.
The dedicated directory can remain unused when the mount is reverted; deleting
it or modifying live configuration is not part of this change. No backup data,
snapshot, log, certificate or credential migration is involved.

## Workflow retries

For a transient failure before activation, confirm the target is still current
main and rerun all jobs. Same-attempt validation is required. For an unresolved
host transaction, use [rollback or recovery](#rollback) before replaying.
The root verifier retries temporarily unavailable public evidence within the
existing deadline and fails closed if it cannot verify the run.

### Recovery acceptance requires separate owner authorization

The installed revision from a failed verification is not accepted by this change.
A successful install or matching HEAD is insufficient; a failed workflow stays
failed. The incident-specific acceptance path below verifies historical CI without
changing the failed workflow's conclusion. The special `reverify-manual` identity
cutover path intentionally rejects a failed deployment workflow and must not be
repurposed for this incident.

Before another production deployment, the owner must explicitly authorize a
bounded recovery review for the installed full SHA and existing transaction:

1. Inspect protected transaction phase, requested/installed SHA, wiring, saved
   controls and immutable recovery artifacts through the approved operator route.
   Keep current data; do not replay install or overwrite post-activation writes.
2. Establish exact-SHA trusted validation from the applicable newest run attempts,
   and identify whether failure was confined to provenance/reporting. Inspect
   sanitized diagnostic codes; the historical generic message does not establish
   the original cause. Reuse valid checks where their coverage is unchanged.
3. Review an exact recovery execution plan under the existing deployment locks.
   Require fresh root wiring, doctor/runtime, required backup and receipt gates.
   The acceptance-only action below is limited to this failed workflow.
4. Obtain explicit owner authorization for that concrete recovery/acceptance
   operation before execution. Root evidence must satisfy the existing acceptance
   checks; never edit journal phase or public receipts to manufacture acceptance.
   If any mandatory gate fails, retain the unresolved transaction and recovery
   artifacts for owner-directed current-data recovery.

An owner merge authorizes normal automatic deployment. This incident-specific host recovery action still requires explicit approval. Rollback remains the existing reviewed revert plus separately
approved host recovery procedure; changing code alone does not restore services.

### Acceptance-only recovery for the 5c2df63 transaction

Production execution requires separate explicit owner authorization. Before
running, confirm privately that the installed checkout and journal identify the
target below, the journal is `awaiting_verifier`, the retained previous checkout,
saved controls, immutable proxy archive and independent backups are available,
and the original failure has no unresolved cause beyond verification. Pause
competing deployment, backup, restore and prune operations. Preserve current data
and all recovery artifacts; do not edit the journal or replay installation.

In an administrator shell, replace the placeholder with the full SHA of the
reviewed, merged recovery driver; it is distinct from the installed SHA. The
checkout must be a new root-owned path, with trusted parents and no symlinks or
group/other-writable files. Use the merged driver that includes the generated
configuration preflight correction. The original #224 driver rejects legitimate
installer output. Do not replace the installed checkout.

The corrected driver checks all other tracked paths against the installed
revision. It reproduces `docker-compose.yml` and `status/Caddyfile` from that
revision's templates and renderer using allowlisted settings from the protected
stack environment file. Both installed files must match their renders byte for
byte. The driver does not source the stack file, read token files, show a diff,
or write to the installed checkout. Review the approved TLS and auth settings
privately before execution. Stop on a mismatch and investigate it without
resetting the checkout, editing installed settings, or rerunning the installer.

```sh
set -eu
reviewed_sha=REPLACE_WITH_REVIEWED_MERGED_DRIVER_SHA
production_sha=5c2df63a73c81ddfbad868dbfe617ee383242ff4
reviewed_checkout=/root/haven-acceptance-recovery-corrected
sudo test ! -e "$reviewed_checkout"
sudo test ! -L "$reviewed_checkout"
sudo git clone --no-checkout https://github.com/jimbobsyouruncle/haven.git "$reviewed_checkout"
sudo git -C "$reviewed_checkout" checkout --detach "$reviewed_sha"
test "$(sudo git -C "$reviewed_checkout" rev-parse HEAD)" = "$reviewed_sha"
test -z "$(sudo git -C "$reviewed_checkout" status --porcelain)"
sudo jq '{sha,phase,started_ns}' /var/lib/haven-install-root/current.json
transaction_hash=$(sudo sha256sum /var/lib/haven-install-root/current.json | cut -d ' ' -f 1)
printf 'transaction sha256: %s\n' "$transaction_hash"
```

Require the target SHA and `awaiting_verifier` in the sanitized journal output.
Record the journal digest privately as the transaction identity. Stop on any
unexpected result. With separate execution authorization, invoke:

```sh
sudo python3 "$reviewed_checkout/scripts/install-root.py" reverify-recovery "$production_sha" "$transaction_hash"
sudo jq '{sha,phase,started_ns}' /var/lib/haven-install-root/current.json
sudo jq '{sha,head,at,verdict,rc,gates}' "/var/lib/haven/hermes_data/deploy-verdicts/$production_sha.json"
```

Success requires exit 0, the same SHA and start time with `phase=accepted`, a
fresh receipt with matching SHA and head, `rc=0`, and every required gate PASS.
The optional historical deployment observation remains FAIL and may produce an
overall WARN; the original GitHub workflow remains failed. The driver uses both
deployment locks, checks the protected journal digest again before acceptance,
verifies retained artifacts and wiring, and obtains fresh root verifier evidence.
A repeat using the old digest refuses without changing the accepted journal.

On a lock conflict, timeout, failed gate, mismatched identity, missing artifact,
or interruption, stop and inspect the protected journal and fresh receipt
privately. A receipt alone does not establish acceptance. Preserve current data
and artifacts and review the exact failure before retrying. Code/control rollback
does not restore data or restart containers; after writers may have run, a
separately reviewed current-data recovery is required. A successor deployment
requires its own authorization.
