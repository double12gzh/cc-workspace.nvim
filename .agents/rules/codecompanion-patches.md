---
trigger: glob
globs: "**/lua/cc_workspace/patches.lua, **/lua/cc_workspace/layout.lua, **/lua/cc_workspace/history_restore.lua, **/lua/cc_workspace/context_send.lua, **/lua/codecompanion/**/*.lua"
---

# CodeCompanion v20.1.0 & Session Patch Invariants

Apply these rules when modifying [lua/cc_workspace/patches.lua](../../lua/cc_workspace/patches.lua), [lua/cc_workspace/layout.lua](../../lua/cc_workspace/layout.lua), [lua/cc_workspace/history_restore.lua](../../lua/cc_workspace/history_restore.lua), [lua/cc_workspace/context_send.lua](../../lua/cc_workspace/context_send.lua), or [lua/codecompanion/_extensions/workspace/init.lua](../../lua/codecompanion/_extensions/workspace/init.lua):

## 1. Idempotent Wrapping Contract

- Upstream modules (`codecompanion`, `codecompanion.acp`, `codecompanion._extensions.history.*`, `persisted`) may be patched multiple times across lazy-load hooks and `User` autocmds.
- Before replacing any upstream function `mod[fn]`, store and reuse `local orig = mod._cc_ws_orig_<fn> or mod._user_ws_orig_<fn> or mod[fn]`, then set `mod._cc_ws_orig_<fn> = orig`. Never wrap an already-wrapped closure.
- Fail gracefully (`pcall(require, ...)` + `type(...) == "table"` / `"function"` checks) when optional plugins (`codecompanion-history.nvim`, `persisted.nvim`, `telescope.nvim`) are absent or not yet loaded.

## 2. Per-Chat `cwd` & `save_id` Isolation

- Every chat instance MUST carry a normalized `chat.opts.cwd` and unique `chat.opts.save_id` from creation (`Chat.new` and `CodeCompanionChatCreated`).
- All ACP subprocess spawns (`conn.methods.job`), ACP RPC requests carrying `params.cwd`, relative ACP filesystem reads/writes (`handle_fs_read_text_file_request`, `handle_fs_write_file_request`), HTTP tool executions (`runner.run_tool` and `orchestrator` lifecycle methods), system prompts (`system_prompt.make_context`), and session serialization (`serializer.to_session`) MUST resolve `projects.get_valid_chat_cwd(chat)` rather than falling back to Neovim's global CWD.
- `resolve_buffer_context(target_cwd)` in `history_restore.lua` (re-exported by `layout.lua`) MUST never leak buffer filenames or lines from buffers outside `target_cwd`.

## 3. Ephemeral Path & Session Save Guards

- `patch_history_storage_tmp_guard()` MUST block `codecompanion-history` writes to the live default history directory whenever `state.projects_file` or the chat's `cwd` resolves to an ephemeral temp directory (`paths.is_ephemeral_tmp_path`), unless explicitly pinned by the user.
- `patch_persisted_session()` MUST prevent `persisted.nvim` from saving transient `cc-workspace` tabs or hijacking session filenames via chat-window `lcd` overrides, and MUST restore window-local `lcd`s after synchronous manual saves.
