# HAVEN-003 repository identity compatibility preparation

Related: #149, #148 and epic #146. This is the bounded executable-identity
portion of #149, not completion of its operational readiness requirements.
The owner approved its Implementation Card in the local developer session.

The accepted cutover and remaining operational observations are recorded in
[#151](https://github.com/jimbobsyouruncle/haven/issues/151). Preparation-stage
dispositions and local results below are historical evidence, not instructions
to repeat completed work. The legacy default remains implemented; canonical
bootstrap and deployment processes must select `haven` explicitly.

## Contract and review decisions

`HYBRID_AI_REPOSITORY_SLUG` is process-environment-only. Unset selects
`jimbobsyouruncle/hybrid-ai`; explicitly selecting `jimbobsyouruncle/haven`
selects the canonical post-cutover identity. Any other value, including empty,
returns exit 2
without echoing its value and before consumer side effects. The setting is not
persisted, inferred from a remote, or loaded from any environment file. This
avoids executing layout data and avoids implying that host cutover is active.

The source-only helper is `scripts/lib/repository-identity.sh`. The verifier
embeds the identical marked function because `install.sh` installs that
executable alone in `/usr/local/sbin`. The new CI fixture compares both blocks
byte-for-byte and exercises a copied standalone verifier without a helper.
No installer or systemd installation contract is changed.

Inventory IDs below refer to the immutable #147 baseline. Source and consumer
inspection resolves the affected entries before their references are changed;
the original CSV and reproduction baseline remain immutable.

| Baseline references | Decision and consumer evidence |
| --- | --- |
| A02023, bootstrap.sh:137 | Prepare canonical clone/fetch URL from the validated selector. Preserve default URL, exact origin equality, userinfo rejection and all host compatibility paths. Offline fixtures cover new/existing clones, mismatch, foreign origin and credential-bearing origin. |
| A02131–A02132, deploy-instance.sh:59 | Derive default fetch URL from the selector; retain the existing public-remote override precedence and validation. Keep lock, auth isolation, ancestry, full SHA and deployed-HEAD checks. |
| A02502, run-post-deploy-verify.sh:49 | Derive API slug from the selector. Keep anonymous API requests, HTTP failure/redirect handling, deadlines and deployed-HEAD/backup-tile verification. |
| A03208 and all other baseline references in the three modified fixture suites | Retain old-identity fixture assertions as compatibility evidence; add explicit Haven and refusal cases rather than replacing legacy expectations. |
| A02024, A02062, A02064–A02065 (bootstrap manual-review entries) | Preserve: these account/diagnostic messages are outside the URL-selection change. Their presence is not approval to rename accounts or alter guidance. |
| A00112, A00121, A00126–A00127 (validate workflow manual-review entries) | Preserve: existing image/test consumers stay unchanged. Add only the offline identity fixture step. |
| Other manual-review records and retained baseline references | Preserve pending resolution in #148/#149 before any affected reference is changed. No blanket approval is inferred from this preparation. |

The bootstrap fixture's historical out-of-scope file guard now allows only the
additional explicitly authorized `scripts/deploy-instance.sh` change. Frozen
backup units and polkit controls remain in that guard. No scanner suppression,
required-check rename or deployment-workflow change is involved.

## Validation and remaining gates

Run the four focused suites:

```sh
bash scripts/test-repository-identity.sh
bash scripts/test-bootstrap.sh
bash scripts/test-deploy-instance.sh
bash scripts/test-run-post-deploy-verify.sh
```

The selector suite covers both approved identities and 14 invalid inputs for
all three consumers, with side-effect sentinels. The verifier fixtures cover
the copied standalone executable, HTTP 301/302/403/404/500, curl timeout and
empty-run deadline without sleeping through the real timeout. Existing
security fixtures still cover credential handling, locks, ancestry, exact SHA,
layout-file parsing and backup-tile verdicts. Final-head required CI/SAST and
tests are authoritative for what they execute; skipped checks are not passes.

E01–E20 remain assigned to their relevant preparation, cutover and verification
gates in [EXTERNAL.md](EXTERNAL.md). #148 presentation changes merged in PR #157.
#149 still owns readiness/runbook/integration evidence despite its observed
closed tracking state; this document does not change issue metadata. The
[readiness handoff](READINESS.md) records existing check/deploy evidence and
the remaining gates. #150 requires reviewed preparation merges, green checks and explicit
owner go/no-go. #151 supplies post-cutover evidence. Successful PR checks do
not establish live deployment or infrastructure health.

Local implementation validation on 2026-11-09:

| Command/check | Result |
| --- | --- |
| `bash scripts/test-repository-identity.sh` | PASS: defaults, both identities, embedded consistency, 14 invalid values across all three consumers |
| `bash scripts/test-bootstrap.sh` | PASS: 189 assertions, zero failures |
| `bash scripts/test-deploy-instance.sh` | PASS: 33 assertions, zero failures; systemd host executable availability explicitly skipped because `/opt/hybrid-ai` is not installed |
| `bash scripts/test-run-post-deploy-verify.sh` | PASS: all 25 cases; real `hermes` account ownership assertion skipped because account absent, file modes checked |
| ShellCheck 0.11.0 `-x` on eight affected shell files | PASS, no suppressions added |
| Immutable audit `--check` | PASS, no inventory artifacts changed |
| Pinned map freshness and fixture checks | PASS, all seven fixture cases; both generated maps below 24,576 bytes |
| `scripts/ci-parity.sh --generator /tmp/haven-147-agent-context-generate.py` | PASS: 14 evaluated gates, zero failures; full shell suites deferred by static parity, affected suites run separately above |

The verifier suite uses jq 1.8.2. Test tools were extracted into `/tmp`; no
system-wide installation was performed. Initial deployment fixture execution
inside the sandbox encountered systemd socket restrictions; the approved
outside-sandbox offline rerun produced the result above. Semgrep, CodeQL,
dependency-installing suites and Docker/Caddy validation remain PR-CI-owned;
this local table does not claim their result. Independent human review remains
required before merge.

The historical #150 activation requirement was to coordinate the clone origin,
selected identity in each system service/transient verifier, and any existing
fetch override. The original selector preparation did not implement operational
propagation. Current source forwards the resolved selector explicitly to the
transient verifier; the next separately authorized deployment must establish
its new-path runtime result, as tracked in #151. Capture the known-good
revision, installed verifier and image digests before a separately approved
deployment. A code revert does not undo external configuration or authorize
renaming back.
