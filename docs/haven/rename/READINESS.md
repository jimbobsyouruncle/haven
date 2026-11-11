# HAVEN-003 readiness and cutover handoff

Issue #149; epic #146. This is the owner-approved **public-source documentation
portion** of readiness preparation. It does not complete #149, authorize #150,
or attest to production behavior beyond the bounded owner evidence below.
No host, backup, credentials, external
integration settings or worker repository were accessed. GitHub rule metadata
was read without changing settings. The source reviewed is public
`main` at `ba7045aab7be83e33f30186e07d5664b0fea91ea` (reviewed 2026-11-11 UTC).

## Acceptance and existing evidence

The owner accepted #147 as completed public-source audit. Keep it closed.
The immutable baseline contains 4,453 occurrences, including 125 manual-review
records. Later decisions supplement that baseline; they do not rewrite it.

| #149 acceptance criterion | Evidence / remaining requirement | Status |
| --- | --- | --- |
| Required CI, SAST, tests and maps pass | Final-head checks for #155/#157/#159/#162/#163/#165/#166/#167/#168/#169/#170 below; this reconciliation PR must obtain its own checks | VERIFIED for listed revisions (executed checks PASS); current PR evidence belongs in its description |
| Deployment smoke and worker integration checks documented | Successful synchronous deploy workflows below; owner backup/restore evidence accepted; historical #166 verifier FAIL (required tile SKIPPED); #168 owner receipt also FAIL (required tile SKIPPED through HTTP/TLS/login redirects); private transport correction #170 has successful deployment automation and owner-confirmed installed HEAD; its matching owner-supplied schema-v2 receipt records PASS at 18:14:41Z for every required gate; E15 satisfied for rename preparation under the owner-approved disposition below | VERIFIED for documented deployment and E15 rename preparation; remaining operational packet PENDING; E04 VERIFIED within recorded scope |
| New URL dependencies identified and actions prepared | D01–D16, selector, all 125 manual-review dispositions and activation sequence below | Public-source preparation and deploy-to-verifier selector handoff implemented; external attestations and host activation review PENDING |
| Rollback and go/no-go reviewed | Procedure below; named operator, reviewed recovery artifacts, downtime threshold and owner acceptance still required | PENDING operational review; no sign-off claimed |
| Preparation PR merged before #150 | #155/#157/#159/#162/#163/#165/#166/#167/#168/#169/#170 merged into main; this reconciliation PR remains a separate deliverable | VERIFIED for existing preparation merges; PENDING for this PR and any separately approved activation implementation |

| Work | Final PR head / merge | Executed evidence |
| --- | --- | --- |
| #147 audit, [PR #154](https://github.com/jimbobsyouruncle/hybrid-ai/pull/154) | `74eaf77e4f00803f807edc8c8d71a75a479568f3` / `ccd924d19ba898ebe6892088e6b44eeb65a7eb08` | [Map](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42682650732) and [SAST/source](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42682650838) passed; owner accepted public-source scope |
| #149 identity preparation, [PR #155](https://github.com/jimbobsyouruncle/hybrid-ai/pull/155) | `4f6d6464d4ca04e62db6ef5e9566aa0dbc29bf1e` / `a2a4863006d995c0b62ae882428fbb6d7e48b530` | [Map](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42694494676), [SAST/source](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42694494506) and [post-merge deploy](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42695975376) passed |
| #148 presentation, [PR #157](https://github.com/jimbobsyouruncle/hybrid-ai/pull/157) | `b5ffe9ae8ee371f443848259d9fc34c4aef1f22b` / `873b41610fc710cb2c8dcde8632f841709e89e2f` | [Map](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42703035002), [SAST/source](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42703034861) and [post-merge deploy](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42705394288) passed |
| #149 runbook, [PR #159](https://github.com/jimbobsyouruncle/hybrid-ai/pull/159) | `a015b279279cf340538e968d1a8544f153beac02` / `ba22a1b8751052e5bcd25d885a708c005cafb001` | [Map](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42714528099), [SAST/source](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42714528721) PASS; documentation deployment NOT_APPLICABLE |
| #160 auth probe, [PR #162](https://github.com/jimbobsyouruncle/hybrid-ai/pull/162) | `b91ca48e807382d648d00c86068da1942ab424c7` / `c126abc62e10c6953f4307ccd55e3aa75da63b2c` | [Map](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42860415665), [SAST/source](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42860415752) PASS; [deploy](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42868756044) success, 2026-11-10 17:48–17:59 UTC; later [owner-accepted live auth evidence](https://github.com/jimbobsyouruncle/hybrid-ai/issues/160#issuecomment-6798231892) completes #160 within the scope below |
| #161 verifier, [PR #163](https://github.com/jimbobsyouruncle/hybrid-ai/pull/163) | `42bf3ffdb3fd6d2c9acdcb186f33f761ac7d03de` / `90e68ad30d7b148c84a4ad158a5b7e81f0684ab4` | [Map](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42916843574), [SAST/source](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42916843542) PASS; [deploy](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42918641980) success, 2026-11-10 22:53–23:07 UTC; asynchronous verifier outcome missing |
| #149 evidence reconciliation, [PR #165](https://github.com/jimbobsyouruncle/hybrid-ai/pull/165) | `937bc0f595b781c46dc2f8cd4adf31e5bddeb00e` / `58e9dfd053864c5999652c7a20542bd23a104179` | [Map](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42948515870), [SAST/source](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42948515887) PASS; merged 2026-11-11 11:21 UTC; documentation deployment NOT_APPLICABLE |
| #149 selector handoff, [PR #166](https://github.com/jimbobsyouruncle/hybrid-ai/pull/166) | `0f6af3fc815d9268b1253241d966771acecf13bd` / `5e641a118db8154c6c753f8365d2b7526aa75273` | [Map](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/43023135406), [SAST/source](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/43023135591) PASS; merged 2026-11-11 13:26 UTC; [deploy](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/43029110310) success, 13:26:15–13:39:37 UTC; matching asynchronous verifier outcome FAIL: required tile SKIPPED; see owner evidence below |
| #149 evidence reconciliation, [PR #167](https://github.com/jimbobsyouruncle/hybrid-ai/pull/167) | `6f46fe382307c05b1827f33ce0edda31f80c37f5` / `c1fb4dd971255cde40f04d462e8abb73f0782b5d` | [Map](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/43038844945), [SAST/source](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/43038844417) PASS; merged 2026-11-11 14:50:47 UTC; documentation deployment NOT_APPLICABLE |
| #149 verifier domain resolution, [PR #168](https://github.com/jimbobsyouruncle/hybrid-ai/pull/168) | `689e0ec8b9660cb3cdc134226ddc89365ee68a28` / `681c961c68e8b2e98cbafd39a2c671acca36558e` | [Map](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/43049003890), [SAST/source](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/43049003583) PASS; merged 2026-11-11 15:57:47 UTC; [deploy](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/43053540322) success, 15:57:51–16:08:35 UTC; matching owner receipt at 16:09:33Z FAIL: required tile SKIPPED through HTTP/TLS/login redirects |
| #149 evidence reconciliation, [PR #169](https://github.com/jimbobsyouruncle/hybrid-ai/pull/169) | `0db6273106550635af2749f888759665262e525a` / `29a11b0aac264a33d40667b78c0203d0eaa9ff7f` | [Map](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/43056856053), [SAST/source](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/43056856244) PASS; merged 2026-11-11 16:28:33 UTC; documentation deployment NOT_APPLICABLE |
| #149 private Backups transport, [PR #170](https://github.com/jimbobsyouruncle/hybrid-ai/pull/170) | `63c0ed7d3ee8ffc730b8bb2c8efa9c6f0c55ec18` / `c81eb3e69ae9c26ef8e80e34c15a2a5eb02f2612` | [Map](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/43071531003), [SAST/source](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/43071530988) PASS; merged 2026-11-11 18:02:12 UTC; [deploy](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/43073883258) success, 18:02:15–18:13:45 UTC; owner confirmed installed HEAD on jarvis; owner-supplied asynchronous receipt PASS at 18:14:41Z; see bounded evidence below |

All listed PRs merged into `main`. PR heads and actual merge SHAs above are
different revisions; the deployment links identify the merge SHA they tested.
Do not use older PR results to satisfy this reconciliation PR's current-head
readiness. For #163 the queried synthetic merge revision
`b0642a0c403c09cedc5aed5933e451f0b86366f4` had no separately attached checks;
its actual merge revision has the successful deployment validation above.
For #166, the synthetic PR merge revision
`c7520d1c11feb848c3a8a0d95384938d700ade5f` is distinct from its actual
merge SHA. The deployment run identifies the actual merge SHA. Its successful
synchronous validation/deploy result does not independently identify the latest
installed host state or establish an asynchronous verifier PASS.

These final-head SAST runs passed ShellCheck, Semgrep, CodeQL (Python/Actions)
and source validation, including offline fixtures and real Caddy/Compose
checks. Hermes non-root smoke was **skipped**, as permitted by the successful
existing change detector: no Hermes image inputs changed. No fresh ARM64
runtime evidence follows. No failed, cancelled or pending final-head checks
were returned in the planning review; earlier failing heads are not evidence
against the corrected final revisions.
In particular, #166's earlier SAST/source run failed at head
`bfb502e526b281baebfe325dbb5726759e12403b`; the final head supplies the
missing identity helper to the existing timer fixture and passed. Hermes smoke
remains SKIPPED, with its execution criterion NOT_APPLICABLE to these unchanged
image inputs; it is never counted as an executed PASS.

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
immutable baseline. Supplemental decisions were reviewed and merged in #165;
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

## Source selector handoff (#149)

The merged selector-handoff change (#166) validates the deployment process's
allowlisted repository identity before reading layout files or mutating the
host, then explicitly passes that identity into the asynchronous verifier's
transient unit. Offline fixtures cover the unset legacy default, both explicit
identities, invalid/empty inputs before deployment side effects, exact launch
arguments and the existing warning behavior when scheduling fails. The shared
identity suite also checks all four consumers against its invalid-input matrix.

This source preparation does not configure the root service, activate Haven,
change remote-override precedence or establish live verification. See the
activation sequence below and [deployment guidance](../../../deploy/README.md#haven-repository-identity-preparation-149).
Review rollback as a source revert; any installed-revision rollback or service
configuration change needs separate operational approval. Reverting this
handoff removes explicit selector forwarding and must be assessed before any
post-cutover rollback. Existing backup/restore evidence remains valid.

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

#160 is owner-approved completed and closed. The
[completion record](https://github.com/jimbobsyouruncle/hybrid-ai/issues/160#issuecomment-6798231892)
accepts the documented placeholder-probe cause, source fix/regressions, successful
CI/deployment automation, and sanitized owner observations on `jarvis`: two
healthy inspections over two minutes apart with failing streak 0, the effective
Python IPv4 loopback probe, independent HTTP 200 and normal gated browser access.
The observed image is
`sha256:731e6f1a8876a58cf99577d1a28332740e001170006bfca94c4c3f1fe34357bc`.
Those runtime observations identify the image, not an independently established
source SHA; exact observation timestamps were not supplied. The owner explicitly
accepted this bounded evidence. No repeated auth-health test is requested.

#161's development criteria are complete and owner-approved
closed; its matching live receipt remains readiness evidence, not a reason to
reopen the development issue. Neither issue is automatically a #148 blocker.

## Evidence collection and ownership

[EXTERNAL.md](EXTERNAL.md) is the authoritative E01–E20 request register.
The repository owner is responsible for E01–E20 under the approved issue
disposition. Listed roles identify consumers, not access grants; execution
operators still need authorization for their scope.
Capture only: evidence ID, named operator, UTC date, revision/artifact identifier,
pass/fail/pending/not-applicable with rationale, sanitized evidence link,
approver and next gate. Do not attach environment contents, raw remotes,
credential values, host logs or backup data. Restricted evidence must stay on
its approved inference/storage route; use a sanitized attestation here.

| Gate | Evidence IDs | Required handoff |
| --- | --- | --- |
| #149 preparation before #150 | E01–E05, E07, E09–E11, E13–E16, E18 | Pi/layout/units, rollback images, backup stability and restore, rules/checks, integrations, setting names/consumers, registry permissions, clones/workspaces, accepted worker disposition, affected TLS and external URL consumers |
| Before operational preparation merges | E06 | GitHub owner confirms actual production reviewer protection and approved freeze/resume procedure; environment declaration alone proves neither |
| #150 cutover | E08, E09, E12, E13, E17, E19; revalidate E07 | Target availability and stable repo ID; external URL changes, clone/selector alignment, paused automation, approved window and rollback operator |
| #151 verification | E07, E11, E14, E16, E20 | Required checks, registry/workspace/TLS operation, agreed observation interval, first successful backup and cleanup approval |

E04 has accepted bounded backup/restore evidence. E15 is satisfied for rename
preparation by the [owner-approved issue disposition](https://github.com/jimbobsyouruncle/hybrid-ai/issues/149),
not by a new live integration test. The owner attests that the existing worker
functions when started. The approved prior cross-repository review identified
compatible model-list/chat/streaming interfaces and no main-repository slug
dependency in the worker build/startup paths. Existing offline client tests
passed in [source validation](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/43085894990)
at final PR head `8bc28837ef8ebc36ae89ef6d3850eb17d2a3eff9`.
That review used main source `ba7045aab7be83e33f30186e07d5664b0fea91ea`
and worker source `cf402976b09d8d155c62f5f4b83d174b35d3521f`;
this documentation task does not access the worker repository.

Preserve the worker repository/package, image, model, authentication and
transport contracts. A fresh worker inventory, rebuild, separately supplied
contract or synthetic test is not required solely for this identity-only rename.
Optional authentication/reachability modes have source-level caveats, not observed
failures of the owner-attested deployment. If cutover changes those interfaces,
reassess the exact affected contract before execution without weakening security.
Normal post-cutover worker observation belongs to #151. This disposition does
not establish Haven's proposed RunPod-only enforcement, isolation or RPO/RTO.

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
   client variable does not configure these services. `deploy-remote.sh` now
   validates and explicitly forwards the resolved process selector to the
   transient verifier, including the legacy default when unset. The
   [service configuration proposal](../../../deploy/README.md#haven-repository-identity-preparation-149)
   requires separate host-owner review and approval; no drop-in or activation
   is installed by this source change. Bootstrap's invocation and existing
   remote overrides still need explicit alignment at cutover.
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
| VERIFIED | #147 audit; #148 presentation completion; #160 accepted operational completion; #161 development completion; #165–#170 preparation merges and listed CI/deployment runs; owner-confirmed #170 installed HEAD and matching receipt PASS; bounded E04 backup/restore evidence | Existing public records; #148, #160 and #161 closed with explicit owner approval on 2026-11-11 UTC |
| REQUIRED NOW | Review this documentation PR; no host operation is required to validate this deliverable | Human PR reviewer / #150 preflight documentation |
| VERIFIED | #170 receipt matches requested/deployed SHA and records PASS for all required gates at 18:14:41Z; latest log not independently inspected; #166/#168 FAIL results remain historical evidence for their own revisions | Owner-supplied sanitized receipt / #149; no rerun requested |
| VERIFIED | E15 rename preparation: owner-attested working worker, approved source review and existing offline client tests; preserve unchanged contracts | Repository owner / E15; normal use after cutover belongs to #151 |
| REQUIRED NOW to advance cutover planning | Supply the bounded packet: identity alignment, affected consumers, recovery availability and operational decisions | Repository owner / #150; not a prerequisite for this documentation PR |
| REQUIRED LATER | Record explicit #150 go/no-go, cutover receipts and #151 observation/first-backup results | Owner / #150 then #151 |
| OPTIONAL | Confirm cleanup of the accepted scratch restore directory; consider separate tracking/rules-policy corrections | Owner; no cleanup, settings change or issue mutation included here |

The bounded packet is required to advance operational readiness; execution and
post-cutover observations remain REQUIRED LATER. Neither blocks validation of
this documentation PR, and neither is an optional deferral.
The owner has supplied the existing #170 receipt and confirmed the installed
checkout revision and layout-derived receipt directory; see the bounded evidence
below. Next obtain only the bounded operational packet below. No raw logs, worker
source or credentials are requested.

The development gate is CLEAR once this PR's applicable checks pass and human
review accepts the bounded deliverable. The operational gate remains NO-GO:
missing affected-consumer, activation and operational decisions are not waived.
Do not ask for credentials, raw private logs, another backup/restore or a new
deployment merely to refresh this document. Exact runtime commands require
confirmed paths/identity and separately authorized host scope first.

#148, #160 and #161 were closed under separate explicit owner authorization;
their public issue bodies/completion comment record the accepted scope and
remaining phase limits. #149 remains
closed as found despite outstanding operational criteria. Reopening #149,
updating the epic checkboxes, linking native dependencies and assigning named
owners/milestones remain recommendations requiring separate approval; this
implementation changes no further issue metadata. GitHub's epic subissue list
returned empty during review; the issue-body sequence still governs:
#147 → #148/#149 → separately approved #150 → #151. Neither #146 nor #150
is complete. #147's accepted audit completion remains unchanged.

Rollback of this reconciliation is a reviewed documentation revert. It changes
no runtime state, permissions, workflow behavior or selector propagation.

## 2026-11-11 owner verifier evidence and bounded correction

Owner-supplied sanitized inspection at 15:22:51 UTC identifies `jarvis`,
`aarch64`, system backup mode and installed HEAD
`5e641a118db8154c6c753f8365d2b7526aa75273`. Its schema-v2 receipt at
13:40:34 UTC matches both requested SHA and deployed HEAD, with numeric
ownership `999:983` and mode 0644 matching the configured identity.
Workflow runs `43029110385` and `43029110310`, deployed HEAD, backup-log
presence and status-identity readability PASS. Overall verdict is **FAIL**,
exit 1: required `backup_tile` is SKIPPED because `LOCAL_DOMAIN` was unavailable
in the layout. The matching log reports the same mandatory-coverage FAIL; the
bounded log inspection returned no receipt-publication failure marker.

The owner confirms `LOCAL_DOMAIN` is present in the stack file. Source review
shows the verifier previously consulted only process/layout for that setting.
The approved correction reads only this literal runtime key from the configured
stack file after existing process/layout overrides. It preserves mandatory
coverage and the existing HTTP route/authentication behavior. Offline regression
coverage is source evidence, not a live tile PASS. PR #168 merged this correction
and deployment automation subsequently succeeded for its actual merge SHA. The subsequent #168 owner receipt below records the HTTP/TLS/auth gap revealed
after domain resolution; #170 implements its private transport correction.

This evidence supersedes the missing-outcome description above for this exact
installed revision: its verifier outcome is now evidenced FAIL, not PENDING.
E01 host/layout inventory remains partial, E04 backup/restore evidence remains
accepted, and the remaining affected external and rollback sign-offs remain outstanding.
The later owner-approved E15 disposition above governs rename preparation. Keep #160/#161 completed and #150 NO-GO. No runtime repair,
backup/restore rerun, credential/permission change or cutover is performed.

## Post-merge #168 reconciliation — historical result

The final-head checks and deployment automation passed for #168's actual merge
SHA `681c961c68e8b2e98cbafd39a2c671acca36558e`; deployment finished at
16:08:35 UTC on 2026-11-11. Its asynchronous result was initially missing.
The subsequent owner receipt below resolves that gap as FAIL for this exact
revision. No further inspection or test of the superseded #168 deployment is
requested. #166's earlier FAIL remains scoped to its own revision and time.

## Owner #168 runtime result and approved private transport correction

The owner confirmed `/opt/hybrid-ai` on `jarvis` at
`681c961c68e8b2e98cbafd39a2c671acca36558e`. Its schema-v2 receipt at
2026-11-11T16:09:33Z matches both `sha` and `head`, with run IDs `43053540207`
and `43053540322`. Workflow conclusions, deployed HEAD, backup-log presence,
status-identity readability and numeric receipt publication PASS. Overall
verdict is **FAIL**, exit 1: required `backup_tile` is SKIPPED because the
status API was unreachable. This supersedes the earlier missing-result/PENDING
statements for this exact revision; it is not a new backup failure. The newest
corresponding full log block has not been independently inspected here.

Owner read-only probes found HTTP 308 from
`http://status.daemonhub.dev/status/api` to the same path over HTTPS, then HTTP
302 to `https://daemonhub.dev/auth/login` with normal certificate validation.
Source confirms that the verifier demanded a 2xx HTTP browser response without
following redirects. Domain resolution is fixed by #168; authenticated browser
routing remains incompatible with that probe. No session or credential was
supplied, no authentication was disabled, and no verifier/backup was rerun.

PR #170 merged the owner-approved private Unix socket correction for #149. Status
returns only the Backups name/state from its existing live probe through a
mode-0600 socket in a status-owned mode-0700 directory. Installer/Compose wire
that dedicated directory; the verifier validates its permissions and exact
response, with missing/invalid evidence still failing required coverage. Caddy
and browser authentication remain unchanged. Source tests/CI establish
development evidence; the successful #170 deployment
and owner-confirmed checkout establish installation. The subsequently supplied
receipt below establishes the recorded asynchronous PASS. See the [transport policy](../../../backup/README.md#post-deploy-verification-coverage-and-receipt-ownership)
and [rollout/rollback](../../../deploy/README.md#private-backups-transport-rollout-and-rollback).

## Post-merge #170 readiness — 2026-11-11 UTC

PR #170 merged into main as `c81eb3e69ae9c26ef8e80e34c15a2a5eb02f2612`.
Its final PR head and actual merge revision are recorded above; the synthetic
PR merge revision `358cfd808cfbdc20746a104b1f90e49fe0bb296c` is distinct
from both. Final-head maps/SAST/source checks passed. An earlier source check
failed at head `e7ae4a54a5363a35dbad006c20d756bc2890e9de` because an
installer fixture assumed Docker GID 999; the corrected final head tests the
resolved numeric identity and passed. No security controls were weakened.
Hermes ARM64 smoke was SKIPPED under the successful unchanged-image detector;
execution is NOT_APPLICABLE to this diff, not an executed PASS.

Deployment run `43073883258` passed source validation, including real private
socket integration, and Deploy over Tailscale, finishing at 18:13:45 UTC.
The owner subsequently supplied `sudo git -C /opt/hybrid-ai rev-parse HEAD`
output from jarvis matching the full merge SHA. This confirms installed HEAD
at that observation; its exact UTC observation time was not supplied.
The owner subsequently supplied a sanitized schema-v2 receipt from the
layout-derived `/var/lib/hybrid-ai/hermes_data/deploy-verdicts/` directory.
Both `sha` and `head` match `c81eb3e69ae9c26ef8e80e34c15a2a5eb02f2612`;
receipt time is `2026-11-11T18:14:41Z`, verdict **PASS**, exit code 0, and
run IDs are `43073883111` and `43073883258`. File ownership `999:983`, mode
0644, matches the reported layout UID/GID. The inspection time itself was
not supplied. Evidence provenance is the owner's sanitized output in the
approved #149 conversation; the receipt is not a CI artifact.

| Receipt gate | Required | Recorded state / coverage |
| --- | --- | --- |
| workflow_runs | yes | PASS: all returned workflow runs succeeded; required PR checks remain separately correlated above |
| deployed_head | yes | PASS: requested SHA matches installed HEAD |
| backup_log | yes | PASS: regular non-empty backup log |
| backup_readability | yes | PASS: readable as configured status identity |
| backup_tile | yes | PASS: live Backups tile reports ok |
| verdict_file | no | PASS: receipt published with configured numeric ownership |

This establishes the recorded #170 asynchronous outcome on jarvis, independently
of deployment workflow success. The latest matching host log was not inspected;
no independent claim about later attempts or publication errors is made. No
contradictory later evidence is known. #166/#168 FAIL results retain their exact
revision/time scope and are not copied onto #170. This receipt neither executes
nor replaces the accepted E04 backup/restore evidence and does not complete E01's
affected host/layout/identity review. E15 has the separate accepted disposition above.

Successful automated deployment logs and this owner-supplied receipt count for
what they actually observed. No verifier rerun, manual socket probe, auth-health
repeat or new backup/restore is requested merely to refresh the evidence.

Before #150, obtain the bounded affected-consumer, activation and rollback
attestations below; E15 preparation is already dispositioned. Existing suitable
automation counts. No repeat auth-health, backup, integrity or restore test is
justified by this reconciliation. #151 retains the distinct post-cutover
integration observations and first successful backup. Accepted E04 and
#147/#148/#160/#161 completion remain intact; #149 operational completion and
#150 remain blocked. This documentation PR is not itself an operational gate
and changes no runtime state, issue metadata, permissions or credentials.

## #150 bounded execution preflight packet

The [owner-approved reconciliation](https://github.com/jimbobsyouruncle/hybrid-ai/issues/150)
supersedes broader pending-inventory requests in earlier historical sections.
The repository owner is responsible for E01–E20, cutover coordination and
rollback. Approval to prepare this documentation is not operational go/no-go.
All unsupplied decisions below remain **PENDING**; no installed activation,
target availability, window or downtime tolerance is inferred.

| Packet item | Required non-secret decision / evidence | Status |
| --- | --- | --- |
| Revision and identity (E01, E02, E12, E13) | Select execution revision; confirm clone/bootstrap/root service/transient verifier alignment and whether a deployment remote override needs an action; record prior state and rollback mechanism | PENDING owner review; source support is implemented, installed Haven activation unverified |
| Affected consumers (E05, E07, E09–E11, E13, E14, E16, E18) | Mark each applicable consumer unchanged, update-at-cutover or NOT_APPLICABLE with reason; name the responsible operator and action/result gate | PENDING owner disposition; only affected dependencies block cutover |
| Recovery (E03, E04) | Confirm selected prior code/verifier revisions, immutable image artifacts and recovery snapshot remain available; reuse accepted restore evidence | PENDING artifact-availability confirmation; E04 recorded restore VERIFIED |
| Operations (E06, E08, E17, E19, E20) | Confirm target availability and stable repository ID; approve window, freeze/resume coverage, downtime threshold, stop/rollback operator and observation interval | PENDING; no operational approval recorded |

Submit only item/evidence ID, owner, UTC date, revision/artifact, environment,
PASS/FAIL or justified NOT_APPLICABLE, planned action and next gate. Keep private
configuration and logs on their approved route. Unchanged backup/certificate
storage, broad host inventory, model tuning and unrelated hardening are not
independent blockers without a demonstrated affected interface. Unknown
applicability still needs a disposition. No backup/restore, auth-health,
verifier or worker retest is requested absent a specific invalidation reason.

The execution ledger must sequence: preserve prior identity/recovery state;
record and approve the freeze (including main map-bot automatic merges,
eligible deploys, image publishing and relevant external schedules); record
separate owner go/no-go; rename while preserving repository ID, visibility and
`main`; align canonical clone URLs, bootstrap process selector, root service
process selector and any remote override; verify the explicitly forwarded
transient-verifier identity; perform approved new-path checks before resuming.
A layout-file edit or SSH-client export does not activate the root service.
The proposed root-owned service drop-in, daemon reload, remote edits and any
deployment require separate operational authorization, as described in
[identity activation guidance](../../../deploy/README.md#haven-repository-identity-preparation-149).

Stop on identity mismatch, missing required checks, unavailable recovery
artifacts, a failed applicable gate or the approved downtime threshold. Record
which ledger entries would be reversed and who may execute each reversal;
rename-back, redeploy and data restore are separately authorized operations.
No automatic rollback or data restore is authorized here.

Handoff to #151 includes new-path clone/PR/check/deploy results, affected
integrations, normal worker-use observations, the agreed sustained observation
interval and first successful post-cutover backup. Record retained aliases,
incidents and rollback decisions before proposing epic closure. The packet is
ready for operational approval only when the pending decisions are supplied;
#150 remains **NO-GO** until then and until separate explicit owner approval.
