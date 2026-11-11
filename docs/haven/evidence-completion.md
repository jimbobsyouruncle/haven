# Haven evidence-based issue completion

[Root AGENTS.md](../../AGENTS.md#evidence-based-completion-and-epic-continuation) is the operating policy for `haven next`, `haven issue`, direct reviews and merged-PR reconciliation. This guide explains how to apply it; it does not manage the local launcher, grant permissions or replace implementation/closure approval.

## Review procedure

1. Read live issue/PR state, accepted owner dispositions and execution order. GitHub records workflow decisions; source/checks/receipts establish bounded technical facts. Identify changes since accepted review before inspecting completed work again. Closed issues with accepted completion are not reopened for stale checkboxes.
2. Identify the exact criterion and owning lifecycle stage. Search existing evidence before asking for tests. Review tested revision, coverage, provenance and relevant implementation/configuration changes. An aggregate green check proves configured executed gates, not all runtime behavior. Invalidated or missing mandatory coverage needs a specific reason and the smallest additional observation.
3. Present only relevant changes and unresolved gates in a compact table: criterion/stage, evidence, revision, sanitized environment/time, observed outcome, gate classification and owner/action. Use VERIFIED, REQUIRED NOW, REQUIRED LATER, OPTIONAL or NOT APPLICABLE separately from PASS, FAILED, WARN, SKIPPED, NOT VERIFIED, PENDING and raw GitHub conclusions. Do not turn unsuccessful mandatory security controls into accepted completion.
4. Distinguish PR head, synthetic merge, actual merge and deployed revisions. Explain why unchanged behavior supports evidence reuse. Keep implementation readiness, PR readiness, merge readiness, deployment readiness, operational verification, cutover readiness, issue closure and epic closure distinct. Current-head PR checks cannot be replaced by historical results.
5. Select the next open unblocked issue in approved order. Operational cutover decisions belong to their execution issue; accepted development can remain completed. Assess all children and epic-wide gates when closure is plausible, not on every invocation. Present the appropriate Implementation, Cutover or Closure Card. Approval for one stage does not authorize merge, deployment, cutover or closure.
6. For REQUIRED NOW, give the criterion, reviewed evidence, insufficiency, technical risk, minimal owner action, expected sanitized evidence and clearing condition. Otherwise state `OWNER ACTION GATE: CLEAR`. Do authorized remote reads yourself; never require private identifiers, endpoints, usernames or raw configuration/logs. Unchanged worker operation needs no fresh test absent an affected contract or mandatory gap.
7. Review mode makes no working-tree/Git changes or issue mutations. Explicit reconciliation authorization permits bounded issue updates, not implementation or operations. Preserve historical comments/evidence, update dispositions in place, compare live body before writing and skip identical updates. Use stable decision references, responsible roles, evidence, next action and reconsideration conditions. Repeated unchanged reviews produce no duplicate updates/comments.

## What existing evidence proves

| Source | Valid coverage | Limits |
| --- | --- | --- |
| Security & SAST Checks and reusable Validate sources | The jobs/steps actually executed at the recorded test revision, including offline backup/restore fixtures and configuration checks | Fixture restores do not prove recovery of production data; conditional Hermes smoke may be SKIPPED when its path detector establishes inapplicability. Inspect the gate and detector rather than demanding a manual rerun. |
| Agent context checks | Generated maps match the tested source with the pinned generator | No deployment or runtime claim |
| Deploy Control Plane | Validation and synchronous remote installation/health gates that actually succeeded for the requested SHA on the configured target | Post-deploy verification is asynchronous and warning-only at scheduling time; workflow success does not prove its eventual result. Documentation-only pushes may not trigger this workflow. |
| Post-deploy receipt and latest corresponding verifier log | Recorded workflow conclusions, matching deployed checkout HEAD, and individual backup-log/readability/tile gates that executed | No backup execution, restic integrity check or restore; no complete inventory of required PR checks. Host DAC readability does not prove the container's actual mounts/identity. |
| Existing owner-recorded backup/check/restore result | The operation, snapshot, scope, environment and time identified by the result | Do not generalize a sampled check to a full audit or a scratch restore to a production recovery/RTO test. Do not rerun it without a concrete coverage/freshness gap. |

The workflows currently rely on check/job/step results and summaries; they do not upload a dedicated issue-completion artifact. The verifier already supplies schema-v2 JSON with `sha`, `head`, `at`, `app_dir`, `run_ids`, overall verdict and per-gate `required`, `state`, `reason`, plus legacy-compatible fields. These existing sources are sufficient for bounded claims when correlated. No new evidence service, manifest, schema or workflow is needed for this policy.

The receipt has no explicit environment identifier or workflow names/attempts. Establish provenance from the authorized deployment target and run metadata. Its `workflow_runs` gate checks the API-returned runs, not an independently enumerated required-check set; reconcile required PR checks separately. `at` identifies receipt publication, not the time of every underlying probe. Files are keyed by SHA and replaced on retry, so compare the latest log and receipt timestamp: a failed publication can leave an older receipt. A legacy PASS without gate coverage proves only the known executed gates. Missing optional JSON can be compensated by sufficient matching log/run evidence; neither an old receipt nor exit 0 converts WARN into PASS.

See [backup coverage and ownership](../../backup/README.md#post-deploy-verification-coverage-and-receipt-ownership) and [deployment verification](../../deploy/README.md#post-deploy-verification-after-the-workflow-has-finished). Proposed architectural gates remain requirements, not implemented features; preserve [approved decisions](DECISIONS.md).

## Minimal owner commands when access is genuinely missing

First use authorized GitHub reads yourself. For example, inspect the specific run with `gh run view RUN_ID --repo jimbobsyouruncle/hybrid-ai --json headSha,event,status,conclusion,jobs`. Resolve the actual run ID; do not hand the owner an unnecessary GitHub task.

If only the owner can access an existing runtime receipt, resolve the exact full SHA and data directory from already authorized evidence. Supply concrete values in the final command, not these placeholders. On the identified deployment host, an authorized administrator can inspect a bounded, content-free projection:

```sh
sudo jq '{schema_version,sha,head,at,verdict,rc,run_ids,gates}' /CONFIRMED_DATA_DIR/hermes_data/deploy-verdicts/FULL_SHA.json
```

Expected: matching `sha`/`head`, appropriate timestamp and PASS for each required gate; assess optional WARN/SKIPPED against the criterion. This reads existing evidence and starts no test. Use `sudo` only if reading that confirmed path requires it. Ask for only the approved metadata needed, never receipt paths, raw logs or payloads that would expose private information to an unapproved inference provider. If environment provenance is unknown, identify that gap before suggesting a host command. Commands that rerun a verifier, restore or deployment are separate operations, not automatic follow-ups to a missing receipt.

## Regression scenarios

These synthetic review cases are the policy regression suite. Exercise input → expected decision during review; they do not claim automated proof of agent reasoning. Use the existing offline suites below for underlying verifier behavior, not a new framework or a fake prose-matching test. No real backlog identifiers or current operational state belong in this suite.

| Case | Synthetic input | Expected decision / regression failure |
| --- | --- | --- |
| R01 | Closed task ALPHA has accepted completion evidence and stale unchecked criteria | Preserve accepted completion; reconcile stale text only if authorized. Reopening/retesting solely for checkboxes fails |
| R02 | Owner accepted ALPHA completion; optional cleanup remains | OPTIONAL cleanup, no completion blocker; decision remains scoped and cannot waive failing mandatory security |
| R03 | Current-head CI/SAST PASS covers development criteria; no deployment required | VERIFIED development, deployment NOT APPLICABLE with reason; no redundant owner tests |
| R04 | Deploy succeeds; separate optional verifier probe WARN/SKIPPED | Preserve deployment result and warning scope; no universal runtime PASS or automatic backup failure |
| R05 | Mandatory live-auth criterion lacks matching evidence | REQUIRED NOW at operational stage, NOT VERIFIED; list reviewed evidence, insufficiency, risk, minimal observation and clearing condition |
| R06 | Owner attests existing worker operation; unchanged source contract/offline coverage | Reuse bounded attestation, no private instance/endpoint/host/username request; do not invent a fresh integration PASS |
| R07 | ALPHA completed; BETA is next open issue with resolved dependencies | Select BETA; no full completed-issue or epic audit without invalidation signal |
| R08 | Development complete; cutover and post-cutover observations separately owned | Preserve development; future-stage gates REQUIRED LATER; present Cutover Card when cutover is current |
| R09 | PR current-head check fails due to change, then correction pushed | Diagnose, local validation, rerun current-head checks; older green results cannot promote; mark Ready when applicable checks pass |
| R10 | External CI outage persists at same head | At most two evidenced transient retries per failure/head, bounded by workflow timeout; report exact blocker and keep Draft while required checks missing |
| R11 | Read-only next/architecture review starts on dirty/diverged checkout | Remote metadata reads only; no pull/merge/reset/rebase/branch/commit/source edits, no issue writes absent authorization; preserve local work |
| R12 | Authorized reconciliation repeated with unchanged evidence/body | Compare current disposition and skip writes; no new comment or timestamp-only body churn; report no change |
| R13 | Evidence artifact expires but surviving job/owner records cover criterion | Reuse sufficient evidence; expiration alone does not force new tests |
| R14 | Relevant integration/configuration changed after accepted observation | Identify invalidated criterion and smallest mandatory verification; operational execution still needs authorization |
| R15 | Required gate SKIPPED/WARN, cancelled/neutral or timed_out | Preserve raw observation; cannot label VERIFIED without other valid coverage; only queued/running remains PENDING |
| R16 | All required children resolved; epic acceptance or security gate remains unmet | No epic closure; identify owning gate. Otherwise present Closure Card and await separate approval |
| R17 | Receipt SHA/head differs, provenance is unknown or an older receipt survives failed publication | NOT VERIFIED for affected runtime claim; inspect matching existing evidence before requesting new execution |
| R18 | Receipt PASS but a required PR check is absent | Receipt cannot establish the missing check; retrieve current-head evidence or report the exact PR-readiness gap |

Review acceptance requires checking all cases against the final policy, including negative outcomes. This suite is reusable across epics. It does not execute the external launcher or mutate GitHub.

Local executable coverage: `bash scripts/test-run-post-deploy-verify.sh`, `python3 status/test_deploy_verification.py`, and `bash scripts/test-doctor-post-deploy-log.sh`. These are offline fixtures, not production backup/restore verification. Run map freshness and its fixtures with the workflow-pinned generator, whitespace/local-link checks and applicable required PR CI/SAST. Rollback is a reviewed documentation revert; no runtime rollout is required.
