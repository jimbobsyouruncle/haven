# ADR-0004 — GitHub epics and agent governance

**Status:** Proposed; no autonomous GitHub mutation authorized.

## Context and proposed decision

Use GitHub Issues/Projects as the canonical cross-repository backlog. Epics have child issues, dependencies, acceptance criteria, owners and evidence. Codex conducts read-only reviews, prepares Implementation Cards, and after explicit scoped approval implements and remediates CI to review-ready PRs. A future Hermes PM persona may groom issues with least-privilege permissions but cannot merge, deploy, access secrets or self-escalate.

`haven new-epic` proposes ranked, deduplicated candidate epics and child issues, without creating them. `haven next` checks closure eligibility before recommending the next issue. Closure requires all required child issues resolved and epic acceptance gates evidenced, with owner-approved deferrals tracked separately. GitHub changes, including epic closure, need explicit approval.

## Tradeoffs and verification

Automatic creation/closure is faster but risks duplicates and skipped owner gates. Review live issues, PRs, check results and both repositories where authorized. Passing CI is not proof of unexecuted production checks.
