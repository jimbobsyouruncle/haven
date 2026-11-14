# Production cutover, existing verification and operator cleanup

Planning runbook only. No migration code, host access, deployment, configuration
change, activation or deletion is authorized by this documentation revision.
Use ADR-0006's existing transaction/recovery tools, extended only for reviewed
identity mappings. Do not implement a second comprehensive Jarvis verifier.

## Evidence and stage gates

| Stage | Disposition | Evidence or clearing condition |
| --- | --- | --- |
| Installation-root baseline | VERIFIED / accepted | [#187 owner acceptance](https://github.com/jimbobsyouruncle/haven/issues/187#issuecomment-6884420911), deployed `f67c5f0ee4c08afaa7ab7559083b8acec26bdc1d`; accepted journal, eight mandatory gates PASS; optional doctor WARN remains WARN |
| Simplified architecture | Approved owner direction | ADR-0007 and PR #201; runtime details receive normal implementation/security review |
| Implementation readiness | REQUIRED LATER | Three cohesive PRs, current-head CI/SAST, changed-boundary tests and applicable ARM64 checks |
| Production cutover | REQUIRED LATER | Explicit owner authorization of reviewed revision/window/procedure and successful private host preflight |
| Automatic deployment activation | REQUIRED LATER | Canonical runtime accepted, tested existing workflow changes and explicit activation authorization |
| Cleanup | REQUIRED LATER | Successful cutover, exact reviewed checklist, recovery retention decision and explicit cleanup authorization |
| Worker changes and second verifier | NOT APPLICABLE | Worker is excluded; extend existing verification |

OWNER ACTION GATE: CLEAR for this documentation revision and already authorized
implementation PR preparation. No new live test is requested now. Future production
gates stay with their execution stage; they do not reopen #187.

## Proposed bounded execution

1. Select the exact reviewed main SHA and validated immutable artifacts. Use the
   existing automated proxy recovery export/compatibility checks. Confirm independent
   encrypted backup access and sufficient space; retain original recovery material.
2. Under the existing deployment mechanism, fence and drain deployment, verifier,
   timers, backup/restore/prune and application writers. Hold old/new locks in fixed
   order during the lock-name handoff. Do not unlink or rename a live lock inode.
3. Preflight only the reviewed host mappings. Refuse populated destination conflicts,
   symlinks, foreign stacks, account collisions, missing mounts or unknown overrides.
   Unsupported cross-filesystem movement needs a concrete reviewed procedure before
   execution; no general filesystem migration support is required.
4. Extend the existing journal/saved controls for necessary path, account, unit,
   credential, mount and firewall recovery. Move quiesced data preserving numeric
   ownership and metadata. Translate known config keys without evaluating secrets.
   Never merge populated trees, create empty replacement mounts or rotate credentials.
5. Switch accounts/units/SSH/polkit, paths and owned Docker project/resources together.
   Preserve app identities. Stage effective firewall protection before new networks.
   Disable old entrypoints; run only one stack against the verified original data.
6. Run existing health, security, data and root deployment verification with targeted
   identity assertions. Wait for matching requested/installed SHA and protected
   accepted transaction with all mandatory gates PASS. Scheduling or unit success
   alone is insufficient. Failure fences subsequent deployment.
7. Verify changed backup paths/tags and historical restore mapping with existing
   backup/restore procedures, using isolated scratch space for affected restores.
   Exercise changed restart/interruption/recovery boundaries; reuse surviving
   accepted evidence for unchanged contracts. Then record canonical cutover outcome.
8. After owner-authorized activation of the prepared existing workflow, record a
   real main-merge deployment and its exact SHA/mandatory verification outcome.
   Manual recovery remains available through the same locking mechanism.

## Extend existing verification

Use `doctor.sh`, existing auth/firewall tests, backup integrity/restore tools and
`scripts/run-post-deploy-verify.sh` rather than a separate gate taxonomy or report
framework. Add focused assertions for canonical entrypoints, restricted SSH/polkit,
existing-data mount identity, one owned stack, firewall selectors, backup mapping
and exact deployed SHA where those boundaries change. Retain existing eight
mandatory receipt gates; optional advisories do not invalidate accepted completion.
A mandatory FAIL, missing evidence or SKIPPED is never PASS.

Record full tested/deployed SHA, CI/run link, non-sensitive environment, time,
coverage and raw outcome. Root acceptance is authoritative; a stale or service-user
writable public receipt is insufficient. Publish sanitized summaries only, never
raw configuration, Docker inspect, logs, private identities/endpoints or data.
Worker compatibility stays unchanged; no new worker image/log/API/transport test
is an acceptance dependency.

## Interrupted handoff and recovery

Use the existing protected journal and recovery entrypoint under exclusive locking.
Inspect actual resource state when interruption may precede a journal update;
complete the bounded operation safely or refuse ambiguity. Before new writers,
restore original coherent controls/mounts and effective firewall protection, enabling
only the selected stack. After new writes, preserve current data and select compatible
code/config/images; never copy stale original data back. Changed credentials block
overwrite. Database restoration is a separate owner decision.

Runner cancellation or SSH disconnect does not establish host completion. The next
run checks the prior transaction and mandatory acceptance before mutation. Retain
failed candidates, rendered configuration, checksummed immutable recovery exports
and independent backups. Source rollback alone does not recover running services.

## Exact operator cleanup checklist

No retirement-manifest engine, cleanup service or generic deletion script. After
successful cutover and explicit cleanup authorization, the operator completes a
concrete reviewed checklist containing exact object identities and recovery effects.
Populate it from private host inspection; this design does not invent live paths.

| Candidate class | Required exact checklist entry and protection |
| --- | --- |
| Inactive legacy code root | Exact path/resource identity; no active unit, cwd, mount or recovery dependency |
| Obsolete units, rules and grants | Exact file/unit/account; inactive, no remaining callers; numeric ownership migrated before account retirement |
| Unused caches or logrotate stubs | Exact path/ownership and retention decision; no application data or open writer |
| Recovery artifacts | Retain until explicit retention/cleanup decision with independent recovery access verified |
| Persistent data, volumes, snapshots, backup keys | Excluded from routine identity cleanup; never prune/delete as a naming shortcut |

Hold the deployment lock, confirm accepted state and absence of active dependencies,
then review each exact entry before removal. Changed ownership/mount identity,
unknown content or missing visibility stops that entry. Never use wildcards or
recursive account-home deletion. Preserve historical Git/issues/inventory and backup
history. Recheck existing health/deployment verification afterward and record sanitized
outcomes. Cleanup is irreversible and is not implied by implementation approval.
