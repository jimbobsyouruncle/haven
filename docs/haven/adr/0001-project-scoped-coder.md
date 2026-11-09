# ADR-0001 — Project-scoped Coder and restricted inference

**Status:** Approved principle (HAVEN-PROJECT-001, 2026-11-07); runtime enforcement not proven.

## Context and decision

One reusable Coder serves multiple projects. The trusted control plane, not persona instructions, enforces per-task immutable repository IDs, project memberships, branch scope, credential leases and explicit repo groups. Default worker is one repo, one worktree, one short-lived GitHub App token. Delegation can only narrow scope. Every model operation involving restricted content, including coordinator, review, embeddings and subagents, uses an approved dedicated RunPod deployment without fallback. Enforce through trusted broker and network egress.

## Alternatives and consequences

A persona per repo duplicates configuration without proving isolation; a multi-repo worker increases blast radius. Dedicated RunPod is still third-party cloud hosting. Both repositories require versioned API contracts and independent integration CI.

## Evidence gate

Negative repo/symlink/cache/delegation tests, scoped-token checks, DNS/IPv6/redirect/proxy egress tests, RunPod outage/fallback tests and model capability probes. Do not claim deployment until proven.
