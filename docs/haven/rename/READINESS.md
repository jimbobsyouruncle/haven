# HAVEN-003 readiness and cutover handoff

Issue #149; epic #146. This is the owner-approved **public-source documentation
portion** of readiness preparation. It does not complete #149, authorize #150,
or attest to current production state. No host, backup, credentials, external
integration settings or worker repository were accessed. GitHub rule metadata
was read without changing settings. The source reviewed is public
`main` at `93f1c6b3a414b25c94090b10e858c9d6e8f91c05` (reviewed 2026-11-11 UTC).

## Acceptance and existing evidence

The owner accepted #147 as completed public-source audit. Keep it closed.
The immutable baseline contains 4,453 occurrences, including 125 manual-review
records. Later decisions supplement that baseline; they do not rewrite it.

| #149 acceptance criterion | Evidence / remaining requirement | Status |
| --- | --- | --- |
| Required CI, SAST, tests and maps pass | Final-head checks for #155/#157/#159/#162/#163 below; this reconciliation PR must obtain its own checks | PASS for listed revisions; current PR evidence belongs in its description |
| Deployment smoke and worker integration checks documented | Successful synchronous deploy workflows below; owner backup/restore evidence accepted; newer asynchronous verifier outcome and E15 worker contract/synthetic results missing | PENDING: live worker integration and remaining operational coverage; E04 VERIFIED within recorded scope |
| New URL dependencies identified and actions prepared | D01–D16, selector, all 125 manual-review dispositions and activation sequence below | Public-source preparation VERIFIED; external consumer attestations and exact selector propagation plan PENDING |
| Rollback and go/no-go reviewed | Procedure below; named operator, reviewed recovery artifacts, downtime threshold and owner acceptance still required | Prepared for review; no operational sign-off claimed |
| Preparation PR merged before #150 | #155/#157/#159/#162/#163 merged into main; this reconciliation PR remains a separate deliverable | VERIFIED for existing preparation merges; PENDING for this PR and any separately approved activation implementation |

| Work | Final PR head / merge | Executed evidence |
| --- | --- | --- |
| #147 audit, [PR #154](https://github.com/jimbobsyouruncle/hybrid-ai/pull/154) | `74eaf77e4f00803f807edc8c8d71a75a479568f3` / `ccd924d19ba898ebe6892088e6b44eeb65a7eb08` | [Map](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42682650732) and [SAST/source](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42682650838) passed; owner accepted public-source scope |
| #149 identity preparation, [PR #155](https://github.com/jimbobsyouruncle/hybrid-ai/pull/155) | `4f6d6464d4ca04e62db6ef5e9566aa0dbc29bf1e` / `a2a4863006d995c0b62ae882428fbb6d7e48b530` | [Map](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42694494676), [SAST/source](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42694494506) and [post-merge deploy](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42695975376) passed |
| #148 presentation, [PR #157](https://github.com/jimbobsyouruncle/hybrid-ai/pull/157) | `b5ffe9ae8ee371f443848259d9fc34c4aef1f22b` / `873b41610fc710cb2c8dcde8632f841709e89e2f` | [Map](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42703035002), [SAST/source](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42703034861) and [post-merge deploy](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42705394288) passed |
| #149 runbook, [PR #159](https://github.com/jimbobsyouruncle/hybrid-ai/pull/159) | `a015b279279cf340538e968d1a8544f153beac02` / `ba22a1b8751052e5bcd25d885a708c005cafb001` | [Map](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42714528099), [SAST/source](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42714528721) PASS; documentation deployment NOT_APPLICABLE |
| #160 auth probe, [PR #162](https://github.com/jimbobsyouruncle/hybrid-ai/pull/162) | `b91ca48e807382d648d00c86068da1942ab424c7` / `c126abc62e10c6953f4307ccd55e3aa75da63b2c` | [Map](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42860415665), [SAST/source](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42860415752) PASS; [deploy](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42868756044) success, 2026-11-10 17:48–17:59 UTC; explicit live auth-health criterion PENDING |
| #161 verifier, [PR #163](https://github.com/jimbobsyouruncle/hybrid-ai/pull/163) | `42bf3ffdb3fd6d2c9acdcb186f33f761ac7d03de` / `90e68ad30d7b148c84a4ad158a5b7e81f0684ab4` | [Map](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42916843574), [SAST/source](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42916843542) PASS; [deploy](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42918641980) success, 2026-11-10 22:53–23:07 UTC; asynchronous verifier outcome missing |

All listed PRs merged into `main`. PR heads and actual merge SHAs above are
different revisions; the deployment links identify the merge SHA they tested.
Do not use older PR results to satisfy this reconciliation PR's current-head
readiness. For #163 the queried synthetic merge revision
`b0642a0c403c09cedc5aed5933e451f0b86366f4` had no separately attached checks;
its actual merge revision has the successful deployment validation above.

These final-head SAST runs passed ShellCheck, Semgrep, CodeQL (Python/Actions)
and source validation, including offline fixtures and real Caddy/Compose
checks. Hermes non-root smoke was **skipped**, as permitted by the successful
existing change detector: no Hermes image inputs changed. No fresh ARM64
runtime evidence follows. No failed, cancelled or pending final-head checks
were returned in the planning review; earlier failing heads are not evidence
against the corrected final revisions.

The deploy runs above passed source validation and the Deploy over Tailscale
job, including reachability and deployment trigger. They do not establish
completion of E01–E20, a successful scratch restore, live worker integration,
or the later asynchronous post-deploy verifier result. Record that result
separately for the approved cutover revision. Do not repeat successful source
tests merely for redundant evidence.

## Occurrence reconciliation

The following **17 distinct manual-review records** have explicit decisions
in merged [COMPATIBILITY.md](COMPATIBILITY.md) and
[PRESENTATION.md](PRESENTATION.md). The supplemental
[MANUAL-DECISIONS.md](MANUAL-DECISIONS.md) reviews the other **108 records**,
with exact IDs, pinned source consumers, rationale, reviewer/date and phase
ownership. Together they account for all **125 records** without changing the
immutable baseline. Supplemental decisions require this PR's human review;
public-source preservation does not satisfy operational consumer gates.

| Decision register | Manual-review IDs | Disposition |
| --- | --- | --- |
| Presentation | A00198 | Rename README product heading |
| Presentation | A00202, A00203, A00237, A00295, A00296, A00306, A00314, A01361 | Retain operational examples, identities and pre-cutover repository reference |
| Compatibility | A02024, A02062, A02064, A02065 | Retain bootstrap account/diagnostic guidance |
| Compatibility | A00112, A00121, A00126, A00127 | Retain existing workflow image/test consumers |

The immutable inventory's **29 rename-class records** reconcile as follows.
IDs refer to baseline positions, not current line numbers.

| IDs | Disposition / remaining owner |
| --- | --- |
| A04442–A04444, A04446–A04448 | Six rendered labels changed in #157; rendering and compatibility assertions passed |
| A04441 | Diagnostic bundle heading explicitly retained by PRESENTATION.md as a compatibility interface |
| A02023, A02131–A02132, A02502 | Clone/fetch/API selection prepared in #155; old default remains; operational activation belongs to #150 |
| A02969, A03100, A03207–A03208, A03213 | Legacy bootstrap/deploy fixture expectations retained; explicit Haven cases added in #155 |
| A00199–A00200, A00235–A00236, A00366, A00967, A01362–A01368 | README badges/clone examples, SECURITY source link, deploy API example and architecture links retain the active slug; #150 owns reviewed canonical URL activation, #151 verifies links |

The supplemental register retains existing compatibility identities, derived
image terminology, attribution and current-clone guidance. It makes no
runtime edits. Clone/grant/documentation alignment is explicitly assigned to
#150/#151; registry, host and integration evidence stays in E01–E20.
No beyond-epic deferral or alias removal is approved. Keep baseline
`owner_issue` values as historical triage rather than rewriting the audit.

## Accepted backup evidence and operational limits

The [owner's #149 evidence](https://github.com/jimbobsyouruncle/hybrid-ai/issues/149)
identifies Pi `jarvis`, checkout/deployed SHA
`873b41610fc710cb2c8dcde8632f841709e89e2f`, and a 2026-11-09 verifier PASS.
That result has an explicit backup-log SKIPPED gate and Hermes ownership
warning; preserve those qualifications. It does not establish the newer
#163 verifier's system-mode mandatory log/readability/tile outcomes.

On 2026-11-10 capture/upload exited 0; snapshot `65235d97` was tagged
`complete:true`, with 20 databases. Sampled restic checks covered 5% of packs,
not a full-pack audit. The isolated scratch restore completed at 16:27:50Z:
4.006 GiB, 14,812 files/directories, 5m01s, **20/20 SQLite integrity checks**.
E04 is VERIFIED for that recorded completeness/integrity/restore scope.
No full bare-metal rebuild, application recovery or RPO/RTO guarantee follows.
Scratch-directory cleanup remains unconfirmed and is not a reason to rerun
restore. No relevant backup/capture/restore source changes are introduced by
#162, #163 or this documentation change. Reuse the evidence unless a concrete
changed configuration, contradictory result or required freshness invalidates
its specific claim. Historical failed deployments do not invalidate later
successful evidence.

#160's source probe correction and regression/CI evidence are complete, with
successful deployment automation; its explicit sustained live-health criterion
remains open. #161's development criteria are complete and owner-approved
closed; its matching live receipt remains readiness evidence, not a reason to
reopen the development issue. Neither issue is automatically a #148 blocker.

## Evidence collection and ownership

[EXTERNAL.md](EXTERNAL.md) is the authoritative E01–E20 request register.
Its owner roles are proposed responsibilities, not named assignments or access
grants. Each operator must receive separate authorization for their scope.
Capture only: evidence ID, named operator, UTC date, revision/artifact identifier,
pass/fail/pending/not-applicable with rationale, sanitized evidence link,
approver and next gate. Do not attach environment contents, raw remotes,
credential values, host logs or backup data. Restricted evidence must stay on
its approved inference/storage route; use a sanitized attestation here.

| Gate | Evidence IDs | Required handoff |
| --- | --- | --- |
| #149 preparation before #150 | E01–E05, E07, E09–E11, E13–E16, E18 | Pi/layout/units, rollback images, backup stability and restore, rules/checks, integrations, setting names/consumers, registry permissions, clones/workspaces, worker contract, TLS and external URL consumers |
| Before operational preparation merges | E06 | GitHub owner confirms actual production reviewer protection and approved freeze/resume procedure; environment declaration alone proves neither |
| #150 cutover | E08, E09, E12, E13, E17, E19; revalidate E07 | Target availability and stable repo ID; external URL changes, clone/selector alignment, paused automation, approved window and rollback operator |
| #151 verification | E07, E11, E14, E16, E20 | Required checks, registry/workspace/TLS operation, agreed observation interval, first successful backup and cleanup approval |

E04 scratch restore and E15 worker compatibility are explicit **hard gates**.
E04 already has the accepted bounded evidence above; do not repeat it merely
because an older register said pending. For E15 obtain a versioned owner-supplied API/auth/model/image/network
contract plus synthetic integration results, or authorize a separate worker
repository task. This documentation task does not access that repository.
Source fixtures do not substitute for either gate. The architecture's proposed
RPO/RTO and isolation guarantees are not established by this rename work.

## Automation and freeze plan

Source review of `.github/workflows/` at the revision above establishes:

- Feature-branch pushes do not run the main-only deploy, image publisher or
  map committer. PRs run validation/maps/SAST; changing draft state is not a merge.
- `deploy.yml` runs on eligible pushes to `main` and manual dispatch, excluding
  pushes containing only its ignored documentation/license/gitignore paths.
  It uses `environment: production`; actual reviewer protection needs E06.
- `sandbox-image.yml` auto-publishes on main changes to the agent-server
  Dockerfile; manual publication is a separate owner action. Preserve packages,
  immutable rollback digests and ARM64 availability rather than renaming images.
- `agent-context-committer.yml` runs on main and can create, dispatch checks for
  and squash-merge a bot map PR. Its no-op behavior does not replace a freeze.
- Required contexts observed on main are `Check agent context maps` and
  `Security & SAST gate`. Revalidate settings at cutover; preserve their names.

For #150 the owner must name a freeze/resume operator and authorize the exact
mechanism covering deployments, image publication, map bot, scheduled sync and
other external writers (E06/E17). First drain or explicitly resolve in-flight
runs and PRs; record main SHA and paused writers. Do not merely assume disabling
one workflow freezes other paths, and do not weaken required checks or review
rules. This PR performs no pause, dispatch, settings change or production action.
Resume only after approved smoke results and owner acceptance; preserve the
ledger of what was paused and restored.

## #150 activation sequence — separate operational approval required

1. **Go/no-go packet:** Require reviewed preparation merges, green applicable
   checks for the exact combined revision, accepted manual-review dispositions,
   E01–E18 evidence at their designated gates, named operators, approved window,
   downtime tolerance, rollback thresholds, recovery access and freeze receipts.
   Missing evidence means no-go. A closed issue or green PR alone is insufficient.
2. **Recovery baseline:** Record the known-good code SHA, installed standalone
   verifier revision, selected identity/override state, immutable image digests
   and verified backup/scratch-restore evidence. Keep host paths, accounts,
   units, volumes, snapshot tags, registry packages and Caddy certificate storage.
3. **Identity plan:** Review the exact propagation mechanism before the window.
   Bootstrap, root deployment service and transient verifier must agree on
   `HYBRID_AI_REPOSITORY_SLUG`; any deployment remote override must also agree.
   The selector is process-only: editing a layout file or exporting an SSH
   client variable does not configure these services. The current transient
   launch does not explicitly propagate the selector. Any required source or
   host configuration change needs separately reviewed and approved scope;
   do not claim this runbook implements propagation.
4. **Explicit owner go:** Record action, repository ID `1380300964`, target
   `jimbobsyouruncle/haven`, revision, operators and window before renaming.
   Confirm target availability, public visibility and default branch `main`.
5. **Rename and align:** The authorized operator renames the repository, verifies
   unchanged ID/history/default branch, then applies the reviewed activation
   plan to clone remotes, all selector consumers, overrides, canonical links,
   callbacks and other inventoried consumers. Preserve dirty work and old clones
   until verified. Do not reuse the old repository slug or rely on redirects.
6. **Check before resuming:** Verify new-URL clone/fetch, required checks and
   access with non-deploying CI first. Then perform only separately approved
   deployment, asynchronous verifier, worker, service, TLS and backup checks.
   Record exact revision/results, elapsed downtime and any stop decision.
7. **Handoff:** Owner accepts immediate results and authorizes automation resume
   and #151's observation interval. Transfer evidence and the action ledger;
   retain compatibility aliases until independently approved deprecation.

## Stop, rollback and #151 acceptance

Stop for repository-ID mismatch, missing required checks, inconsistent selector
consumers, inaccessible images, failed deployment/verifier/inference/backup
checks, unexpected mount/data changes, or the owner's downtime threshold.
An unset threshold or missing rollback operator is a pre-cutover no-go.

The named rollback operator follows the approved action ledger in reverse,
restoring the known-good code, installed verifier, identity configuration and
image digests while preserving working services and data. A documentation/code
revert does not undo external configuration. Renaming back, redeployment or
restoration of production data requires distinct owner authorization; none is
an automatic fallback. Never delete volumes, remove backups, rotate keys,
weaken checks or restore databases merely to repair a URL.

#151 must record fresh clone and PR/check behavior, branch rules, SAST,
Dependabot, maps/tests, approved build/publish/deploy evidence, asynchronous
verification, worker/Pi/integration/TLS results and the first successful backup
after cutover. Repeat the reference inventory separately from the immutable
#147 baseline, explain retained aliases, record incidents/rollback decisions
and finish the agreed sustained observation period. Only then evaluate all
five children and epic-wide acceptance. Beyond-epic deferrals require explicit
owner acceptance plus a successor issue, owner and milestone. Epic closure
still requires its own Closure Card and approval.

## Owner action gate and tracking handoff

| Classification | Action / expected non-secret evidence | Owner / phase |
| --- | --- | --- |
| VERIFIED | #147 audit; #148 presentation completion; #161 development completion; listed CI/deployment runs; bounded E04 backup/restore evidence | Existing public records; #148 and #161 closed with explicit owner approval on 2026-11-11 UTC |
| REQUIRED NOW | Review this documentation PR and supplemental source decisions; no host operation is required to validate this deliverable | Human PR reviewer / #149 development |
| REQUIRED LATER | Identify latest installed revision/environment and inspect existing matching verifier evidence: full sha/head, time, overall verdict and each required gate's state; confirm provenance before proposing a receipt-path command | Authorized Pi owner / #149 before #150; no rerun automatically requested |
| REQUIRED LATER | Supply versioned worker API/auth/model/image/network contract and synthetic integration results, or separately authorize a worker-repository task | Named worker owner still unassigned / E15, #149 hard gate |
| REQUIRED LATER | Complete remaining EXTERNAL.md preparation attestations; review exact selector propagation, recovery image availability, freeze/resume, downtime threshold and rollback ownership | Named operators/approvals still pending / #149–#150 |
| REQUIRED LATER | Record explicit #150 go/no-go, cutover receipts and #151 observation/first-backup results | Owner / #150 then #151 |
| OPTIONAL | Confirm cleanup of the accepted scratch restore directory; consider separate tracking/rules-policy corrections | Owner; no cleanup, settings change or issue mutation included here |

The development gate is CLEAR once this PR's applicable checks pass and human
review accepts the bounded deliverable. The operational gate remains NO-GO:
missing external readiness, worker and activation evidence is not waived.
Do not ask for credentials, raw private logs, another backup/restore or a new
deployment merely to refresh this document. Exact runtime commands require
confirmed paths/identity and separately authorized host scope first.

#148 and #161 were closed under separate explicit owner authorization; their
public issue bodies record completion and remaining phase limits. #149 remains
closed as found despite outstanding operational criteria. Reopening #149,
updating the epic checkboxes, linking native dependencies and assigning named
owners/milestones remain recommendations requiring separate approval; this
implementation changes no further issue metadata. GitHub's epic subissue list
returned empty during review; the issue-body sequence still governs:
#147 → #148/#149 → separately approved #150 → #151. Neither #146 nor #150
is complete. #147's accepted audit completion remains unchanged.

Rollback of this reconciliation is a reviewed documentation revert. It changes
no runtime state, permissions, workflow behavior or selector propagation.
