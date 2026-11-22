# ADR-0001 — Persona-scoped coding access and restricted inference

**Status:** Revised owner-approved principle (2026-11-22; supersedes the universal task-worker requirement approved 2026-11-07). Runtime enforcement not proven.
**Related:** [ADR-0008](0008-persona-runtime-isolation.md), [decision register](../DECISIONS.md).

## Context and decision

A reusable Coder *definition* may serve multiple projects, but authorization and execution are bounded by the **persona runtime environment**, not by its instructions. The owner has chosen separate persistent personas for sensitive coding projects. A persona may run Hermes, Agent Canvas, an Agent Server and coding tools under one dedicated unprivileged host UID/GID, with shared persona-authorized storage and credentials under ADR-0008. A separate worker per coding task or per repository is **not universally required**.

Assign repositories, local checkouts, configuration and credentials only to personas authorized to use them. A persona-specific fine-grained GitHub token, deploy key or equivalent credential limits **remote** repository access to the minimum necessary repositories and permissions. Credential restrictions do **not** protect any local checkout, file, secret or socket already accessible to the persona; intra-persona code execution is trusted only to the extent of the entire persona's authorized resources. Treat compromise of one coding app or task as compromise of all resources accessible to that persona.

Sensitive projects requiring isolation from the general Developer persona must use a **separate persona runtime** with different host UID/GID, private storage, credentials and container/network grants. No other persona's repositories or private secrets may be mounted into it. Where distinct tasks or collaborators inside one persona require mutually exclusive local access, stronger task-scoped workers and explicit grants remain required; alternatively split them into separate personas. Task-level policy can narrow access but cannot claim isolation while sharing an unrestricted Unix identity and filesystem.

## Inference provider selection and data protection

**Public development.** The general Developer persona may use configured public inference providers, local models, or RunPod for authorized public development tasks in Canvas, ACP, Hermes and other supported applications. Provider selection is a normal user capability. Public development must not depend on dedicated RunPod availability or fail-closed restricted-mode enforcement. A public repository does not make local secrets, private attachments, other personas' resources or private conversation context public: authorized agent resources and provider-bound content must still be scoped appropriately.

**Private and restricted development.** Sensitive projects requiring isolation from general development use separate persona runtimes and scoped resources under ADR-0008. RunPod may be selected for private inference, but that selection alone does not prove protected routing. If a dedicated **protected restricted-inference mode** is implemented and explicitly enabled, enforce its approved-provider restrictions for every model operation handling restricted data (including delegated and ancillary calls), with no unauthorized fallback on outage or credentials/configuration failure. Until those controls have been verified, do not advertise a fail-closed private inference guarantee or silently disclose restricted data to public inference providers.

**Independent protections.** Persona isolation and human-user authorization protect data, credentials and repositories regardless of inference provider selection. Application capabilities should remain available to authorized users; authorization should narrow access to sensitive resources rather than disable features globally.

Agent-accessible containers must not receive host Docker/container-management sockets, privileged execution, broad host mounts or unrestricted infrastructure credentials. If an engine requires these to launch per-conversation containers, keep that control with a separate trusted component or use a safe compatible execution mode; do not grant the engine a privileged socket simply to avoid per-task workers.

## Alternatives and accepted tradeoffs

Universal one-task/one-repository ephemeral workers and short-lived per-task GitHub App leases provide stronger task containment but add provisioning, state and integration complexity. They are optional for projects whose authorized trust boundary is the persona; they remain an available stronger mode when task separation is actually necessary. Persona separation increases configuration and resource duplication, deliberately accepted for sensitive projects.

Fine-grained credentials restrict remote GitHub operations, not local filesystem reads or writes. Multiple authorized repositories inside one persona may be accessible to any code running as its UID. Do not claim per-task repository isolation unless separately implemented and verified.

## Evidence gate

Public-repository Canvas activation requires authenticated HTTPS, API and WebSocket access; authorized repository and credential scopes; an unprivileged agent runtime without host container-management sockets or broad host mounts; and effective separation from other personas' private storage, secrets, checkouts and services. Verify usable native Canvas development with a selected public inference provider, and check Hermes independence and supported interoperability separately. Follow the normal PR, CI, owner-merge and automatic deployment path. A comprehensive rollout of all future personas, universal task-scoped workers, and dedicated RunPod fail-closed restricted-mode routing are **not** prerequisites for public Canvas activation. Document limits and unverified protections rather than claiming them deployed.

If protected restricted inference is enabled in the future, separately verify approved RunPod-only routing, endpoint outage and fallback denial for Canvas and ACP before describing that mode as enforced.
