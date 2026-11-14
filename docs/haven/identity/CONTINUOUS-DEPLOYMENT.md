# Restore automatic deployment through the existing workflow

Approved architecture: extend `.github/workflows/deploy.yml` and the existing
restricted SSH/host deployment mechanism. Current source remains manual dispatch;
this revision changes no workflow or production state. Detailed trigger wiring is
an implementation proposal for the third cohesive PR, not a new orchestration layer.

## Trusted validation and exact SHA

A main-branch event runs trusted repository validation/SAST for that exact commit
before the existing deployment job can access production credentials. Reuse the
existing reusable validation and required checks, including applicable image/ARM64
gates. PR-head or synthetic merge results alone do not validate an actual main SHA.
Pin checkout to the full validated SHA with persisted credentials disabled. Preserve
SSH host fingerprint pinning, strict `deploy <40-lowercase-hex>` grammar, host
main-provenance checks and immutable recovery preflight. Never deploy fork/PR
artifacts or scripts with secrets.

Observed main rules in the original PR #201 review required two checks but did not
require a PR. Main ancestry alone therefore does not establish a merged PR. Validate
merged-main provenance for the automatic path; retain the existing owner-dispatched
exact-main recovery path. Do not add branch settings changes, administrative bypasses
or recurring human approval requirements. Required missing/failed/skipped/ambiguous
validation blocks deployment; verify trusted workflow/app identity and SHA.

## Serialization and mandatory acceptance

Keep the existing shared `deploy-control-plane` concurrency group with
`cancel-in-progress: false` for manual and automatic execution. GitHub can replace
pending runs; intermediate commits need not each deploy. Check candidate eligibility
before the remote trigger and allow an already started host transaction to complete.
No custom coalescing scheduler or reconciliation service is needed.

The host deployment lock remains authoritative, including recovery. During identity
handoff hold old/new locks until stale entrypoints are disabled; do not create a
parallel manual path. A later deployment must refuse unresolved or unaccepted prior
state, using ADR-0006's existing recovery procedure.

Wait, with bounded host/workflow deadlines, for existing protected root acceptance:
requested SHA equals installed SHA, matching receipt and all mandatory gates PASS.
Successful dispatch, SSH or unit exit alone is insufficient. Keep existing async
verification and ensure its workflow evidence check excludes the deployment job
waiting for it, avoiding self-wait. Timeout/cancellation/disconnect never counts as
acceptance or permission to replay an interrupted transaction. No new receipt
framework or second verifier is required.

## Existing automation interaction

The map-refresh committer uses GITHUB_TOKEN, whose bot merges can suppress push
workflows. Prefer a bounded explicit dispatch of the same validation/deployment
workflow for the exact merged map revision, if needed and reviewed in the third PR.
It must pass the same trust/SHA/validation gates; add no auto-merge capability and
change no required checks. A map-only revision may instead be explicitly documented
as deployment-neutral with evidence that runtime inputs are unchanged. Resolve and
test this exact event boundary in that PR; do not invent a background reconciliation
service or claim untested every-merge coverage. This documentation push does not
trigger the main-only committer or production deployment.

## Preparation, activation and tests

Prepare and test the existing workflow changes in the third PR without enabling
production triggers through an ordinary preparatory merge. The exact activation
change can be reviewed in that same PR; no additional activation PR or approval
bureaucracy is required. Applying/enabling it requires owner production authorization
after canonical runtime acceptance. No repository settings/secrets change is implied.

Test wrong repo/fork/event, unmerged or stale SHA, failed/missing checks, missing
image, manual/automatic overlap, cancellation/disconnect, verifier timeout/failure
and interrupted host recovery using existing fixtures. Required current-head CI/SAST
must pass. After separately authorized activation, acceptance needs one real trusted
main merge deployed at the exact validated SHA with mandatory verification and the
manual recovery path retained. Reuse prior recovery evidence when unchanged.

Disable automatic entry on a concrete acceptance failure; keep bounded manual
recovery under the same lock. Reverting trigger wiring stops future runs, not an
in-flight transaction, and does not restore data. No merge, deployment, activation,
settings/credential change or live test is performed in this revision.
