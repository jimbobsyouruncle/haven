# Haven — Architecture Design

**Status:** Proposed implementation architecture. The owner approved `HAVEN-PROJECT-001` (2026-11-07) and `HAVEN-SEC-012` (2026-11-19). See the [decision register](DECISIONS.md) for approval and verification status.
**Baseline:** `jimbobsyouruncle/hybrid-ai`, inspected read-only on 2026-11-07. No runtime security claims or deployments are implied.  
**Primary platform:** Raspberry Pi 5, 16 GB, 64-bit Raspberry Pi OS, NVMe; cloud inference; eight configured personas across three human accounts.

Haven is the product name during migration. The source repository remains
`jimbobsyouruncle/hybrid-ai` until the approved #150 cutover; the baseline
attribution and source links below retain that identity. This document describes
the target architecture. Renaming presentation labels does not implement its
multi-user authorization, isolation or inference policy. See the
[presentation decisions](rename/PRESENTATION.md).

## 1. Decisions and objectives

1. One reusable **Coder persona definition** can be instantiated in multiple isolated persona runtimes. Coding tasks within one persona may share its authorized filesystem and credentials; sensitive projects requiring separation get their own persona. Enforce remote repository credential scopes and inference policy independently. See [ADR-0001](adr/0001-project-scoped-coder.md).
2. A **persona runtime** is the local execution and filesystem security boundary. A **project** defines collaboration, classification and intended repository access; sensitive projects needing local isolation use a separate persona runtime. A task-level repository allowlist narrows access only where separately enforced, not merely through instructions.
3. **Private repository** is an explicit repository classification. Any task touching private-restricted content must use its approved dedicated **RunPod-only inference** for *every* model operation (planning, coding, review, summarization, embeddings, delegated agents); fail closed. A GitHub `private` visibility flag can trigger this default but must not be the only classification signal.
4. Agent processes never receive host container-management sockets or unrestricted infrastructure credentials and cannot access resources of other personas. Resources deliberately shared within one persona are within that persona's accepted compromise boundary.
5. Support Hermes for persistent persona coordination; Pi and Codex as independent execution adapters; OpenHands optional for coding workflows. No engine is automatically authorized to run under a given inference policy: prove provider compatibility and network restrictions first.
6. Keep the RunPod inference image repository separate by default, with versioned API contracts, pinned image digests, and independent CI. An explicitly authorized multi-repository task may coordinate work across both without merging workspaces.
7. Existing Caddy/Cloudflare DNS-01 ACME, Tailscale, CI, and Restic/R2 investments should be reused and upgraded where compatible; avoid replacing them by default.
8. Invite-only local OIDC identity, passkeys preferred, password + TOTP fallback; no SMS/email MFA. Separate persona/project roles, and platform administration must not imply private-data read access.
9. Minimal operational/security logging: authentication and errors, plus necessary authorization grants, approvals, deletion receipts, and budget reservations; no general prompt-content audit trail.
10. User-private memory is not promoted to project/shared memory without explicit authorization. Canonical conversations and memory belong to Haven, not to an engine's internal history.

## 2. Trust boundaries and components

```text
Human clients (LAN / Tailscale)        Matrix mobile clients (restricted public entry)
                 |                                    |
          Caddy 2 / existing DNS-01 ACME -------- Matrix Synapse + MAS
                 |                                    |
      OIDC IdP (Authentik or Kanidm PoC)       authorized E2EE bridge
                 |                                    |
        Haven control plane <--------------------------+
  - identity/session validation
  - policy decision + task authorization
  - project/repository catalog
  - credential broker / approval workflow
  - canonical event and memory services
  - model policy and inference broker
  - scheduler, budget and RunPod lifecycle
                 |
       isolated persona runtimes (UID/GID, mounts, secrets)
                 |
   +-------------+---------------+----------------+
   |             |               |                |
 General Dev   Sensitive A    Sensitive B     Other personas
 Hermes/Canvas  project apps    project apps   own private trees
 scoped repos   scoped token    scoped token   no cross-persona mounts
   |             |               |
   +-------------+---------------+
                 |
### 4.1 Authorization and inference policy

For a coding session, authenticate the human user and authorize the selected persona and its project(s). Provision that persona only with authorized local checkouts, integrations and scoped remote repository credentials. A fine-grained token or deploy key limits remote GitHub operations; it does not isolate accessible local files. Sensitive projects requiring filesystem or credential separation run in distinct personas.

Calculate effective content classification and inference policy from the project, repository and data actually used. Restricted content requires the approved dedicated RunPod deployment for all model operations, including delegations, with no fallback. Enforce through trusted routing and network controls rather than instructions. Explicit user-private conversations and data remain independently authorized even when apps share a persona identity.

Task-level policy snapshots, approval receipts, expiring leases and dedicated sandboxes are optional stronger controls where separately implemented; do not claim per-task containment when applications share a persona UID and mounts.

### 4.2 Runtime enforcement

- Use a distinct unprivileged host UID/GID, dedicated containers, private storage tree, limited mounts and secrets per persona under ADR-0008. Deny cross-persona filesystem and unauthorized network access.
- Applications within one persona may use the same identity and access its authorized repositories and persistent storage. Do not mount another persona's checkouts, private storage, keys or backup data.
- Use persona-scoped fine-grained GitHub tokens or deploy keys with minimum remote repository and permission scope; validate token scopes and negative unauthorized repository operations. Prefer short-lived or revocable credentials when available.
- Keep host Docker/Podman management sockets, privileged execution and broad host mounts out of agent-accessible workloads. If a separate sandbox provisioner is necessary for a stronger task boundary, make it trusted and expose only narrowly authorized operations.
- Restrict inference egress to approved endpoints and test DNS, IPv6, redirects, proxy bypasses and outages. Mandatory dedicated RunPod routing for restricted operations must fail closed.
- Treat repository content, installs, test scripts, model output and agent tool requests as untrusted. Assume malicious code may access all resources intentionally exposed to its persona UID. Separate sensitive projects into different personas.


