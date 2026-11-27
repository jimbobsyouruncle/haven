# ADR-0008 — Persona runtime, host filesystem, and secret isolation

**Status:** Approved owner requirement (2026-11-19), clarified for coding tasks (2026-11-22). Implementation and runtime enforcement are unverified.
**Related:** [HAVEN-SEC-012](../DECISIONS.md), [ADR-0001](0001-project-scoped-coder.md), [ADR-0002](0002-persona-credentials.md), [ADR-0003](0003-ciso-persona.md), and the [architecture](../ARCHITECTURE.md).

## Isolation boundary

A **persona definition** supplies reusable behavior, instructions, skills and configuration. Haven's trusted control plane grants access independently of that definition. A **persona runtime environment** enforces isolation between persistent personas through dedicated application containers, a Unix identity, private storage and secrets.

Each persistent persona must have a dedicated unprivileged Unix UID/GID on the Haven host. Different personas must have distinct host UIDs and GIDs that are never reassigned to another persona. Every application container belonging to one persona may use that same UID/GID and share designated storage. The security boundary is the persona runtime. A compromised application may expose any resources accessible to that persona identity. This is an accepted tradeoff. Narrow application mounts where practical and use ordinary ownership and permissions rather than adding per-application identities or complex ACLs.

Each persona owns an isolated persistent tree. Default private directories to mode `0700` and sensitive files to `0600`, or equivalently restrictive permissions. A persona container may mount only the private storage authorized for its own persona. Prohibit mounts of another persona's private storage, including read-only mounts. Deny privileged host access, container-management sockets, broad host mounts, privilege escalation and unnecessary Linux capabilities. Cross-persona network access is denied by default. Access to shared services requires explicit, narrowly scoped authorization.

A persona's passwords, tokens, API keys and other secrets must be inaccessible to every other persona through mounts, environment files, images, logs, shared configuration and management interfaces. Keep infrastructure credentials outside persona mounts. Trusted provisioning and backup/restore services may access only what their operational role requires. Backups and restores must preserve ownership, access controls, applicable encryption keys and persona separation. [ADR-0002](0002-persona-credentials.md) governs proposed credential delivery and lifecycle.

Project authorization and human user privacy remain independent of persona instructions. Under the owner-approved revision of [ADR-0001](0001-project-scoped-coder.md), coding applications and tasks within a persona may share that persona's Unix identity, authorized checkouts, storage and credentials; no universal per-task worker or per-repository sandbox is required. Sensitive projects that must not share these resources belong in separate persona runtimes. Fine-grained GitHub tokens or deploy keys restrict remote repository permissions but do not isolate files already accessible to the persona UID. Stronger task-level isolation is required only where users or tasks must be mutually separated within a persona. Human users sharing a persona retain independently authorized private data and conversations; a shared Unix identity alone does not enforce that privacy. Shared application storage or services handling user-private data must independently authorize access.

## Applications and access

A persona may have any number of applications. Examples include Financial Planner with Hermes and Obsidian or another knowledge base, Graphic Designer with Hermes and ComfyUI, Developer with Hermes and Agent Canvas, and CISO with Hermes and authorized security tools.

Applications may keep their native WebUIs behind Haven's existing Caddy reverse proxy and planned identity architecture. Use flat persona-service hostnames such as `finances-hermes.daemonhub.dev`, `finances-notes.daemonhub.dev`, `designer-comfyui.daemonhub.dev` and `developer-canvas.daemonhub.dev`. These names are illustrative. Require authentication and authorization for each persona/service and prevent bypass through direct backend access, internal networks or spoofed identity headers. A universal frontend is unnecessary.

The Matrix design uses a shared, non-federated Synapse homeserver and Matrix Authentication Service. Each Hermes persona may connect to its own authorized private rooms with an independent bot account, credentials and device/encryption state. Enforce room authorization and Haven's trusted authorization checks independently. Preserve E2EE where applicable and review public-facing Matrix and OIDC routes.

Personas may use authorized inference services, including RunPod, under Haven's existing classifications and routing policy. Every model operation involving restricted content must use the approved dedicated RunPod deployment and fail closed. ComfyUI and other media applications may require contracts distinct from the current vLLM interface. Image-generation support in the current RunPod worker is unverified.

## Implementation and verification

The repository currently defines one Hermes service with a configurable host UID/GID and a single `hermes_data` bind tree. It also defines Caddy routing and a single-user forward-auth gate. Persona runtime isolation, persona-aware OIDC authorization, Matrix integration and additional persona services remain target functionality. Reuse Compose, pinned images and existing routing. Host paths, secret transport, service sizing and migration sequencing require implementation review. This decision requires no new orchestrator or secrets platform.

- Inventory legacy profile data and credential consumers without collecting secret values. Preserve CISO digest continuity under [ADR-0003](0003-ciso-persona.md). Review rollback before any separately approved migration.
- Verify effective UID/GID, storage modes, mounts, supplementary groups, capabilities, sockets and secret delivery. Test that each persona can use its own resources and cannot traverse, read, write or mount another persona's storage, including through symlinks, ACLs or volumes.
- Test unauthorized persona/service requests and direct backend access, independent user privacy, persona-scoped repository permissions and cross-persona project access. Test optional task boundaries only where configured, and Matrix room authorization when enabled.
- Verify backup and restore isolation, functional continuity and effective controls after recreation or relevant image/configuration changes. Record runtime evidence before marking implementation complete.

## Incremental implementation decision — single-owner persona MVP (2026-11-26)

**Owner-approved scope; implementation not yet complete.** Implement the isolation model through [epic #294](https://github.com/jimbobsyouruncle/haven/issues/294), beginning with only the existing Haven owner login and existing authenticated HTTPS. This is **not** a decision to eliminate independent human-user authorization from the eventual multi-user design: persona-aware user login/RBAC and OIDC are postponed to a separate phase. Do not represent shared owner authentication as multi-human separation.

Reuse the existing `scripts/provision-persona.sh` stable UID/GID reservation and private storage roots, Docker Compose and systemd deployment, existing Caddy proxy and firewall, and Restic backup. Provide a minimal declarative mechanism for enabling a persona and its services; do not introduce a daemon, orchestration control plane, application marketplace, generic secret broker or per-application identities. Multiple services in a persona share that persona's unprivileged Unix UID/GID and **only** its explicitly mounted private storage. Its internal network may be shared within the persona, while cross-persona private networking, mounts, credentials and host-management access remain denied by default. Public internet access follows the networking decision below.

Expose each approved native WebUI behind existing authenticated Caddy HTTPS on a flat `<persona>-<service>.<TLS_DOMAIN>` name. Enforce backend non-bypass and service boundaries; single-owner authentication does not imply a new RBAC platform. Existing persona data and deployments should not be migrated merely to add new personas. Backup/deploy/doctor should reuse their existing paths and report actual coverage, not add blanket CI or scheduled test frameworks.

**Verification proportionate to change:** use two disposable personas for a representative positive same-persona file exchange and denied peer file/service access, verify service identity/mount/privilege and authenticated access, and retain data through one recreation and the existing backup capture. Reuse prior qualified CI, ARM64 and restore evidence; do not repeat unrelated fleet or full-system rehearsals. Capture unverified restrictions as limits, not claims. Matrix, multi-human login, protected restricted RunPod mode, full Canvas/Hermes delegation and specialized ComfyUI inference are separate future capabilities.


## Persona network decision (2026-11-27)

Each persona uses one routable Docker bridge. Containers on the same bridge
can communicate freely. The operator-reviewed declaration persists
`PERSONA_INTERNET`, which defaults to `true` and allows public IPv4 via the
host uplink. When it is `false`, Haven's firewall denies internet traffic
and still permits explicitly configured Caddy ingress and established replies.
Changing the setting retains persona state, identity, and bridge addressing.
The launcher verifies firewall rules before starting persona containers.

Use the existing Docker and Haven host firewall model. Deny traffic between
personas and block host gateways, other Docker bridges and published port
bypass. Apply and verify the boundary before starting any persona workload.
[#296](https://github.com/jimbobsyouruncle/haven/issues/296) introduces the
network and private Hermes service without published ports.
[#297](https://github.com/jimbobsyouruncle/haven/issues/297) owns authenticated
proxy ingress and must preserve the peer and backend denials, including with
internet enabled. Keep Docker socket access, privileged execution,
infrastructure credentials and peer storage outside persona containers.

### Companion WebUI ingress decision — #297

The owner approved a Haven firewall exception scoped to the existing Caddy
instance and each explicitly configured companion HTTP endpoint. Companions
publish no host ports. Caddy stays outside persona bridges, and the exception
permits only the configured connection and its established replies. Peer
persona, direct backend and host management access remain denied. Same-persona
communication and the persona's outbound internet setting retain their existing
behavior.

Caddy must enforce Haven owner authentication at each companion HTTPS hostname
before proxying. Remove `haven_auth` from upstream requests and prevent the
app from setting it in downstream responses. Preserve app-specific cookies
where required and strip infrastructure credentials and unnecessary
authorization headers.

Caddy uses a dedicated source bridge that only Caddy joins. The IPv4
firewall permits TCP/8080 from Caddy's bridge and address to the reserved
FileBrowser address on that persona's bridge. The reverse rule matches only
established replies. The address derives from the persona's non-reused UID and
sits outside Docker's dynamic allocation range. The operator adds an explicit
route under the authenticated HTTPS wildcard site. See the
[operator procedure](../../../deploy/README.md#filebrowser-https-access).

FileBrowser Quantum v2.1.0-stable is the selected replacement. The pinned
image index includes Linux ARM64. The optional `PERSONA_APPS=hermes,files`
declaration shares the persona's `projects` directory with both apps.
Quantum keeps its database and cache in the separately provisioned `files`
directory, runs with the reserved persona UID/GID, and publishes no ports.
[Published image](https://github.com/gtsteffaniak/filebrowser/pkgs/container/filebrowser/1630175613?tag=2.1.0-stable)
