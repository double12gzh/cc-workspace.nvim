---
trigger: glob
globs: "**/lua/**/*.lua, **/tests/**/*.lua, **/scripts/**/*.lua"
---

# Lua & Neovim Plugin Coding Standards

Apply these rules whenever editing Lua files in `cc-workspace.nvim`:

## 1. Strict Modularity (`<= 800` Lines) & Acyclic DAG

- **Max 800 Lines per `.lua` File**: Every `.lua` file across `lua/`, `scripts/`, and `tests/` MUST stay `<= 800` physical lines after `stylua` formatting (enforced by `M.check_lua_line_limit` in [scripts/lint_repo.lua](../../scripts/lint_repo.lua)). Split growing files into focused single-responsibility modules while preserving existing facade exports.
- **0-Cycle Top-Level `require()` DAG**:
  - Leaf modules (`config`, `icons`, `state`, `git`, `worktree_ops`, `agent_state`, `worktree`, `winbar_highlights`, `winbar`, `statusline`, `switcher`, `keymaps`) MUST NOT top-level `require("cc_workspace")`. Use deferred `pcall(require, "cc_workspace")` inside functions when cross-branch coordination is needed.
- Never assign unprefixed globals or `_G._user_cc_*` callbacks. Winbar `%@...@` statusline callbacks MUST use `v:lua.require'cc_workspace.winbar'.<fn>`.

## 2. Formatting, Types & Modern Neovim APIs

- Format with `stylua` using [stylua.toml](../../stylua.toml) (`Tabs`, width `4`, `column_width = 120`, `AutoPreferDouble`, `call_parentheses = "Always"`).
- Maintain **0 warnings and 0 errors** under `lua-language-server --check` (`--checklevel=Warning`). Document exported functions and option shapes with EmmyLua (`---@param`, `---@return`, `---@class`, `---@field`).
- Use modern Neovim `>= 0.11` APIs exclusively:
  - `vim.uv` (never `vim.loop`)
  - `vim.api.nvim_buf_set_extmark` (never `nvim_buf_add_highlight`)
  - `vim.bo[buf]` / `vim.wo[win]` (never `nvim_buf_get_option` / `nvim_win_set_option`)
  - `vim.islist` (never `vim.tbl_islist`)

## 3. Non-Blocking UI & Resource Lifecycle

- Never call `vim.fn.system`, `vim.fn.systemlist`, `io.popen`, `os.execute`, or `:wait()` inside UI rendering, winbar, statusline, switcher, layout, or worktree modules.
- In libuv callbacks (`vim.uv` timers, pipes, `vim.system` exit handlers), check `vim.in_fast_event()` and wrap Neovim API calls in `vim.schedule(...)`.
- Stop and close every `vim.uv.new_timer()` (`timer:stop(); if not timer:is_closing() then timer:close() end`) when animations go idle or floating windows close.
- Guard all buffer/window operations with `vim.api.nvim_buf_is_valid(buf)` / `vim.api.nvim_win_is_valid(win)`.

## 4. Path, Dynamic Keymap & Display-Width Safety

- Never run `vim.fn.expand()` on arbitrary paths (only `vim.fn.expand("~")` fallback is permitted). Normalize directories via `paths.expand_raw_dir_path`, `paths.normalize_project_path`, or `git.normalize_path`.
- Never use global `:cd` for per-chat isolation; use window-local `lcd` (`paths.sync_win_lcd`) or `paths.with_temp_cwd`.
- Route all user-configurable keybindings through `config.KEYMAP_SCHEMA` and `keymaps.lua` (`vim.b[buf]._cc_ws_bound_keys` / `_bound_global_keys`) so `set_keymaps()` hot-rebinding and `:CodeCompanionWorkspaceKeys` always reflect live bindings.
- Use `vim.fn.strdisplaywidth` / `vim.api.nvim_strwidth` for column layout and truncation (never `#str`, which counts UTF-8 bytes rather than screen cells). Use `#str` only for byte-indexed extmark highlight ranges (`col_start` / `end_col`).
