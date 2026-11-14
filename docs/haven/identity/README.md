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
3. **External:** worker repository, GHCR artifacts and dependencies. Coordinate
   publication and compatibility before switching consumers.
4. **Historical:** previous audit and ADR records. Preserve evidence; add explicit
   supersession links. Historical Git, closed issues and snapshots are immutable.
5. **Obsolete compatibility:** old repository selector and aliases. Remove active
   selection only after all callers use Haven; retain narrowly scoped import and
   recovery readers where historical artifacts require them.

## Implementation Card — architecture and discovery packet

Objective: document the complete consolidation before changing coupled security
and storage behavior. Files: this directory, ADR-0007, decision index, generated
maps and one additive offline inventory test step in `validate.yml`.
Deliverable: draft PR, then Ready after current-head required checks pass;
parent epic and seven dependent tracking issues. Branch:
`feature/haven-final-identity`. No automatic issue closure.

The owner has explicitly authorized repository implementation and PR preparation;
no repeated implementation permission is requested. Security-sensitive runtime
implementation must receive the architecture review required by AGENTS.md before
changing accounts, polkit, firewall, deployment authorization or storage handoff.
Subsequent bounded PRs follow the issue order below; this first PR changes none of
those runtime contracts. Rollback: revert the documentation/tooling commit.
Validation: reproducible inventory, scanner refusal fixtures, map freshness,
repository static checks and required GitHub checks. Risks: source cannot reveal
private host overrides or external account policies; cutover must refuse unknown
layouts rather than guessing. No private host discovery is authorized here.

## Delivery order and review boundaries

Tracking: [epic #193](https://github.com/jimbobsyouruncle/haven/issues/193);
source/config #194, units/accounts #195, Docker #196, data/backups #197,
security/integrations #198, continuous deployment #199, runtime/retirement #200.
Prepare #197's mappings/readers with #194, then #195/#196 against those contracts;
#198 reviews security design before their sensitive implementation and validates
the integrated result. #199 can be tested inertly in preparation; #200 accepts
canonical runtime before #199 activation and returns for final CD/cleanup gates.
This is a staged dependency, not a cycle requiring CD before canonical acceptance.

1. Review this architecture, inventory and migration threat model.
2. Prepare data/backup migration and historical restore readers; prepare canonical
   config and source consumers. Neither may activate the new stack independently.
3. Prepare systemd/account and Docker handoffs behind the same inactive,
   versioned migration transaction. Security/integration tests bind the pieces.
4. Prepare automatic deployment in an inert candidate with no production trigger
   or activation path from a normal merge. Manual recovery remains available.
5. Merge reviewed preparatory PRs by owner action. Freeze production deployment,
   authorize one coordinated cutover only when all implementations are ready.
6. Run runtime acceptance, then separately authorize automatic deployment;
   demonstrate a protected-main merge and recovery. Only then approve cleanup.

Data mapping is designed before Docker recreation; account and firewall consumers
are ready before the new network or SSH entrypoint activates. Keep the preparation
period on the existing identity. Split PRs may add dormant modules and fixtures,
but must not change production defaults piecemeal. A bounded maintenance window
performs one activation, avoiding prolonged split operation.

See [ADR](../adr/0007-complete-platform-identity.md),
[cutover/recovery/cleanup](CUTOVER.md) and
[automatic deployment acceptance](CONTINUOUS-DEPLOYMENT.md).

OWNER ACTION GATE: architecture/security review before runtime implementation.
Production execution, secrets/settings changes, repository rename, automatic
deployment activation, cleanup and issue closure each require separate explicit
owner authorization. This packet is implementation planning, not platform
completion or production acceptance.
