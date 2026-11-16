local icons = require("cc_workspace.icons")
local patches = require("cc_workspace.patches")
local projects = require("cc_workspace.projects")
local render = require("cc_workspace.render")
local state_mod = require("cc_workspace.state")

local state = state_mod.state

local M = {}

---Build `buffer_context` scoped to `target_cwd` without leaking files from unrelated projects.
---@param target_cwd? string
---@return table
local function resolve_buffer_context(target_cwd)
	local ctx_mod = require("codecompanion.utils.context")
	return projects.with_temp_cwd(target_cwd, function()
		if
			state.prev_code_buf
			and vim.api.nvim_buf_is_valid(state.prev_code_buf)
			and projects.buf_within_dir(state.prev_code_buf, target_cwd)
		then
			return ctx_mod.get(state.prev_code_buf)
		end
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			if
				vim.api.nvim_buf_is_loaded(buf)
				and vim.bo[buf].buftype == ""
				and vim.bo[buf].filetype ~= ""
				and projects.buf_within_dir(buf, target_cwd)
			then
				return ctx_mod.get(buf)
			end
		end
		local base =
			ctx_mod.get(state.sidebar_buf and vim.api.nvim_buf_is_valid(state.sidebar_buf) and state.sidebar_buf or 0)
		if target_cwd and target_cwd ~= "" then
			base.buftype = ""
			base.code = false
			base.filetype = ""
			base.filename = ""
			base.is_visual = false
			base.is_normal = true
			base.lines = {}
			base.line_count = 0
			base.path = ""
			base.relative_path = ""
		end
		return base
	end)
end

---Create or return a read-only welcome placeholder buffer for `main_win` when no active chats exist.
---@return integer
local function get_empty_main_buf()
	if state.empty_buf and vim.api.nvim_buf_is_valid(state.empty_buf) then
		return state.empty_buf
	end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].buflisted = false
	vim.bo[buf].undolevels = -1
	local aichat_icons = icons.get("aichat", true)
	local lines = {
		"",
		"",
		string.format("    %sNo active conversation selected", aichat_icons.Chat),
		"",
		"    • Press [n] in the sidebar (or <leader>cn) to start a new conversation",
		"    • Press [a] in the sidebar to add Project(s) (<Tab> multi-select + <CR>)",
		"    • Press [w] in the sidebar to create a Git Worktree & start an Agent Chat",
		"    • Press [u] in the sidebar to jump to the next unread / attention chat",
		"    • Press [Enter] on any item under PROJECTS to open or restore it",
		"    • Press [f] to filter conversations, [s] for full-text history search",
		"    • Press [q] (or <leader>cw) to jump back to your code tab",
	}
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.keymap.set("n", "n", function()
		M.new_chat(true)
	end, { buffer = buf, nowait = true, silent = true })
	vim.keymap.set("n", "a", function()
		if state.actions.prompt_add_project then
			state.actions.prompt_add_project()
		end
	end, { buffer = buf, nowait = true, silent = true })
	vim.keymap.set("n", "w", function()
		if state.actions.prompt_create_worktree_chat then
			state.actions.prompt_create_worktree_chat()
		end
	end, { buffer = buf, nowait = true, silent = true })
	vim.keymap.set("n", "u", function()
		local wt = state_mod.get_wt()
		if wt and type(wt.jump_to_attention) == "function" then
			wt.jump_to_attention()
		end
	end, { buffer = buf, nowait = true, silent = true })
	vim.keymap.set("n", "q", function()
		M.focus_sidebar()
	end, { buffer = buf, nowait = true, silent = true })
	state.empty_buf = buf
	return buf
end

---Apply fixed layout options to the sidebar window without redundant option/resize triggers.
function M.configure_sidebar_win()
	if not state.sidebar_win or not vim.api.nvim_win_is_valid(state.sidebar_win) then
		return
	end
	local target_w = state_mod.get_sidebar_width()
	if vim.api.nvim_win_get_width(state.sidebar_win) ~= target_w then
		pcall(vim.api.nvim_win_set_width, state.sidebar_win, target_w)
	end
	local wo = vim.wo[state.sidebar_win]
	local win_opts = {
		number = false,
		relativenumber = false,
		signcolumn = "no",
		foldcolumn = "0",
		wrap = false,
		cursorline = true,
		winfixwidth = true,
		winfixbuf = true,
		spell = false,
		list = false,
		winbar = "",
	}
	for k, v in pairs(win_opts) do
		local ok_cur, cur_v = pcall(function()
			return wo[k]
		end)
		if not ok_cur or cur_v ~= v then
			pcall(vim.api.nvim_set_option_value, k, v, { win = state.sidebar_win })
		end
	end
end

---Keep sidebar width synced after global resize events even when workspace is in a background tab.
function M.sync_sidebar_width()
	if state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
		local target_w = state_mod.get_sidebar_width()
		if vim.api.nvim_win_get_width(state.sidebar_win) ~= target_w then
			pcall(vim.api.nvim_win_set_width, state.sidebar_win, target_w)
		end
	end
end

---Tag the workspace tabpage so bufferline renders a named clickable tab pill.
local function label_workspace_tab()
	if not state.tab or not vim.api.nvim_tabpage_is_valid(state.tab) then
		return
	end
	local aichat_icons = icons.get("aichat", true)
	pcall(vim.api.nvim_tabpage_set_var, state.tab, "name", aichat_icons.Chat .. "AI")
	if #vim.api.nvim_list_tabpages() > 1 then
		if not package.loaded["bufferline"] then
			pcall(require, "bufferline")
		end
		if vim.o.showtabline == 0 then
			vim.o.showtabline = 2
		end
	end
end

---Find an existing valid chat buffer to populate a freshly repaired `main_win`.
---@return table|nil
local function find_fallback_chat()
	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	if not chat_mod then
		return nil
	end
	local fallback_chat = chat_mod.last_chat()
	if fallback_chat and vim.api.nvim_buf_is_valid(fallback_chat.bufnr) then
		return fallback_chat
	end
	local all = chat_mod.buf_get_chat()
	if type(all) == "table" then
		for _, entry in ipairs(all) do
			if entry.chat and vim.api.nvim_buf_is_valid(entry.chat.bufnr) then
				return entry.chat
			end
		end
	end
	return nil
end

---Repair or recreate the left sidebar + right main pane inside `state.tab` without leaving `sidebar_win` missing.
---@return boolean
function M.ensure_workspace_layout()
	if state.in_layout_repair then
		return state_mod.is_workspace_valid()
	end
	if not state.tab or not vim.api.nvim_tabpage_is_valid(state.tab) then
		return false
	end
	state.in_layout_repair = true
	local ok_repair, res = pcall(function()
		vim.api.nvim_set_current_tabpage(state.tab)
		label_workspace_tab()

		if not state.sidebar_buf or not vim.api.nvim_buf_is_valid(state.sidebar_buf) then
			local buf = vim.api.nvim_create_buf(false, true)
			vim.bo[buf].filetype = "cc-workspace"
			vim.bo[buf].buftype = "nofile"
			vim.bo[buf].bufhidden = "hide"
			vim.bo[buf].swapfile = false
			vim.bo[buf].buflisted = false
			vim.bo[buf].undolevels = -1
			vim.bo[buf].modifiable = false
			state.sidebar_buf = buf
		end
		if state.actions.setup_sidebar_buf and state.sidebar_buf_ready ~= state.sidebar_buf then
			state.actions.setup_sidebar_buf(state.sidebar_buf)
		end

		-- Locate existing valid main_win (prefer an existing non-floating codecompanion window in this tab)
		if
			not state.main_win
			or not state_mod.is_split_win(state.main_win)
			or vim.api.nvim_win_get_tabpage(state.main_win) ~= state.tab
		then
			state.main_win = nil
			for _, w in ipairs(vim.api.nvim_tabpage_list_wins(state.tab)) do
				if state_mod.is_split_win(w) then
					local b = vim.api.nvim_win_get_buf(w)
					if b ~= state.sidebar_buf and vim.bo[b].filetype == "codecompanion" then
						state.main_win = w
						break
					end
				end
			end
			if not state.main_win then
				for _, w in ipairs(vim.api.nvim_tabpage_list_wins(state.tab)) do
					if state_mod.is_split_win(w) and vim.api.nvim_win_get_buf(w) ~= state.sidebar_buf then
						state.main_win = w
						break
					end
				end
			end
		end

		-- Ensure sidebar_win exists on the far left with state.sidebar_buf
		local sb_ok = state.sidebar_win
			and vim.api.nvim_win_is_valid(state.sidebar_win)
			and vim.api.nvim_win_get_tabpage(state.sidebar_win) == state.tab
			and state.sidebar_win ~= state.main_win
		if not sb_ok then
			vim.cmd("topleft vsplit")
			state.sidebar_win = vim.api.nvim_get_current_win()
		end
		if vim.api.nvim_win_get_buf(state.sidebar_win) ~= state.sidebar_buf then
			pcall(vim.api.nvim_set_option_value, "winfixbuf", false, { win = state.sidebar_win })
			vim.api.nvim_win_set_buf(state.sidebar_win, state.sidebar_buf)
		end
		M.configure_sidebar_win()

		if
			not state.main_win
			or not vim.api.nvim_win_is_valid(state.main_win)
			or state.main_win == state.sidebar_win
		then
			vim.api.nvim_set_current_win(state.sidebar_win)
			vim.cmd("rightbelow vsplit")
			state.main_win = vim.api.nvim_get_current_win()
			local fallback_chat = find_fallback_chat()
			if fallback_chat and fallback_chat.ui and vim.api.nvim_buf_is_valid(fallback_chat.bufnr) then
				fallback_chat.hidden = false
				fallback_chat.ui:show_in_win({
					winnr = state.main_win,
					window_opts = { default = true },
				})
				projects.sync_win_lcd(state.main_win, projects.get_valid_chat_cwd(fallback_chat))
			else
				vim.api.nvim_win_set_buf(state.main_win, get_empty_main_buf())
				projects.sync_win_lcd(state.main_win, nil)
			end
			M.configure_sidebar_win()
		end

		return true
	end)
	state.in_layout_repair = false
	if not ok_repair then
		error(res)
	end
	return res
end

---Move cursor focus into the left workspace sidebar (always in Normal mode).
function M.focus_sidebar()
	if not state_mod.is_workspace_valid() then
		M.ensure_workspace_layout()
	end
	if state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
		vim.api.nvim_set_current_win(state.sidebar_win)
		vim.cmd("stopinsert")
	end
end

---Display an existing Chat inside `main_win` without poisoning `chat.ui.window_opts`.
---@param chat table
---@param focus_main? boolean
function M.show_chat(chat, focus_main)
	if not state_mod.is_workspace_valid() then
		M.ensure_workspace_layout()
	end
	if not state_mod.is_workspace_valid() or not chat or not vim.api.nvim_buf_is_valid(chat.bufnr) then
		return
	end
	local chat_cwd = projects.get_valid_chat_cwd(chat)
	if chat_cwd then
		state.last_selected_project = chat_cwd
	end
	chat.hidden = false
	if chat.ui and type(chat.ui.show_in_win) == "function" then
		chat.ui:show_in_win({
			winnr = state.main_win,
			window_opts = { default = true },
		})
	else
		vim.api.nvim_win_set_buf(state.main_win, chat.bufnr)
	end
	projects.sync_win_lcd(state.main_win, chat_cwd)
	M.configure_sidebar_win()
	if focus_main then
		vim.api.nvim_set_current_win(state.main_win)
	elseif vim.api.nvim_win_is_valid(state.sidebar_win) then
		vim.api.nvim_set_current_win(state.sidebar_win)
		vim.cmd("stopinsert")
	end
	if state_mod.is_current_tab() then
		local wt = state_mod.get_wt()
		if wt and type(wt.mark_read) == "function" then
			pcall(wt.mark_read, chat.bufnr)
		end
	end
	render.render()
	state_mod.refresh_winbars()
end

---Resolve target working directory for a new workspace conversation.
---@param explicit_project_path? string
---@return string
local function resolve_new_chat_cwd(explicit_project_path)
	if type(explicit_project_path) == "string" and explicit_project_path ~= "" then
		local norm = projects.normalize_project_path(explicit_project_path)
		if norm then
			if vim.fn.isdirectory(norm) == 1 then
				return norm
			end
			vim.notify(
				string.format("Project directory missing on disk (%s); using current directory", norm),
				vim.log.levels.WARN,
				{ title = "AI Workspace" }
			)
			return projects.get_global_cwd()
		end
	end

	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	if chat_mod and state.main_win and vim.api.nvim_win_is_valid(state.main_win) then
		local mbuf = vim.api.nvim_win_get_buf(state.main_win)
		local cur_chat = chat_mod.buf_get_chat(mbuf)
		local cur_cwd = projects.get_valid_chat_cwd(cur_chat)
		if cur_cwd then
			return cur_cwd
		end
	end

	if
		type(state.last_selected_project) == "string"
		and state.last_selected_project ~= ""
		and vim.fn.isdirectory(state.last_selected_project) == 1
	then
		return state.last_selected_project
	end

	return projects.get_global_cwd()
end

---Create a new CodeCompanion Chat inside `main_win` without disturbing `sidebar_win`.
---@param focus_main? boolean
---@param project_path? string
---@param chat_opts? { skip_show?: boolean }
---@return table|nil
function M.new_chat(focus_main, project_path, chat_opts)
	chat_opts = type(chat_opts) == "table" and chat_opts or {}
	if not state_mod.is_workspace_valid() then
		M.ensure_workspace_layout()
	end
	if not state_mod.is_workspace_valid() then
		return nil
	end
	require("codecompanion")
	patches.patch_codecompanion_cwd()
	local chat_mod = require("codecompanion.interactions.chat")
	local target_cwd = resolve_new_chat_cwd(project_path)
	state.last_selected_project = target_cwd
	local chat = projects.with_temp_cwd(target_cwd, function()
		local ctx = resolve_buffer_context(target_cwd)
		local rules_cb = nil
		pcall(function()
			rules_cb =
				require("codecompanion.interactions.shared.rules.helpers").add_callbacks({ buffer_context = ctx })
		end)
		return chat_mod.new({
			hidden = true,
			cwd = target_cwd,
			buffer_context = ctx,
			callbacks = rules_cb,
		})
	end)
	if chat then
		chat.opts = chat.opts or {}
		chat.opts.cwd = target_cwd
		local proj_root = projects.get_chat_project_path(chat)
		if proj_root and proj_root ~= "" and proj_root ~= "Other" then
			state.collapsed_projects[proj_root] = false
		end
		local wt = state_mod.get_wt()
		local wt_root = (wt and target_cwd and type(wt.get_worktree_root) == "function")
				and projects.normalize_project_path(wt.get_worktree_root(target_cwd))
			or target_cwd
		if wt_root and wt_root ~= "" then
			state.collapsed_worktrees[wt_root] = false
		end
		if not chat_opts.skip_show then
			M.show_chat(chat, focus_main)
		end
	end
	return chat
end

---Validate saved history adapter and model settings against currently registered CodeCompanion adapters.
---@param data table
---@return any adapter, table|nil settings
local function resolve_saved_adapter_and_settings(data)
	local adapter = data.adapter
	local settings = type(data.settings) == "table" and vim.deepcopy(data.settings) or nil
	if not adapter then
		return nil, nil
	end
	local ok_res, resolved = pcall(require("codecompanion.adapters").resolve, adapter)
	if not ok_res or not resolved then
		vim.notify(
			string.format("Saved adapter '%s' unavailable; using default adapter", tostring(adapter)),
			vim.log.levels.WARN,
			{ title = "AI Workspace" }
		)
		return nil, nil
	end
	if resolved.type == "acp" then
		return adapter, nil
	end
	if settings and settings.model and resolved.schema and resolved.schema.model then
		local choices = resolved.schema.model.choices
		if type(choices) == "table" then
			local valid_models = {}
			for k, v in pairs(choices) do
				table.insert(valid_models, type(k) == "string" and k or v)
			end
			if #valid_models > 0 and not vim.tbl_contains(valid_models, settings.model) then
				vim.notify(
					string.format(
						"Saved model '%s' unavailable in '%s'; using default",
						tostring(settings.model),
						tostring(adapter)
					),
					vim.log.levels.WARN,
					{ title = "AI Workspace" }
				)
				settings = nil
			end
		end
	end
	return adapter, settings
end

---Re-attach stored `context_items` / `refs` onto a restored history chat under `effective_cwd`.
---@param chat table
---@param data table
---@param effective_cwd string
local function restore_saved_chat_context(chat, data, effective_cwd)
	local stored_ctx = data.context_items or data.refs or {}
	if not chat.context or type(stored_ctx) ~= "table" or #stored_ctx == 0 then
		return
	end
	projects.with_temp_cwd(effective_cwd, function()
		local existing_items = chat.context_items or {}
		for _, item in ipairs(stored_ctx) do
			local dup = vim.tbl_contains(existing_items, function(ci)
				return ci.id == item.id
			end, { predicate = true })
			if not dup then
				pcall(function()
					chat.context:add(item)
				end)
			end
		end
	end)
end

---Restore a saved history entry by `save_id` into the workspace `main_win` or current tab's chat split.
---@param save_id string
---@param focus_main? boolean
---@return table|nil
function M.open_history_chat(save_id, focus_main)
	if focus_main == nil then
		focus_main = true
	end
	local in_ws = state_mod.is_current_tab()
	if in_ws then
		if not state_mod.is_workspace_valid() then
			M.ensure_workspace_layout()
		end
		if not state_mod.is_workspace_valid() then
			return nil
		end
	end

	---@type any
	local cc = require("codecompanion")
	patches.patch_codecompanion_cwd()
	local chat_mod = require("codecompanion.interactions.chat")
	local all = chat_mod.buf_get_chat()
	if type(all) == "table" then
		for _, entry in ipairs(all) do
			if entry.chat and entry.chat.opts and entry.chat.opts.save_id == save_id then
				if in_ws then
					M.show_chat(entry.chat, focus_main)
				else
					M.focus_or_open_chat(entry.chat)
				end
				return entry.chat
			end
		end
	end

	local history = cc.extensions and cc.extensions.history
	if not history or not history.load_chat then
		vim.notify("codecompanion-history extension not loaded", vim.log.levels.WARN, { title = "AI Workspace" })
		return nil
	end

	local data = history.load_chat(save_id)
	if not data then
		vim.notify("Failed to load chat: " .. save_id, vim.log.levels.ERROR, { title = "AI Workspace" })
		return nil
	end

	local messages = data.messages or {}
	local last_msg = messages[#messages]
	if last_msg and (last_msg.role ~= "user" or (last_msg.opts or {}).visible == false) then
		table.insert(messages, {
			role = "user",
			content = "",
			opts = { visible = true },
		})
	end

	local adapter, settings = resolve_saved_adapter_and_settings(data)
	local raw_saved_cwd = projects.normalize_project_path(data.cwd)
		or projects.normalize_project_path(data.project_root)
	local effective_cwd = projects.get_global_cwd()
	if raw_saved_cwd then
		if vim.fn.isdirectory(raw_saved_cwd) == 1 then
			effective_cwd = raw_saved_cwd
		else
			vim.notify(
				string.format("Saved project directory missing on disk (%s); using current directory", raw_saved_cwd),
				vim.log.levels.WARN,
				{ title = "AI Workspace" }
			)
		end
	end
	local saved_cwd_field = raw_saved_cwd or data.cwd or effective_cwd

	local chat = projects.with_temp_cwd(effective_cwd, function()
		local ctx = resolve_buffer_context(effective_cwd)
		return chat_mod.new({
			hidden = true,
			save_id = data.save_id,
			cwd = saved_cwd_field,
			messages = messages,
			buffer_context = ctx,
			settings = settings,
			adapter = adapter,
			title = data.title,
		})
	end)
	if chat then
		restore_saved_chat_context(chat, data, effective_cwd)
		if type(chat.tool_registry) == "table" then
			if type(data.schemas) == "table" then
				chat.tool_registry.schemas = data.schemas
			end
			if type(data.in_use) == "table" then
				chat.tool_registry.in_use = data.in_use
			end
		end
		chat.cycle = data.cycle or 1
		chat.opts = chat.opts or {}
		chat.opts.title_refresh_count = data.title_refresh_count or 0
		chat.opts.cwd = saved_cwd_field
		if in_ws then
			M.show_chat(chat, focus_main)
		else
			M.focus_or_open_chat(chat)
		end
	end
	return chat
end

---Switch to AI Workspace, expand `project_path`, and open/reuse a conversation for it in `main_win`.
---@param project_path string|nil
---@param focus_main? boolean
---@return table|nil
function M.activate_project(project_path, focus_main)
	if focus_main == nil then
		focus_main = true
	end
	local norm = projects.normalize_project_path(project_path)
	if not norm or vim.fn.isdirectory(norm) ~= 1 then
		return nil
	end
	if not state_mod.is_current_tab() or not state_mod.is_workspace_valid() then
		M.enter(focus_main, { skip_auto_chat = true })
	end
	local wt = state_mod.get_wt()
	local repo_root = (wt and type(wt.get_repo_root) == "function") and wt.get_repo_root(norm) or nil
	if repo_root then
		local norm_repo = projects.normalize_project_path(repo_root) or repo_root
		state.collapsed_projects[norm_repo] = false
		if norm_repo ~= norm then
			state.collapsed_worktrees[norm] = false
			state.focus_worktree_path = norm
		else
			state.focus_project_path = norm_repo
		end
	else
		state.collapsed_projects[norm] = false
		state.focus_project_path = norm
	end
	state.last_selected_project = norm

	local matched = projects.find_active_chat_for_project(norm)
	if matched then
		M.show_chat(matched, focus_main)
		return matched
	end
	return M.new_chat(focus_main, norm)
end

---Open or focus a normal code tab rooted (`tcd`) at `project_path` (without leaking `[No Name]` buffers).
---@param project_path string
function M.open_project_in_code_tab(project_path)
	local norm = projects.normalize_project_path(project_path)
	if not norm or vim.fn.isdirectory(norm) ~= 1 then
		vim.notify(
			"Project directory not found: " .. tostring(project_path),
			vim.log.levels.WARN,
			{ title = "AI Workspace" }
		)
		return
	end
	state_mod.stop_timer()
	for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
		if tp ~= state.tab and vim.api.nvim_tabpage_is_valid(tp) then
			local tp_nr = vim.api.nvim_tabpage_get_number(tp)
			local tp_cwd = projects.normalize_project_path(vim.fn.getcwd(-1, tp_nr))
			if tp_cwd == norm then
				state.prev_tab = tp
				vim.api.nvim_set_current_tabpage(tp)
				return
			end
		end
	end
	-- Switch to sidebar_win before `:tabnew` if in `main_win` so the new tab doesn't inherit `main_win`'s `lcd`
	if state_mod.is_current_tab() and state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
		pcall(vim.api.nvim_set_current_win, state.sidebar_win)
	end
	vim.cmd("tabnew")
	local new_tab = vim.api.nvim_get_current_tabpage()
	local scratch_buf = vim.api.nvim_get_current_buf()
	state_mod.mark_tabnew_scratch(scratch_buf)
	pcall(function()
		vim.cmd("silent! tcd " .. vim.fn.fnameescape(norm))
	end)
	local pinned = projects.get_pinned_map()[norm]
	local wt = state_mod.get_wt()
	local tab_label
	if pinned and pinned.name and pinned.name ~= "" then
		tab_label = pinned.name
	elseif wt and type(wt.is_linked_worktree) == "function" and wt.is_linked_worktree(norm) then
		local rroot = type(wt.get_repo_root) == "function" and wt.get_repo_root(norm) or nil
		local br = type(wt.get_worktree_branch) == "function" and wt.get_worktree_branch(norm) or nil
		tab_label = (rroot and br and br ~= "") and string.format("%s:%s", projects.project_basename(rroot), br)
			or projects.project_basename(norm)
	else
		tab_label = projects.project_basename(norm)
	end
	pcall(vim.api.nvim_tabpage_set_var, new_tab, "name", tab_label)
	state.prev_tab = new_tab
	label_workspace_tab()
	vim.notify(
		string.format("Opened Project tab: %s (%s)", tab_label, vim.fn.fnamemodify(norm, ":~")),
		vim.log.levels.INFO,
		{ title = "AI Workspace" }
	)
end

---Safely close a chat from any tab without destroying `state.main_win` or stealing another tab's visible chat.
---@param chat table
---@param keep_sidebar_focus? boolean
function M.close_chat(chat, keep_sidebar_focus)
	if not chat then
		return
	end
	local closing_bufnr = chat.bufnr
	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	local candidates = {}
	if chat_mod then
		local all = chat_mod.buf_get_chat()
		if type(all) == "table" then
			for _, entry in ipairs(all) do
				if entry.chat and entry.chat.bufnr ~= closing_bufnr and vim.api.nvim_buf_is_valid(entry.chat.bufnr) then
					table.insert(candidates, entry.chat)
				end
			end
			table.sort(candidates, function(a, b)
				return a.bufnr < b.bufnr
			end)
		end
	end

	-- 1. Protect workspace `main_win` even if closing from a code tab (`<leader>cl` / middle-click)
	local ws_next = candidates[1]
	if state_mod.is_workspace_valid() and vim.api.nvim_win_get_buf(state.main_win) == closing_bufnr then
		if ws_next then
			ws_next.hidden = false
			if ws_next.ui and type(ws_next.ui.show_in_win) == "function" then
				ws_next.ui:show_in_win({
					winnr = state.main_win,
					window_opts = { default = true },
				})
			else
				vim.api.nvim_win_set_buf(state.main_win, ws_next.bufnr)
			end
			projects.sync_win_lcd(state.main_win, projects.get_valid_chat_cwd(ws_next))
		else
			vim.api.nvim_win_set_buf(state.main_win, get_empty_main_buf())
			vim.wo[state.main_win].winbar = ""
			projects.sync_win_lcd(state.main_win, nil)
		end
	end

	-- 2. If closing a chat displayed in a non-workspace tab's split, swap to an available sibling chat if any
	local cur_tab = vim.api.nvim_get_current_tabpage()
	local orphaned_wins = {}
	if cur_tab ~= state.tab then
		local cur_next = nil
		for _, c in ipairs(candidates) do
			if not state_mod.is_buf_visible_in_other_tab(c.bufnr, cur_tab) then
				cur_next = c
				break
			end
		end
		for _, w in ipairs(vim.api.nvim_tabpage_list_wins(cur_tab)) do
			if state_mod.is_split_win(w) and vim.api.nvim_win_get_buf(w) == closing_bufnr then
				if cur_next then
					cur_next.hidden = false
					if cur_next.ui and type(cur_next.ui.show_in_win) == "function" then
						cur_next.ui:show_in_win({
							winnr = w,
							window_opts = { default = true },
						})
					else
						vim.api.nvim_win_set_buf(w, cur_next.bufnr)
					end
					projects.sync_win_lcd(w, projects.get_valid_chat_cwd(cur_next))
				else
					table.insert(orphaned_wins, w)
				end
			end
		end
	end

	pcall(function()
		chat:close()
	end)

	for _, w in ipairs(orphaned_wins) do
		if vim.api.nvim_win_is_valid(w) then
			local b = vim.api.nvim_win_get_buf(w)
			if vim.bo[b].filetype ~= "codecompanion" then
				local tp = vim.api.nvim_win_get_tabpage(w)
				projects.sync_win_lcd(w, vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(tp)))
			end
		end
	end

	if state_mod.is_workspace_valid() then
		M.configure_sidebar_win()
		if state_mod.is_current_tab() and (keep_sidebar_focus or not ws_next) then
			vim.api.nvim_set_current_win(state.sidebar_win)
		end
		render.render()
	end
	state_mod.refresh_winbars()
end
M.close_chat_safely = M.close_chat

---Cycle to the next or previous chat buffer (`}` / `{`) without leaking into CLI terminal buffers.
---@param chat table
---@param delta integer
function M.cycle_chat(chat, delta)
	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	if not chat or not chat_mod then
		return
	end
	local all = chat_mod.buf_get_chat()
	local chats = {}
	local cur_tab = vim.api.nvim_get_current_tabpage()
	local in_ws = state_mod.is_current_tab()
	if type(all) == "table" then
		for _, entry in ipairs(all) do
			if entry.chat and vim.api.nvim_buf_is_valid(entry.chat.bufnr) then
				if
					in_ws
					or entry.chat.bufnr == chat.bufnr
					or not state_mod.is_buf_visible_in_other_tab(entry.chat.bufnr, cur_tab)
				then
					table.insert(chats, entry.chat)
				end
			end
		end
	end
	table.sort(chats, function(a, b)
		return a.bufnr < b.bufnr
	end)
	if #chats <= 1 then
		return
	end
	local cur_idx = nil
	for i, c in ipairs(chats) do
		if c.bufnr == chat.bufnr then
			cur_idx = i
			break
		end
	end
	if not cur_idx then
		return
	end
	local next_idx = delta > 0 and ((cur_idx % #chats) + 1) or (((cur_idx - 2 + #chats) % #chats) + 1)
	local target = chats[next_idx]
	if target then
		M.focus_or_open_chat(target)
	end
end

---Restore `state.prev_code_buf` into the current window of a newly created fallback code tab.
---@param blank_buf integer
local function restore_prev_code_buf_in_new_tab(blank_buf)
	if
		state.prev_code_buf
		and vim.api.nvim_buf_is_valid(state.prev_code_buf)
		and vim.bo[state.prev_code_buf].buftype == ""
	then
		pcall(vim.api.nvim_win_set_buf, 0, state.prev_code_buf)
		if blank_buf ~= state.prev_code_buf and vim.api.nvim_buf_is_valid(blank_buf) then
			pcall(vim.api.nvim_buf_delete, blank_buf, { force = true })
		end
	end
end

---Switch back to the previous code tabpage (creating one if AI Workspace is the sole tabpage; never stops running chats).
function M.leave()
	state_mod.stop_timer()
	if state.prev_tab and vim.api.nvim_tabpage_is_valid(state.prev_tab) and state.prev_tab ~= state.tab then
		vim.api.nvim_set_current_tabpage(state.prev_tab)
		return
	end
	if #vim.api.nvim_list_tabpages() > 1 then
		vim.cmd("tabprevious")
		return
	end
	if state_mod.is_current_tab() then
		vim.cmd("tabnew")
		local new_tab = vim.api.nvim_get_current_tabpage()
		local blank_buf = vim.api.nvim_get_current_buf()
		state_mod.mark_tabnew_scratch(blank_buf)
		restore_prev_code_buf_in_new_tab(blank_buf)
		state.prev_tab = new_tab
		label_workspace_tab()
	end
end

---Close the workspace tab completely (creating a normal code tab first if it was the last tabpage).
function M.close()
	state_mod.stop_timer()
	local ws_tab = state.tab
	local prev_tab = state.prev_tab
	state.tab = nil
	state.sidebar_win = nil
	state.main_win = nil
	if ws_tab and vim.api.nvim_tabpage_is_valid(ws_tab) then
		if #vim.api.nvim_list_tabpages() == 1 then
			vim.api.nvim_set_current_tabpage(ws_tab)
			vim.cmd("tabnew")
			local blank_buf = vim.api.nvim_get_current_buf()
			state_mod.mark_tabnew_scratch(blank_buf)
			restore_prev_code_buf_in_new_tab(blank_buf)
		end
		if #vim.api.nvim_list_tabpages() > 1 then
			local tabnr = vim.api.nvim_tabpage_get_number(ws_tab)
			pcall(function()
				vim.cmd(tostring(tabnr) .. "tabclose")
			end)
			if prev_tab and vim.api.nvim_tabpage_is_valid(prev_tab) then
				pcall(vim.api.nvim_set_current_tabpage, prev_tab)
			end
		end
	end
end

---Open the AI Workspace tab (if not already active) without toggling out when already inside.
---@param focus_main? boolean
---@param opts? { skip_auto_chat?: boolean, target_project?: string }
function M.enter(focus_main, opts)
	opts = opts or {}
	state_mod.setup_highlights()
	patches.setup_autocmds()
	local wt = state_mod.get_wt()
	if wt and type(wt.setup) == "function" then
		pcall(wt.setup)
	end
	projects.warm_zoxide_cache()

	local target_proj = opts.target_project and projects.normalize_project_path(opts.target_project) or nil

	local cur_tab = vim.api.nvim_get_current_tabpage()
	if cur_tab ~= state.tab then
		state_mod.capture_prev_code_context()
	end

	if state.tab and vim.api.nvim_tabpage_is_valid(state.tab) then
		if cur_tab ~= state.tab then
			state.prev_tab = cur_tab
			state.needs_focus_sync = true
			vim.api.nvim_set_current_tabpage(state.tab)
		end
		require("codecompanion")
		patches.patch_history_ui()
		patches.patch_codecompanion_cwd()
		if not state_mod.is_workspace_valid() then
			M.ensure_workspace_layout()
		end
		if target_proj and not opts.skip_auto_chat then
			local chat_mod = require("codecompanion.interactions.chat")
			local mbuf = state.main_win
				and vim.api.nvim_win_is_valid(state.main_win)
				and vim.api.nvim_win_get_buf(state.main_win)
			local cur_c = mbuf and chat_mod.buf_get_chat(mbuf) or nil
			if
				not cur_c
				or (
					projects.get_chat_project_path(cur_c) ~= target_proj
					and projects.get_valid_chat_cwd(cur_c) ~= target_proj
				)
			then
				local matched = projects.find_active_chat_for_project(target_proj)
				if matched then
					M.show_chat(matched, focus_main)
				else
					M.new_chat(focus_main, target_proj)
				end
			end
		end
		if focus_main and state.main_win and vim.api.nvim_win_is_valid(state.main_win) then
			vim.api.nvim_set_current_win(state.main_win)
		elseif state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
			vim.api.nvim_set_current_win(state.sidebar_win)
			vim.cmd("stopinsert")
		end
		render.render()
		return
	end

	state.prev_tab = cur_tab
	state.needs_focus_sync = true
	vim.cmd("tabnew")
	local ws_scratch_buf = vim.api.nvim_get_current_buf()
	state_mod.mark_tabnew_scratch(ws_scratch_buf)
	state.tab = vim.api.nvim_get_current_tabpage()
	state.main_win = vim.api.nvim_get_current_win()
	label_workspace_tab()

	if not state.sidebar_buf or not vim.api.nvim_buf_is_valid(state.sidebar_buf) then
		local buf = vim.api.nvim_create_buf(false, true)
		vim.bo[buf].filetype = "cc-workspace"
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "hide"
		vim.bo[buf].swapfile = false
		vim.bo[buf].buflisted = false
		vim.bo[buf].undolevels = -1
		vim.bo[buf].modifiable = false
		state.sidebar_buf = buf
	end
	if state.actions.setup_sidebar_buf then
		state.actions.setup_sidebar_buf(state.sidebar_buf)
	end

	vim.cmd("topleft vsplit")
	state.sidebar_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(state.sidebar_win, state.sidebar_buf)
	M.configure_sidebar_win()

	require("codecompanion")
	patches.patch_history_ui()
	patches.patch_codecompanion_cwd()
	local chat_mod = require("codecompanion.interactions.chat")
	if target_proj then
		local matched = projects.find_active_chat_for_project(target_proj)
		if matched then
			M.show_chat(matched, focus_main)
		elseif opts.skip_auto_chat then
			vim.api.nvim_win_set_buf(state.main_win, get_empty_main_buf())
			vim.wo[state.main_win].winbar = ""
			projects.sync_win_lcd(state.main_win, nil)
		else
			M.new_chat(focus_main, target_proj)
		end
	else
		local existing = chat_mod.last_chat()
		if existing and vim.api.nvim_buf_is_valid(existing.bufnr) then
			M.show_chat(existing, focus_main)
		elseif opts.skip_auto_chat then
			vim.api.nvim_win_set_buf(state.main_win, get_empty_main_buf())
			vim.wo[state.main_win].winbar = ""
			projects.sync_win_lcd(state.main_win, nil)
		else
			M.new_chat(focus_main)
		end
	end

	if vim.api.nvim_buf_is_valid(ws_scratch_buf) and vim.fn.bufwinid(ws_scratch_buf) == -1 then
		pcall(vim.api.nvim_buf_delete, ws_scratch_buf, { force = true })
	end

	if focus_main and state.main_win and vim.api.nvim_win_is_valid(state.main_win) then
		vim.api.nvim_set_current_win(state.main_win)
	elseif state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
		vim.api.nvim_set_current_win(state.sidebar_win)
		vim.cmd("stopinsert")
	end
	render.render()
end

---Compute a file path for `src_buf` relative to `base_dir` (or `~`-shortened if outside `base_dir`).
---@param src_buf integer|nil
---@param base_dir string|nil
---@return string
local function compute_buf_rel_path(src_buf, base_dir)
	if not src_buf or not vim.api.nvim_buf_is_valid(src_buf) then
		return ""
	end
	local raw_name = vim.api.nvim_buf_get_name(src_buf)
	if raw_name == "" then
		return ""
	end
	local norm_file = projects.normalize_project_path(raw_name) or vim.fs.normalize(raw_name)
	local norm_base = projects.normalize_project_path(base_dir)
	if norm_file and norm_base then
		local rel = vim.fs.relpath(norm_base, norm_file)
		if rel and rel ~= "" then
			return rel
		end
		return vim.fn.fnamemodify(norm_file, ":~")
	end
	return vim.fn.fnamemodify(raw_name, ":.")
end

---Capture the active visual selection (or last `'<,'>` marks) and exit visual mode.
---@return string[] lines, string filetype, integer src_buf
local function capture_visual_selection()
	local src_buf = vim.api.nvim_get_current_buf()
	local ft = vim.bo[src_buf].filetype or ""
	local cur_mode = vim.fn.mode()
	local sel_lines = {}
	if cur_mode:match("^[vV\22]") then
		local pos_v = vim.fn.getpos("v")
		local pos_cur = vim.fn.getpos(".")
		local ok_r, res = pcall(vim.fn.getregion, pos_v, pos_cur, { type = cur_mode })
		if ok_r and type(res) == "table" then
			sel_lines = res
		end
		local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
		vim.api.nvim_feedkeys(esc, "nx", false)
	else
		local pos_start = vim.fn.getpos("'<")
		local pos_end = vim.fn.getpos("'>")
		if pos_start[2] > 0 and pos_end[2] > 0 then
			local vmode = vim.fn.visualmode()
			local ok_r, res = pcall(vim.fn.getregion, pos_start, pos_end, { type = vmode ~= "" and vmode or "V" })
			if ok_r and type(res) == "table" then
				sel_lines = res
			end
		end
	end
	return sel_lines, ft, src_buf
end

---Append captured code lines as a fenced markdown block into `chat` safely (even if buffer is locked).
---@param chat table|nil
---@param sel_lines string[]
---@param ft string
---@param rel_path string
---@param target_win? integer
local function append_selection_to_chat(chat, sel_lines, ft, rel_path, target_win)
	if not chat or not vim.api.nvim_buf_is_valid(chat.bufnr) or #sel_lines == 0 then
		return
	end
	local header = ft
	if rel_path ~= "" then
		header = ft ~= "" and string.format("%s {%s}", ft, rel_path) or string.format("{%s}", rel_path)
	end
	local md = require("codecompanion.utils.markdown")
	local block = md.form_codeblock(table.concat(sel_lines, "\n"), { ft = header })
	pcall(
		vim.api.nvim_buf_clear_namespace,
		chat.bufnr,
		vim.api.nvim_create_namespace("CodeCompanion-virtual_text"),
		0,
		-1
	)
	if chat.prompt and type(chat.prompt.add) == "function" then
		chat.prompt:add({ content = block .. "\n\n" })
	else
		local was_locked = not vim.bo[chat.bufnr].modifiable
		if was_locked and chat.ui and chat.ui.unlock_buf then
			chat.ui:unlock_buf()
		end
		local lc = vim.api.nvim_buf_line_count(chat.bufnr)
		local raw_lines = vim.split("\n" .. block .. "\n", "\n", { plain = true })
		pcall(vim.api.nvim_buf_set_lines, chat.bufnr, lc, lc, false, raw_lines)
		if was_locked and chat.ui and chat.ui.lock_buf then
			chat.ui:lock_buf()
		end
	end
	local win = target_win or vim.fn.bufwinid(chat.bufnr)
	if win and win ~= -1 and vim.api.nvim_win_is_valid(win) then
		local new_last = vim.api.nvim_buf_line_count(chat.bufnr)
		pcall(vim.api.nvim_win_set_cursor, win, { new_last, 0 })
	end
end

---Send the current visual selection into the AI Workspace's matching Project chat and focus the chat pane.
function M.send_visual_selection()
	local sel_lines, ft, src_buf = capture_visual_selection()
	if #sel_lines == 0 then
		return
	end
	local in_ws = state_mod.is_current_tab()
	local src_proj = not in_ws and projects.resolve_context_project_dir(src_buf) or nil

	M.enter(true, { target_project = src_proj })

	local chat_mod = require("codecompanion.interactions.chat")
	local mbuf = state.main_win
		and vim.api.nvim_win_is_valid(state.main_win)
		and vim.api.nvim_win_get_buf(state.main_win)
	local chat = mbuf and chat_mod.buf_get_chat(mbuf) or nil
	if not chat then
		chat = M.new_chat(true, src_proj)
	end
	local rel_path = compute_buf_rel_path(src_buf, projects.get_valid_chat_cwd(chat) or src_proj)
	append_selection_to_chat(chat, sel_lines, ft, rel_path, state.main_win)
end

---Add the current visual selection into the current tab's side chat (scoped to the current buffer's Project).
function M.add_visual_to_chat()
	if state_mod.is_current_tab() then
		M.send_visual_selection()
		return
	end
	local sel_lines, ft, src_buf = capture_visual_selection()
	if #sel_lines == 0 then
		return
	end
	require("codecompanion")
	patches.patch_codecompanion_cwd()
	local chat_mod = require("codecompanion.interactions.chat")
	local chat = nil
	for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if state_mod.is_split_win(w) then
			local b = vim.api.nvim_win_get_buf(w)
			if vim.bo[b].filetype == "codecompanion" then
				chat = chat_mod.buf_get_chat(b)
				if chat then
					break
				end
			end
		end
	end
	local src_proj = projects.resolve_context_project_dir(src_buf)
	if not chat then
		chat = projects.find_active_chat_for_project(src_proj)
		if not chat then
			chat = M.new_smart_chat()
		end
	end
	if not chat then
		return
	end
	M.focus_or_open_chat(chat)
	local rel_path = compute_buf_rel_path(src_buf, projects.get_valid_chat_cwd(chat) or src_proj)
	append_selection_to_chat(chat, sel_lines, ft, rel_path, vim.api.nvim_get_current_win())
end

---Toggle a side-panel chat in normal code tabs without disturbing the AI Workspace tab.
function M.toggle_side_chat()
	if state_mod.is_current_tab() then
		M.leave()
		return
	end
	require("codecompanion")
	patches.patch_codecompanion_cwd()
	local chat_mod = require("codecompanion.interactions.chat")

	-- If a tiled chat window is visible in the current tabpage, hide that window cleanly and remember its buffer
	for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if state_mod.is_split_win(w) then
			local b = vim.api.nvim_win_get_buf(w)
			if vim.bo[b].filetype == "codecompanion" then
				vim.t.cc_last_side_chat_buf = b
				local c = chat_mod.buf_get_chat(b)
				if c and c.ui then
					c.ui.winnr = w
					c.ui.window_opts = nil
					c.ui:hide()
				else
					pcall(vim.api.nvim_win_hide, w)
				end
				return
			end
		end
	end

	-- Prefer the side chat previously hidden in this tab, then a chat matching the current Project
	local code_buf = vim.api.nvim_get_current_buf()
	local cur_tab = vim.api.nvim_get_current_tabpage()
	local target = nil
	local prev_side_buf = vim.t.cc_last_side_chat_buf
	if type(prev_side_buf) == "number" and vim.api.nvim_buf_is_valid(prev_side_buf) then
		local prev_chat = chat_mod.buf_get_chat(prev_side_buf)
		if prev_chat and not state_mod.is_buf_visible_in_other_tab(prev_chat.bufnr, cur_tab) then
			target = prev_chat
		end
	end
	if not target then
		local cur_proj = projects.resolve_context_project_dir(code_buf)
		target = projects.find_active_chat_for_project(cur_proj)
	end
	if not target and vim.api.nvim_buf_get_name(code_buf) == "" then
		local last = chat_mod.last_chat()
		if
			last
			and vim.api.nvim_buf_is_valid(last.bufnr)
			and not state_mod.is_buf_visible_in_other_tab(last.bufnr, cur_tab)
		then
			target = last
		end
	end

	if target and vim.api.nvim_buf_is_valid(target.bufnr) then
		local target_cwd = projects.get_valid_chat_cwd(target)
		if vim.bo[code_buf].buftype == "" and vim.bo[code_buf].filetype ~= "codecompanion" then
			if not target_cwd or projects.buf_within_dir(code_buf, target_cwd) then
				target.buffer_context = projects.with_temp_cwd(target_cwd, function()
					return require("codecompanion.utils.context").get(code_buf)
				end) or target.buffer_context
			end
		end
		if target.ui:is_visible_non_curtab() then
			target.ui.winnr = nil
		end
		target.ui:open({ toggled = true, window_opts = { default = true } })
		vim.t.cc_last_side_chat_buf = target.bufnr
		if target.ui.winnr and vim.api.nvim_win_is_valid(target.ui.winnr) then
			projects.sync_win_lcd(target.ui.winnr, target_cwd)
		end
		local wt = state_mod.get_wt()
		if wt and type(wt.mark_read) == "function" then
			pcall(wt.mark_read, target.bufnr)
		end
		state_mod.refresh_winbars()
		return
	end

	M.new_smart_chat()
end

---Show `target` inside an existing split window `win`, sync `lcd`, focus `win`, and mark read.
---@param target table
---@param win integer
---@param target_cwd string|nil
---@param wt table|nil
local function show_target_in_split_win(target, win, target_cwd, wt)
	target.hidden = false
	target.ui:show_in_win({
		winnr = win,
		window_opts = { default = true },
	})
	vim.t.cc_last_side_chat_buf = target.bufnr
	projects.sync_win_lcd(win, target_cwd)
	vim.api.nvim_set_current_win(win)
	if wt and type(wt.mark_read) == "function" then
		pcall(wt.mark_read, target.bufnr)
	end
	state_mod.refresh_winbars()
end

---Display an existing chat in the current tab's chat pane (or workspace `main_win`), or open a vertical split.
---@param target table
---@param preferred_win? integer
function M.focus_or_open_chat(target, preferred_win)
	if not target or not vim.api.nvim_buf_is_valid(target.bufnr) then
		return
	end
	if state_mod.is_current_tab() then
		M.show_chat(target, true)
		return
	end
	local wt = state_mod.get_wt()
	local target_cwd = projects.get_valid_chat_cwd(target)
	if
		preferred_win
		and state_mod.is_split_win(preferred_win)
		and vim.api.nvim_win_get_tabpage(preferred_win) == vim.api.nvim_get_current_tabpage()
		and vim.bo[vim.api.nvim_win_get_buf(preferred_win)].filetype == "codecompanion"
	then
		show_target_in_split_win(target, preferred_win, target_cwd, wt)
		return
	end
	for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if state_mod.is_split_win(w) and vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "codecompanion" then
			show_target_in_split_win(target, w, target_cwd, wt)
			return
		end
	end
	if target.ui then
		if target.ui:is_visible_non_curtab() then
			target.ui.winnr = nil
		end
		target.ui:open({ window_opts = { default = true } })
		vim.t.cc_last_side_chat_buf = target.bufnr
		if target.ui.winnr and vim.api.nvim_win_is_valid(target.ui.winnr) then
			projects.sync_win_lcd(target.ui.winnr, target_cwd)
		end
		if wt and type(wt.mark_read) == "function" then
			pcall(wt.mark_read, target.bufnr)
		end
		state_mod.refresh_winbars()
	end
end

---Create a new chat in-place (reusing the current tab's chat pane or workspace `main_win` without killing background tabs).
---@return table|nil
function M.new_smart_chat()
	if state_mod.is_current_tab() then
		return M.new_chat(true)
	end
	require("codecompanion")
	patches.patch_codecompanion_cwd()
	local chat_mod = require("codecompanion.interactions.chat")
	local code_buf = nil
	local cur_buf = vim.api.nvim_get_current_buf()
	if vim.bo[cur_buf].buftype == "" and vim.bo[cur_buf].filetype ~= "codecompanion" then
		code_buf = cur_buf
	else
		for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
			if state_mod.is_split_win(w) then
				local b = vim.api.nvim_win_get_buf(w)
				if vim.bo[b].buftype == "" and vim.bo[b].filetype ~= "codecompanion" then
					code_buf = b
					break
				end
			end
		end
	end

	local target_cwd = projects.resolve_context_project_dir(code_buf)

	-- Always create with `hidden = true` first so `Chat.close_last_chat()` never destroys `state.main_win` in `ws_tab`
	local chat = projects.with_temp_cwd(target_cwd, function()
		local ctx = require("codecompanion.utils.context").get(code_buf)
		local rules_cb = nil
		pcall(function()
			rules_cb =
				require("codecompanion.interactions.shared.rules.helpers").add_callbacks({ buffer_context = ctx })
		end)
		return chat_mod.new({
			hidden = true,
			cwd = target_cwd,
			buffer_context = ctx,
			callbacks = rules_cb,
		})
	end)
	if chat then
		chat.opts = chat.opts or {}
		chat.opts.cwd = target_cwd
		M.focus_or_open_chat(chat)
	end
	return chat
end

---Toggle into or out of the dedicated AI Workspace tab.
function M.toggle()
	if state_mod.is_current_tab() then
		if not state_mod.is_workspace_valid() then
			M.ensure_workspace_layout()
			if state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
				vim.api.nvim_set_current_win(state.sidebar_win)
			end
			render.render()
		else
			M.leave()
		end
		return
	end
	M.enter(false)
end

state.actions.close = M.close
state.actions.close_chat = M.close_chat
state.actions.enter = M.enter
state.actions.ensure_workspace_layout = M.ensure_workspace_layout
state.actions.configure_sidebar_win = M.configure_sidebar_win
state.actions.sync_sidebar_width = M.sync_sidebar_width
state.actions.open_history_chat = M.open_history_chat

return M
