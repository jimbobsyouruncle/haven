# Automatic deployment design and activation acceptance

This is a proposed implementation contract, not an enabled workflow. Current
`deploy.yml` accepts manual exact-main dispatch with explicit production assent.
Keep it available for recovery/deliberate redeployment during preparation.

## Trusted revision selection

Prefer a production orchestrator reacting to trusted successful validation for a
main push, with an independent manual dispatch path. Bind repository numeric ID
`1380300964`, full name `jimbobsyouruncle/haven`, event type, main ref, workflow
identity and `head_sha`. Never trust PR/fork `workflow_run` artifacts or execute
their downloaded scripts with secrets. Candidate code comes from the exact
approved main SHA with checkout credentials disabled.

At inspection, effective main rules require `Check agent context maps` and
`Security & SAST gate` from GitHub Actions integration `15368`, plus deletion and
non-fast-forward restrictions. Strict up-to-date checking is false. No required
PR/review rule was returned by that branch-rules read. Thus “protected-main
merge” provenance cannot be inferred merely from main ancestry or a green check.
The implementation must verify a merged PR association and its actual merge
revision, or stop automatic deployment when that proof is absent. Any desired
ruleset strengthening requires separate owner authorization; do not change it
implicitly. Manual approved redeploy can use the existing exact-main contract.

Re-run required validation/SAST against the actual main commit; earlier PR head
or synthetic merge checks alone are insufficient. Validate workflow identity,
trusted app ID, status `completed`, conclusion `success`, and full SHA; duplicate
same-name or ambiguous checks refuse. Enumerate all applicable required checks,
including ARM64 publication/smoke when image inputs changed. No raw cancelled,
skipped, neutral, timeout or missing required check becomes success.

The map-refresh workflow currently can push a bot branch and merge its PR with
GITHUB_TOKEN. Such a merge may suppress downstream push events. Decide explicitly
in the CD issue how the orchestrator observes it: a trusted completion/reconcile
path can select the latest main commit, run its exact-SHA checks and verify its
merged-PR association. Never add another auto-merge capability or change that
workflow to bypass required checks. If no safe observation exists, report a
missed-deploy blocker; do not claim every main merge is covered.

## Serialization and overlapping merges

Use a single production concurrency group for automatic and manual paths with
`cancel-in-progress: false`. GitHub concurrency may replace pending runs; define
this deliberately as latest-successful-main coalescing, never promising every
intermediate commit deploys. A superseded candidate exits before connecting to
production. Re-read main after validation and immediately before remote trigger;
if changed, requeue/reconcile the latest eligible revision. Once remote mutation
begins, do not cancel it because a newer merge arrived.

Host exclusivity remains authoritative. Both entrypoints use the same canonical
lock; the migration holds both old and new locks until old entrypoints are
disabled. No parallel “manual recovery” deployment path. The next transaction
must reconcile the previous protected journal before any new install.

Root post-deploy verifier acceptance remains asynchronous but mandatory. The
orchestrator waits for accepted journal state tied to requested/installed SHA,
fresh root evidence, schema version and all required gates PASS. Do not trust
only the service-account-writable public receipt. A unit exit or scheduled
verifier is insufficient. Bound wait time to documented host/workflow deadlines;
timeout is failure/pending recovery, never readiness. Avoid a verifier waiting
for the orchestrator that itself waits for verification: checks consumed by the
host verifier must exclude its own waiting deployment run.

Runner cancellation/disconnect cannot kill host recovery or create a second
transaction. The next run first reconciles host state; failed/missing acceptance
blocks it. Do not automatically restore a database or retry partially activated
code. Immutable proxy recovery and fail-closed provenance gates remain required.

## Inert preparation and explicit activation

Prepare candidate logic and fixture tests without attaching it to a production
trigger or executable deployment job. A disabled-looking job with a mutable
variable is not a sufficient activation boundary. Keep the candidate outside
active production workflows until separate owner authorization of an exact
reviewed activation diff and canonical runtime acceptance. No secrets/settings
change is authorized by this packet.

Activation acceptance requires:

- Canonical identity cutover and runtime gates accepted; architecture/security
  review and current-head CI/SAST passed, no blocking findings.
- Tests reject fork, wrong repository/app/workflow, PR-only SHA, unmerged main
  commit, stale checks, failed/skipped checks, missing immutable image,
  superseded revision and unaccepted previous transaction.
- Race tests cover two merges, a manual dispatch during automation, cancellation
  before/after SSH, timeout, failed asynchronous verifier and interrupted host
  activation. No duplicate stack or concurrent deploy.
- Owner-authorized activation followed by a real protected-main PR merge with
  exact deployed SHA, fresh mandatory PASS receipt and accepted journal.
- Demonstrated manual recovery/redeploy and restart behavior. Independent backup
  and old/new restore remain successful. Sanitized records link full SHA,
  workflow/run, time, non-sensitive environment and observed outcome.

If any criterion fails, fence automatic entry, keep manual owner recovery and
report the precise failure. Reverting activation prevents future triggers; it
does not undo a running transaction or restore production. Never merge, activate,
change settings/secrets or deploy as part of preparing this specification.
