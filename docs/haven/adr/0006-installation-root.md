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
Layouts with durable data or secrets inside the code root require separate
preparation and fail before activation; this migration never moves or deletes
persistent data. No compatibility symlink is created.

Update the layout and exact SSH forced-command path without changing key material
or options. Reapply systemd templates from the new root and retain narrow polkit
grammar. Refuse foreign, symlinked or non-root-controlled code roots and ambiguous
drop-ins. Stop before recreation if the running proxy's exact image cannot be
resolved locally; #186 requires verified accessible recovery or an explicitly
approved equivalent before an affected operation. Local inspect is a necessary
automatic preflight, not proof of full disaster recovery.

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
