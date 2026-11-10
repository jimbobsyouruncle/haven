# Haven evidence-based issue completion

[Root AGENTS.md](../../AGENTS.md#evidence-based-completion-and-epic-continuation) is the operating policy for `haven next`, `haven issue`, direct reviews and merged-PR reconciliation. This guide explains how to apply it; it does not manage the local launcher, grant permissions or replace implementation/closure approval.

## Review procedure

1. Read the issue's acceptance criteria, phase, dependencies, linked PRs and owner-approved deferrals. Inspect actual source and merge records. Record implemented, merged, deployed, runtime-verified and completed separately. Use unknown where evidence is unavailable; a closed checkbox or issue is not a test result.
2. Inspect existing evidence before requesting anything new: required checks and constituent jobs/steps, tested revision, workflow conditions, deployment results, artifacts where available, and existing verifier receipts or owner-recorded results within the task's data permissions. An aggregate green check proves its configured gates, not every possible test. Check required-check configuration where accessible; report unavailable requirements without guessing.
3. Produce a compact criterion table: criterion/phase; evidence reference; tested SHA; environment and time; observed coverage; status; outstanding action/owner. This is a review presentation, not a new persisted receipt schema. Use the statuses defined in AGENTS.md and retain raw GitHub conclusions. Separate execution status SKIPPED from a justified NOT_APPLICABLE criterion. WARN is not a clean PASS; assess which criterion its qualification affects. A required unsuccessful or missing result remains blocking.
4. Explain revision relationships. PR checks may test a synthetic merge SHA; a squash merge has a different SHA. Record the PR head and tested merge revision, actual merge commit and deployed SHA when relevant. Source/merge comparison can establish unchanged coverage for issue review; it cannot satisfy current-head PR readiness with older checks. A runtime result applies to its named environment, revision and observed configuration, not every host or later deployment.
5. Reconcile every linked issue against its own criteria, including merged PRs whose issues remain open. Recommend closure only when evidence satisfies that issue's required gates. Otherwise identify the exact unmet criterion and its owner/phase. Preserve accepted later-phase deferrals and epic #146's accepted #147 audit disposition. Present the appropriate issue/epic Closure Card and await separate owner approval before changing tracking.
6. Request only the smallest observation still missing. Name the criterion or concrete risk that warrants runtime verification. State why existing evidence is insufficient and what would invalidate reusable evidence. Documentation and development-only criteria normally need no production checks. Never turn a later deployment/cutover gate into a prerequisite for an already completed development phase.

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

These review cases exercise policy decisions. Existing executable suites test the underlying verifier and display behavior; prose assertions would not prove that an agent reasons correctly.

| Scenario | Expected review outcome |
| --- | --- |
| Documentation PR has required current-head CI/SAST PASS; no deployment run | Development criteria satisfied; deployment NOT_APPLICABLE with reason; no production commands |
| Merged PR passes applicable checks; linked issue remains open | Reconcile every criterion; recommend closure if all satisfied; await owner approval; do not mutate issue |
| PR merged but acceptance explicitly requires live authentication behavior | Implemented/merged can be established; runtime criterion remains outstanding until matching evidence exists |
| Hermes smoke SKIPPED because unchanged paths exclude the image | Preserve SKIPPED execution; criterion NOT_APPLICABLE only after verifying detector/scope; no redundant manual smoke |
| Optional backup probe SKIPPED and verifier WARN/exit 0 | Optional coverage gap recorded; no clean PASS and no conclusion that backups failed |
| Required gate SKIPPED, missing, WARN, or wait TIMEOUT | Criterion blocked; TIMEOUT retains its original result and is not PENDING forever |
| Check cancelled, neutral, or queued/running | Preserve conclusion; cancelled/neutral are not PASS; queued/running is PENDING |
| Receipt SHA/head mismatch, wrong environment, or stale receipt after failed publication | No valid proof for the requested runtime claim; inspect existing corresponding evidence before rerunning anything |
| Receipt PASS but required PR check is absent | Receipt does not establish that missing check; retrieve matching check evidence or report the gap |
| Restore already evidenced for a named snapshot/environment; verifier cannot query tile | Restore evidence remains valid; isolate tile coverage gap; no repeated restore |
| Artifact expired but surviving job results/owner evidence cover the criterion | Reuse sufficient surviving evidence; expiration alone does not require repeating tests |
| Relevant backup configuration changed after the accepted restore | Explain which restore claim is invalidated and the minimum justified verification; obtain operational authorization before execution |
| Issue closed but a concrete acceptance criterion lacks evidence | Report the outstanding criterion and recommend a tracking correction; do not automatically reopen |
| Accepted development work has tracked, owner-approved later cutover verification | Preserve phase completion and successor ownership; do not reopen the earlier issue solely for the later gate |

Local executable coverage: `bash scripts/test-run-post-deploy-verify.sh`, `python3 status/test_deploy_verification.py`, and `bash scripts/test-doctor-post-deploy-log.sh`. These are offline fixtures, not new production backup/restore verification. Rollback of this policy is a reviewed documentation revert; it requires no runtime rollout.
