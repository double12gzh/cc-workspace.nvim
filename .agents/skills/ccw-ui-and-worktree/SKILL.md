---
name: ccw-ui-and-worktree
description: >-
  Use this skill when adding or modifying sidebar tree rendering, dynamic keymaps, chat winbar
  pills, lualine statusline components, floating agent switcher views, or async Git worktree
  operations in cc-workspace.nvim.
---

# Extend UI Chrome, Dynamic Keymaps & Git Worktree Flows

Use this runbook when modifying [render.lua](../../../lua/cc_workspace/render.lua), [render_tree.lua](../../../lua/cc_workspace/render_tree.lua), [sidebar.lua](../../../lua/cc_workspace/sidebar.lua), [sidebar_actions.lua](../../../lua/cc_workspace/sidebar_actions.lua), [keymaps.lua](../../../lua/cc_workspace/keymaps.lua), [winbar.lua](../../../lua/cc_workspace/winbar.lua), [winbar_highlights.lua](../../../lua/cc_workspace/winbar_highlights.lua), [statusline.lua](../../../lua/cc_workspace/statusline.lua), [switcher.lua](../../../lua/cc_workspace/switcher.lua), [layout.lua](../../../lua/cc_workspace/layout.lua), [git.lua](../../../lua/cc_workspace/git.lua), [worktree_ops.lua](../../../lua/cc_workspace/worktree_ops.lua), [agent_state.lua](../../../lua/cc_workspace/agent_state.lua), or [worktree.lua](../../../lua/cc_workspace/worktree.lua). Keep every `.lua` file `<= 800` lines.

## 1. Two-Phase Non-Blocking Git & Render Pattern

UI chrome renders synchronously on window/tab/autocmd events and MUST complete in `< 1ms` without spawning subprocesses:

1. **Synchronous pass**: Read pure-Lua/libuv `.git` metadata in [git.lua](../../../lua/cc_workspace/git.lua) (`get_repo_root`, `get_worktree_branch`, `is_linked_worktree`) and cached worktree lists (`worktree_ops.list_worktrees`).
2. **Coalesced async pass**: Trigger bounded async `run_git_async` refreshes in [worktree_ops.lua](../../../lua/cc_workspace/worktree_ops.lua) (`GIT_TERMINAL_PROMPT=0`, `GIT_OPTIONAL_LOCKS=0`, `SIGKILL` timeout watchdog) and coalesce UI redraws via `render.schedule_render()` / `winbar.schedule_refresh()`.

When adding new `git` mutations:

- Refuse destructive operations on the main repository worktree (`is_main == true`).
- Check dirty status (`git status --porcelain`) before removing a linked worktree unless `opts.force == true`.
- Guard all libuv callbacks with `if vim.in_fast_event() then vim.schedule(...) end`.

## 2. Adding or Updating Actions & Dynamic Keymaps

Keep these 5 locations synchronized whenever adding or changing a shortcut or action:

1. **Schema & defaults**: Register the action key, default binding (`string`, `string[]`, or `false`), and description in `M.defaults.keymaps` + `M.KEYMAP_SCHEMA` inside [lua/cc_workspace/config.lua](../../../lua/cc_workspace/config.lua).
2. **Keymap engine & inspector**: Wire buffer/global binding cleanup and execution in [lua/cc_workspace/keymaps.lua](../../../lua/cc_workspace/keymaps.lua) so `cc_workspace.set_keymaps()` and `:CodeCompanionWorkspaceKeys` (`show_keys`) reflect live overrides automatically.
3. **Sidebar / Switcher handler**: Attach row metadata in [render_tree.lua](../../../lua/cc_workspace/render_tree.lua) / [render.lua](../../../lua/cc_workspace/render.lua) and bind the action in [sidebar.lua](../../../lua/cc_workspace/sidebar.lua) / [sidebar_actions.lua](../../../lua/cc_workspace/sidebar_actions.lua) or [switcher.lua](../../../lua/cc_workspace/switcher.lua).
4. **Public facade & docs**: Expose public functions in [lua/cc_workspace/init.lua](../../../lua/cc_workspace/init.lua) and document in [README.md](../../../README.md).
5. **Headless E2E test**: Add coverage in [tests/run_headless.lua](../../../tests/run_headless.lua) or [tests/test_keymaps_and_lint.lua](../../../tests/test_keymaps_and_lint.lua).

## 3. Winbar, Statusline & Switcher Invariants

- **Display width vs byte offsets**:
  - Compute layout padding and truncation with `vim.fn.strdisplaywidth` / `vim.api.nvim_strwidth` (`state_mod.truncate_display`, `winbar_highlights.truncate_cells`).
  - Compute `nvim_buf_set_extmark` `col_start` / `end_col` spans using UTF-8 byte lengths (`#segment`).
- **Winbar width budget (`winbar.lua`)**:
  - Render `1..7` chat pills maximum; collapse off-screen chats into `‹ +N` / `+M ›` badges carrying the highest-priority off-screen attention bufnr (`waiting > error > unread > streaming/thinking`).
  - `nvim_eval_statusline(bar, { winid = win, use_winbar = true, maxwidth = 9999 }).width` MUST stay `<= nvim_win_get_width(win)` across terminal widths `180`, `120`, `90`, and `62`.
  - Use `%<arg>@v:lua.require'cc_workspace.winbar'.<fn>@...%X` click regions exclusively (zero `_G` globals).
- **Theme resilience**:
  - Re-register highlight groups (`CcWs*`, `CcWinbar*`) on `ColorScheme` autocmds and support both dark and light `vim.o.background`.

## 4. Validate

Run `./scripts/check.sh` to verify formatting, `<= 800` line limits, 0-cycle DAG rules, LuaLS types, dynamic keymap hot-rebinding, and `nvim --embed` mouse click routing.
