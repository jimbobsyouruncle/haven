# Haven local Codex launcher

The version-controlled `scripts/haven` is the reference for your workstation's `~/.local/bin/haven`. It is **not installed automatically**. It is a human-initiated convenience for already-public, authorized material; it does not enforce Haven permissions or grant access to the RunPod repository.

After the PR is reviewed and merged, from your local checkout:

```bash
git switch main && git pull --ff-only
install -Dm755 scripts/haven "$HOME/.local/bin/haven"
haven help
```

Commands: `haven` (refresh and open Codex), `haven status`, `haven next [EPIC_NUMBER]` (read-only completion/closure review or next Implementation Card), `haven new-epic` (read-only prioritized epic and child issue proposals). Set `HAVEN_EPIC` for the default epic or `HAVEN_REPO` for the checkout path after a rename.

The launcher preserves the existing clean-worktree fetch/fast-forward behavior and never merges/rebases feature branches. It does not create or close GitHub issues. GitHub mutations require explicit owner approval. External Codex must not receive unpublished private data or credentials. See `AGENTS.md` and `docs/haven/DECISIONS.md`.

Offline tests: `bash scripts/test-haven-launcher.sh`.
