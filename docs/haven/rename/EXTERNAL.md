# External evidence checklist — pending authorization

Nothing in this checklist is verified by the public source inventory. Source documents identify expected consumers; they do not prove installed host state or GitHub account configuration. The owner must assign a named operator, authorize each scope separately, and attach sanitized result/identifier/date evidence. Do not collect tokens, environment-file contents, logs, personal data or full backup manifests into this PR. No external item is waived by an empty result or lack of access.

See [READINESS.md](READINESS.md) for acceptance/evidence links, proposed phase
ownership, collection format, freeze/resume, activation and rollback. The
2026-11-11 UTC reconciliation reuses owner-recorded E04 evidence and current
GitHub evidence below. Other items remain pending or partially covered; a
successful deployment does not complete the external checklist. Proposed roles
still need named operators, authorizations and milestone assignments.

| ID | Evidence required / proposed owner | Prerequisite / safe evidence | Status / gate |
| --- | --- | --- | --- |
| E01 | Pi deployed SHA, OS/ARM64, host layout, active units/timers — Pi owner | Separate host read authorization; report identifiers and agreement with source, no secret files | PENDING for complete host/layout/unit agreement; recorded `jarvis` SHA and newer successful deploy runs provide bounded partial evidence, not latest installed-state attestation |
| E02 | Deployment forced command, account, polkit, unit/path agreement — Pi owner | Separate host authorization; pass/fail for expected contract, not key material | Pending / #149 |
| E03 | Deployed images and rollback availability — Pi/registry owner | Separate access; record digest/platform/availability, not credentials | Pending / #149 |
| E04 | Current backup completeness, snapshot selection and scratch restore — backup owner | Separate backup/data authorization and suitable inference policy; report snapshot ID, result and restore time only | VERIFIED for owner-recorded snapshot `65235d97`, complete capture, sampled integrity and isolated restore, 20/20 SQLite checks, 5m01s on 2026-11-10; [evidence and limits](READINESS.md#accepted-backup-evidence-and-operational-limits). No repeat requested |
| E05 | R2 repository/bucket/keys and schedules remain stable — backup owner | Identifier-only attestation; no bucket rename or key rotation | Pending / #149 |
| E06 | Production environment reviewer protection and deploy freeze — GitHub owner | Separate settings authorization; report protection and freeze/resume owner | Pending / before operational preparation merges |
| E07 | Current ruleset/check names and human PR review policy — GitHub owner | Revalidate at cutover; planning observation: active main-protection requires Check agent context maps and Security & SAST gate, no pull-request review rule | VERIFIED current required check names via main rules read on 2026-11-11 UTC; no PR-review rule returned. PENDING owner review-policy disposition and cutover/#151 revalidation |
| E08 | Repository target name available; public visibility/default branch/ID preserved — GitHub owner | Separate rename approval for any change; expected repository ID 1380300964 | Pending / #150 go/no-go |
| E09 | Apps/installations, OAuth callbacks, webhooks, marketplace/third-party consumers — integration owners | Separate settings access; checklist of owners, URL actions, callback delivery results; no secret values | Pending / #149 and #150 |
| E10 | Actions secrets/variables and environment-scoped dependencies — GitHub owner | Names/presence/consumers only; do not read or rotate values | Pending / #149 |
| E11 | GHCR package association, pull/write permissions, ARM64 manifests — registry owner | Separate registry verification; preserve package names and digests | Pending / #149 and #151 |
| E12 | Deployment, OpenHands and developer clone fetch/push remotes — clone owners | Separate local-config authorization; credential-safe normalized target/ID results only, never raw remote output | Pending / #150 |
| E13 | Hermes reference clone/manifests/bookmarks/kanban repository references — Hermes owner | Separate profile/config scope; reconcile only this repository; preserve dirty work and stale clone until verified | Pending / #149 and #150 |
| E14 | OpenHands workspace/state and repository integration — OpenHands owner | Separate host/profile authorization; preserve mounts/conversations, test approved repository operation | Pending / #149 and #151 |
| E15 | RunPod worker API/auth/model/image/network contract — worker owner | Separate task/repository authorization or owner-supplied versioned contract; synthetic integration results | Pending / #149 hard gate; worker repository NOT accessed |
| E16 | Caddy certificate storage, renewal monitoring and domain health — Pi/TLS owner | Separate host/network approval; public handshake/result only; keep domains/issuer/token paths stable | Pending / #149 and #151 |
| E17 | Scheduled sync, map bot, image publisher and deployment freeze — automation owners | Separate control approval; no workflow dispatch or enable/disable in this audit | Pending / #150 |
| E18 | Outside documentation, Pages/custom domains, hosted action/reusable workflow consumers — integration owners | Separate consumer inventory; preserve old-name redirect; do not create replacement at old slug | Pending / #149 |
| E19 | Canary/smoke results, downtime tolerance, change window and rollback operator — owner | Explicit operational approval; exact revision, results and stop conditions | Pending / #150 |
| E20 | Sustained verification interval, first successful backup after cutover, cleanup approval — owner | Observation policy and separately approved checks; retained aliases allowed | Pending / #151 |

## Outstanding owner decisions

- Accept the proposed preservation of runtime names, environment settings, host paths/accounts/units, cookie names, snapshot tags, Caddy domains/storage and separate image packages for this epic.
- Assign owners and authorization/evidence routes for E01–E20. Public-source inspection alone cannot complete these gates.
- Review the supplemental [108 per-occurrence decisions](MANUAL-DECISIONS.md), alongside the 17 existing merged decisions: all 125 historical manual-review records are accounted for. Source preservation is distinct from external verification; operational actions stay at their designated gates. Do not modify the immutable baseline.
- Decide whether human review should be technically required in GitHub rules, and whether the map bot's automatic merging remains desired. This audit changes neither.
- Define freeze/resume procedure, permissible downtime, rollback threshold and post-cutover observation interval.
- Keep #147 closed under the owner's recorded acceptance of public-source completion. The original keep-open request is superseded; E01–E20 remain required in their #149/#150/#151 phases and are not waived.

Issue-body dependencies observed in planning: #147 precedes #148/#149; both precede #150; #151 follows #150. No native blocking relationships or assignees were present. The owner may add them separately; this PR does not edit issue metadata.

## Evidence collection sequence

First reuse the public GitHub/owner evidence linked in READINESS.md. No
additional owner diagnostic is required for this documentation deliverable.
Before #150, named operators must supply only each remaining item's minimal
sanitized attestation: evidence ID, operator, UTC date, revision/artifact ID,
environment, coverage/outcome, approver and next gate. Keep raw runtime data
on its approved route. For E15, a versioned contract plus synthetic results
avoids granting this task the worker source tree. For newer verifier evidence,
first confirm installed SHA/environment and receipt provenance; do not invent
a data directory or rerun the verifier to compensate for missing access.

E04 is no longer a pending restore request. E20 still requires the distinct
first successful backup after cutover and the agreed observation interval;
pre-cutover evidence cannot satisfy a future event. No cutover approval is
recorded by this reconciliation. #148/#161 closure does not complete #149 or
waive external gates.
