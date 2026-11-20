# deploy/ — headless deploy (one commit, one unit)

Automatic deployment preparation (#199): inactive until canonical cutover acceptance
and explicit owner activation of `HAVEN_AUTOMATIC_DEPLOYMENT=enabled` in Actions
repository variables. No settings/secrets or host changes occur in this PR.
After activation, trusted main pushes validate and deploy the exact merged SHA;
manual dispatch retains explicit assent for the current main SHA. See
[the activation and recovery contract](../.github/CICD.md).

Canonical `haven-deploy@` units now run the existing verifier in `ExecStartPost`:
SSH success requires root verification and transaction acceptance, not merely
scheduling. The installer releases its locks first; the unresolved journal fences
other deployments. The verifier requires successful validation in its own waiting
deploy workflow instead of waiting for that workflow's eventual completion.
Older deployment attempts at the same SHA are superseded by the current validated
run; other returned workflows must finish successfully. Verification has a ten-minute bound;
failed, disconnected or timed-out attempts require inspection of the protected
journal and existing current-data recovery procedure. Disconnecting the client
never authorizes rollback or cancels the root transaction. Keep immutable recovery
artifacts. Do not clear the journal or retry around failed mandatory controls.

The asynchronous behavior described below remains for direct operator migration
and custom/local paths. It no longer describes canonical unit success.


## Installation root migration

Fresh bootstrap uses `/opt/haven`. Existing bootstrapped `/opt/haven`
installations migrate during the next **separately authorized normal deployment**.
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

After approval and merge, the owner must prepare the reviewed driver before
dispatch: the installed driver runs preflight before it stages the new SHA.
Use the locked preparation procedure below with the reviewed current main SHA,
saving the installed driver and replacing only `scripts/install-root.py`.
Keep the override unchanged. Release the lock, dispatch that same SHA with
production authorization, and wait for the mandatory verifier.

For the Compose secret-target correction, enter the full reviewed merge SHA
at the prompt in the [locked preparation procedure](#complete-the-existing-installation-root-migration).
After checkout and SHA verification, create the private `previous-driver`
directory and run only these backup and replacement commands while the lock
is held. Skip the override copy and all `deploy-instance.sh` operations.

```bash
cp -a /opt/haven/scripts/install-root.py "$PREP/previous-driver/"
install -o root -g root -m 0644 "$PREP/scripts/install-root.py" /opt/haven/scripts/.install-root.py.new
mv /opt/haven/scripts/.install-root.py.new /opt/haven/scripts/install-root.py
cmp "$PREP/scripts/install-root.py" /opt/haven/scripts/install-root.py
exec 9>&-
```

Keep the backup for undo under the same lock. Driver preparation alone does
not start services. In the separately authorized deployment, confirm that
candidate preflight accepts the Compose-reported DNS credential mount and
that the mandatory verifier accepts the same requested SHA.

- Confirm the journal records the pre-deploy running image as both
  `running_image_id` and `recovery_image_id`.
- Confirm the private archive checksum matches the journal and the previous
  checkout still contains the rendered Compose and Caddy configuration.
- Confirm the requested SHA and runtime-health gates passed and the journal
  reached `accepted`. Report outcomes without sharing protected file contents.
- If preparation must be undone before dispatch, restore the saved driver
  under the same lock. If deployment fails, use the existing control rollback
  and separately authorized proxy-only recovery below.

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

Automatic production deployment on a push to main requires prior owner
activation. A manual workflow run requires explicit assent and the exact
current main SHA.

### Complete the existing installation-root migration

This is the retained first-time installation-root procedure. Accepted installations
already at `/opt/haven` do not repeat it. Namespace preparation uses the existing
corrected transaction to stage a complete matched checkout; do not copy individual
new namespace scripts into an older checkout lacking their canonical helpers.
Review any first-time driver preparation against that selected revision's helper
dependencies before separately authorizing it.

Use one reviewed, merged main revision throughout. No bootstrap rerun, directory
rename, proxy replacement or new recovery rehearsal is necessary. The recovery
candidate must already be available locally; automated checks will refuse if it
is missing or incompatible. Preserve existing backups and recovery archives.

1. On the host, open a root shell (`sudo -i`). Enter the reviewed **full main SHA**
   at the prompt below. This stages only public source and installs two corrected
   driver files under the existing root; it does not start services. The lock
   prevents concurrent deployment. Keep the printed preparation directory locally
   for undo; do not publish host files or the transaction journal.

   ```bash
   set -e
   read -r -p 'Reviewed merged full main SHA: ' SHA
   [[ "$SHA" =~ ^[0-9a-f]{40}$ ]]
   exec 9>/run/lock/haven-deploy.lock
   flock -n 9
   PREP="/opt/.haven-driver-$SHA"
   test ! -e "$PREP"
   umask 022
   GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 git -c credential.helper= -c http.extraHeader= -c core.hooksPath=/dev/null clone --no-checkout https://github.com/jimbobsyouruncle/haven.git "$PREP"
   git -C "$PREP" merge-base --is-ancestor "$SHA" origin/main
   git -C "$PREP" -c core.hooksPath=/dev/null checkout --detach "$SHA"
   test "$(git -C "$PREP" rev-parse HEAD)" = "$SHA"
   mkdir -m 0700 "$PREP/previous-driver"
   if test -e /etc/haven/proxy-recovery-image; then
     cp -a /etc/haven/proxy-recovery-image "$PREP/previous-driver/"
   fi
   cp -a /opt/haven/scripts/install-root.py "$PREP/previous-driver/"
   cp -a /opt/haven/scripts/deploy-instance.sh "$PREP/previous-driver/"
   install -o root -g root -m 0644 "$PREP/scripts/install-root.py" /opt/haven/scripts/.install-root.py.new
   mv /opt/haven/scripts/.install-root.py.new /opt/haven/scripts/install-root.py
   install -o root -g root -m 0755 "$PREP/scripts/deploy-instance.sh" /opt/haven/scripts/.deploy-instance.sh.new
   mv /opt/haven/scripts/.deploy-instance.sh.new /opt/haven/scripts/deploy-instance.sh
   printf 'Prepared driver revision %s; undo files: %s/previous-driver\n' "$SHA" "$PREP"
   exec 9>&-
   ```

   Keep an existing validated selection, or follow the recovery instructions above
   if its digest is unavailable. With no selection file, preflight checks the
   running image reference. Existing obsolete approval JSON files are ignored.

2. In GitHub Actions, run the **deploy** workflow from main with `deployment_sha`
   set to that same full SHA and `authorize_production` checked. This is the
   explicit production action. If main advanced, use the new reviewed main SHA
   consistently, including driver preparation. Do not retry an old driver.

3. Wait for both deployment and its post-deploy verifier. On the host, keep checks
   local: confirm `git -C /opt/haven rev-parse HEAD` equals the requested SHA,
   `/etc/haven/haven.env` selects `/opt/haven`, and the protected journal
   has phase `accepted` with that SHA. The mandatory verifier checks canonical
   SSH/unit wiring and service health; use the existing configured Compose command with `-p haven` to inspect services if a specific failure needs it.
   Report only the revision, accepted outcome and health result in the issue.
   Leave the issue open on any missing/failed mandatory check. After success,
   request owner closure; implementation does not authorize automatic closure.

Subsequent deployments need only step 2 and verification. The corrected installed
driver stages fresh checkouts; no repeated driver installation or recovery
paperwork is needed. The recovery selection may remain until deliberately changed.

### Rollback

If preparation alone must be undone, hold the same deployment lock and copy the
two saved `previous-driver` files back to `/opt/haven/scripts/`, preserving
ownership/modes. Remove the new selection only if it was newly created; preserve
any prior selection. Do not undo preparation during a running deployment.

If migration fails synchronously, the transaction restores roots/control files
automatically. For an interrupted activation, the next authorized deploy restores
it before retrying. For failed/missing asynchronous verification, stop further
deployment and run the following as root using the retained preparation checkout
and the failed deployment's full SHA:

```bash
python3 /opt/.haven-driver-<reviewed-SHA>/scripts/install-root.py rollback <deployment-SHA>
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

The synchronous deploy must schedule its transient verifier successfully.
Acceptance then requires a fresh schema-v2 receipt with requested and installed
SHA, canonical layout/SSH/service wiring, doctor/application health and all other
mandatory gates passing. Root verifier evidence, rather than the service-owned
receipt alone, accepts the journal. Missing/failed verification leaves the
transaction `awaiting_verifier` and blocks the next deployment.

On synchronous failure, restore control files/root and retain the failed code.
An interrupted `activating` journal is recovered on the next authorized deploy.
An interrupted runtime handoff is deliberately held for operator diagnosis.
For a separately authorized control-plane rollback, an operator can run the
retained script with `python3 <retained-root>/scripts/install-root.py rollback
<full-requested-SHA>`. It acquires the deployment lock, restores the previous
control files/root and reloads systemd; it does **not** restart containers or
restore data. If services were recreated, a separately authorized runtime
recovery must use retained code/configuration and verified immutable images.
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

Nothing here is active on its own. Today's deploy path
(`.github/workflows/deploy.yml`) already calls this entrypoint through
`scripts/deploy-trigger.sh`; it becomes fully active once the owner runs the
bootstrap below.

> ## Active after bootstrap
>
> The host pieces here are inert until an owner migration runs. **Card F**,
> `scripts/bootstrap.sh`, installs the pieces on the host and adds the
> `authorized_keys` line, which makes the deploy pass live. `deploy.yml` has
> already been switched over: it connects as `haven-deploy` and sends exactly
> `deploy <sha>`. Until the bootstrap runs, no account, unit or polkit rule
> exists on the host, so that connection fails closed at SSH auth with nothing
> run.

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
in a root-owned drop-in for `haven-deploy@.service`. Any daemon reload or
subsequent deployment requires its own authorization. Bootstrap's invocation
must independently select the same identity. Editing the layout file or
exporting a variable in the SSH client does not perform this activation.

`HAVEN_DEPLOY_PUBLIC_REMOTE` is accepted only when it equals the canonical
HTTPS clone URL above. It does not configure bootstrap or verification. Align
old redirected or custom overrides before any separately authorized deployment;
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
runtime rollback requires separate approval of the known-good revision,
installed standalone verifier and recovery artifacts.

The [readiness runbook](../docs/haven/rename/READINESS.md) preserves historical
preparation and evidence. Current accepted lifecycle decisions and remaining
post-cutover gates are recorded in [#151](https://github.com/jimbobsyouruncle/haven/issues/151).
Reuse accepted backup/restore and unchanged worker evidence within its recorded
scope. New-path runtime verifier propagation awaits the next separately
approved deployment; source forwarding support alone is not a runtime PASS.

---

## What card F installs (one bootstrap, on the host)

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
   re-validates the sha, takes an exclusive lock, refuses a credential-bearing
   origin, fetches main from the public https remote, refuses unless `<sha>` is
   an ancestor of `origin/main`, resets to it, asserts `HEAD == <sha>`, and
   `exec`s the existing `scripts/deploy-remote.sh`.
5. `scripts/deploy-remote.sh` re-asserts `HEAD`, runs `install.sh`, and gates on
   `doctor.sh`. `install.sh` rebuilds the Hermes image only when its build
   inputs changed, and prints a per-phase duration summary
   (see `docs/TROUBLESHOOTING.md`, "The build phase of a deploy").
6. The forced command reads back the unit's result and prints the run log from
   `$HAVEN_LOG_DIR/deploy/<sha>.log`.

---

## Post-deploy verification (after the workflow has finished)

The deploy cannot verify its own build: the workflow run it belongs to is still
in progress at that moment. So `scripts/deploy-remote.sh` starts
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

## Provenance retries and reruns

The root post-deployment verifier reads public GitHub evidence over HTTPS from
`api.github.com`, without a token. Trust comes from the fixed repository API,
matching repository/head repository, main workflow path/event, full commit SHA,
run ID and attempt identity; a job name alone is insufficient. Runner-side
exact-main/merged-PR authorization and workflow `needs: validate` remain in place.

For a rerun, `deploy-provenance.py runs` reads the complete bounded job history,
selects the newest applicable `validate / Validate sources` attempt, and requires
successful completed validation. It confirms that job through its attempt-specific
jobs endpoint and requires the current attempt's deployment job to be in progress.
This supports both inherited earlier validation and GitHub's copied validation
job in a newer attempt. A newer failed, skipped, cancelled, timed-out or neutral
validation cannot be replaced with an older success. A final run read must still
identify the same active attempt. Historical failed deployment jobs are not
validation failures and do not override a valid current recovery attempt.

Diagnostics are fixed `PROVENANCE_*` codes, never exception text, API bodies,
credentials or host configuration. `PROVENANCE_API_TRANSPORT`,
`PROVENANCE_API_TRANSIENT`, `PROVENANCE_API_JSON`, missing/pending evidence,
inconsistent views and changed attempts return temporary exit 75 only in `runs`
mode. The existing verifier retries every 30 seconds within its 540-second
job-aware deadline; each helper invocation is capped by the remaining budget,
with ExecStartPost's 10-minute timeout as the outer bound. Temporary
uncertainty never publishes successful acceptance. Other helper failures stop
verification immediately. Non-rate-limit 403, other permanent HTTP errors,
identity mismatches, ambiguous gates, failed validation and completed deployment
runs remain refused. Truncated/count-mismatched lists (including the existing
100-item bound) cannot pass; persistent incompleteness expires unsuccessfully.
Neither runner authorization nor manual-cutover acceptance gains retry/override
semantics from exit 75.

The SSH forced command takes its log directory from the non-secret canonical
layout (`/etc/haven/haven.env`), ignoring inherited log-directory overrides. A
missing/unreadable layout or missing log setting refuses before starting a unit;
it cannot silently report `/opt/haven/deploy`. The stack secrets remain unread,
and SSH grammar, polkit rights and log permissions are unchanged.

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

Owner merge review of this PR is not production deployment or recovery acceptance
authorization. Rollback remains the existing reviewed revert plus separately
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
