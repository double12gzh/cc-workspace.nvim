local config = require("cc_workspace.config")
local keymaps = require("cc_workspace.keymaps")
local projects = require("cc_workspace.projects")
local render = require("cc_workspace.render")
local state_mod = require("cc_workspace.state")

local state = state_mod.state
local unpack_fn = table.unpack or unpack

local M = {}

local guarded_history_callbacks = setmetatable({}, { __mode = "k" })

---Guard `persisted.nvim` session saves so chat `lcd`s never hijack session filenames or write zombie workspace/chat splits.
function M.patch_persisted_session()
	local ok_p, persisted = pcall(function()
		return package.loaded["persisted"]
	end)
	if not ok_p or type(persisted) ~= "table" then
		return
	end
	local orig_save = persisted._cc_ws_orig_save or persisted._user_ws_orig_save or persisted.save
	if type(orig_save) ~= "function" then
		return
	end
	persisted._cc_ws_orig_save = orig_save
	persisted._cc_ws_patched = true
	persisted.save = function(opts)
		opts = opts or {}
		local ws_open = state.tab ~= nil and vim.api.nvim_tabpage_is_valid(state.tab)
		if opts.auto and #vim.api.nvim_list_tabpages() == 1 and not state_mod.has_real_code_buffers() then
			if
				(ws_open and state_mod.is_current_tab())
				or vim.bo[vim.api.nvim_get_current_buf()].filetype == "codecompanion"
			then
				return
			end
		end

		local was_in_ws = ws_open and state_mod.is_current_tab()
		if ws_open and state.actions.close then
			state.actions.close()
		end

		local restored_lcds = {}
		for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
			local tabnr = vim.api.nvim_tabpage_get_number(tp)
			local tab_cwd = vim.fn.getcwd(-1, tabnr)
			local split_wins, cc_wins = {}, {}
			for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tp)) do
				if state_mod.is_split_win(w) then
					table.insert(split_wins, w)
					if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "codecompanion" then
						table.insert(cc_wins, w)
					end
				end
			end
			if opts.auto then
				local remaining_splits = #split_wins
				for _, w in ipairs(cc_wins) do
					if remaining_splits > 1 then
						pcall(vim.api.nvim_win_hide, w)
						remaining_splits = remaining_splits - 1
					elseif vim.api.nvim_win_is_valid(w) then
						projects.sync_win_lcd(w, tab_cwd)
					end
				end
			else
				for _, w in ipairs(cc_wins) do
					if vim.api.nvim_win_is_valid(w) then
						local prev_dir = projects.get_win_cwd(w)
						if prev_dir and prev_dir ~= tab_cwd then
							table.insert(restored_lcds, { win = w, dir = prev_dir })
							projects.sync_win_lcd(w, tab_cwd)
						end
					end
				end
			end
		end

		local res = orig_save(opts)
		for _, item in ipairs(restored_lcds) do
			if vim.api.nvim_win_is_valid(item.win) then
				projects.sync_win_lcd(item.win, item.dir)
			end
		end
		if not opts.auto and was_in_ws and state.actions.enter then
			vim.schedule(function()
				state.actions.enter(false, { skip_auto_chat = true })
			end)
		end
		return res
	end
end

---Guard `CodeCompanionHistory`'s `CodeCompanionChatCreated` autocmd against races when chats close immediately.
function M.guard_history_chat_created()
	local ok_ac, autocmds = pcall(vim.api.nvim_get_autocmds, {
		group = "CodeCompanionHistory",
		event = "User",
		pattern = "CodeCompanionChatCreated",
	})
	if not ok_ac or type(autocmds) ~= "table" then
		return
	end
	for _, ac in ipairs(autocmds) do
		local cb = ac.callback
		if type(cb) == "function" and not guarded_history_callbacks[cb] then
			local orig_cb = cb
			pcall(vim.api.nvim_del_autocmd, ac.id)
			local wrapped_cb
			wrapped_cb = function(ev)
				vim.schedule(function()
					local chat_mod = package.loaded["codecompanion.interactions.chat"]
					if not chat_mod or not ev.data or not chat_mod.buf_get_chat(ev.data.bufnr) then
						return
					end
					orig_cb(ev)
				end)
			end
			guarded_history_callbacks[wrapped_cb] = true
			vim.api.nvim_create_autocmd("User", {
				group = "CodeCompanionHistory",
				pattern = "CodeCompanionChatCreated",
				callback = wrapped_cb,
			})
			break
		end
	end
end

---Convert a keymap spec into a CodeCompanion `modes` table (or `nil` when disabled).
---@param spec any
---@param default_modes string[]
---@return table|nil
local function to_cc_modes(spec, default_modes)
	if spec == false or spec == nil then
		return nil
	end
	if type(spec) == "table" and not vim.islist(spec) then
		return spec
	end
	local keys = keymaps.normalize_keys(spec)
	if #keys == 0 then
		return nil
	end
	local val = #keys == 1 and keys[1] or keys
	local out = {}
	for _, m in ipairs(default_modes) do
		out[m] = val
	end
	return out
end

---Register workspace-aware default chat keymaps (`q`, `<C-c>`, `}`, `{`) on `codecompanion.config` when loaded.
---@param keymap_opts? boolean|CcWorkspaceChatKeymapsConfig
function M.register_chat_keymaps(keymap_opts)
	if keymap_opts == nil then
		keymap_opts = config.options and config.options.chat_keymaps
	end
	if keymap_opts == false then
		return
	end
	local cc_cfg = package.loaded["codecompanion.config"]
	if type(cc_cfg) ~= "table" then
		return
	end
	local interactions = cc_cfg.interactions or (cc_cfg.config and cc_cfg.config.interactions)
	if type(interactions) ~= "table" or type(interactions.chat) ~= "table" then
		return
	end
	interactions.chat.keymaps = interactions.chat.keymaps or {}
	local km = interactions.chat.keymaps

	if km.send ~= nil and km.submit ~= nil then
		km.submit = nil
	end

	---@type table<string, any>
	local base_chat = (config.options and config.options.keymaps and config.options.keymaps.chat)
		or (config.defaults.keymaps and config.defaults.keymaps.chat)
		or {}
	local eff = vim.deepcopy(base_chat)
	if type(keymap_opts) == "table" then
		for k, v in pairs(keymap_opts) do
			eff[k] = v
		end
	end

	local function set_cc_km(field, spec, default_modes, idx, desc, cb)
		local modes = to_cc_modes(spec, default_modes)
		km[field] = modes and { modes = modes, index = idx, description = desc, callback = cb } or nil
	end

	set_cc_km("stop", eff.stop, { "n" }, 5, "Stop request, or hide/leave chat when idle", function(chat)
		if chat.current_request or chat.tool_orchestrator then
			chat:stop()
			return
		end
		local ws = require("cc_workspace")
		if ws.is_current_tab() then
			ws.focus_sidebar()
		elseif chat.ui and chat.ui:is_visible() then
			chat.ui:hide()
		end
	end)
	set_cc_km("close", eff.close, { "n", "i" }, 4, "Close the chat buffer", function(chat)
		vim.cmd("stopinsert")
		require("cc_workspace").close_chat_safely(chat, false)
	end)
	set_cc_km("next_chat", eff.next_chat, { "n" }, 11, "Open the next chat", function(chat)
		require("cc_workspace").cycle_chat(chat, 1)
	end)
	set_cc_km("previous_chat", eff.previous_chat, { "n" }, 12, "Open the previous chat", function(chat)
		require("cc_workspace").cycle_chat(chat, -1)
	end)
end

---Patch `Chat.new` so every conversation carries an explicit `cwd` and collision-free `save_id`.
local function patch_chat_constructor()
	local ok_chat, chat_mod_init = pcall(require, "codecompanion.interactions.chat")
	if not ok_chat or type(chat_mod_init) ~= "table" then
		return
	end
	local orig_chat_new = chat_mod_init._cc_ws_orig_new or chat_mod_init._user_ws_orig_new or chat_mod_init.new
	if type(orig_chat_new) ~= "function" then
		return
	end
	chat_mod_init._cc_ws_orig_new = orig_chat_new
	chat_mod_init._cc_ws_cwd_patched = true
	chat_mod_init.new = function(args)
		args = type(args) == "table" and args or {}
		if type(args.cwd) ~= "string" or args.cwd == "" then
			args.cwd = projects.normalize_project_path(vim.fn.getcwd()) or projects.get_global_cwd()
		end
		if type(args.save_id) ~= "string" or args.save_id == "" then
			args.save_id = state_mod.next_unique_save_id()
		end
		local chat = orig_chat_new(args)
		if type(chat) == "table" then
			chat.opts = chat.opts or {}
			if type(chat.opts.cwd) ~= "string" or chat.opts.cwd == "" then
				chat.opts.cwd = args.cwd
			end
			if type(chat.opts.save_id) ~= "string" or chat.opts.save_id == "" then
				chat.opts.save_id = args.save_id
			end
		end
		return chat
	end
end

---Patch ACP transport job spawning, RPC cwd fields, and relative filesystem paths to honor `chat.opts.cwd`.
local function patch_acp_cwd()
	local ok_acp, acp_mod = pcall(require, "codecompanion.acp")
	if not ok_acp or type(acp_mod) ~= "table" then
		return
	end
	acp_mod._cc_ws_cwd_patched = true

	local orig_new = acp_mod._cc_ws_orig_new or acp_mod._user_ws_orig_new or acp_mod.new
	if type(orig_new) == "function" then
		acp_mod._cc_ws_orig_new = orig_new
		acp_mod.new = function(args)
			local conn = orig_new(args)
			if conn and conn.methods then
				local orig_job = conn.methods._cc_ws_orig_job or conn.methods._user_ws_orig_job or conn.methods.job
				if type(orig_job) == "function" then
					conn.methods._cc_ws_orig_job = orig_job
					conn.methods.job = function(cmd, opts, on_exit)
						local chat_cwd = projects.get_valid_chat_cwd(conn.chat)
						if chat_cwd and type(opts) == "table" then
							opts = vim.tbl_extend("force", opts, { cwd = chat_cwd })
						end
						return orig_job(cmd, opts, on_exit)
					end
				end
			end
			return conn
		end
	end

	local orig_send_rpc = acp_mod._cc_ws_orig_send_rpc or acp_mod._user_ws_orig_send_rpc or acp_mod.send_rpc_request
	if type(orig_send_rpc) == "function" then
		acp_mod._cc_ws_orig_send_rpc = orig_send_rpc
		acp_mod.send_rpc_request = function(self, method, params)
			if type(params) == "table" and params.cwd ~= nil then
				local chat_cwd = projects.get_valid_chat_cwd(self and self.chat)
				if chat_cwd then
					params = vim.tbl_extend("force", params, { cwd = chat_cwd })
				end
			end
			return orig_send_rpc(self, method, params)
		end
	end

	local function wrap_acp_fs_method(fn_name)
		local orig_key = "_cc_ws_orig_" .. fn_name
		local orig_fs = acp_mod[orig_key] or acp_mod["_user_ws_orig_" .. fn_name] or acp_mod[fn_name]
		if type(orig_fs) ~= "function" then
			return
		end
		acp_mod[orig_key] = orig_fs
		acp_mod[fn_name] = function(self, id, params)
			if
				type(params) == "table"
				and type(params.path) == "string"
				and params.path ~= ""
				and not params.path:match("^/")
				and not params.path:match("^%a:[/\\]")
			then
				local chat_cwd = projects.get_valid_chat_cwd(self and self.chat)
				if chat_cwd then
					params = vim.tbl_extend("force", params, { path = vim.fs.joinpath(chat_cwd, params.path) })
				end
			end
			return orig_fs(self, id, params)
		end
	end

	wrap_acp_fs_method("handle_fs_read_text_file_request")
	wrap_acp_fs_method("handle_fs_write_file_request")
end

---Patch HTTP tool runner and orchestrator callbacks to execute under `chat.opts.cwd`.
local function patch_tool_runtime_cwd()
	local ok_runner, runner_mod = pcall(require, "codecompanion.interactions.chat.tools.runtime.runner")
	if ok_runner and type(runner_mod) == "table" then
		local orig_run_tool = runner_mod._cc_ws_orig_run_tool
			or runner_mod._user_ws_orig_run_tool
			or runner_mod.run_tool
		if type(orig_run_tool) == "function" then
			runner_mod._cc_ws_orig_run_tool = orig_run_tool
			runner_mod._cc_ws_cwd_patched = true
			runner_mod.run_tool = function(self, tool_cmd, action, args)
				local chat = self and self.orchestrator and self.orchestrator.tools and self.orchestrator.tools.chat
				return projects.with_temp_cwd(projects.get_valid_chat_cwd(chat), function()
					return orig_run_tool(self, tool_cmd, action, args)
				end)
			end
		end
	end

	local ok_orch, orch_mod = pcall(require, "codecompanion.interactions.chat.tools.orchestrator")
	if ok_orch and type(orch_mod) == "table" then
		orch_mod._cc_ws_cwd_patched = true
		for _, method_name in ipairs({ "setup_next_tool", "finalize_tool", "success", "error" }) do
			local orig_key = "_cc_ws_orig_" .. method_name
			local orig_m = orch_mod[orig_key] or orch_mod["_user_ws_orig_" .. method_name] or orch_mod[method_name]
			if type(orig_m) == "function" then
				orch_mod[orig_key] = orig_m
				orch_mod[method_name] = function(self, ...)
					local chat = self and self.tools and self.tools.chat
					local argv, argc = { ... }, select("#", ...)
					return projects.with_temp_cwd(projects.get_valid_chat_cwd(chat), function()
						return orig_m(self, unpack_fn(argv, 1, argc))
					end)
				end
			end
		end
	end
end

---Patch system prompt context builder and session serializer to reflect `chat.opts.cwd`.
local function patch_prompt_and_session_cwd()
	local ok_sp, sp_mod = pcall(require, "codecompanion.interactions.shared.system_prompt")
	if ok_sp and type(sp_mod) == "table" then
		local orig_make_context = sp_mod._cc_ws_orig_make_context
			or sp_mod._user_ws_orig_make_context
			or sp_mod.make_context
		if type(orig_make_context) == "function" then
			sp_mod._cc_ws_orig_make_context = orig_make_context
			sp_mod._cc_ws_cwd_patched = true
			sp_mod.make_context = function(opts)
				local ctx = orig_make_context(opts)
				local bufnr = type(opts) == "table" and opts.bufnr or nil
				if bufnr then
					local chat_mod = package.loaded["codecompanion.interactions.chat"]
					local chat = chat_mod and chat_mod.buf_get_chat(bufnr) or nil
					local chat_cwd = projects.get_valid_chat_cwd(chat)
					if chat_cwd and type(ctx) == "table" then
						ctx.cwd = chat_cwd
						ctx.project_root = vim.fs.root(chat_cwd, { ".git", ".svn", ".hg" }) or chat_cwd
					end
				end
				return ctx
			end
		end
	end

	local ok_ser, ser_mod = pcall(require, "codecompanion.interactions.chat.sessions.serializer")
	if ok_ser and type(ser_mod) == "table" then
		local orig_to_session = ser_mod._cc_ws_orig_to_session or ser_mod._user_ws_orig_to_session or ser_mod.to_session
		if type(orig_to_session) == "function" then
			ser_mod._cc_ws_orig_to_session = orig_to_session
			ser_mod._cc_ws_cwd_patched = true
			ser_mod.to_session = function(chat, opts)
				local res = orig_to_session(chat, opts or {})
				local chat_cwd = projects.get_valid_chat_cwd(chat)
				if chat_cwd and type(res) == "table" and type(res.meta) == "table" then
					res.meta.cwd = chat_cwd
				end
				return res
			end
		end
	end
end

---Guard `codecompanion-history` storage so ephemeral `/tmp` test chats never pollute user history.
local function patch_history_storage_tmp_guard()
	local ok_storage, storage_mod = pcall(require, "codecompanion._extensions.history.storage")
	if not ok_storage or type(storage_mod) ~= "table" then
		return
	end
	local orig_save_chat = storage_mod._cc_ws_orig_save_chat
		or storage_mod._user_ws_orig_save_chat
		or storage_mod.save_chat
	if type(orig_save_chat) ~= "function" then
		return
	end
	storage_mod._cc_ws_orig_save_chat = orig_save_chat
	storage_mod._cc_ws_tmp_guarded = true
	local default_hist = vim.fs.normalize(vim.fn.stdpath("data") .. "/codecompanion-history"):gsub("/+$", "")
	storage_mod.save_chat = function(self, chat)
		local target_chat = chat
		if not target_chat then
			local cc_mod = package.loaded["codecompanion"]
			target_chat = (cc_mod and type(cc_mod.last_chat) == "function") and cc_mod.last_chat() or nil
		end
		local loc = (type(self) == "table" and type(self.base_path) == "string")
				and vim.fs.normalize(self.base_path):gsub("/+$", "")
			or ""
		if loc == default_hist then
			if type(state.projects_file) == "string" and state_mod.is_ephemeral_tmp_path(state.projects_file) then
				return
			end
			if type(target_chat) == "table" then
				local raw_cwd = (type(target_chat.opts) == "table" and target_chat.opts.cwd) or target_chat.cwd
				local norm_cwd = projects.normalize_project_path(raw_cwd) or raw_cwd
				if state_mod.is_ephemeral_tmp_path(raw_cwd) or state_mod.is_ephemeral_tmp_path(norm_cwd) then
					local pinned_map = projects.get_pinned_map()
					local proj_path = projects.get_chat_project_path(target_chat, pinned_map)
					if not pinned_map[proj_path] and not (norm_cwd and pinned_map[norm_cwd]) then
						return
					end
				end
			end
		end
		return orig_save_chat(self, chat)
	end
end

---Patch CodeCompanion Chat.new, ACP, HTTP tools, system prompt, and session serializer to honor per-chat `chat.opts.cwd`.
function M.patch_codecompanion_cwd()
	M.setup_autocmds()
	M.patch_persisted_session()
	projects.warm_zoxide_cache()
	local wt = state_mod.get_wt()
	if wt and type(wt.setup) == "function" then
		pcall(wt.setup)
	end
	M.register_chat_keymaps()

	if package.loaded["codecompanion"] then
		patch_chat_constructor()
		patch_acp_cwd()
		patch_tool_runtime_cwd()
		patch_prompt_and_session_cwd()
		patch_history_storage_tmp_guard()
		M.guard_history_chat_created()
	end
end

---Patch `codecompanion-history` picker selection and summary root detection so per-chat Projects work cleanly.
function M.patch_history_ui()
	M.patch_codecompanion_cwd()
	if not package.loaded["codecompanion"] then
		return
	end
	local ok_ui, hist_ui = pcall(require, "codecompanion._extensions.history.ui")
	if ok_ui and type(hist_ui) == "table" then
		hist_ui._cc_ws_patched = true
		hist_ui._handle_on_select = function(_self, save_id)
			if save_id and state.actions.open_history_chat then
				state.actions.open_history_chat(save_id, true)
			end
		end
	end
	local ok_sg, sg_mod = pcall(require, "codecompanion._extensions.history.summary_generator")
	if ok_sg and type(sg_mod) == "table" then
		local orig_detect = sg_mod._cc_ws_orig_detect_project_root
			or sg_mod._user_ws_orig_detect_project_root
			or sg_mod._detect_project_root
		if type(orig_detect) == "function" then
			sg_mod._cc_ws_orig_detect_project_root = orig_detect
			sg_mod._cc_ws_cwd_patched = true
			sg_mod._detect_project_root = function(self, chat)
				local chat_cwd = projects.get_valid_chat_cwd(chat)
				if chat_cwd then
					return projects.detect_safe_project_root(chat_cwd) or chat_cwd
				end
				return orig_detect(self, chat)
			end
		end
	end
	M.guard_history_chat_created()
end

---Handle `User` autocmd events from CodeCompanion and Persisted.
---@param args table
local function on_cc_user_event(args)
	if args.match == "PersistedStart" then
		M.patch_persisted_session()
		return
	end
	if
		args.match == "CodeCompanionHistoryTitleSet"
		or args.match == "CodeCompanionHistoryTitleRenamed"
		or args.match == "CodeCompanionChatClosed"
		or args.match == "CodeCompanionRequestFinished"
	then
		state_mod.invalidate_history_cache()
	end
	if args.match == "CodeCompanionChatCreated" then
		M.register_chat_keymaps()
		M.guard_history_chat_created()
		local bufnr = type(args.data) == "table" and args.data.bufnr or nil
		local chat_mod = package.loaded["codecompanion.interactions.chat"]
		local chat = (bufnr and chat_mod) and chat_mod.buf_get_chat(bufnr) or nil
		if chat then
			chat.opts = chat.opts or {}
			if type(chat.opts.cwd) ~= "string" or chat.opts.cwd == "" then
				chat.opts.cwd = projects.normalize_project_path(vim.fn.getcwd()) or projects.get_global_cwd()
			end
			if type(chat.opts.save_id) ~= "string" or chat.opts.save_id == "" then
				chat.opts.save_id = state_mod.next_unique_save_id()
			end
		end
		if bufnr then
			vim.schedule(function()
				keymaps.apply_chat_buf_keymaps(bufnr)
			end)
		end
	end
	if state_mod.is_workspace_valid() and state_mod.is_current_tab() then
		if args.match == "CodeCompanionRequestStreaming" then
			if not state.timer and (state_mod.now_ms() - (state.last_render_ms or 0)) >= 220 then
				render.schedule_render()
			end
		else
			render.schedule_render()
		end
	end
end

---Scheduled layout repair and `main_win` `lcd` synchronization when entering or resizing the workspace tab.
local function sync_workspace_on_enter_tick()
	state.layout_sync_scheduled = false
	if state.in_layout_repair then
		return
	end
	if not state_mod.is_current_tab() then
		if state.actions.sync_sidebar_width then
			state.actions.sync_sidebar_width()
		end
		return
	end
	if not state_mod.is_workspace_valid() then
		if state.actions.ensure_workspace_layout then
			state.actions.ensure_workspace_layout()
		end
	elseif state.actions.configure_sidebar_win then
		state.actions.configure_sidebar_win()
	end
	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	if chat_mod and state.main_win and vim.api.nvim_win_is_valid(state.main_win) then
		local c = chat_mod.buf_get_chat(vim.api.nvim_win_get_buf(state.main_win))
		if c then
			if c.ui then
				c.ui.winnr = state.main_win
			end
			projects.sync_win_lcd(state.main_win, projects.get_valid_chat_cwd(c))
		end
	end
	render.render()
end

---Handle `TabEnter`, `WinEnter`, `BufWinEnter`, and `VimResized` events for the workspace tab.
---@param args? table
local function on_layout_or_resize_event(args)
	if state.in_layout_repair then
		return
	end
	local is_resize = type(args) == "table" and args.event == "VimResized"
	if not state_mod.is_current_tab() then
		state_mod.stop_timer()
		if is_resize and state.actions.sync_sidebar_width then
			state.actions.sync_sidebar_width()
			vim.schedule(function()
				if state.actions.sync_sidebar_width then
					state.actions.sync_sidebar_width()
				end
			end)
		end
		return
	end
	if is_resize and state.actions.sync_sidebar_width then
		state.actions.sync_sidebar_width()
	end
	if state.layout_sync_scheduled then
		return
	end
	state.layout_sync_scheduled = true
	vim.schedule(sync_workspace_on_enter_tick)
end

---Check whether an active chat buffer has an in-flight turn that should be snapshotted on `VimLeavePre`.
---@param c table
---@param pinned_map table<string, table>
---@param wt table|nil
---@return boolean
local function should_snapshot_inflight_chat(c, pinned_map, wt)
	if not c or not vim.api.nvim_buf_is_valid(c.bufnr) then
		return false
	end
	local raw_cwd = (type(c.opts) == "table" and c.opts.cwd) or c.cwd
	local norm_cwd = projects.get_valid_chat_cwd(c) or projects.normalize_project_path(raw_cwd) or raw_cwd
	local proj_path = projects.get_chat_project_path(c, pinned_map)
	if
		(
			state_mod.is_ephemeral_tmp_path(raw_cwd)
			or state_mod.is_ephemeral_tmp_path(norm_cwd)
			or state_mod.is_ephemeral_tmp_path(proj_path)
		)
		and not pinned_map[proj_path]
		and not (norm_cwd and pinned_map[norm_cwd])
	then
		return false
	end
	local st = state_mod.get_chat_status_info(c.bufnr, false)
	local has_req = wt and type(wt.has_active_request) == "function" and wt.has_active_request(c.bufnr) or false
	local in_flight = c.current_request ~= nil
		or has_req
		or st.state == "thinking"
		or st.state == "streaming"
		or st.state == "waiting"
	if not in_flight or type(c.messages) ~= "table" then
		return false
	end
	for _, m in ipairs(c.messages) do
		if type(m) == "table" and m.role and m.role ~= "system" then
			return true
		end
	end
	return false
end

---Snapshot any non-ephemeral in-flight chats into `codecompanion-history` before Neovim exits.
local function snapshot_inflight_chats_on_exit()
	if type(state.projects_file) == "string" and state_mod.is_ephemeral_tmp_path(state.projects_file) then
		return
	end
	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	local cc = package.loaded["codecompanion"]
	local save_fn = cc and cc.extensions and cc.extensions.history and cc.extensions.history.save_chat
	if not chat_mod or type(save_fn) ~= "function" then
		return
	end
	local all = chat_mod.buf_get_chat()
	if type(all) ~= "table" then
		return
	end
	local pinned_map = projects.get_pinned_map()
	local wt = state_mod.get_wt()
	for _, entry in ipairs(all) do
		local c = entry and entry.chat
		if should_snapshot_inflight_chat(c, pinned_map, wt) then
			pcall(function()
				projects.with_temp_cwd(projects.get_valid_chat_cwd(c), function()
					save_fn(c)
				end)
			end)
		end
	end
end

---Register autocmds that keep the workspace sidebar synchronized with live chat activity.
function M.setup_autocmds()
	local group = vim.api.nvim_create_augroup("CcWorkspaceAutocmds", { clear = true })
	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = {
			"PersistedStart",
			"CodeCompanionRequestStarted",
			"CodeCompanionRequestStreaming",
			"CodeCompanionRequestFinished",
			"CodeCompanionChatCreated",
			"CodeCompanionChatOpened",
			"CodeCompanionChatSubmitted",
			"CodeCompanionChatStopped",
			"CodeCompanionChatCleared",
			"CodeCompanionChatClosed",
			"CodeCompanionChatTitle",
			"CodeCompanionTool*",
			"CodeCompanionHistoryTitleSet",
			"CodeCompanionHistoryTitleRenamed",
		},
		callback = on_cc_user_event,
	})
	vim.api.nvim_create_autocmd({ "TabEnter", "WinEnter", "BufWinEnter", "VimResized" }, {
		group = group,
		callback = on_layout_or_resize_event,
	})
	vim.api.nvim_create_autocmd("OptionSet", {
		group = group,
		pattern = "showtabline",
		callback = function()
			if state_mod.is_workspace_valid() and state_mod.is_current_tab() then
				render.schedule_render()
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		callback = function(args)
			if
				state_mod.is_workspace_valid()
				and state_mod.is_current_tab()
				and vim.bo[args.buf].filetype == "codecompanion"
			then
				render.schedule_render()
			end
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = snapshot_inflight_chats_on_exit,
	})
end

return M
