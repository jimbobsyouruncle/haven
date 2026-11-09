# Validation and acceptance evidence

This report distinguishes reproducible public-source evidence from pending external verification. No production security or restore claim follows from source inspection.

## Issue #147 acceptance criteria

| Criterion | Evidence | Status |
| --- | --- | --- |
| Auditable file/line inventory and external dependency checklist attached/linked | inventory.csv, immutable source-manifest.json, summary.json; DEPENDENCIES.md and EXTERNAL.md | Public-source deliverables provided; external verification pending |
| Every occurrence classified with rationale and proposed action | One CSV row per lexical occurrence with line/column/hash, rule, classification, rationale, action and owner issue; deterministic audit.py --check | Satisfied for declared immutable lexical scope; ambiguous records explicitly classified manual review, decisions pending |
| Production-breaking risks and required approvals documented | D01–D16 consumer register, E01–E20 evidence gates, stop/rollback procedure and owner decisions | Documented; operational evidence/go-no-go not supplied |
| No runtime changes or GitHub repository rename performed | Diff limited to docs/haven/rename and generated navigation maps; no workflow dispatch, issue mutation, merge, rename or deployment | Required scope invariant, checked before publication |

Do not use a closing keyword for #147 in the PR. The full issue remains open because untracked configuration, live Pi/registry/RunPod/integration verification and owner review require separate authorization/evidence.

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
