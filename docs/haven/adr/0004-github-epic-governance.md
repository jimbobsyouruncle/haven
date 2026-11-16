# ADR-0004 — GitHub epics and agent governance

**Status:** Proposed; no autonomous GitHub mutation authorized.

## Context and proposed decision

Use GitHub Issues/Projects as the canonical cross-repository backlog. Epics have child issues, dependencies, acceptance criteria, owners and evidence. The Review Agent conducts authorized read-only reviews; the Architecture Agent defines scoped interfaces and acceptance criteria; the Coordinator tracks authorized work. The Implementation Agent follows the [canonical root workflow](../../../AGENTS.md#standard-development-workflow): explicit bounded implementation authorization covers implementation, testing, draft PR creation, CI remediation and review readiness, subject to mandatory owner decisions for consequential security risks before PR creation. Implementation Cards apply to recommendations or missing authorization, not as a repeated approval gate. Only the Human Owner merges; no agent may merge, enable auto-merge, bypass branch protection or delegate merge authority. A proposed backlog-management persona requires least-privilege authorization and cannot deploy, access secrets or self-escalate.

The backlog design remains proposed. Development behavior is governed by root AGENTS.md, independently of harness or model, including multi-model harnesses. The local `haven` launcher supplies standardized modes and prompts outside the repository; it does not override that policy.

`haven new-epic` proposes ranked, deduplicated candidate epics and child issues, without creating them. `haven next` checks closure eligibility before recommending the next issue. Closure requires all required child issues resolved and epic acceptance gates evidenced, with owner-approved deferrals tracked separately. Backlog creation, issue updates and closure need explicit approval; ordinary implementation PR operations are covered by bounded implementation authorization under root policy.

## Tradeoffs and verification

Automatic creation/closure is faster but risks duplicates and skipped owner gates. Review live issues, PRs, check results and both repositories where authorized. Passing CI is not proof of unexecuted production checks.
