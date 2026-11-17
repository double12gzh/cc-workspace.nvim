---
trigger: glob
globs: "**/tests/**/*.lua, **/scripts/**"
---

# Testing & Quality Gate Invariants

Apply these rules when editing [tests/run_headless.lua](../../tests/run_headless.lua), [tests/test_keymaps_and_lint.lua](../../tests/test_keymaps_and_lint.lua), or scripts under `scripts/`:

## 1. Hermetic, Zero-Network Execution & `<= 800` Line Modularity

- Every `.lua` file under `tests/` and `scripts/` MUST stay `<= 800` physical lines after `stylua` formatting.
- Headless tests MUST run deterministically under `nvim --headless -u NONE -i NONE --noplugin --cmd "set rtp+=<repo>" "+luafile tests/run_headless.lua"` with **zero network calls** and **zero external LLM/ACP agent processes** (never `-l`, which executes before Neovim finishes editor `maphash` initialization).
- Stub `codecompanion` and optional `telescope` modules via `package.preload[...]` when exercising workspace UI, lifecycle transitions, dynamic keymap overrides (`set_keymaps` / `show_keys`), winbar pagination, statusline rollups, and switcher interactions.
- Real local `git` commands (`git init`, `git worktree`, `git status`) MUST operate exclusively inside `tmp_root = vim.fn.tempname()` with explicit repo-local `user.name` and `user.email`, and with inherited `GIT_DIR` / `GIT_INDEX_FILE` / `GIT_WORK_TREE` variables cleared so `git commit` hook runs stay hermetic.

## 2. Mandatory Live Data Checksums & Teardown

- Snapshot SHA-256 digests of `~/.local/share/nvim/cc-workspace-projects.json` and `~/.local/share/nvim/codecompanion-history/index.json` (plus history/worktrees tree digests) in [tests/run_headless.lua](../../tests/run_headless.lua) before any setup runs, and assert exact equality at the end of the suite (even if an assertion inside `xpcall` fails).
- Stop active timers (`statusline.stop()`, `wt.reset_states()`), kill any spawned `nvim --embed` child process (`pcall(handle.kill, handle, "sigterm")`), close libuv pipes, restore `vim.notify`, and remove `tmp_root` unconditionally.

## 3. Assertion Strength, Binary Hygiene & Negative Controls

- Bound every `vim.wait(timeout_ms, predicate, interval_ms)` call (`timeout_ms <= 5000`) and assert the postcondition explicitly after `vim.wait` returns.
- For winbar/statusline changes, evaluate actual statusline markup via `vim.api.nvim_eval_statusline(..., { use_winbar = true, highlights = true })` across terminal widths (`180`, `120`, `90`, `62`) and check `vim.v.errmsg == ""` plus `ev.width <= win_w`.
- When adding a new lint rule in [scripts/lint_repo.lua](../../scripts/lint_repo.lua) or [scripts/lint_markdown.lua](../../scripts/lint_markdown.lua), verify both passing clean state and a negative control (confirming a synthetic violation is rejected).
