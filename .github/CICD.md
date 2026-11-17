# `.github/` — Continuous Deployment

| File | Purpose |
|---|---|
| `workflows/deploy.yml` | Inert until owner activation; then canonical main pushes reuse `validate.yml` and deploy the exact validated merged SHA. Manual exact-main recovery remains available. |
| `workflows/validate.yml` | Reusable source validation (`workflow_call` only). Called by `sast-checks.yml` on every pull request and by `deploy.yml` on activated main pushes or authorized manual dispatch. Holds no secrets. |
| `workflows/sandbox-image.yml` | Builds and publishes the derived agent-server image to GHCR. Auto-publishes on a push to `main` that changes `openhands/agent-server/Dockerfile` (tag read from the `image_tag` default, guarded against overwriting an existing tag); `workflow_dispatch` is the manual rebuild path. |
| `workflows/agent-context.yml` | Checks the checked-in `REPO_MAP.md` and `CODE_INDEX.md` are fresh on every pull request. Read-only; never commits. |
| `workflows/sast-checks.yml` | The single pull-request gate: ShellCheck, Semgrep, source validation, CodeQL and the Hermes non-root smoke test, ending in the `Security & SAST gate`. |
| `dependabot.yml` | Grouped pull request that opens weekly on Sunday at 22:00 America/New_York to bump the SHA-pinned GitHub Actions. GitHub Actions only. |

---

## What this does

Automatic deployment is prepared but **inactive** until canonical cutover acceptance and explicit owner authorization to set the repository variable `HAVEN_AUTOMATIC_DEPLOYMENT` to exactly `enabled`. This PR changes no settings or secrets. After activation, owner merges to main need no additional deployment approval. The existing `production` environment remains in use; any configured protection still applies. Clearing the variable disables future automatic jobs without cancelling a running host transaction.

For manual recovery, dispatch **Deploy Control Plane** from `main`, supply the full current main SHA in `deployment_sha`, and select `authorize_production`. Both paths validate that exact SHA before production access. The automatic path additionally requires a canonical repository push and a matching merged-main PR from the GitHub API; fork, forced/deleted push, unmatched SHA and stale main are refused. Provenance is rechecked after the image wait.

Generated maps still travel through the owner-reviewed draft PR path introduced in #206. The bot never merges. Its token-suppressed branch/PR events are handled by the existing bounded validation dispatches, not by production dispatch. The human owner's eventual main merge generates the ordinary deployment push; map-only main merges are validated/deployed normally after activation. No reconciliation service or bot auto-merge is introduced.


The interesting part is how it reaches your Pi. **Your Pi has no public IP address, no open firewall ports, and no port forwarding configured.** The GitHub runner temporarily joins your Tailscale network as a member tagged `tag:ci`, connects over the encrypted mesh, does its work, and disappears when the job ends.

This is strictly better than the conventional approach of exposing SSH to the internet. There is no permanent attack surface, because there is no permanently reachable service.

Installation-root migration must use the transactional deployment path and its automated immutable-image recovery preflight. Do not use an installer invocation to bypass that gate. See [ADR-0006](../docs/haven/adr/0006-installation-root.md) for recovery checks and installed-driver preparation requirements.

---

## The deploy jobs

`deploy.yml` has two jobs. The first is now a thin caller of the reusable
`validate.yml`, which the pull-request gate calls too.

### Job 1 — `validate`

Runs on every pull request to `main` (through `sast-checks.yml`) and on every
activated canonical-main push or authorized manual dispatch (through `deploy.yml`). Catches mistakes before they can reach
the Pi.

| Check | What it catches |
|---|---|
| `bash -n` on every `*.sh` in the repo | Syntax errors, unbalanced quotes |
| `py_compile` on every `*.py` in the repo | Python syntax errors, including `status/app.py`, which is bind-mounted with no build step |
| `build_pipe.py --check` | A forgotten rebuild — the pasted pipe not matching its reviewed sources |
| `pip install httpx==0.28.1` | Installs the pinned dependency the behavioural tests import (`runpod_core.py` imports `httpx`, which the job does not otherwise install) |
| `test_refactor.py` | Regressions in mesh enforcement, credential scrubbing, truncation detection |
| `scripts/test-bootstrap.sh` | Regressions in the one-time host bootstrap: account/layout creation, the layout/stack env split, migration moves, refusal exit codes, and no-secret-in-output |
| `docker compose config`, all three files | Malformed compose file, OpenHands overlay, or Hermes overlay |
| **Caddy allowlist assertion** | A sensitive route losing its `trusted_only` IP allowlist |
| **Hermes gateway pin assertion** | The `hermes -p default gateway run --replace` CMD being dropped from `hermes/Dockerfile` |
| **WebUI pin assertion** | The WebUI agent dir, interpreter, server cwd, local-venv disable, WebUI commit pin, or `--skip-agent-install` being dropped from `hermes/Dockerfile` |
| **Secret assertion** | Fails the build if `.env` or a data folder was ever committed |

That last check is the one worth understanding. If `.env` somehow got committed, this stops the deploy and tells you. Note that by then the credentials are already in git history and **must be rotated** — deleting the file in a later commit does not remove it from history, and anyone with a clone still has a copy.

The old advisory ShellCheck step is gone from validation. It was `continue-on-error`, so it never blocked anything. The blocking ShellCheck job in `sast-checks.yml` covers the same ground and does fail the gate.

### Job 2 — `deploy`

Only runs if `validate` passed.

1. Runs `scripts/deploy-image-gate.sh`, a fail-closed pre-flight gate that polls GHCR until the sandbox image tag pinned by `install.sh` STEP 8 is published, so the deploy cannot race the image build. It needs no token and no tailnet; `permissions` stay `contents: read`. Bounded at 36 minutes, just past the build workflow's 30-minute ceiling.
2. Joins the tailnet as an ephemeral node tagged `tag:ci`
3. Confirms the Pi is reachable, retrying for ~50 seconds while mesh routes establish
4. Connects as the dedicated `haven-deploy` account and sends exactly one command string, `deploy <sha>`, through `scripts/deploy-trigger.sh`
5. The forced command on the Pi starts the system unit `haven-deploy@<sha>.service`, which runs `scripts/deploy-instance.sh <sha>`: it refuses any revision that is not an ancestor of `origin/main`, resets to the exact `github.sha` CI validated, and asserts `HEAD` equals it
6. `scripts/deploy-instance.sh` hands off to `scripts/deploy-remote.sh <sha>`, which re-asserts `HEAD` and then runs `./install.sh --non-interactive`
7. `scripts/deploy-remote.sh` polls the health endpoint for up to two minutes and gates on `./doctor.sh --no-cloud`: warnings stay green, failures turn the deploy red
8. On the canonical unit path, `ExecStartPost` runs the existing root verifier **after** the transaction process releases its locks. It has a 10-minute bound (plus a 30-second kill grace), following the unit's 45-minute install bound, inside the 60-minute SSH step. It requires the matching main deployment run's successful `validate / Validate sources` job and its in-progress deployment job, supersedes older deployment attempts at the same SHA, then checks other returned workflows, exact deployed HEAD, canonical wiring, runtime health, backup policy and durable transaction acceptance. It does not wait for its own deployment job to finish. Non-successful mandatory evidence, API failures, timeout or unresolved transactions fail closed. The existing journal blocks another deployment until acceptance or explicit recovery. Direct operator migration and custom/local deploy paths retain asynchronous verification.
9. The forced command reads back the unit result and prints the run log into the workflow output, so you can diagnose a failure without SSHing in yourself

**Why the revision is pinned, not `origin/main`.** `validate` tests the commit that
triggered the run (`GITHUB_SHA`). If the deploy reset to `origin/main`, and `main`
moved after validation, the Pi would run an unvalidated revision. A manual
**Run workflow** from a non-main branch would make the validated and deployed
trees differ outright. The client sends the exact SHA, the host refuses any
revision that is not an ancestor of `origin/main`, and the tree is reset to that
SHA with a `HEAD` assert — twice, once in `scripts/deploy-instance.sh` and once
as `scripts/deploy-remote.sh`'s first action. The ancestor check keeps the target
on the deployed line of history.

**Why the runner no longer runs a shell script on the Pi.** The deploy account's
SSH key is pinned to ONE forced command. It cannot run git, a shell, or a second
command. All the host-side work lives in the tracked scripts the unit runs. This
is what removes the admin-account login from the deploy path.

---

## The pull-request gate

`sast-checks.yml` is the one workflow that runs on every pull request to `main`. It has no `paths:` filter on its triggers, so a docs-only pull request still produces the `Security & SAST gate` check the branch ruleset requires. Source validation selects component steps as described below. The only whole job that is filtered is `hermes-nonroot-smoke`, and only by an in-workflow `changes` job: it is skipped only when the shared component mapping excludes Hermes and full validation. Every other job stays unfiltered; `schedule`/`workflow_dispatch` run full validation. It runs on `pull_request` (opened, synchronize, reopened — not `ready_for_review`, so marking a draft ready re-runs nothing), on manual `workflow_dispatch`, and on a weekly `schedule` (Mondays) for a CodeQL baseline and a Semgrep rule-drift check. There is no push-to-main trigger.

| Job | Check | What it catches |
|---|---|---|
| `shellcheck` | ShellCheck (Bash) | Common shell scripting bugs. Blocking. |
| `semgrep` | Semgrep (`--config auto --error`) | SAST findings from the community rulesets. Blocking. On a pull request it scans only the files the PR changed (`--baseline-commit` against the PR base SHA); `workflow_dispatch` and the weekly `schedule` keep the full-tree scan. |
| `validate` | `Validate sources` | Calls the same reusable `validate.yml` the deploy uses (see Job 1 above). |
| `codeql` | `Analyze (python)` and `Analyze (actions)` | CodeQL advanced setup for Python and GitHub Actions. |
| `changes` | Detect Hermes changes | Diffs the exact PR base SHA against HEAD using the shared component mapping (including full fallback), passing the SHA through `env:`. Fails closed (`set -euo pipefail`); an empty base (schedule, dispatch) sets the smoke to run. No third-party action. |
| `hermes-nonroot-smoke` | Hermes non-root smoke | Builds the Hermes image as uid/gid `10001` and runs it as `10001` with `--cap-drop ALL --security-opt no-new-privileges`, no secrets, and a `10001`-owned `/root/.hermes` seeded with a **decoy** agent (a valid Agent source root that writes a marker if imported). Checks `id -u`, HTTP 200 on 8501 within 180 s, liveness at +60 s, the gateway is up, and the local kanban patch is in `/opt/hermes-agent`. Then the pinning checks: PID 1 maps Python only from `/opt/hermes-agent` (never `/root/.hermes`), the decoy marker is absent, one `/api/onboarding/status` request (which imports `run_agent`) answers 200, `bash -lc 'command -v hermes'` resolves to `/usr/local/bin/hermes`, and `docker diff` shows no change under `/app` or `/opt`. Prints `docker diff` (paths only). Skipped only when the `changes` job successfully selects no Hermes/full coverage. |
| `gate` | **`Security & SAST gate`** | The single required check. Always runs; requires `success` from every job, with one exception: `hermes-nonroot-smoke` may be `skipped`, and only when `changes` succeeded. A `failure` or `cancelled` anywhere still reds it. |

**CodeQL advanced setup.** CodeQL previously ran as GitHub "default setup", a dynamic workflow GitHub created and ran on each pull request and each push to `main`. This workflow replaces it with advanced setup: a checked-in `codeql` job, pinned to `github/codeql-action` `33d7b85da1a04171e211befe2c739303b9a4c066` (`v4.39.3`), analysing `python` and `actions` with `build-mode: none`, publishing under the category `/language:<lang>`. Results also appear on the weekly schedule run under **Security → Code scanning**. The `codeql` job is the only job that widens permissions, adding `security-events: write` and `actions: read`; the workflow default is `contents: read`.

**One gate.** Branch protection needs one check, not several. `gate` depends on all six jobs with `if: always()`, so it runs even when an earlier job fails or is cancelled. It prints each result and exits non-zero unless every result is `success`. The single exception is the Hermes non-root smoke, which may be `skipped` — and only because the `changes` job, itself required to succeed, proved the pull request cannot change the image the smoke builds. A failure or a cancellation anywhere, and a skip by any job other than `hermes-nonroot-smoke`, all fail the gate.

### Component validation policy

The required names remain **Security & SAST gate** and **Check agent context maps**
(live main rules inspected during #214). No settings change is needed. Validation
is one job with native step conditionals, not a job per component. The small
[switch table](../scripts/ci-components.py) emits booleans for those conditionals.
It compares the exact PR base SHA to HEAD with NUL-delimited paths and renames
expanded into both paths. Invalid/missing PR metadata or Git failure fails the
job; it cannot silently skip tests. Unknown paths select full validation.
`changed_only` defaults to false; only the SAST caller opts in, and only PR
events use selection. Deployment, weekly and manual SAST runs stay full.

| Changed boundary | Tests and direct/shared consumers | Independent test boundary |
| --- | --- | --- |
| `backup/`, named backup fixtures | Backup/restore safety, system units, timers, container control; status backup socket/log mounts; doctor; remote deploy and verifier; installation-root restore identity | Restic/Docker/systemctl fixtures and scratch SQLite/Git trees; no cloud credentials |
| `auth/`, password reset and named auth fixtures | Auth behavior, installer env escaping, reset; TLS/auth rendering, real Caddy, allowlists and headers | Python login fixtures; stubs for password reset/installer; dummy credentials and isolated Caddy |
| TLS check, Caddy image, status Caddy templates, named TLS fixtures | Proxy plus auth tests, Compose configuration and render matrices | Stub render tests offline; real TLS loopback and Docker Caddy tests require local sockets/engine, not production |
| Status app/tests and named status fixtures | Status probes, private backup API, backup consumers and proxy configuration | Temporary files, mocked DNS/API, real local Unix socket |
| `openwebui/` | Generated pipe and behavioral tests; status wake probe and doctor API/mesh consumers | httpx/mock streams and synthetic worker responses; no worker source or live RunPod |
| `hermes/`, secret-guard fixture | Guard installation/negative input tests, password reset, image pin assertions and Compose; separate ARM64 non-root smoke | Guard fixtures are offline; smoke builds pinned upstream dependencies and starts a local isolated container |
| Doctor and named doctor fixtures | Doctor plus backup/status/inference contracts, remote deployment exit mapping and verifier | Stubbed host/API commands; healthy/degraded/failing states, no production diagnosis |
| Shared paths (including TLS helpers), install/deploy mechanics, firewall/isolation, CI configuration/selection, unknown paths | Full existing suite, including provenance, authorization, destructive restore and rollback protections | Existing fixtures; no live destructive restores |
| Markdown, LICENSE, generated navigation maps | Universal baseline only | No component behavior changes |

Groups explicitly include their consumer tests rather than assuming directories
are independent. Test-script changes follow the same boundary; new/unclassified
tests select full validation. Group expansion is intentionally conservative,
not a recursive graph: the table directly lists tested consumer coverage.
The [offline selection regressions](../scripts/test-ci-components.py) exercise
backup/auth/docs/shared/CI changes, unions, unknown paths, deleted/renamed code,
invalid bases, and actual workflow selection. They also execute the aggregate
gate with failure, cancellation, missing and unexpected skipped results.
The smoke may be skipped only when a successful detector explicitly requests
that skip. Selection/workflow/shared/unknown changes exercise the ARM64 smoke.

| Check | Before #214 | After #214 | Cost / security rationale |
| --- | --- | --- | --- |
| Syntax, tracked-secret/state checks, masked-literal guard | Every PR | Every PR | Fast whole-tree baseline; includes newly added languages' files without maintaining file lists |
| ShellCheck, diff-aware Semgrep, Python/Actions CodeQL | Every PR; weekly/manual whole scans | Unchanged | Preserve SAST and secret rule coverage; avoid a security-scanner migration in this change |
| Source behavior/config tests | All 71 workflow steps | 73 possible steps including selector and its tests; fixture selection: backup 33, auth 25, docs 9; shared/CI 73 | Execute existing affected tests; no weakened assertions |
| Hermes ARM64 smoke | Image/workflow paths; weekly/manual | Image, shared/unknown, workflow or selector paths; weekly/manual | Real non-root image behavior; conservative fallback on selection changes |
| Deployment validation / health | Full source checks, exact-SHA provenance, doctor | Unchanged | Doctor cannot replace unexecuted code-path, restore, authorization or artifact checks |

Timing reference: [PR #213 source-validation job](https://github.com/jimbobsyouruncle/haven/actions/runs/43983948151/job/133707372734)
at tested head `7b2797a54dd87ea18fa869a39eb91352271ada5c` took
12m45s (including job setup/cleanup). Its shell/Python syntax steps totaled 2s;
backup fixtures 26s, auth 12s, remote-deploy fixtures 204s and dynamic port-80
Caddy tests 90s. These explain why unrelated suites are omitted; they are
historical measurements, not promises of current PR wall time. Selection counts
are executable fixture evidence, not separate GitHub PR runs. Queue/setup/cache
and unchanged SAST jobs still bound end-to-end latency.

No behavior suite was proven obsolete. Several tests render overlapping Caddy
variants, but the stub tests isolate helper errors while real Caddy tests catch
adapter/runtime rejection and HTTP routing; retain both for proxy/auth changes.
Doctor fixtures test the diagnostic behavior itself, not a second operational
health gate. `scripts/deploy-remote.sh` remains the runtime authority via
`doctor.sh --no-cloud`: 0 healthy, 1 warning/degraded (deployment warns), 2 failure
(deployment fails), and a missing doctor fails closed. Existing remote-deploy
and doctor fixtures cover these semantics and asleep/optional components.
Exact-SHA assertions and the canonical root verifier/transaction acceptance are
unchanged. CI never runs doctor against production or requests live cloud work.

Known coupling (tracked in [#217](https://github.com/jimbobsyouruncle/haven/issues/217)): installer render tests extract sections of the large installer;
backup/status share log paths, Unix socket permissions and system-unit wiring;
doctor fixtures must stub multiple host commands. Full validation for shared or
installation changes contains this risk without a platform rewrite. Follow-up
refactoring should retain these contracts and fixtures before narrowing further.
Caddy builds, package installs and the ARM64 smoke require approved public
package/image sources; they are not fully offline. Runtime integration and live
restore evidence remain separately authorized operational work.

Local parity deliberately ignores component conditions and replays its existing
full/static modes. Its selector setup step is CI-owned (event/output metadata),
while selection regressions run locally too. Rollback is a reviewed revert of
this change; deploy workflow, credentials, live configuration and image pins
are untouched. Manual full validation is **Security & SAST Checks → Run workflow**;
the existing Monday schedule also runs it. Neither action deploys.

---

## Keeping the pins current (Dependabot)

`dependabot.yml` keeps the SHA-pinned actions in the workflows current. It opens one grouped pull request weekly on Sunday at 22:00 America/New_York (all actions in a single group, commit prefix `ci`, at most 5 open at a time) that bumps every pin it finds.

Dependabot covers **GitHub Actions only**. These pins still move by hand and are easy to forget:

| Pin | Where | Why Dependabot does not cover it |
|---|---|---|
| `semgrep/semgrep:1.179.0@sha256:93963d…` | `workflows/sast-checks.yml` | Container image tag and digest, not an action |
| Compose / Dockerfile image tags | `docker-compose.yml`, `hermes/Dockerfile` | Container images, not actions |
| `httpx==0.28.1` | `workflows/validate.yml` | pip pin inside a workflow step |
| shared-actions `ref:` | `workflows/agent-context.yml` | A non-action git ref outside Dependabot's scope |
| Tailscale `version: '1.104.1'` | `workflows/deploy.yml` | An action input, not a versioned dependency |

---

## Agent context maps and freshness check

`REPO_MAP.md` and `CODE_INDEX.md` at the repository root are small, generated maps of the tracked tree. Coding agents read them instead of whole-code dumps, so context stays small and answers stay fast. The measured cost of that first read, and the layouts compared against it, are recorded in [`../docs/agent-context-index-design.md`](../docs/agent-context-index-design.md).

The **Agent context** workflow (`workflows/agent-context.yml`) enforces that they are fresh. On every pull request to `main` it checks out the generator at a pinned commit from `jimbobsyouruncle/shared-actions`, runs the fixture test (`scripts/test-check-agent-context.sh`), and runs `scripts/check-agent-context.sh` against the committed maps.

The check prints nothing and exits `0` when both maps match a fresh run. It exits `1` when a map is stale or missing, or when a retired `CONSOLIDATED_*.md` is still tracked. It exits `2` on a usage error or a generator failure (including a size overflow over `--max-bytes 28672`).

To refresh the maps yourself:

```bash
python3 <path-to-generate.py> --root . --output-dir . --max-bytes 28672
```

The workflow holds `permissions: contents: read`, adds no write permission, and never commits or pushes. The maps land only through reviewed pull requests.

The separate **Agent context committer** (`workflows/agent-context-committer.yml`) runs on pushes to `main`. When maps are stale it pushes a bot branch, opens a **draft** refresh PR, dispatches the map and SAST workflows, and polls their required checks. It stops with an owner-review handoff; it never merges, enables auto-merge or deletes branches. Its permissions remain `contents: write` (bot branch), `pull-requests: write` (draft PR), `actions: write` (check dispatch) and `checks: read` (check polling). GitHub does not provide a create-PR-only permission here: these write grants still require branch protection and human-controlled review; removing the merge step does not revoke token-level merge capability.

---

## Headless deploy (active after bootstrap)

`deploy/` and `scripts/deploy-*.sh` hold the pieces of a **headless
deploy**: a dedicated, unprivileged `haven-deploy` account with a
forced-command SSH entrypoint that can do exactly one thing — start the system
unit `haven-deploy@<sha>.service` for a 40-character commit.

**This path is now the deploy.** `deploy.yml` connects as the dedicated
`haven-deploy` account and sends exactly one command string, `deploy <sha>`,
through the tracked client `scripts/deploy-trigger.sh`. It no longer logs in as
the admin account and no longer runs a shell script on the Pi. The ancestor
check, the reset to that exact commit and the `HEAD` assert all run inside
`scripts/deploy-instance.sh`, which the system unit runs as root.

It becomes fully active when the owner runs **card F**, `scripts/bootstrap.sh`,
which installs the unit, the polkit rule, the scripts and the `authorized_keys`
line on the host and creates the account as a system account with `/bin/sh` and
a locked password (sshd runs the forced command through the login shell). Once
that bootstrap has run, an explicitly authorized manual dispatch takes this path. The bootstrap
installs those files once; `install.sh` re-applies the unit and the polkit rule
on every deploy, so a change to either file reaches the host without a by-hand
copy (effective from the next instantiation). See
[`../deploy/README.md`](../deploy/README.md) for the `authorized_keys` line, the
install locations, the refusal exit codes and the least-privilege statement.

The account holds no login beyond the forced command (its password is locked), no
sudo, and is in neither the `docker` nor the `systemd-journal` group. The polkit
rule grants only
`start` of a matching unit.

---


## Why your data is safe during a deploy

`git reset --hard` is a destructive command, and seeing it in a deploy script should make you pause. It is safe here because of a specific chain of guarantees:

| Guarantee | Mechanism |
|---|---|
| Backup credentials are untouched | They live in `~/.config/hybrid-ai-backup/` (or `/etc/credstore/hybrid-ai-backup/` in system mode), outside the repo entirely |
| `webui_data/` and `ollama_data/` are untracked | Listed in `.gitignore`, so `git reset` cannot see or touch them |
| `.env` survives | Also gitignored. `install.sh` reads existing values and preserves them |
| Login sessions survive | `WEBUI_SECRET_KEY` is reused, not regenerated, so cookies stay valid |
| Containers are never destroyed with volumes | The workflow runs `up -d`, never `down -v` |
| Failure is visible | A health-check failure fails the build with logs attached, and a `doctor.sh` exit 2 fails the build after the health report prints |
| Validated revision is what runs | The deploy asks the host to run exactly the `github.sha` CI validated. `scripts/deploy-instance.sh` refuses unless it is an ancestor of `origin/main`, resets to it and asserts `HEAD` equals it, and `scripts/deploy-remote.sh` re-asserts `HEAD` before reprovisioning |

The deploy prints disk usage of both data folders after the run, so every deploy leaves an audit trail showing nothing shrank.

---

## Setup

### 1. Generate a deploy SSH key

On your own machine — **not** on the Pi:

```bash
ssh-keygen -t ed25519 -C "github-actions-hybrid-ai" -f ~/.ssh/haven_deploy
```

Install the **public** half on the Pi through the bootstrap, which writes it to
the dedicated `haven-deploy` account and pins it to the forced command:

```bash
sudo ./scripts/bootstrap.sh --deploy-pubkey ~/.ssh/haven_deploy.pub
```

Do not copy it to the admin account with `ssh-copy-id`: the deploy no longer logs
in as the admin account. See [`../deploy/README.md`](../deploy/README.md) for the
`authorized_keys` line and the install locations.

### 2. Create a Tailscale OAuth client

Tailscale admin console → **Settings** → **OAuth clients** → **Generate**:

- Scope: **`auth_keys`** (write)
- Tags: **`tag:ci`**

Save both the client ID and the secret.

### 3. Add the ACL rule

Admin console → **Access controls**. Without this, the runner joins the network but is not permitted to reach your Pi:

```jsonc
{
  "tagOwners": {
    "tag:ci": ["autogroup:admin"]
  },
  "acls": [
    // Your own devices can reach everything
    { "action": "accept", "src": ["autogroup:member"], "dst": ["*:*"] },

    // CI runners: SSH to the Pi only. Nothing else.
    { "action": "accept", "src": ["tag:ci"], "dst": ["100.x.x.x:22"] }
  ]
}
```

Replace `100.x.x.x` with your Pi's address from `tailscale ip -4`. Keep this rule as narrow as it is — the CI runner needs exactly one port on exactly one host.

### 4. Add the repository secrets

GitHub repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**.

| Secret | Value | Where to get it |
|---|---|---|
| `TS_OAUTH_CLIENT_ID` | OAuth client ID | Step 2 |
| `TS_OAUTH_SECRET` | OAuth client secret | Step 2 |
| `PI_TAILSCALE_FULL_DOMAIN` | The Pi's MagicDNS name, e.g. `jarvis.tailXXXX.ts.net` | `tailscale status` on the Pi — the peer's `DNSName` without its trailing dot. Use the name, not the address: a re-registered Pi keeps its name but can change its mesh address |
| `PI_SSH_KEY` | **Private** key contents | `cat ~/.ssh/haven_deploy` — include the BEGIN and END lines. The matching public key is pinned to the forced command on the `haven-deploy` account |
| `PI_SSH_HOST_KEY` | The Pi's SSH host key fingerprint | `ssh-keyscan -t ed25519 $(tailscale ip -4) \| ssh-keygen -lf -` on the Pi — use the SHA256:... field, not the raw known_hosts line |
| `PI_SSH_USER` | **Unused** | May be deleted by the owner |
| `PI_REPO_PATH` | **Unused** | May be deleted by the owner |

> `PI_SSH_KEY` takes the **private** key. That is correct and expected — GitHub needs it to authenticate. It is stored encrypted and masked in logs. This is also why the key should be dedicated to this purpose and authorised only on the Pi, never a key you use elsewhere. It is now the key for the dedicated `haven-deploy` account, and its `authorized_keys` line pins it to the forced command.

> `PI_SSH_USER` and `PI_REPO_PATH` are unused. The deploy no longer logs in as
> the admin account (the login name is the literal `haven-deploy`), and the
> remote path is resolved on the host by `scripts/deploy-instance.sh`. The owner
> may delete both secrets.

### 5. Optional — require approval before deploying

The workflow declares `environment: production`, but that name alone does not enforce reviewer approval. The inspected environment had only a branch policy. The tracked workflow requires either separately activated automatic canonical-main deployment or manual dispatch with explicit production assent for the exact main SHA before production access. Automated host recovery preflight is also mandatory. Configuring required reviewers is a separate owner settings action; this PR does not change settings.

Worth enabling if the Pi is doing anything you depend on.

### 6. Test it

```bash
git commit --allow-empty -m "test: verify deploy pipeline"
git push
```

Watch the **Actions** tab. First run takes 2–4 minutes.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Pi ... is unreachable over the tailnet` | ACL rule missing, or Pi offline | Verify the `tag:ci` ACL; check `tailscale status` on the Pi |
| SSH `permission denied (publickey)` | Wrong key, or public half not installed | Re-run `sudo ./scripts/bootstrap.sh --deploy-pubkey ~/.ssh/haven_deploy.pub` on the Pi; confirm you pasted the **private** key into the secret. `ssh-copy-id` will not work — the deploy account's key is pinned to the forced command |
| `RUNPOD_API_KEY missing and --non-interactive was requested` | `.env` does not exist on the Pi yet | Run `./install.sh` interactively on the Pi once first |
| `Open WebUI failed its health check` | Container did not start | The workflow output includes the last 50 log lines — read those |
| OAuth client errors | Wrong scope or missing tag | Client needs `auth_keys` write scope and `tag:ci` |
| Automatic deploy job skipped | Activation variable absent or not `enabled` | Keep inactive until canonical acceptance and explicit owner activation; manual exact-main dispatch remains available |

---

## Manual deploy

The workflow is a convenience, not a dependency. This does the same thing:

```bash
ssh pi@<pi-tailscale-ip>
cd hybrid-ai
git pull
./install.sh
```

---

## Security notes

- **Least privilege.** The workflow declares `permissions: contents: read`. It can read your code and nothing else.
- **Ephemeral identity.** The runner's tailnet membership exists only for the duration of the job.
- **Narrow ACL.** `tag:ci` reaches port 22 on one host. Not your laptop, not the GPU pod.
- **Concurrency lock.** `concurrency: deploy-control-plane` prevents two runners reconfiguring the Pi simultaneously.
- **Secret masking.** GitHub redacts secret values from logs automatically — but avoid `echo`-ing them regardless, since masking is pattern-based and not infallible.
- **Rotate the deploy key** if you ever suspect the repository was accessed by someone else.
