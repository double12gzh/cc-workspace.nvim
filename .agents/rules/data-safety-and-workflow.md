---
trigger: always_on
---

# Live User Data Safety & Development Workflow

## 1. Zero Pollution of Live User Persistence

`cc-workspace.nvim` is mounted directly into the user's live Neovim setup by `lazy.nvim`. Verification runs, screenshot generators, debugging sessions, and ad-hoc `nvim --headless` scripts MUST NEVER read-modify-write or pollute live user data:

- `~/.local/share/nvim/cc-workspace-projects.json` (`vim.fn.stdpath("data") .. "/cc-workspace-projects.json"`)
- `~/.local/share/nvim/cc-worktrees/` (`vim.fn.stdpath("data") .. "/cc-worktrees"`)
- `~/.local/share/nvim/codecompanion-history/` (`vim.fn.stdpath("data") .. "/codecompanion-history"`)

Whenever invoking plugin code outside interactive user sessions:

1. Create an isolated temp directory (`local tmp = vim.fn.tempname(); vim.fn.mkdir(tmp, "p")`).
2. Redirect persistence paths (or `XDG_DATA_HOME` / `XDG_STATE_HOME` / `XDG_CACHE_HOME`) before calling actions:
   - `ws.setup({ projects_file = tmp .. "/projects.json", worktrees_base_dir = tmp .. "/worktrees" })`
   - `ws.set_projects_file(tmp .. "/projects.json")`
   - `wt.set_worktrees_base_dir(tmp .. "/worktrees")`
3. Delete `tmp` in a cleanup block (`pcall(vim.fn.delete, tmp, "rf")`) and verify live file SHA-256 hashes did not change.

## 2. Quality Gate & Modularity Discipline

- Run `./scripts/check.sh` before claiming any change is complete.
- Keep every `.lua` file across `lua/`, `scripts/`, and `tests/` strictly `<= 800` physical lines.
- Never weaken, skip, or delete existing assertions in [tests/run_headless.lua](../../tests/run_headless.lua), [tests/test_keymaps_and_lint.lua](../../tests/test_keymaps_and_lint.lua), or [tests/test_commit_msg.lua](../../tests/test_commit_msg.lua) to make a broken change pass.
- Never bypass `pre-commit`, `commit-msg`, or `pre-push` hooks (`git commit --no-verify` / `git push --no-verify`) unless explicitly requested by the user.

## 3. Git Commit, Shell & Multi-Agent Conventions

- **Human Authorship Sovereignty**: Preserve local Git `user.name` and `user.email` as `Author` and `Committer`; never pass `--author` or override `GIT_AUTHOR_*` / `GIT_COMMITTER_*` / `git config`.
- **Ban Bare `cat` (`bat` Alias Hazard)**: Never invoke bare `cat` or `cat <<'EOF'` in shell commands (`cat` is aliased to `bat`, injecting line numbers and `STDIN ─────────` borders); use dedicated file-reading tools or escape `\cat` / `/bin/cat` when shell stdin/stdout plumbing is strictly necessary.
- **Standard 3-Paragraph `-m` Commit Structure**: Every AI `git commit` MUST pass exactly 3 `-m` arguments (enforced by [scripts/lint_commit_msg.lua](../../scripts/lint_commit_msg.lua) via `./scripts/check.sh commit-msg`):
  1. `<type>(<scope>): <subject>` (or `<type>: <subject>` for cross-module changes), where `type` is one of `feat`, `fix`, `refactor`, `perf`, `docs`, `style`, `test`, `build`, `ci`, `chore`, `revert` (aligned with [cliff.toml](../../cliff.toml)).
  2. Bulleted `- <change>` list combined inside a **single** `-m` argument separated by newlines (never pass a separate `-m` per bullet item).
  3. Mandatory `Co-Authored-By: <Model> <email>` trailer using **only** the base model family name (never version numbers, sub-models, or outer client/harness names such as `Gemini 3.8 Flash`, `Claude 3.7 Sonnet`, `Antigravity`, `agy`, `Oh-My-Pi`, `omp`, `Claude Code`, `Codex`, or `Cursor`) and official vendor noreply email:
     - `Co-Authored-By: Claude <noreply@anthropic.com>`
     - `Co-Authored-By: Gemini <218195315+gemini-cli@users.noreply.github.com>`
     - `Co-Authored-By: GPT <noreply@openai.com>`
     - `Co-Authored-By: DeepSeek <noreply@deepseek.com>`
- **Multi-Agent Worktrees & Destructive Git Ban**: Isolate concurrent/experimental agent work under `.worktrees/{name}` (or `claude -w {name}`), check `git branch --show-current` before editing, and never run `git reset --hard`, `git clean -fd`, `git checkout -- .`, `git restore .`, or `git push --force` without explicit user confirmation.
- **Ban Unbounded `$HOME` / `/` Scans**: Never run `find ~`, `find /`, `find /Users`, or recursive `grep`/`rg` across `~` (avoids macOS TCC privacy hangs and watchdog kills); restrict searches to the current repo/worktree or bounded cache subdirectories with `-maxdepth`.
- **Mermaid Layout**: Keep Mermaid diagrams vertical (`flowchart TD` / `TB`), linked without wide horizontal fan-out (`<= 3`), and within 120 terminal columns.
