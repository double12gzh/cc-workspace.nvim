---
name: ccw-codecompanion-patch
description: >-
  Use this skill when inspecting, debugging, extending, or upgrading monkey-patches in
  lua/cc_workspace/patches.lua, lua/cc_workspace/history_restore.lua, lua/cc_workspace/context_send.lua,
  or lua/cc_workspace/layout.lua against codecompanion.nvim (v20.1.0), codecompanion-history.nvim,
  or persisted.nvim.
---

# Maintain CodeCompanion & Session Patches

`cc-workspace.nvim` relies on targeted runtime patches in [lua/cc_workspace/patches.lua](../../../lua/cc_workspace/patches.lua) (alongside [history_restore.lua](../../../lua/cc_workspace/history_restore.lua) and [context_send.lua](../../../lua/cc_workspace/context_send.lua)) so multiple open chats across different repositories and Git worktrees keep isolated working directories, system prompts, ACP subprocesses, tool runs, and history records.

Read [references/patch-surface.md](./references/patch-surface.md) for the complete inventory of upstream targets and saved `_cc_ws_orig_*` slots.

## Step-by-Step Procedure

### 1. Inspect Upstream Source Read-Only Before Changing Any Patch

Verify exact upstream function signatures and table fields in the locally installed lazy plugins (read-only — never modify files under `~/.local/share/nvim/`):

- `codecompanion.nvim` (`v20.1.0`): `~/.local/share/nvim/site/lazy/codecompanion.nvim/lua/codecompanion/`
- `codecompanion-history.nvim`: `~/.local/share/nvim/site/lazy/codecompanion-history.nvim/lua/codecompanion/_extensions/history/`
- `persisted.nvim`: `~/.local/share/nvim/site/lazy/persisted.nvim/lua/persisted/`

### 2. Follow the Idempotent Wrapping Pattern

Every patch function in `patches.lua` may run multiple times (`setup()`, `vim.schedule`, `CodeCompanionChatCreated`, `PersistedStart`). Always guard against double-wrapping:

```lua
local ok, mod = pcall(require, "codecompanion.some.module")
if not ok or type(mod) ~= "table" then
	return
end
local orig = mod._cc_ws_orig_target_fn or mod.target_fn
if type(orig) ~= "function" then
	return
end
mod._cc_ws_orig_target_fn = orig
mod._cc_ws_cwd_patched = true
mod.target_fn = function(self, ...)
	-- Resolve per-chat cwd via projects.get_valid_chat_cwd(chat)
	return orig(self, ...)
end
```

### 3. Enforce Per-Chat CWD & Ephemeral Guard Invariants

- Resolve per-chat CWD exclusively through `projects.get_valid_chat_cwd(chat)`.
- For synchronous upstream code that calls `vim.fn.getcwd()` internally (HTTP tool runner, orchestrator callbacks, buffer context), wrap execution in `paths.with_temp_cwd(chat_cwd, fn)` / `projects.with_temp_cwd(chat_cwd, fn)` so global CWD is always restored via `pcall` cleanup even on error.
- For ACP subprocesses and RPC payloads, inject `cwd = chat_cwd` into copied `opts` / `params` tables (`vim.tbl_extend("force", ...)` — never mutate shared caller tables in place).
- Preserve `patch_history_storage_tmp_guard()` so ephemeral `/tmp` / `vim.fn.tempname()` directories never write entries into live `~/.local/share/nvim/codecompanion-history/`.

### 4. Validate

1. Add or update mock coverage in [tests/run_headless.lua](../../../tests/run_headless.lua) or [tests/test_keymaps_and_lint.lua](../../../tests/test_keymaps_and_lint.lua) (keeping every `.lua` file `<= 800` lines) verifying both normal per-chat CWD scoping and fallback behavior when optional modules are unloaded.
2. Run `./scripts/check.sh` and confirm `0` warnings and `0` failures.
