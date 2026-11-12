# HAVEN-002 presentation and compatibility decisions

Issue #148; epic #146. Implemented under the owner-approved Implementation Card.
Haven is the product name; the canonical repository is `jimbobsyouruncle/haven`
following the accepted cutover. The tables below preserve the original
presentation-stage decisions against the immutable audit baseline; their
pre-cutover wording is historical, not a current instruction to retain old
canonical URLs. Current lifecycle and operational follow-ups are recorded in
[#151](https://github.com/jimbobsyouruncle/haven/issues/151).

Current-facing clone and badge links use `haven`. The clone example explicitly
keeps the `hybrid-ai` directory so subsequent commands and compatibility paths
still agree. Historical evidence URLs, original audit records, runtime names
and the unset repository-selector default remain unchanged. Deprecating any
compatibility identity requires separate consumer review and approval.

## Scope and consumer review

Only the README product heading and six rendered status/hub titles, headings
and footers change branding. The architecture naming note distinguishes target
security architecture from current behavior and preserves baseline attribution.
No Python package, import or CLI rename is needed for these presentation changes.
`status/test_hub_urls.py` renders synthetic fixtures without Docker or network;
it covers all existing TLS selections, the new labels, the retained diagnostic
download filename and the HTTP server identity.

The following tables cover every baseline inventory occurrence in the three
modified product/source documents. IDs and locations refer to the immutable
[audit inventory](inventory.csv) at baseline
`c2286bcd266e1924797fc787a677e6f8aa2d94da`, not current line numbers.
The original inventory, classifier and counts remain immutable. New explanatory
references in these documents describe the current identity and are retained
until cutover. The modified URL test has no matching baseline records.
Audit documents and generated maps retain historical examples and actual paths;
editing status prose does not reclassify their historical occurrences.

## Manual-review decisions before edits

These nine records are resolved for this bounded scope. Preservation decisions
retain their exact resource identity; they do not approve an operational change.
Other unresolved manual-review records remain unchanged in #148/#149 until
consumer review. The baseline count of 125 is historical, not a remaining-work count.

| Audit ID | Decision and consumer rationale |
| --- | --- |
| A00198 | Rename product heading; Markdown heading has no resource-selection consumer. |
| A00202 | Preserve network name; Compose and service DNS consumers require the existing identity (D06). |
| A00203 | Preserve network table entry to match actual Compose networking (D06). |
| A00237 | Preserve clone-directory command while the repository still has its old name; update with clone URL at #150 (D01). |
| A00295 | Preserve network teardown names to match uninstall consumers (D06). |
| A00296 | Preserve systemd unit names to match deployed unit contracts (D05/D07). |
| A00306 | Preserve account names to match host ownership and backup consumers (D05/D07). |
| A00314 | Preserve credential directory and unit names to match the uninstall allowlist (D05/D07). |
| A01361 | Preserve repository identifier in scoped-worker example until #150; product naming grants no new repository scope. |

## Complete scoped occurrence disposition

Ranges below are inclusive inventory IDs within the named file. Retention is
intentional; a preserved match is not evidence of unfinished branding work.

| File / baseline IDs | Disposition and consumer |
| --- | --- |
| `README.md`: A00198 | Rename visible presentation only; no operational resource selection (D01/D11). |
| `README.md`: A00199–A00200, A00235–A00236 | Preserve active canonical URL until #150 activation; current links must continue working (D01). |
| `README.md`: A00201, A00239–A00240, A00315 | Preserve historical attribution, technical terminology, separate worker/image identity or current-behavior examples under the original inventory rationale (D01/D09/D16). |
| `README.md`: A00202–A00203, A00237, A00295–A00296, A00306, A00314 | Preserve after explicit consumer review in the manual-review table above. |
| `README.md`: A00204–A00234, A00238, A00241–A00294, A00297–A00305, A00307–A00313 | Preserve settings, paths, service/container/network identities and diagnostic interfaces; consumers retain existing spelling (D04–D07/D11). |
| `docs/haven/ARCHITECTURE.md`: A01360 | Preserve historical attribution, technical terminology, separate worker/image identity or current-behavior examples under the original inventory rationale (D01/D09/D16). |
| `docs/haven/ARCHITECTURE.md`: A01361 | Preserve after explicit consumer review in the manual-review table above. |
| `docs/haven/ARCHITECTURE.md`: A01362–A01368 | Preserve active canonical URL until #150 activation; current links must continue working (D01). |
| `status/app.py`: A04433–A04440, A04445, A04449–A04450 | Preserve settings, paths, service/container/network identities and diagnostic interfaces; consumers retain existing spelling (D04–D07/D11). |
| `status/app.py`: A04441 | Preserve diagnostic bundle heading as part of the diagnostic interface; excluded from this titles/headings/footers change (D11). |
| `status/app.py`: A04442–A04444, A04446–A04448 | Rename visible presentation only; no operational resource selection (D01/D11). |

## Delivery, later gates and rollback

The following section records the historical presentation-stage handoff.

#147 is complete under the recorded owner decision. PR #155 completed the
bounded #149 identity selector preparation, with the old identity still default;
see [COMPATIBILITY.md](COMPATIBILITY.md). #149 still owns combined readiness,
runbook and integration evidence despite its observed closed tracking state.
This implementation does not update issue metadata or claim #149 completion.

E01–E20 in [EXTERNAL.md](EXTERNAL.md) retain their designated owners and gates:
#149 prepares evidence including host/backup/worker/registry and integration
readiness; #150 owns go/no-go, identity activation, remotes, freeze and cutover;
#151 owns sustained post-cutover checks and cleanup. Owner-only checks do not
block this independent presentation PR. Canonical URL activation remains
explicitly deferred to #150; compatibility aliases and diagnostic identities
are retained through this epic, with any later deprecation requiring consumer
evidence and separately reviewed scope.

Validation requires the rendering fixture, immutable audit check, documentation
links, pinned map generation/freshness and repository static parity, followed
by current-head required CI/SAST. Exact executed results belong in
[VALIDATION.md](VALIDATION.md) and the PR. Skips are not passes.

Before publishing, inspect automation: feature-branch/PR events run validation;
main merges can deploy and run the map bot. Merge/deployment require separate
owner approval. No infrastructure, credential, domain, cookie, image, host
path or inference-policy change is part of this PR. No independent human
approval or live operational verification is claimed.

Rollback is a reviewed revert of presentation/docs changes. A deployed revert
requires separate deployment authorization; reverting does not undo external
configuration. Preserve data and existing compatibility identities.
