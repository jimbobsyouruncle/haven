# Haven architecture decision register

This is the index of design commitments, **not** evidence of deployed functionality. Current source, CI and runtime verification establish implementation status. Approved principles may not be silently reopened.

| ID | Decision | Status | Reference |
| --- | --- | --- | --- |
| HAVEN-PROJECT-001 | One reusable Coder, project/task repo isolation, mandatory dedicated RunPod inference for restricted content | **Approved principle**, 2026-11-07; implementation unverified | [ADR-0001](adr/0001-project-scoped-coder.md) |
| HAVEN-SEC-002 | Persona-scoped credential brokerage and migration of legacy profile secrets | **Design requirement; proposed implementation** | [ADR-0002](adr/0002-persona-credentials.md) |
| HAVEN-OPS-003 | Independent CISO persona preserving existing Hermes daily digest | **Design requirement; proposed implementation** | [ADR-0003](adr/0003-ciso-persona.md) |
| HAVEN-ENG-004 | GitHub canonical backlog, Codex execution, future Hermes PM | **Proposed operating design** | [ADR-0004](adr/0004-github-epic-governance.md) |
| HAVEN-REN-005 | Staged repository rename, explicit owner cutover approval | **Approved staged procedure**, not cutover approval | [Epic #146](https://github.com/jimbobsyouruncle/hybrid-ai/issues/146) |
| HAVEN-ID-006 | OIDC, passkeys/TOTP, separate project and persona permissions | **Target requirement; IdP choice open** | [Architecture](ARCHITECTURE.md) |
| HAVEN-DATA-007 | Canonical conversation/memory with scope isolation and crypto-erasure | **Target requirement; PoC pending** | [Architecture](ARCHITECTURE.md) |
| HAVEN-INF-008 | Rootless workers, egress enforcement, versioned RunPod worker contract | **Target requirement; PoC pending** | [Architecture](ARCHITECTURE.md) |
| HAVEN-ENG-009 | Evidence-based issue completion using existing checks and deployment receipts | **Proposed operating decision** | [ADR-0005](adr/0005-evidence-based-completion.md) |
| HAVEN-OPS-010 | Transactional installation root migration to /opt/haven, preserving FHS state and recovery gates | **Proposed implementation; no production approval** | [ADR-0006](adr/0006-installation-root.md) |

Status vocabulary: **approved** means explicit owner decision on principle; **proposed** means not ratified; **implemented** requires source changes and relevant passing validation; **merged** requires a GitHub merge record; **deployed** identifies an installed revision in a named environment; **runtime-verified** identifies behavior actually observed there; **completed** requires the issue's phase-specific acceptance criteria and required evidence (or explicitly owner-approved tracked deferrals). A closed issue is a tracking state, not independent verification. These states are not interchangeable. Apply the [root completion policy](../../AGENTS.md#evidence-based-completion-and-epic-continuation) and [evidence guide](evidence-completion.md). Explicit owner decisions and enforced security policy take precedence over proposed ADRs. Record a proposed superseding ADR rather than silently changing approved requirements.

See [migration gates](MIGRATION.md), [root agent instructions](../../AGENTS.md), and locally managed `~/.local/bin/haven` launcher.
