# Final platform identity consolidation

This is the new scope requested by the owner on 2026-11-14. It supersedes
indefinite identity retention, not the completion of earlier work. #146, #151,
#186 and #187 remain closed. The owner reports revision
`f67c5f0ee4c08afaa7ab7559083b8acec26bdc1d` installed at `/opt/haven`, accepted
transaction and matching schema-v2 receipt with all eight mandatory gates PASS,
seven primary containers, operational backups, canonical deployment/maintenance
paths and a retained legacy installation for recovery. This packet does not
independently inspect production or invalidate that accepted evidence.

## Public source inventory

Haven baseline: `bdfbbc6269bf3b5d6430b13cdea587c833ea1832` (merged #192).
Worker baseline: `cf402976b09d8d155c62f5f4b83d174b35d3521f`.
Both repositories were public at inspection. The worker was reviewed read-only;
no worker contract, repository name, image or deployment was changed.

The [CSV](inventory.csv) records every matching filename and content occurrence
in **every regular tracked file at both revisions**, including tests, fixtures,
generated maps, historical audit artifacts and documentation. The
[manifest](manifest.json) includes every scanned file and its Git/SHA256 identity;
the [summary](summary.json) reconciles counts. There are 211 files and 10,234
occurrences (10,228 Haven; 6 worker). Counts include references inside the
previous inventory; they are not counts of edits. Pattern: case-insensitive
`hybrid`, optional `-ai`, `_ai` or space form, and identifier suffixes. This also
catches lowercase Python namespaces, image tags, legacy paths and labels.
Standalone technical uses of “hybrid” require semantic review, not renaming.

Reproduce with the authorized worker checkout containing its pinned revision:

```sh
python3 docs/haven/identity/inventory.py --worker /path/to/public-worker --check
```

The scanner reads Git objects, never ignored files, `.env`, credentials, runtime
logs, backup payloads, submodules or symlinks. Nonregular entries and invalid
UTF-8 fail rather than silently disappearing. Line 0 means a filename;
other positions are one-based Unicode positions. Only token and line hash are
stored, not source lines. This is an immutable discovery baseline, not a
current-head absence gate. A final implementation must add a current-source gate
with a reviewed, narrowly bounded migration/history allowlist.

## Classification and disposition

CSV categories use the owner's five classes. They are conservative lexical
triage; the [dependency register](DEPENDENCIES.md) governs semantic changes.
A line can have multiple contracts; its primary triage does not exempt its
other consumers. In particular, tests and docs describing current behavior must
change with that behavior, while their immutable baseline records stay intact.

1. **Active:** source, config, operational docs, tests and generated navigation.
   Change consumers together; regenerate maps with the pinned generator.
2. **Persistent/security:** state paths, credentials, cookie, account, lock,
   authorization and backup selectors. Controlled transaction and negative tests.
3. **External:** worker repository and published application contracts remain unchanged.
   No worker publication or rename is a Haven dependency.
4. **Historical:** previous audit and ADR records. Preserve evidence; add explicit
   supersession links. Historical Git, closed issues and snapshots are immutable.
5. **Obsolete compatibility:** old repository selector and aliases. Remove active
   selection only after all callers use Haven; retain narrowly scoped import and
   recovery readers where historical artifacts require them.

## Approved architecture and implementation proposals

Owner-approved simplified architecture: personal single-owner Pi deployment,
bounded extensions to ADR-0006, canonical Haven-owned identities, unchanged
third-party applications and worker, existing verification and automatic deployment
through the existing Actions/host mechanism. Exact code, host mappings and trigger
wiring remain implementation proposals subject to normal review and tests.

The worker repository is entirely excluded from epic #193 and #194–#200 changes,
dependencies, deliverables and acceptance criteria. Its historical inventory is
read-only compatibility evidence, never an action list. Preserve its deployed
source/images/logs/configuration/API/deployment/infrastructure exactly. Optional
future worker proposals require separate owner approval and cannot block Haven.

## Three cohesive implementation PRs

| PR | Traceability | Bounded deliverable |
| --- | --- | --- |
| Canonical Haven source and configuration | #194; relevant #198 checks | Platform namespaces/config/templates/callers and focused fixtures; preserve application identities and worker contracts |
| Coordinated host, accounts, persistent data and Docker migration | #195–#198; #200 cutover/acceptance | One coherent extension of existing transaction, locks/recovery, accounts/SSH/polkit, backup mappings, mounts and firewall; existing verification extensions and operator checklist |
| Automatic deployment preparation and activation | #199; #200 deployment evidence | Existing Actions/host path, trusted exact-main validation, serialized deploy and mandatory verification; manual recovery; activation only with production authorization |

The seven issues remain traceability workstreams, not seven PR prerequisites.
Coordinate mappings within the second PR; adjust boundaries only for safe atomic
deployment or reviewability. The third PR can be prepared alongside stable interfaces;
production activation follows accepted canonical cutover. No extra activation PR,
reconciliation service, generalized filesystem engine, retirement-manifest engine
or second comprehensive verifier is required.

## Canonical configuration preparation

See the [configuration handoff](CONFIGURATION.md) for canonical source interfaces,
transitional installed readers, literal alias/refusal rules, credential preservation,
one-time auth re-login and recovery boundaries. Host resource names and paths stay
at their existing values until the coordinated handoff; source preparation alone
does not activate the final platform identity or continuous deployment.

## Architecture baseline and authorization

PR #201 revised architecture documentation and live issue/PR dispositions; it
implemented no migration code. Rollback is a documentation
revert; it does not affect production. Validate inventory integrity/scanner fixtures,
map freshness, static checks and current-head CI/SAST. Preserve baseline inventory
and ADR-0006/#187 evidence rather than rescanning completed runtime work.

Owner authorization already covers bounded implementation PR preparation; no
additional permission is requested. Security-sensitive implementation receives
normal review of exact changes. Production cutover/configuration, automatic
deployment activation, cleanup, merges and issue closure remain owner actions.

OWNER ACTION GATE: CLEAR for this revision and authorized PR preparation.
Future production authorization is REQUIRED LATER, not a documentation blocker.
See [ADR-0007](../adr/0007-complete-platform-identity.md),
[cutover/recovery/checklist](CUTOVER.md), [dependencies](DEPENDENCIES.md) and
[automatic deployment](CONTINUOUS-DEPLOYMENT.md).
