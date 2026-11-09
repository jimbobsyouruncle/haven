# Validation and acceptance evidence

## Subsequent owner decision and compatibility preparation

The owner subsequently accepted #147 as complete public-source audit evidence
and recorded that decision on #147 and epic #146. Earlier keep-open statements
below describe the original audit handoff and are superseded by that explicit
decision. Unresolved manual-review entries and E01–E20 remain later-phase gates,
not reasons to reopen #147. Required final-head PR checks are authoritative for
their actual execution; post-merge/deployment evidence is checked separately
when needed, and skipped checks are not passes.

[COMPATIBILITY.md](COMPATIBILITY.md) records the bounded #149 repository
identity contract, affected inventory decisions, fixtures and operational
handoff. It does not claim full #149 completion or live cutover verification.

This report distinguishes reproducible public-source evidence from pending external verification. No production security or restore claim follows from source inspection.

## Issue #149 readiness documentation validation

The approved deliverable adds [READINESS.md](READINESS.md) and reconciles the
existing handoff documents without changing runtime code or workflows.
Local validation on 2026-11-09:

- Immutable audit `--check`: passed; inventory, summary and manifest unchanged.
- CSV reconciliation: passed; 17 distinct previously decided manual-review IDs
  are in the 125-record baseline, leaving 108; all 29 rename-class IDs are
  accounted for exactly once in the readiness disposition table.
- Relative documentation links and approved file scope: passed.
- Pinned map regeneration/freshness: passed; REPO_MAP.md 12,227 bytes and
  CODE_INDEX.md 23,349 bytes, both below 24,576; CODE_INDEX.md unchanged.
- All seven map freshness/error fixtures: passed.
- Static CI parity: passed, 14 evaluated gates, zero failures. Full shell
  suites, dependency-installing tests and real Caddy/Compose checks remain
  CI-owned; ShellCheck, Semgrep and CodeQL require this PR's check results.
- Diff whitespace check: passed. No new runtime tests are needed for this
  documentation-only change; no host, restore or live worker check ran.

Current-head CI results belong in the PR description. Existing implementation
evidence is linked below and in READINESS.md; it does not substitute for this
PR's applicable required checks or the still-pending operational gates.

## Issue #148 presentation validation

Final head `b5ffe9ae8ee371f443848259d9fc34c4aef1f22b` passed the required
[map check](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42703035002)
and [SAST/source gate](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42703034861).
PR #157 merged as `873b41610fc710cb2c8dcde8632f841709e89e2f`; its
[post-merge deployment](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42705394288)
passed. The Hermes image smoke was skipped by the successful existing change
detector; no fresh ARM64 runtime or external readiness is established.
See [READINESS.md](READINESS.md) for the acceptance matrix, 17 explicit
manual-review decisions, remaining 108 unresolved records and operational gates.

See [PRESENTATION.md](PRESENTATION.md) for the bounded scope, nine explicit
manual-review decisions and disposition of all 145 baseline occurrences in
the three modified product/source documents. The immutable audit is unchanged.

Local validation on 2026-11-09:

| Check | Result |
| --- | --- |
| `PYTHONDONTWRITEBYTECODE=1 python3 status/test_hub_urls.py` | PASS: 86 assertions, zero failures; Haven labels, existing TLS/domain/tunnel URLs, legacy diagnostic filename and server identity |
| Regression proof against the original application in a temporary fixture tree | PASS: all 36 new branding assertions reject the original labels; compatibility assertions still pass |
| Application diff review | PASS: exactly six rendered labels change; all other application source bytes retained |
| Decision-register reconciliation against immutable CSV | PASS: all 145 scoped baseline IDs accounted for exactly once |
| Relative Markdown links in README, architecture and audit documents | PASS: local targets resolve |
| `python3 docs/haven/rename/audit.py --check` | PASS: inventory, summary and source manifest reproduce |
| Pinned map regeneration and freshness | PASS: REPO_MAP.md 11,613 bytes; CODE_INDEX.md 23,349 bytes; both below 24,576 bytes |
| Map-check fixture suite | PASS: all seven cases |
| `bash scripts/ci-parity.sh --generator /tmp/haven-147-agent-context-generate.py` | PASS: 14 evaluated gates, zero failures |
| `git diff --check` | PASS |

Static parity includes deployment probe (34 assertions), GPU probe (24),
syntax, pipe freshness, source/security invariants and map freshness. Its full
shell suites are deferred to CI. Dependency-installing tests, real Caddy/Compose,
ShellCheck, Semgrep and CodeQL remain CI-owned; the PR records current-head
results. No fresh ARM64 runtime, host access, RunPod integration or backup
restore is claimed. E01–E20 retain their existing later-phase gates. Merge and
deployment require separate owner approval.

Earlier final-head evidence remains available without repeating those tests:
[PR #154](https://github.com/jimbobsyouruncle/hybrid-ai/pull/154) completed #147
with [map](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42682650732)
and [security/test](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42682650838)
checks passing. [PR #155](https://github.com/jimbobsyouruncle/hybrid-ai/pull/155)
completed only the #149 identity compatibility portion, with
[map](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42694494676) and
[security/test](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42694494506)
checks passing. Its [post-merge deployment workflow](https://github.com/jimbobsyouruncle/hybrid-ai/actions/runs/42695975376)
also passed; this is evidence for that executed workflow, not completion of
the external evidence register or current production verification.

## Issue #147 acceptance criteria

| Criterion | Evidence | Status |
| --- | --- | --- |
| Auditable file/line inventory and external dependency checklist attached/linked | inventory.csv, immutable source-manifest.json, summary.json; DEPENDENCIES.md and EXTERNAL.md | Public-source deliverables provided; external verification pending |
| Every occurrence classified with rationale and proposed action | One CSV row per lexical occurrence with line/column/hash, rule, classification, rationale, action and owner issue; deterministic audit.py --check | Satisfied for declared immutable lexical scope; ambiguous records explicitly classified manual review, decisions pending |
| Production-breaking risks and required approvals documented | D01–D16 consumer register, E01–E20 evidence gates, stop/rollback procedure and owner decisions | Documented; operational evidence/go-no-go not supplied |
| No runtime changes or GitHub repository rename performed | Diff limited to docs/haven/rename and generated navigation maps; no workflow dispatch, issue mutation, merge, rename or deployment | Required scope invariant, checked before publication |

Historical handoff: the original audit requested that #147 remain open for external evidence. The subsequent owner decision above supersedes that request: #147 is complete; the external evidence remains assigned to later phases.

## Validation procedure

1. Run `python3 docs/haven/rename/audit.py --check` against the fixed baseline. Independently reconcile CSV line/column/token/hashes, counts, filename coverage and classifications with Git blobs. Include failure-direction verification using a temporary artifact mutation with restoration, without changing runtime files.
2. Stage only intended audit files for the pinned map generator's tracked-file discovery, regenerate REPO_MAP.md/CODE_INDEX.md, and run the map fixture/freshness checks. Owner separately authorized only generate.py at shared-actions commit 3156ad16725e149a9baebeb71862a8d1d341418c.
3. Run repository static parity checks with that generator, shell/Python syntax, pipe freshness and relevant repository policy checks. Record unavailable CI tools/infrastructure explicitly; do not treat skips as passes. No new runtime regression tests are needed for documentation; the audit script itself needs meaningful coverage/reconciliation.
4. Check links to local audit artifacts and pinned source anchors, `git diff --check`, map size limits, file allowlist and absence of runtime diffs. Verify no credentials or source payloads beyond public identifiers/tokens are introduced.
5. Open a draft PR only; leave both required checks and independent human review visible. No approval of this artifact authorizes implementation of later issues, merging, deploying or renaming.

## Results

Results are recorded below after execution, and in the draft PR description. Required GitHub checks are authoritative for their own execution; local parity does not replace SAST, CodeQL, Docker/Caddy or ARM64 CI evidence.

Validation performed on 2026-11-09 on branch `docs/haven-147-public-rename-audit`:

| Check | Result |
| --- | --- |
| `python3 docs/haven/rename/audit.py --check` | PASS; all three artifacts reproduce byte-for-byte from immutable public blobs |
| Independent CSV/manifest reconciliation | PASS; 173 SHA-256 values, 4,453 unique positions, 3,543 Git-grep lines, all per-line multiplicities and required classification/action fields agree |
| Failure-direction check | PASS; temporary corruption of summary.json was rejected with exit 1; original restored and clean check passed |
| Local document artifact links | PASS; all relative targets resolve |
| Pinned generator regeneration | PASS; REPO_MAP.md 11,089 bytes, CODE_INDEX.md 22,935 bytes, each below 24,576 bytes |
| `bash scripts/check-agent-context.sh /tmp/haven-147-agent-context-generate.py` | PASS |
| `bash scripts/test-check-agent-context.sh /tmp/haven-147-agent-context-generate.py` | PASS; all seven fresh/stale/error fixture cases |
| `bash scripts/ci-parity.sh --generator /tmp/haven-147-agent-context-generate.py` | PASS; 14 evaluated gates, zero failures |
| Static parity coverage | Shell/Python syntax, generated pipe freshness, status deployment probe (34 assertions), GPU probe (24), proxy allowlist/headers, Hermes source assertions, tracked-secret policy, masked-literal ratchet, IP-literal report and map freshness |

The full shell fixture suites were explicitly deferred by default static parity; no runtime files changed. Dependency-installing tests and Docker/Caddy/Compose checks were announced as CI-owned, not passed locally. ShellCheck, Semgrep and CodeQL are not included in local parity and require PR CI evidence. No Docker socket or live service was accessed. ARM64, live RunPod, Pi deployment, backup/restore and external settings checks remain pending separate authorization. Independent human review remains required. See the draft PR for check run status on its actual head; this baseline audit does not claim that every current GitHub check is green.

## PR #154 CodeQL correction

The initial PR head 8514b6faf705b89e7f97c0e28f2a10c2871d3355 triggered CodeQL's **Incomplete URL substring sanitization** alert at audit.py:49. The audit used a registry-name substring as classification evidence. The fix parses complete candidate references with urllib.parse.urlsplit, requires the exact ghcr.io hostname and HTTPS, rejects userinfo and unexpected/invalid ports, and keeps deceptive suffixes intact during extraction. No scanner suppression or runtime behavior changes are involved.

Offline regression command: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s docs/haven/rename -p 'test_*.py' -v`. Three tests cover six accepted references, twelve rejected references and four classification outcomes. The old classifier incorrectly preserves a standalone hybrid token beside a deceptive registry hostname; the corrected classifier routes it to manual review.

Regeneration changes exactly **A01566** (doctor.sh:1046) from preserve/P06 to manual review/M01: the source line contains a bare registry-name marker rather than a complete registry reference. Total coverage, positions, source hashes and manifest remain unchanged. Updated classification totals: 823 preserve, 125 manual review, 29 rename, 3,476 compatibility alias. Required PR CI/CodeQL must be assessed on the correction commit, not the failing initial head.

Correction validation: all three regression tests passed; the old classifier's deceptive-host false positive was reproduced; independent old/new inventory comparison confirmed exactly A01566 changed and all 4,453 records/source manifest were preserved. `audit.py --check`, pinned map freshness and `git diff --check` passed. Static parity was rerun: 14 evaluated gates, zero failures. Regenerated maps are 11,202 and 23,195 bytes, below the 24,576-byte limit. Local tests do not substitute for the PR CodeQL result.
