# Upstream Patch Surface (`codecompanion.nvim` `v20.1.0`)

All runtime monkey-patches reside in [lua/cc_workspace/patches.lua](../../../../lua/cc_workspace/patches.lua).

| Upstream Module | Target Function / Autocmd | Saved Original Slot | Purpose & Invariant |
| :--- | :--- | :--- | :--- |
| `persisted` | `save(opts)` | `_cc_ws_orig_save` | Prevents auto-saving empty `cc-workspace` tabs, temporarily closes workspace / restores code-tab `lcd`s during session writes, and re-enters workspace on manual save. |
| `CodeCompanionHistory` augroup | `User` `CodeCompanionChatCreated` | `guarded_history_callbacks` weak table | Defers callback via `vim.schedule` and aborts if `buf_get_chat(bufnr)` is already nil (prevents race when transient chats close immediately). |
| `codecompanion.interactions.chat` | `new(args)` | `_cc_ws_orig_new` | Seeds normalized `args.cwd` and unique `args.save_id` before construction and ensures `chat.opts.cwd` / `chat.opts.save_id` are populated on the returned instance. |
| `codecompanion.acp` | `new(args)` -> `conn.methods.job` | `_cc_ws_orig_new`, `_cc_ws_orig_job` | Forces spawned ACP agent subprocesses (`oh-my-pi`, `claude-code`, etc.) to start with `opts.cwd = chat_cwd`. |
| `codecompanion.acp` | `send_rpc_request(self, method, params)` | `_cc_ws_orig_send_rpc` | Rewrites `params.cwd` to `chat_cwd` whenever an outgoing ACP JSON-RPC request carries a `cwd` field. |
| `codecompanion.acp` | `handle_fs_read_text_file_request`, `handle_fs_write_file_request` | `_cc_ws_orig_handle_fs_*` | Resolves relative `params.path` requests from the ACP agent against `chat_cwd` instead of Neovim's global CWD. |
| `codecompanion.interactions.chat.tools.runtime.runner` | `run_tool(self, tool_cmd, action, args)` | `_cc_ws_orig_run_tool` | Wraps HTTP tool execution in `projects.with_temp_cwd(chat_cwd, ...)`. |
| `codecompanion.interactions.chat.tools.orchestrator` | `setup_next_tool`, `finalize_tool`, `success`, `error` | `_cc_ws_orig_<method>` | Wraps tool lifecycle transitions in `projects.with_temp_cwd(chat_cwd, ...)` preserving varargs (`select("#", ...)`). |
| `codecompanion.interactions.shared.system_prompt` | `make_context(opts)` | `_cc_ws_orig_make_context` | Overrides `ctx.cwd` and `ctx.project_root` from the chat associated with `opts.bufnr`. |
| `codecompanion.interactions.chat.sessions.serializer` | `to_session(chat, opts)` | `_cc_ws_orig_to_session` | Persists `res.meta.cwd = chat_cwd` in serialized session payloads. |
| `codecompanion._extensions.history.storage` | `save_chat(self, chat)` | `_cc_ws_orig_save_chat` | Blocks writes to default `stdpath("data")/codecompanion-history` when `state.projects_file` or unpinned `chat_cwd` is an ephemeral temp path. |
| `codecompanion._extensions.history.ui` | `_handle_on_select(_self, save_id)` | `_cc_ws_patched` flag | Routes history picker selection through `state.actions.open_history_chat(save_id, true)` so restored chats open in the proper Workspace pane/CWD. |
| `codecompanion._extensions.history.summary_generator` | `_detect_project_root(self, chat)` | `_cc_ws_orig_detect_project_root` | Resolves summary project root from `chat_cwd` via `projects.detect_safe_project_root(chat_cwd)`. |
