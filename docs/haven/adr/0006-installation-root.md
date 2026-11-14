# ADR-0006 — Transactional installation root migration

Status: proposed implementation for [#187](https://github.com/jimbobsyouruncle/haven/issues/187).
This is not production migration approval. Related completed rename: #146;
retained proxy recovery prerequisite: #186 and its final owner disposition.

## Decision

Fresh bootstrap uses `/opt/haven`. Normal authorized deployment stages a new,
credential-free public checkout of the exact requested full SHA and checks its
ancestry against freshly fetched main before changing active paths. A protected,
fsynced journal records the previous root, retained checkout and original control
files before handoff. Directory renames and individual control-file replacements
are atomic; a multi-file handoff is recoverable, not globally atomic.

The first migration must also work when the previously installed dispatcher has
already reset the legacy checkout before entering the new deploy-remote script.
That checkout is retained, and an independent validated checkout of its
pre-reset ORIG_HEAD is retained for code rollback. This is not an untouched
pre-deployment rendered configuration.
Subsequent deployments stage without resetting the active checkout and retain
that checkout, including its rendered configuration, for rollback.

Only the application root changes. `/etc/hybrid-ai`, `/var/lib/hybrid-ai`, logs,
backup credentials/repositories, numeric ownership, service accounts, unit names,
Compose project `hybrid-ai`, networks, containers and worker contracts remain.
Stateful installer, maintenance, agent-control and uninstall Compose calls pin
that project explicitly, and preflight refuses a different existing project.
Layouts with durable data or secrets inside the code root require separate
preparation and fail before activation; this migration never moves or deletes
persistent data. No compatibility symlink is created.

Update the layout and exact SSH forced-command path without changing key material
or options. Reapply systemd templates from the new root and retain narrow polkit
grammar. Refuse foreign, symlinked or non-root-controlled code roots and ambiguous
drop-ins. Before recreation require a protected owner decision and compatibility
evidence for an available immutable recovery image. The running exact image or
an explicitly approved equivalent can satisfy this gate; a tag cannot. Export
the approved local image by ID into a protected retained archive before staging.
Neither local inspect nor successful export proves full disaster recovery.

## Deployment #271 recovery-preflight correction

[PR #188](https://github.com/jimbobsyouruncle/haven/pull/188) merged as
`1a9dec3622931c45343095f5707765db283c4ba4`.
[Run 43317551461](https://github.com/jimbobsyouruncle/haven/actions/runs/43317551461)
passed source validation and failed its deploy trigger with systemd `exit-code`,
status 1 and the generic `install-root` refusal. Owner-confirmed observations:
active root `/opt/hybrid-ai`, no migration journal, and exact running proxy image
unavailable through image inspect. No successful migration or proxy recreation
is established.

**Confirmed source defect:** the original gate obtains the running immutable ID
from container `.Image` and inspects that ID. An inspect subprocess failure
escapes to the generic exception handler; its later identity comparison/refusal
is never reached. It also has no way to accept the separately validated and
owner-approved alternative retained by #186's final disposition. These facts
explain the missing-artifact refusal path. The old log does not identify the
individual failed command, so it cannot independently exclude an earlier gate
failure or establish every runtime step. Absence of the journal limits evidence
to pre-activation; do not infer successful rollback or untouched earlier legacy
dispatcher activity.

Container `.Config.Image` and image `RepoTags` are mutable references. The
recorded locally cached tag resolved to a different ARM64 ID in #186; neither
tag equality, source build arguments nor the candidate's platform proves running
image identity or compatibility. No candidate equivalence is asserted here.

The correction requires two fixed host files under
`/etc/hybrid-ai/install-root-approvals/`: `<requested-full-SHA>.json` and
`<requested-full-SHA>.evidence.json`. Both must be root-owned regular files,
mode `0600`, with trusted, non-writable, non-symlinked parents. There is no
environment/SSH/CLI override or automatic approval writer. The recovery operator
records verified compatibility evidence; the owner approves its exact hash.
This gate applies to each transactional deployment, including canonical-root
redeployment, so a later revision cannot silently reuse a migration approval.

Approval schema v1:

```json
{
  "schema_version": 1,
  "decision": "approve-install-root-deployment-and-proxy-recovery",
  "requested_sha": "<full authorized commit SHA>",
  "approved_at": 0,
  "expires_at": 0,
  "evidence_sha256": "<SHA256 of exact evidence file bytes>"
}
```

The timestamps are UTC Unix seconds; approval must be current, not future-dated,
and last at most 24 hours. Zeros/placeholders above are intentionally invalid.
Evidence schema v1 contains `running_image_id`, `recovery_image_id` (both full
`sha256:` image IDs), `platform` (Docker OS/architecture, plus variant if present),
`configuration_sha256` with exactly `caddyfile`, `compose`, `stack_env` hashes,
and `checks` with exactly `caddy_version`, `dns_modules`, `config_validation`,
`platform`, `recovery_procedure`. Each check contains `state: "PASS"` and a
`receipt_sha256` identifying the retained private validation receipt. These
receipts must cover running/candidate version and required DNS modules,
compatible platform, installed configuration validation and the bounded recovery
procedure using retained code/configuration and immutable recovery image. A
stock Caddy image or mere tag match is insufficient. Hashes/receipts, configuration
and approval files stay on the approved private route, never in public CI/issues.

This is an owner-attested evidence mechanism, not automatic execution of
compatibility tests. Root control is its trust boundary; root must record the
owner's actual explicit decision only after reviewing real evidence. Root can
already modify the deployment code; these files do not defend against a hostile
root operator. Missing, WARN, skipped, failed or unverified checks cannot pass.
The gate compares the live running ID, installed Caddyfile, rendered Compose and
protected stack-env bytes to that evidence, then inspects the approved recovery
ID and platform. It saves that image to a unique root-only archive in the private
`0700` transaction directory, checks nonempty export, fsyncs/hashes it and records
the archive, identities and approval hash in the journal. Missing local images,
unavailable layers, export/disk failures or mismatches refuse before activation.
No automatic pull/load/build, candidate execution, tag mutation or replacement
container is used by preflight. Successful archives survive rollback and later
tag changes; keep sufficient disk space and retain them until approved cleanup.
Runtime use/loading of the archive still needs separate authorization.

Fixed `PROXY_IDENTITY`, `RECOVERY_APPROVAL`, `RECOVERY_COMPATIBILITY`,
`RECOVERY_CONFIGURATION`, `RECOVERY_IMAGE`, `RECOVERY_ARTIFACT` and
`RECOVERY_STORAGE` diagnostics identify failed recovery gates. Refusals use
GitHub Actions error annotations without subprocess output, image IDs, paths,
hashes, environment contents or raw host configuration.

The deployment workflow is manual-only and requires explicit production assent,
the exact dispatched main SHA, source validation and the existing production
environment. A merge/push cannot initiate migration. The inspected production
environment had a branch policy but no required-reviewer rule; an environment
name alone is not approval. No repository/environment settings are changed by
this correction. Existing SSH grammar, polkit permissions and deployment locks
remain unchanged. Host approval does not itself dispatch a deployment.

**Remaining owner actions, before a production attempt:** separately authorize
compatibility validation and a bounded method to install the reviewed corrected
driver on the legacy root. The currently installed dispatcher invokes its local
driver before staging the requested SHA: merging or dispatching a new SHA alone
does not reliably propagate this preflight correction. Do not retry the old
driver, rename directories manually or relax the gate. Retain verified recovery
code/configuration/image evidence, provision the protected evidence/approval
files for the final authorized SHA, and authorize the exact production dispatch.
No host preparation is performed by this PR. Subsequent runtime acceptance needs
requested/installed SHA correlation, canonical wiring and the matching mandatory
verifier gates, with ordinary worker-use evidence only for its affected scope.
No fresh worker operation or cross-repository change is required for this fix.

## Owner-reported recovery progress — 2026-11-13 (not migration acceptance)

This is an evidence update for [#187](https://github.com/jimbobsyouruncle/haven/issues/187),
not a change to the approved migration and proxy-recovery gates. The operator
reported the following private-host observations; the underlying private
receipts and live configuration were not independently inspected for this PR.

- **DRIVER-271 — OWNER-ATTESTED / corrected host preparation:** the legacy
  deployment entrypoint remained at `/opt/hybrid-ai`, with legacy checkout
  `1a9dec3622931c45343095f5707765db283c4ba4`. The operator used the
  bounded, deployment-locked, SHA-verified replacement of only
  `scripts/install-root.py` from merged PR #189
  (`59bc6d41390c75af1d9457f683d6f4c5847c7724`). Reported Python syntax
  PASS, driver integrity PASS, and previous driver retained. No deployment or
  installation-root migration was initiated. The Git checkout remains at the
  historical commit with an intentionally modified driver; a `git reset --hard`
  would overwrite the corrected file and is not a repair step.
- **RECOVERY-271 — PARTIAL / candidate compatibility:** running proxy and
  expected Compose project confirmed; the running image ID was not locally
  inspectable; a *different* locally cached immutable Caddy candidate was
  present and matched the host platform. The running binary reported Caddy
  `v2.11.7`. After matching the diagnostic container to Caddy's executable
  capability needs, the candidate executed and reported `v2.11.7`, with
  `dns.providers.cloudflare` and `dns.providers.rfc2136` present. These
  are presence checks, **not** proof of matching module versions, full binary
  equivalence, installed-config compatibility or recovery viability.
- **Validation-tool finding:** the first diagnostic ran with
  `--cap-drop ALL --security-opt no-new-privileges --user 65534:65534`
  and failed with `exec /usr/bin/caddy: operation not permitted`.
  The same candidate subsequently executed when `NET_BIND_SERVICE` was
  explicitly added back, still without network access, privileges, host
  credentials or production proxy changes. This is consistent with Caddy
  executable file-capability requirements; no file-capability inspection
  established exact causation. A failed over-restricted diagnostic must not
  be misreported as an invalid recovery image. Do not weaken the running
  proxy's configuration to accommodate a diagnostic.
- **Still REQUIRED BEFORE production dispatch:** privately compare running
  and candidate nonstandard module **versions**; use the repository's
  `scripts/lib/tls.sh` Caddy-validation semantics to validate the actually
  installed Caddyfile against the candidate with the appropriate protected
  env/credential mounts (not merely `caddy adapt`); retain a bounded
  recovery-procedure receipt, actual configuration hashes and immutable
  IDs. Obtain owner approval of evidence for the **final dispatched SHA**
  using the fixed root-owned records above, then allow the new driver to
  inspect and durably export the approved image before staging.
  No `docker image save`, approved equivalence, production dispatch or
  canonical-root verifier PASS has been established by this evidence.
- **Follow-up, not a migration dependency:** assess a separate, pinned Caddy
  patch-version upgrade after verified recovery and installation-root
  migration. The v2.11.7 image and its candidate must not be silently
  retagged/rebuilt as part of fixing the root migration. The base image,
  custom DNS modules, Caddyfile, ARM64 build and TLS/ACME behavior need
  their own compatibility/security validation and rollback artifact.

## Failure and acceptance

Keep the existing deployment lock throughout staging and synchronous install.
Restore saved control files and root after synchronous failure. Retain failed
checkout and transaction for diagnosis, with no automatic container or database
rollback. Interrupted activation is restored on the next authorized invocation.
An installation awaiting asynchronous verification blocks another deployment;
failure/missing receipt is never accepted. Verifier receipt publication, requested
SHA, installed SHA, installation wiring and mandatory health gates must succeed.
Only then may the journal mark the handoff accepted. Optional warnings retain
their evidence status. No background work is promised by the development agent.

## Recovery

The deployment operator inspects the protected journal locally. An explicit
`rollback` restores saved control files and the retained checkout under the same
deployment lock; it does not restart containers or restore data. If install had
already recreated services, stop and authorize a bounded runtime recovery using
the recorded previous SHA, matching rendered configuration and retained immutable
images. For the first legacy handoff, reconstructing a previous runtime needs the
operator's previously retained configuration/image evidence; ORIG_HEAD alone is
insufficient. Keep all recovery artifacts until owner-approved cleanup. No code
in this migration removes checkpoints, persistent directories or Docker volumes.

## Validation and limits

Offline real-Git fixtures cover fresh/bootstrap, legacy and canonical roots,
interruption, repeat deployment, rollback, trust refusals, unit/SSH/layout wiring,
receipt/SHA gates and uninstall preservation. CI adds ShellCheck, security tests
and SAST. Public worker source review establishes no `/opt/hybrid-ai` dependency
in its image/startup at public revision
[`cf402976b09d8d155c62f5f4b83d174b35d3521f`](https://github.com/jimbobsyouruncle/runpod-hybrid-worker/tree/cf402976b09d8d155c62f5f4b83d174b35d3521f);
no worker behavior or configuration changes are proposed.
Live ARM64 migration, proxy recovery and normal worker-use observations require
the separately authorized deployment; source tests do not establish them.

The complete generated code index grows beyond its former 24 KiB cap. The
freshness checker and existing map committer use a matching 28 KiB capacity;
the pinned generator, complete symbol coverage and freshness comparison remain.
