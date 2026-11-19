# ADR-0008 — Persona runtime, host filesystem, and secret isolation

**Status:** Approved owner requirement (2026-11-19); implementation and runtime enforcement not verified.
**Related:** HAVEN-SEC-002, HAVEN-ID-006, HAVEN-DATA-007; ADR-0001, ADR-0002, ADR-0003.

## Context and decision

Haven's persona profiles are behavioral configurations, not security boundaries. The owner requires isolation between persistent personas such as Developer, CISO and Financial Planner, including their applications, persistent data and credentials. A shared Hermes runtime holding every profile's private storage is not an acceptable final deployment.

Each persistent persona must run in dedicated container(s) with a distinct, non-reused unprivileged host runtime identity (UID/GID or an equivalently proven user-namespace mapping). Reuse pinned immutable application images and trusted platform infrastructure, not writable private state. A persona may operate several associated applications, such as Hermes and a notes editor, but **only that persona's authorized containers** may mount that persona's private persistent storage. No other persona's private tree may be mounted, even read-only.

On the Haven host, private persona directory trees are owned by that persona's dedicated host identity; private directories default to 0700 and sensitive private files to 0600 or stricter. Verify parent traversal permissions, ACLs, supplementary groups, UID mapping, bind mounts, named volumes and symlink behavior. Container configuration must not give persona workloads unrestricted root, privileged mode, Docker/container-management sockets, broad host mounts, unnecessary Linux capabilities or privilege escalation. A filesystem permission scheme is not a substitute for restricting host/container-admin privileges.

Each persona receives only its own secrets and credentials. Do not expose other personas' passwords, API keys, tokens or credentials via global environment files, images, shared configuration, Docker inspection interfaces, logs or mounts. A host-controlled, narrowly scoped delivery mechanism is preferred for secrets that require rotation, short leases or revocation; persona-owned writable storage alone is not sufficient protection for high-value credentials. Infrastructure credentials for DNS, backups, deployment and administration remain infrastructure-owned and outside persona mounts. Credential rotation and live migration require separate approval and rollback.

Persona-specific memory, conversation history, databases, search/vector indexes, attachments, caches and application state stay in persona-owned storage or in shared services whose authentication and storage enforcement independently prove the same isolation. The Developer's project/task data is *additionally* subject to ADR-0001; reusable persona configuration does not authorize reading every project.

Network access between personas and to shared services is deny-by-default, with narrowly scoped explicit exceptions. A shared Caddy reverse proxy and identity service may route separate per-persona WebUIs, but authentication at a front door alone is not authorization: every protected backend must accept only the intended persona's authenticated sessions or trusted, validated identity assertions, and must not be bypassable by direct ports, internal networks or spoofed headers. No new universal persona frontend is required by this decision.

Trusted host root, the narrow container provisioner, approved backup/restore services and other explicitly authorized host infrastructure are part of the trusted computing base; this decision does not promise secrecy from compromise of the Haven host itself. Backups and restores must preserve storage ownership, access controls, applicable keys and persona isolation.

## Verification / acceptance

- Inventory and migrate legacy Hermes profiles, their mounted data and credential consumers without exposing secret values; preserve CISO digest schedule and integrations.
- Verify persona A can read/write its own data but cannot list, traverse, read, write or mount persona B's data (including symlink, ACL, supplementary-group, volume and user-namespace bypass cases).
- Confirm the effective runtime UID/GID, capabilities, privilege settings, socket exposure, effective mounts, secret delivery and service-specific network access.
- Verify cross-persona denial at HTTP endpoints and shared backends, not just at the reverse proxy; test unauthorized routes and direct-backend requests.
- Verify per-persona backup/restore ownership and private data boundaries.
- Test independently after deployment, recreation and relevant image/configuration changes; keep checks scoped and actionable, with no secrets printed.
- Prove functional continuity of each persona and record runtime verification before marking migration complete.

## Tradeoffs and implementation state

More persistent containers and OS identities increase provisioning and backup complexity and may increase Pi resource usage. Reuse container images, Compose templates and existing Caddy routing; do not add a separate orchestrator or frontend merely to achieve isolation. Evaluate resource load and service compatibility before deployment.

**This ADR records an owner-approved security requirement, not a claim that it has been deployed.** The specific host directory names, routing hostnames, secret transport and migration sequence are implementation details subject to review. No production migration, secret rotation or deployment is authorized by this document.
