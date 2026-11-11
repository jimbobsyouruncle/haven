# ADR-0005 — Evidence-based issue completion

**Status:** Proposed operating decision; no merge, closure or deployment authorization.

## Context and proposed decision

Haven already accepts passing automated evidence. Reviews still need consistent separation of implemented, merged, deployed, runtime-verified and completed work, particularly when merged PRs leave issues open or optional verifier probes skip.

Extend the existing root AGENTS.md completion policy for every entry point, including `haven next` and `haven issue`. Map acceptance criteria to existing check/run/receipt evidence, revision, environment and observed coverage. Preserve PASS, WARN, FAIL, SKIPPED, PENDING, NOT_APPLICABLE and missing evidence distinctions. Reuse sufficient valid evidence and request additional runtime observations only for an explicit unmet criterion or concrete uncovered operational risk. Honor accepted completion despite stale checkboxes; reconcile contradictory issue descriptions rather than restarting work. Select the next open unblocked issue in approved order using changes since accepted review, without requiring an epic-wide audit each time. Classify gates separately from test observations and keep development, deployment, cutover and closure distinct. Reconcile issues only with explicit authorization and idempotent in-place updates; closure still requires separate owner approval. Consequential decisions stay in their owning GitHub issue with evidence, responsible role, next action and reconsideration condition. Use sanitized evidence without private infrastructure or personal identifiers.

## Alternatives and consequences

A new evidence format/service would duplicate existing GitHub results and schema-v2 deployment receipts without fixing interpretation. Mandatory manual retesting wastes successful evidence and can introduce operational risk. Treating merge or deployment success as universal completion hides unexecuted criteria. Use the existing sources with explicit scope and provenance instead; unknown or contradictory coverage remains an identified gap.

This policy guides agent reviews; it does not mechanically enforce local launcher behavior. The launcher remains developer-local and unchanged. Existing implementation approval, current-head CI, review readiness, branch protection, restricted inference and operational authorization remain authoritative. This proposal does not revise ADR-0001's approved isolation/inference principles or ratify other proposed ADRs.

## Verification

Apply the [review procedure and regression scenarios](../evidence-completion.md), retain existing verifier/status/doctor fixture coverage, and validate repository maps and required PR checks. No runtime rollout or repeated production backup/restore test is required to validate documentation changes.
