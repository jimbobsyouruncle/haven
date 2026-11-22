# ADR-0001 — Persona-scoped coding access and restricted inference

**Status:** Revised owner-approved principle (2026-11-22; supersedes the universal task-worker requirement approved 2026-11-07). Runtime enforcement not proven.
**Related:** [ADR-0008](0008-persona-runtime-isolation.md), [decision register](../DECISIONS.md).

## Context and decision

A reusable Coder *definition* may serve multiple projects, but authorization and execution are bounded by the **persona runtime environment**, not by its instructions. The owner has chosen separate persistent personas for sensitive coding projects. A persona may run Hermes, Agent Canvas, an Agent Server and coding tools under one dedicated unprivileged host UID/GID, with shared persona-authorized storage and credentials under ADR-0008. A separate worker per coding task or per repository is **not universally required**.

Assign repositories, local checkouts, configuration and credentials only to personas authorized to use them. A persona-specific fine-grained GitHub token, deploy key or equivalent credential limits **remote** repository access to the minimum necessary repositories and permissions. Credential restrictions do **not** protect any local checkout, file, secret or socket already accessible to the persona; intra-persona code execution is trusted only to the extent of the entire persona's authorized resources. Treat compromise of one coding app or task as compromise of all resources accessible to that persona.

Sensitive projects requiring isolation from the general Developer persona must use a **separate persona runtime** with different host UID/GID, private storage, credentials and container/network grants. No other persona's repositories or private secrets may be mounted into it. Where distinct tasks or collaborators inside one persona require mutually exclusive local access, stronger task-scoped workers and explicit grants remain required; alternatively split them into separate personas. Task-level policy can narrow access but cannot claim isolation while sharing an unrestricted Unix identity and filesystem.

For any model operation involving restricted content (including coordinator, planning, coding, review, embeddings or delegated agents), require the approved dedicated RunPod inference deployment; no fallback to an unapproved endpoint. Enforce this outside agent prompts through trusted routing, egress policy and fail-closed behavior. An inaccessible mandatory endpoint must block the operation. Independent persona and user authorization remain required for shared services.

Agent-accessible containers must not receive host Docker/container-management sockets, privileged execution, broad host mounts or unrestricted infrastructure credentials. If an engine requires these to launch per-conversation containers, keep that control with a separate trusted component or use a safe compatible execution mode; do not grant the engine a privileged socket simply to avoid per-task workers.

## Alternatives and accepted tradeoffs

Universal one-task/one-repository ephemeral workers and short-lived per-task GitHub App leases provide stronger task containment but add provisioning, state and integration complexity. They are optional for projects whose authorized trust boundary is the persona; they remain an available stronger mode when task separation is actually necessary. Persona separation increases configuration and resource duplication, deliberately accepted for sensitive projects.

Fine-grained credentials restrict remote GitHub operations, not local filesystem reads or writes. Multiple authorized repositories inside one persona may be accessible to any code running as its UID. Do not claim per-task repository isolation unless separately implemented and verified.

## Evidence gate

Before production Canvas coding activation, verify effective persona UID/GID, private mounts/storage and secrets, cross-persona filesystem/network denial, no privileged sockets or capabilities, repo token scopes, unauthorized remote repo access, and authorized user/service access. Verify an agent cannot reach another persona's repository checkout or credentials. Test mandatory RunPod-only routing, endpoint outage and fallback denial for Canvas and ACP. Verify native Canvas workflows, authenticated HTTPS/WebSockets and Hermes interoperability independently. Do not claim enforcement or deployment until demonstrated.
