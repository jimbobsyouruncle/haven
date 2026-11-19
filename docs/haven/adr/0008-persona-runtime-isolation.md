# ADR-0008 — Persona runtime, host filesystem, and secret isolation

**Status:** Approved owner requirement (2026-11-19). Implementation and runtime enforcement are unverified.
**Related:** [HAVEN-SEC-012](../DECISIONS.md), [ADR-0001](0001-project-scoped-coder.md), [ADR-0002](0002-persona-credentials.md), [ADR-0003](0003-ciso-persona.md), and the [architecture](../ARCHITECTURE.md).

## Isolation boundary

A **persona definition** supplies reusable behavior, instructions, skills and configuration. Haven's trusted control plane grants access independently of that definition. A **persona runtime environment** enforces isolation between persistent personas through dedicated application containers, a Unix identity, private storage and secrets.

Each persistent persona must have a dedicated unprivileged Unix UID/GID on the Haven host. Different personas must have distinct host UIDs and GIDs that are never reassigned to another persona. Every application container belonging to one persona may use that same UID/GID and share designated storage. The security boundary is the persona runtime. A compromised application may expose any resources accessible to that persona identity. This is an accepted tradeoff. Narrow application mounts where practical and use ordinary ownership and permissions rather than adding per-application identities or complex ACLs.

Each persona owns an isolated persistent tree. Default private directories to mode `0700` and sensitive files to `0600`, or equivalently restrictive permissions. A persona container may mount only the private storage authorized for its own persona. Prohibit mounts of another persona's private storage, including read-only mounts. Deny privileged host access, container-management sockets, broad host mounts, privilege escalation and unnecessary Linux capabilities. Cross-persona network access is denied by default. Access to shared services requires explicit, narrowly scoped authorization.

A persona's passwords, tokens, API keys and other secrets must be inaccessible to every other persona through mounts, environment files, images, logs, shared configuration and management interfaces. Keep infrastructure credentials outside persona mounts. Trusted provisioning and backup/restore services may access only what their operational role requires. Backups and restores must preserve ownership, access controls, applicable encryption keys and persona separation. [ADR-0002](0002-persona-credentials.md) governs proposed credential delivery and lifecycle.

Project/task authorization and human user privacy apply independently. Persistent Developer applications sharing a UID/GID gain only explicitly authorized project/task access under [ADR-0001](0001-project-scoped-coder.md). Task-scoped workers retain independent isolation and do not inherit the Developer runtime's filesystem grants. Human users sharing a persona retain independently authorized private data and conversations. Shared application storage or services must enforce those user and project boundaries.

## Applications and access

A persona may have any number of applications. Examples include Financial Planner with Hermes and Obsidian or another knowledge base, Graphic Designer with Hermes and ComfyUI, Developer with Hermes and Agent Canvas, and CISO with Hermes and authorized security tools.

Applications may keep their native WebUIs behind Haven's existing Caddy reverse proxy and planned identity architecture. Use flat persona-service hostnames such as `finances-hermes.daemonhub.dev`, `finances-notes.daemonhub.dev`, `designer-comfyui.daemonhub.dev` and `developer-canvas.daemonhub.dev`. These names are illustrative. Require authentication and authorization for each persona/service and prevent bypass through direct backend access, internal networks or spoofed identity headers. A universal frontend is unnecessary.

The Matrix design uses a shared, non-federated Synapse homeserver and Matrix Authentication Service. Each Hermes persona may connect to its own authorized private rooms with an independent bot account, credentials and device/encryption state. Enforce room authorization and Haven's trusted authorization checks independently. Preserve E2EE where applicable and review public-facing Matrix and OIDC routes.

Personas may use authorized inference services, including RunPod, under Haven's existing classifications and routing policy. Every model operation involving restricted content must use the approved dedicated RunPod deployment and fail closed. ComfyUI and other media applications may require contracts distinct from the current vLLM interface. Image-generation support in the current RunPod worker is unverified.

## Implementation and verification

The repository currently defines one Hermes service with a configurable host UID/GID and a single `hermes_data` bind tree. It also defines Caddy routing and a single-user forward-auth gate. Persona runtime isolation, persona-aware OIDC authorization, Matrix integration and additional persona services remain target functionality. Reuse Compose, pinned images and existing routing. Host paths, secret transport, service sizing and migration sequencing require implementation review. This decision requires no new orchestrator or secrets platform.

- Inventory legacy profile data and credential consumers without collecting secret values. Preserve CISO digest continuity under [ADR-0003](0003-ciso-persona.md). Review rollback before any separately approved migration.
- Verify effective UID/GID, storage modes, mounts, supplementary groups, capabilities, sockets and secret delivery. Test that each persona can use its own resources and cannot traverse, read, write or mount another persona's storage, including through symlinks, ACLs or volumes.
- Test unauthorized persona/service requests and direct backend access, independent user and project/task access, and Matrix room authorization when enabled.
- Verify backup and restore isolation, functional continuity and effective controls after recreation or relevant image/configuration changes. Record runtime evidence before marking implementation complete.
