---
name: ccw-verify-and-lint
description: >-
  Use this skill when running formatting, static LuaLS diagnostics, architectural AST/DAG
  and <=800-line checks, pre-commit hooks, or isolated Neovim headless E2E tests in
  cc-workspace.nvim, or when adding regression tests to tests/.
---

# Verify, Lint & Test `cc-workspace.nvim`

Follow this runbook to validate changes locally and author regression tests without touching live user files (`~/.local/share/nvim/cc-workspace-projects.json`, `~/.local/share/nvim/cc-worktrees/`, or `~/.local/share/nvim/codecompanion-history/`).

## 1. Run Quality Gates

Use [scripts/check.sh](../../../scripts/check.sh), which resolves `nvim`, `stylua`, `lua-language-server`, and `shfmt` across `$PATH`, `~/.local/share/nvim/mason/bin`, `~/tools/nvim/bin`, and Homebrew:

```sh
# Fast static checks only: hygiene (incl. PNG magic) + stylua + AST/DAG/800L/docs + LuaLS
./scripts/check.sh lint

# Full repository verification: static checks + isolated headless E2E suite
./scripts/check.sh

# Validate a commit message file (Conventional Commits, 3-part -m & AI Co-Authored-By)
./scripts/check.sh commit-msg .git/COMMIT_EDITMSG
```

To auto-format Lua (`stylua`) and shell scripts (`shfmt`) in place before re-checking:

```sh
./scripts/check.sh fmt --fix
```

## 2. Diagnose Gate Failures

1. **`hygiene` failure**: Fix merge conflict markers, `CRLF` endings, trailing whitespace, missing trailing newline, invalid JSON, corrupted PNG/JPEG/WebP image headers, or `shfmt` diffs (`./scripts/check.sh fmt --fix`).
2. **`fmt` failure**: Run `./scripts/check.sh fmt --fix` to apply [stylua.toml](../../../stylua.toml).
3. **`arch` failure ([scripts/lint_repo.lua](../../../scripts/lint_repo.lua) & [scripts/lint_markdown.lua](../../../scripts/lint_markdown.lua))**:
   - **`exceeding max 800 lines`**: Split the oversized `.lua` file along single-responsibility boundaries so every `.lua` file in `lua/`, `scripts/`, and `tests/` stays `<= 800` lines after `stylua`.
   - **Top-level `require()` cycle**: Move cross-module calls (especially into `cc_workspace` or `cc_workspace.worktree` from UI leaf modules) inside functions via `pcall(require, ...)`.
   - **Accidental global write**: Prefix local variables/functions with `local`.
   - **Forbidden API**: Replace `vim.loop` with `vim.uv`, `nvim_buf_add_highlight` with `vim.api.nvim_buf_set_extmark`, and `vim.fn.expand(var)` with `paths.expand_raw_dir_path(var)`.
   - **Customization / link / Mermaid error**: Fix YAML frontmatter (`name` matching folder name, valid `trigger` / `globs`, `AGENTS.md` without frontmatter and `<= 24000` bytes), broken relative Markdown/image links, or horizontal/disconnected Mermaid diagrams.
4. **`lsp` failure (`lua-language-server --check`)**:
   - Fix nil-narrowing (`local x = tbl.field` before `if x then`), EmmyLua `@param` / `@return` / `@class` types, or `---@cast` annotations. Never suppress warnings with file-wide `---@diagnostic disable`.
5. **`commit-msg` failure ([scripts/lint_commit_msg.lua](../../../scripts/lint_commit_msg.lua))**:
   - Ensure `<type>(<scope>): <subject>` (or `<type>: <subject>`) uses a valid [cliff.toml](../../../cliff.toml) type (`feat`, `fix`, `refactor`, `perf`, `docs`, `style`, `test`, `build`, `ci`, `chore`, `revert`), no `bat` `STDIN` decoration, a single `-m` body paragraph for bullets, and a canonical 3rd-paragraph `Co-Authored-By: <Model> <email>` trailer using base model family names only (`Claude`, `Gemini`, `GPT`, `DeepSeek`).
6. **`test` failure ([tests/run_headless.lua](../../../tests/run_headless.lua), [tests/test_keymaps_and_lint.lua](../../../tests/test_keymaps_and_lint.lua), & [tests/test_commit_msg.lua](../../../tests/test_commit_msg.lua))**:
   - Inspect `FAIL: <label> (<detail>)` lines on stderr. Fix the broken behavior rather than weakening existing assertions.

## 3. Add Isolated Regression Tests

When adding new behavior or fixing a bug, extend [tests/run_headless.lua](../../../tests/run_headless.lua) or [tests/test_keymaps_and_lint.lua](../../../tests/test_keymaps_and_lint.lua) (keeping both files `<= 800` lines):

1. Reuse `tmp_root` (`tmp_projects_file`, `tmp_worktrees_dir`) or subdirectories under `tmp_root` — never create files in `$HOME` or `stdpath("data")`.
2. Record expectations with `check(condition, "descriptive invariant label", optional_debug_detail)`.
3. For mouse-clickable winbar/statusline `%@...@` handlers, test via `nvim_eval_statusline(..., { use_winbar = true, highlights = true })` or Section `6b` (`nvim --embed` RPC session).
4. Re-run `./scripts/check.sh` and confirm `0` failed checks and unchanged live user SHA-256 digests.
