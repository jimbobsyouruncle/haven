# HAVEN-001 public-source rename audit

Issue: [#147](https://github.com/jimbobsyouruncle/hybrid-ai/issues/147); parent: [#146](https://github.com/jimbobsyouruncle/hybrid-ai/issues/146).

## Status and scope

Public-source inventory complete for the immutable baseline below; external verification and ambiguous edit decisions remain pending. This is evidence for #147, **not a claim that the whole issue is complete** and not permission to execute #148–#151. The owner approved this audit implementation and draft PR only. No runtime behavior, infrastructure, repository identity, credentials or external worker source is changed.

Baseline: `c2286bcd266e1924797fc787a677e6f8aa2d94da`, public `main` observed on 2026-11-09. Repository ID: `1380300964`; repository: `jimbobsyouruncle/hybrid-ai`. The audit reads immutable Git blobs from this repository, not files in deployment directories or ignored/untracked configuration. Git remotes, environment files, logs, customer data, backups and other repositories were not inspected. The separately authorized exception is execution of the pinned public map generator, not permission to inspect its repository generally.

## Artifacts

| File | Purpose |
| --- | --- |
| [inventory.csv](inventory.csv) | One record per matching content/filename occurrence, with position, classification, reason, action, owning issue and source-line hash. |
| [summary.json](summary.json) | Reconciled counts and classification totals. |
| [source-manifest.json](source-manifest.json) | Every baseline tracked regular file, Git blob ID and SHA-256. |
| [audit.py](audit.py) | Deterministic reproduction/check command; only `--write` writes the three generated audit artifacts. |
| [DEPENDENCIES.md](DEPENDENCIES.md) | Coupled consumers, risks, proposed sequencing and rollback boundaries. |
| [EXTERNAL.md](EXTERNAL.md) | External dependency checklist, evidence owners and separate authorization gates. |
| [VALIDATION.md](VALIDATION.md) | Acceptance-criterion mapping and validation evidence/limitations. |

## Reproduce and navigate

From the repository root:

```sh
python3 docs/haven/rename/audit.py --check
```

To regenerate after intentionally changing classification rules, use `--write`, inspect the diff, then run `--check`. The baseline is deliberately fixed. Do not silently advance it or recursively inventory this audit's own historical examples. For #151, perform a separate current-source scan and reconcile approved retained references against this baseline.

The scanner uses `hybrid[-_ ]ai|\bhybrid\b`, case-insensitively, in every baseline tracked file and filename. It does not follow symlinks or submodules: nonregular entries fail closed. No binary files were present. Invalid UTF-8 also fails rather than disappearing from coverage. Filename records have line `0`; content line and column numbers are one-based Unicode character positions. Multiple matches on a line are separate records. The CSV intentionally stores the matched token and source-line SHA-256 rather than copying entire lines, which can contain synthetic credential fixtures.

To inspect context for a CSV record, read the indicated public file at the pinned commit, for example:

```sh
git show c2286bcd266e1924797fc787a677e6f8aa2d94da:scripts/run-post-deploy-verify.sh
```

Coverage: **173 tracked files; 4,431 content occurrences on 3,543 lines across 137 files; 22 filename occurrences across 22 paths (21 legacy-name paths plus one standalone-hybrid image-test path)**. Of the content occurrences, 4,191 match the legacy product forms; the additional 240 are standalone `hybrid` matches, including architecture terminology and image identities. These are lexical counts, not counts of required edits. Indirect dependencies such as `github.repository`, clone-name derivation and GitHub settings need the separate registers.

## Classification policy

Every record has one of the issue's four classifications. Ordered rules in `audit.py` provide reproducible conservative triage, **not authorization or a semantic proof**. A reviewer must inspect pinned context before editing. Full-line operational context can conservatively retain a display occurrence; later issues may refine a record by ID with rationale.

| Classification | Meaning and proposed action |
| --- | --- |
| rename | Canonical repository identity at #150 cutover, or a narrowly recognized visible status label in #148. Update its fixtures/consumers together. |
| preserve | Separate worker/image identity, historical attribution, generated navigation, technical terminology, or current-behavior fixtures. A fixture is updated only when its corresponding production consumer changes. |
| compatibility alias | Existing path, setting, symbol, service, network, log/cookie identity, unit or backup selector. Retain for this epic; a later migration requires consumer tests and separate approval. This label does not claim an alias adapter already exists. |
| manual review | Ambiguous branding/technical meaning, diagnostic interface or executable example. No edit until the reviewer resolves its consumer and records the decision. |

Current totals, including filenames: 29 rename; 824 preserve; 3,476 compatibility alias; 124 manual review. The manual-review population is explicitly outstanding; classification does not close those decisions. Most documentation triage is intentionally conservative because the same guide mixes prose with operational commands. Technical `hybrid`, separate `runpod-hybrid-worker`, package names, and historical evidence are not mass-replaced.

## Issue boundaries and next gate

[#148](https://github.com/jimbobsyouruncle/hybrid-ai/issues/148) owns visible product labels and documentation decisions; [#149](https://github.com/jimbobsyouruncle/hybrid-ai/issues/149) owns executable identity support, CI/CD and runbooks. [#150](https://github.com/jimbobsyouruncle/hybrid-ai/issues/150) alone owns the separately approved repository rename/cutover; [#151](https://github.com/jimbobsyouruncle/hybrid-ai/issues/151) verifies it and records retained compatibility names. On the planning observation date all six issues were open, with no labels, assignees or native blocking relationships; dependencies were textual. #147's sole existing comment explicitly described only an initial sampled audit. No issue state or metadata is changed here.

Before accepting #147 as fully complete, the owner must review the classification policy/manual-review queue and provide or separately authorize the external evidence in EXTERNAL.md. Before #150: both preparation workstreams must be reviewed/merged, exact revisions green, external dependencies verified, restoration/rollback ready, automation frozen and explicit go/no-go recorded. The Haven architecture remains proposed; a naming migration does not implement its isolation, identity, inference or erasure guarantees.
