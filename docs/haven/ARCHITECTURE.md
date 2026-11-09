# Haven — Architecture Design

**Status:** Proposed implementation architecture; `HAVEN-PROJECT-001` approved by product owner on 2026-11-07. Other design elements are recommendations pending PoC and acceptance tests.  
**Baseline:** `jimbobsyouruncle/hybrid-ai`, inspected read-only on 2026-11-07. No runtime security claims or deployments are implied.  
**Primary platform:** Raspberry Pi 5, 16 GB, 64-bit Raspberry Pi OS, NVMe; cloud inference; eight configured personas across three human accounts.

Haven is the product name during migration. The source repository remains
`jimbobsyouruncle/hybrid-ai` until the approved #150 cutover; the baseline
attribution and source links below retain that identity. This document describes
the target architecture. Renaming presentation labels does not implement its
multi-user authorization, isolation or inference policy. See the
[presentation decisions](rename/PRESENTATION.md).

## 1. Decisions and objectives

1. One reusable **Coder persona** can work across many projects; **project and task session**, not persona, enforce repository and inference authorization.
2. A **project** is a security and collaboration boundary with one or more authorized repositories. A **task** has a narrower explicit repository allowlist. A group is an authorization ceiling, not implicit access.
3. **Private repository** is an explicit repository classification. Any task touching private-restricted content must use its approved dedicated **RunPod-only inference** for *every* model operation (planning, coding, review, summarization, embeddings, delegated agents); fail closed. A GitHub `private` visibility flag can trigger this default but must not be the only classification signal.
4. Agent processes never receive host container-management sockets, unrestricted GitHub credentials, or arbitrary access to other project files, services, memories, and secrets.
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
        trusted worker provisioner (narrow API; no arbitrary socket access)
                 |
   +-------------+---------------+----------------+
   |             |               |                |
 Worker A     Worker B       Worker C         integration runner
 Repo A only  Repo B only    selected group    artifacts/contracts only
 Hermes/Pi/   Codex/Pi/      explicit grants   no blanket repo access
 Codex/etc.   OpenHands
   |             |               |
   +-------------+---------------+
                 |
        inference egress broker -> approved dedicated RunPod deployment
                 |                  (or other approved provider only for
          restricted egress         non-restricted projects)
```

**Control plane vs data plane:** The trusted Haven control plane authenticates users, evaluates policy, provisions short-lived workers and credentials, and records minimal transactional state. Worker containers are untrusted; model output, repository content, retrieved documents, and agent tool requests are untrusted inputs. An OpenHands controller with host orchestration access, if retained, must be separated from its untrusted agent workers and accessed only through a restricted provisioning interface.

## 3. Resource model

- **User:** human identity via OIDC, roles, sessions and personal private memory.
- **Persona:** reusable behavioral profile, engine capabilities, approved tools, non-secret instructions, and optional non-sensitive general skills. Persona is *not* a security boundary.
- **Project:** tenant-like boundary with membership, policy, repositories, encryption key, project memory and budget.
- **Repository:** immutable provider identity (`github:<installation-id>:<repo-id>`), visibility/classification, allowed refs, optional write policies, and one primary project membership. Cross-project sharing must be explicit and versioned.
- **Repository group:** named subset of a project's repositories; its members are an authorization ceiling, never automatic mounts.
- **Task:** initiating user, persona, project, approved repository IDs, read/write levels, branch constraints, inference policy, expiry, budget and approval receipt.
- **Worker:** ephemeral sandbox bound to a single task and short-lived credential leases; one worker per repo is the default. Multi-repo worker requires a separate explicit approval and is discouraged.
- **Execution session:** user+persona+project+task context; independent across users even when sharing a persona.
- **Inference deployment:** dedicated RunPod pod, endpoint, model identity, owner, cost ceiling, network policy and lifecycle state.

### Core schema (conceptual)

```text
users(id, oidc_subject, status)
personas(id, owner_id, profile_version)
projects(id, classification, key_ref, policy_version)
project_members(user_id, project_id, role, expires_at)
repositories(id, provider_repo_id, project_id, classification, canonical_url)
repo_groups(id, project_id, name)
repo_group_members(group_id, repository_id)
tasks(id, user_id, persona_id, project_id, state, policy_snapshot, expires_at)
task_repos(task_id, repository_id, access_mode, allowed_refs)
workers(id, task_id, sandbox_id, lease_expiry)
credential_leases(id, task_id, repo_id, scopes, expiry, revoked_at)
inference_policies(id, project_id, allowed_deployments, fallback_mode)
inference_requests(id, task_id, provider, deployment_id, budget_reservation_id)
conversation_events(id, project_id, session_id, actor_id, ciphertext_ref, timestamp)
memory_items(id, scope_type, scope_id, ciphertext_ref, provenance, expiry)
approval_receipts(id, task_id, approver_id, action_digest, expiry)
```

Database row-level authorization and encryption are defense-in-depth, not substitutes for API authorization. Use a relational DB such as PostgreSQL for authoritative grants/events; separate vector indexes by authorized scope.

## 4. Authorization and repository isolation

### 4.1 Decision procedure

For every task and tool invocation, evaluate:

1. Verify user OIDC session and project membership.
2. Verify persona is permitted in project and engine is permitted by policy.
3. Resolve repository IDs from GitHub API, not names alone; ensure all belong to authorized project/group.
4. Compute **effective classification = strictest classification** of project, selected repositories, retrieved sources, and delegated context.
5. Compute **effective inference policy** from effective classification. Restricted private data requires approved dedicated RunPod deployment; no fallback.
6. Mint immutable task policy snapshot, scoped credentials, approved worktree paths, and egress policy; issue short expiry.
7. On each tool call, check task, resource, verb, branch, expiry, remaining budget and approval state. Reject unknown targets.
8. A child task inherits the parent classification and can only *narrow* repository set, privileges, egress, time and budget. Broader access requires a new human-authorized parent task.
9. On completion/revocation: revoke leases, stop workers, scrub ephemeral volumes, expire sessions, retain only approved artifacts and minimal receipts.

**Deny by default:** A project group is a maximum set; an individual task starts with no repository grants. A worker cannot change its own project, repo allowlist, classification or inference route. Cross-project tasks require a separate user-approved workflow that delegates to project-local workers and shares only approved contracts/artifacts.

### 4.2 Runtime enforcement

- Use dedicated rootless worker identity/UID and user namespace; separate filesystem mount namespace, PID namespace, network namespace, read-only base image, restricted capabilities, seccomp and resource quotas. No privileged mode or Docker/Podman sockets.
- Mount only selected checkout/worktree and ephemeral scratch; never mount deployment directory, other repos, `$HOME`, SSH agent, host credentials, backups or key stores.
- Provisioner runs as a trusted host service with an authenticated narrow API; workers cannot invoke generic container-create commands or Docker API. Validate mount and network templates server-side.
- Use short-lived GitHub App tokens scoped to exact repository IDs and minimum permissions, preferably one token per repo; verify Git remote URL and repository ID before checkout/push. Enforce branch protection and PR-only merges. GitHub App installation restrictions must be verified in practice.
- Egress policy: block host, RFC1918/ULA, link-local, metadata endpoints, other project networks, control-plane APIs, credential services, and arbitrary inference endpoints. Private work uses an allowlisted broker/proxy for model requests, git, package registries and necessary integrations. DNS rebinding, redirects, CONNECT, IPv6, proxy env vars, local Unix sockets and agent subprocesses must be tested. Generic unrestricted internet egress cannot guarantee non-exfiltration.
- Treat tests, dependency install scripts, build steps, repository instructions, and model tool output as untrusted code. Prefer offline/reproducible dependencies and approval gates for risky operations.
- Ensure worker image, base filesystem, caches, package mirrors, container build context, build logs and artifacts do not mix restricted projects.

### 4.3 Memory and conversation separation

Persona-wide memory contains only generic non-sensitive working methods. Project and user-private memory are encrypted and indexed separately. The coordinator can use project memory only after project authorization; it cannot silently summarize private repository contents into persona-wide memory. Cross-project knowledge transfer requires an approved, reviewed, explicitly classified artifact. Cache keys include project, task, classification, model and authorization scope. Retrieval filters authorization **before** candidate ranking or summarization.

## 5. Private inference and RunPod

### 5.1 Strict routing policy

A private project is not merely a UI toggle. A server-enforced policy applies to **all** model-bearing operations: coordinator, architect, builder, reviewer, troubleshooting, delegated agents, embeddings, summaries, evaluations, prompt caching and third-party AI tool plugins. Private content must never be sent to an unapproved provider. If a model adapter cannot prove compatibility with RunPod's approved endpoint, disable it for restricted tasks.

```yaml
# Illustrative policy, not a deployable Haven configuration
project: private-example
classification: restricted
inference:
  mode: dedicated_runpod_only
  allowed_deployment_ids: [runpod-private-a]
  fallback: deny
  embeddings: approved_runpod_or_disabled
  summarization: approved_runpod_or_disabled
  model_capability_probe: required
network:
  model_egress: broker_only
  other_egress: explicit_allowlist
agents:
  permitted_engines: [pi] # Codex/Hermes/OpenHands only after compatibility PoC
  inherit_policy_to_children: true
```

**Important limitation:** A private RunPod GPU is still a third-party cloud infrastructure environment. Confidentiality also depends on RunPod account access, endpoint authentication, pod storage, telemetry, server configuration and provider terms. “RunPod-only” is a routing requirement, not a promise of on-premises privacy.

### 5.2 Model and engine compatibility

Build an adapter capability matrix: configurable OpenAI-compatible endpoint, streaming, tools/function calls, context length, structured output, token accounting, session persistence, embedding support, auth and telemetry control. Pi is a strong PoC candidate for custom provider routing; Hermes, Codex and OpenHands must each pass actual end-to-end tests before they are allowed in restricted mode. Do not assume a particular Codex build supports arbitrary model endpoints or that its ancillary features are disabled by configuration alone.

### 5.3 RunPod deployment management

- Existing `openwebui/runpod_core.py` separates wake/readiness/streaming from UI and validates Tailscale destinations; reuse concepts and tests, not necessarily the legacy API client.
- Replace single global pod/key assumptions with per-deployment, per-project credential leases, concurrency-safe lifecycle, readiness checks, idle timeout, max runtime and budget reservations.
- Prefer current supported RunPod API with an adapter and contract tests; verify actual version and endpoint support before migration.
- Pin RunPod container image digest and model revision; use authenticated private endpoint via Tailscale or equivalent secure transport. Deny unauthenticated public model access.
- Pod state machine: `stopped -> starting -> health_check -> ready -> draining -> stopped`, plus `failed` and `budget_exhausted`. Deduplicate concurrent wake requests; enforce timeout and cancellation.
- Budget hard limits reserve estimated maximum spend before startup and each inference; stop when exhausted. Track model token usage, pod uptime and idle fees.
- Failure of RunPod, readiness, routing, authentication or budget checks means **queue or fail**, never silently switch provider.

## 6. Coder workflow across repositories

**Example:** Haven inference adapter and RunPod image need compatible changes.

1. User selects project `Haven Platform`, repository group `Haven + RunPod`, and approves two scoped workstreams.
2. Hermes Architect gets approved read-only contracts and relevant source snippets, drafts versioned API and acceptance tests. If restricted source enters context, coordinator must already use RunPod-only inference.
3. Worker A (Codex or Pi) receives only `hybrid-ai`, an isolated branch, and a repo-specific GitHub token; implements Haven adapter and tests.
4. Worker B (Pi or OpenHands, if policy permits) receives only RunPod container repo and separate credentials; updates inference server and health checks.
5. Integration runner receives pinned images, schemas and synthetic test fixtures; it has no default access to either source repository. Tests compatibility, auth, streaming, failures and privacy.
6. Independent Hermes Reviewer examines approved diffs and test results; if it reads restricted content, it must use the same RunPod-only inference policy.
7. Separate PRs, approvals and staged releases. Publish RunPod image first, then Haven adapter. Roll back independently on failure.

Never place two independent agents on the same writable branch/worktree. An optional cross-repo worker needs an explicit exceptional grant and heightened approval; project grouping alone does not authorize it.

## 7. Identity, UI, and Matrix

- Local IdP (Authentik or Kanidm, selected by PoC), OIDC; passkeys preferred, password + TOTP fallback, hardware-key admin recovery; invite-only accounts. Stable `auth.daemonhub.dev` hostname and TLS.
- Haven local interface `haven.daemonhub.dev` through existing Caddy wildcard DNS-01 ACME and Tailscale/LAN restrictions; show effective project, repo allowlist, classification, inference backend, engine compatibility, cost estimate, tool approvals and worker state. UI cannot weaken server-side policy.
- Matrix Synapse + Matrix Authentication Service as optional remote chat surface; non-federated, E2EE where applicable, explicit bridge as authorized decrypting endpoint. Matrix room membership does not replace Haven project authorization. Public-facing Matrix/OIDC routes must be minimized and reviewed.
- Roles: platform admin, security admin, project owner/editor/member/viewer, persona owner/editor/member/viewer. Admin privileges do not imply private content read. Shared persona members have review at 90 days and revocation at 180 days inactivity, owner exempt, subject to approved policy.

## 8. Data, keys, backup, deletion

- Canonical conversation event store owned by Haven; adapters emit normalized tool/model events. Preserve engine-native session IDs only as references. Never assume engine UI history is canonical.
- Encrypt user-private, project and persona data with separate destroyable data-encryption keys, wrapped by a master key; separate encryption domains for highly restricted project data. Enforce retention and scope-aware indexes.
- To support cryptographic erasure from historical backups, encrypt sensitive data *before* Restic with independent destroyable keys, and ensure wrapped keys are not preserved in recoverable backups after deletion. Key deletion, backup manifests, caches and restoration paths require an explicit adversarial recovery test.
- Reuse Restic + Cloudflare R2; move from existing nightly backup cadence to satisfy target **RPO <= 4 hours**, test **RTO <= 8 hours** with full restore rehearsals. Restic encryption alone cannot erase a single project's historical data.
- Delete live DB/index/cache objects, destroy relevant keys, revoke credentials, and retain only minimal deletion receipt. Cannot retract content already delivered to external clients/providers.
- Evaluate LUKS2 unattended hardware-bound unlock and verified-boot chain as a PoC, not an assumed Raspberry Pi feature.

## 9. Operations, capacity, and updates

- Always-on services: Caddy, IdP, Haven API, DB, optional Matrix. Start with **two concurrent active workers**, idle-stop workers, test three under load. This is a recommended initial limit, not a measured Pi benchmark.
- Use a component inventory with image digest, approved version, upstream source, ARM64 compatibility, security advisories, DB/schema migration requirements, dependency contracts, rollback artifact and release notes.
- Automatically discover latest stable compatible releases; **do not auto-deploy `latest` tags**. Pin image digests; run dependency, SAST, integration, security and ARM64 smoke tests; canary/stage; preserve rollback and schema migration plan.
- Reuse existing Caddy ACME issuance and TLS monitoring, deployment-by-SHA, GitHub Actions/SAST, Tailscale, and backup practices. Validate Docker-to-rootless-Podman migration; do not treat `:ro` Docker socket mount as read-only API permission.
- Minimal auth/error logs and narrowly necessary transactional receipts, with retention and access controls. No general prompt/tool payload audit logging.

## 10. Current repository conflicts and migration mapping

| Current source | Observed baseline | Haven action |
|---|---|---|
| `auth/app.py` | Single-user password/session forward auth | Replace with OIDC and project-aware authorization |
| `openhands/docker-compose.openhands.yml` | OpenHands image default `1.10`; host Docker socket mounted; separate workspace clone documented | Upgrade compatibility-tested image, remove agent-adjacent host socket, isolate controller and workers |
| `docker-compose.yml` | Docker Compose, Open WebUI/Ollama, Docker networks, host-facing services | Parallel Haven control plane, restrict ports, cloud-first inference, migrate isolation |
| `openwebui/runpod_core.py` | Tailscale-validated vLLM wake/readiness/streaming abstraction | Adapt to dedicated per-project deployment and strict inference broker |
| `status/Caddyfile.tmpl` | Existing Caddy routing, LAN/Tailscale allowlist and forward-auth | Add explicit OIDC/Haven/Matrix routes; preserve existing DNS-01 ACME |
| `backup/README.md` | Restic/R2; nightly backup | Add per-project encryption keys and <=4h RPO with restore testing |
| `.github/workflows/sast-checks.yml` | Existing SAST/security checks | Reuse, expand to image/engine/ARM64 and policy regression tests |

These are source observations, not runtime verification. Do not overwrite legacy volumes or import histories without inventory, owner consent and tested rollback.

## 11. Implementation phases and gates

**Phase 0 — Inventory and compatibility.** Enumerate images, tags/digests, runtime versions, repos, secrets, data volumes and exact RunPod repo. Record latest *compatible* versions, not simply latest available. Establish reproducible dev/test environment and golden backups.

**Phase 1 — Security PoCs (hard gate).** Rootless worker filesystem isolation, denied cross-project reads/writes, no management socket, network egress deny, DNS/IPv6 bypass tests, GitHub token scoping, RunPod-only model routing for all model operations, independent-key deletion across old backups. No production private repo access until all pass.

**Phase 2 — Identity and authorization.** OIDC passkeys/TOTP, projects/groups/repositories, task policy snapshots, approvals, scoped credentials and UI effective-policy display. Test admin cannot read other users' private data by default.

**Phase 3 — Engine and inference adapters.** Hermes coordinator, Pi and Codex task workers, optional OpenHands, normalized events, capability matrix, RunPod lifecycle and budget enforcement. Restricted projects only on proven compatible engines.

**Phase 4 — Cross-repo development.** Separate GitHub App tokens, branches/PRs, integration artifacts and contract tests; preserve source separation.

**Phase 5 — Matrix, memory, resilience.** Matrix/MAS bridge, canonical event/memory stores, backup cadence, cryptographic erasure, disaster recovery, staged upgrades.

### Mandatory acceptance tests

- Task authorized for repo A cannot list/read/write repo B, including via git remote, filesystem, network, symlink, cache, tool plugin, delegated worker or credential reuse.
- Group A+B can authorize two independent workers but does not implicitly mount both repos in either worker.
- Private source never reaches non-RunPod model endpoints, including planner, reviewer, summarizer, embeddings and error paths; DNS/IPv6/redirect/proxy bypasses fail.
- RunPod offline or over budget -> queue/fail closed; no cloud fallback.
- An engine incompatible with approved RunPod endpoint is unavailable for restricted tasks.
- Revocation invalidates task/credential leases; already exported PRs/artifacts are treated as external copies.
- Restore an old backup after project-key destruction cannot decrypt deleted project data.
- All production image digests are pinned and upgrades have validated rollback artifacts.

## 12. Open design decisions

1. Confirm actual RunPod repository and its inference-server API, models and authentication.
2. Select IdP (Authentik/Kanidm) after Pi capacity, OIDC/MAS and passkey tests.
3. Validate rootless Podman networking, firewall enforcement and the trusted provisioner design on Pi OS.
4. Verify per-engine RunPod custom endpoint compatibility, telemetry behavior and license/provider restrictions.
5. Decide whether Matrix is a v1 release dependency or a subsequent phase.
6. Benchmark Pi worker concurrency, PostgreSQL, IdP and Matrix memory use; adjust two-worker default.
7. Define private repository classification overrides, sharing policy and emergency incident response procedures.

## 13. Source references

- https://github.com/jimbobsyouruncle/hybrid-ai/blob/main/REPO_MAP.md
- https://github.com/jimbobsyouruncle/hybrid-ai/blob/main/docker-compose.yml
- https://github.com/jimbobsyouruncle/hybrid-ai/blob/main/openhands/docker-compose.openhands.yml
- https://github.com/jimbobsyouruncle/hybrid-ai/blob/main/openwebui/runpod_core.py
- https://github.com/jimbobsyouruncle/hybrid-ai/blob/main/status/Caddyfile.tmpl
- https://github.com/jimbobsyouruncle/hybrid-ai/blob/main/backup/README.md
- https://github.com/jimbobsyouruncle/hybrid-ai/blob/main/.github/workflows/sast-checks.yml
