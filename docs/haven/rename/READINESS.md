# HAVEN-003 readiness and cutover handoff

Issue #149; epic #146. This is the owner-approved **public-source documentation
portion** of readiness preparation. It does not complete #149, authorize #150,
or attest to current production state. No host, backup, credentials, external
settings or worker repository were accessed. The source reviewed is public
`main` at `5dc84dd24c076d4b653bd508ba65deaf98100219`.

## Acceptance and existing evidence

The owner accepted #147 as completed public-source audit. Keep it closed.
The immutable baseline contains 4,453 occurrences, including 125 manual-review
records. Later decisions supplement that baseline; they do not rewrite it.

| #149 acceptance criterion | Evidence / remaining requirement | Status |
| --- | --- | --- |
| Required CI, SAST, tests and maps pass | Final-head checks for #155 and #157 below; this documentation PR must obtain its own required checks | Prior implementation passed; current PR evidence belongs in its description |
| Deployment smoke and worker integration checks documented | Successful deploy workflows below; E01–E05, E14–E16 require the separately authorized operational evidence in EXTERNAL.md | Partial; worker and restore hard gates remain pending |
| New URL dependencies identified and actions prepared | D01–D16, compatibility selector, occurrence reconciliation and activation sequence below | Public-source plan documented; external consumer inventory remains pending |
| Rollback and go/no-go reviewed | Procedure below; named operator, reviewed recovery artifacts, downtime threshold and owner acceptance still required | Prepared for review; no operational sign-off claimed |
| Preparation PR merged before #150 | #155 and #157 merged; this readiness PR also needs human review and merge approval | Not yet satisfied for this deliverable |

| Work | Final PR head / merge | Executed evidence |
| --- | --- | --- |
| #147 audit, [PR #154](https://github.com/jimbobsyouruncle/hybrid-ai/pull/154) | `74eaf77e4f00803f807edc8c8d71a75a479568f3` / `ccd924d19ba898ebe6892088e6b44eeb65a7eb08` | [Map](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42682650732) and [SAST/source](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42682650838) passed; owner accepted public-source scope |
| #149 identity preparation, [PR #155](https://github.com/jimbobsyouruncle/hybrid-ai/pull/155) | `4f6d6464d4ca04e62db6ef5e9566aa0dbc29bf1e` / `a2a4863006d995c0b62ae882428fbb6d7e48b530` | [Map](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42694494676), [SAST/source](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42694494506) and [post-merge deploy](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42695975376) passed |
| #148 presentation, [PR #157](https://github.com/jimbobsyouruncle/hybrid-ai/pull/157) | `b5ffe9ae8ee371f443848259d9fc34c4aef1f22b` / `873b41610fc710cb2c8dcde8632f841709e89e2f` | [Map](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42703035002), [SAST/source](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42703034861) and [post-merge deploy](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42705394288) passed |

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
[PRESENTATION.md](PRESENTATION.md). Of the historical 125, **108 remain
unresolved by those registers**. This arithmetic is not a new blanket approval
of remaining references. Preserve unresolved references before consumer review.

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

For the remaining 108 manual-review records, retain the baseline `owner_issue`
as the original triage assignment and use D01–D16 for consumer coordination
between #148/#149. A named reviewer must record exact IDs, consumer, decision,
evidence and later issue/phase before an affected edit. They remain an open
queue, not completed classification decisions or permission to remove aliases.
Before #150, account for each record as reviewed preservation or an approved
tracked action; any deferral beyond the epic needs explicit owner acceptance,
a successor issue, named owner and milestone. No such beyond-epic deferral is
approved here.

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
For E04 the authorized backup owner records snapshot identifier, complete
capture/integrity result, scratch-restore result and duration without exporting
data. For E15 obtain a versioned owner-supplied API/auth/model/image/network
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

## Tracking handoff

Planning observed #148 open despite merged #157, and #149 closed despite
#155's explicit partial scope. Recommend recording #148 evidence, reopening
#149 for remaining readiness, linking native dependencies and assigning named
owners/milestones. These are recommendations only; this PR updates no issues.
Full #149 completion awaits operational evidence and review. This documentation
deliverable may become ready for review after its own applicable CI passes,
without claiming that the #150 operational prerequisites are complete.
