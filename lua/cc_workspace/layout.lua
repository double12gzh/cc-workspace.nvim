-- 2-pane AI Workspace tab/window lifecycle (`ensure_workspace_layout`, `enter`, `leave`,
-- `close`, `toggle`), workspace chat mounting/closing, and re-exported history/context APIs.

local context_send = require("cc_workspace.context_send")
local history_restore = require("cc_workspace.history_restore")
local icons = require("cc_workspace.icons")
local patches = require("cc_workspace.patches")
local projects = require("cc_workspace.projects")
local render = require("cc_workspace.render")
local state_mod = require("cc_workspace.state")

local state = state_mod.state

local M = {
	-- Re-exported history & buffer context helpers (`history_restore.lua`)
	resolve_buffer_context = history_restore.resolve_buffer_context,
	open_history_chat = history_restore.open_history_chat,

	-- Re-exported visual context & code-tab side-chat actions (`context_send.lua`)
	capture_visual_selection = context_send.capture_visual_selection,
	append_selection_to_chat = context_send.append_selection_to_chat,
	send_visual_selection = context_send.send_visual_selection,
	add_visual_to_chat = context_send.add_visual_to_chat,
	toggle_side_chat = context_send.toggle_side_chat,
	focus_or_open_chat = context_send.focus_or_open_chat,
	new_smart_chat = context_send.new_smart_chat,
	cycle_chat = context_send.cycle_chat,
}

---@return integer
local function get_empty_main_buf()
	local existing = state.empty_buf
	if type(existing) == "number" and vim.api.nvim_buf_is_valid(existing) then
		return existing
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
	local bopts = { buffer = buf, nowait = true, silent = true }
	vim.keymap.set("n", "n", function()
		M.new_chat(true)
	end, bopts)
	vim.keymap.set("n", "a", function()
		if state.actions.prompt_add_project then
			state.actions.prompt_add_project()
		end
	end, bopts)
	vim.keymap.set("n", "w", function()
		if state.actions.prompt_create_worktree_chat then
			state.actions.prompt_create_worktree_chat()
		end
	end, bopts)
	vim.keymap.set("n", "u", function()
		local wt = state_mod.get_wt()
		if wt and type(wt.jump_to_attention) == "function" then
			wt.jump_to_attention()
		end
	end, bopts)
	vim.keymap.set("n", "q", function()
		M.focus_sidebar()
	end, bopts)
	state.empty_buf = buf
	return buf
end

---@param win integer|nil
---@param chat table
local function mount_chat_in_win(win, chat)
	if not win or not vim.api.nvim_win_is_valid(win) then
		return
	end
	chat.hidden = false
	if chat.ui and type(chat.ui.show_in_win) == "function" then
		chat.ui:show_in_win({ winnr = win, window_opts = { default = true } })
	else
		vim.api.nvim_win_set_buf(win, chat.bufnr)
	end
	projects.sync_win_lcd(win, projects.get_valid_chat_cwd(chat))
end

local function mount_empty_main_win()
	local mwin = state.main_win
	if not mwin or not vim.api.nvim_win_is_valid(mwin) then
		return
	end
	vim.api.nvim_win_set_buf(mwin, get_empty_main_buf())
	vim.wo[mwin].winbar = ""
	projects.sync_win_lcd(mwin, nil)
end

local function ensure_sidebar_buf()
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
end

local function focus_workspace_pane(focus_main)
	if focus_main and state.main_win and vim.api.nvim_win_is_valid(state.main_win) then
		vim.api.nvim_set_current_win(state.main_win)
	elseif state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
		vim.api.nvim_set_current_win(state.sidebar_win)
		vim.cmd("stopinsert")
	end
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

local function label_workspace_tab()
	if not state.tab or not vim.api.nvim_tabpage_is_valid(state.tab) then
		return
	end
	pcall(vim.api.nvim_tabpage_set_var, state.tab, "name", icons.get("aichat", true).Chat .. "AI")
	if #vim.api.nvim_list_tabpages() > 1 then
		if not package.loaded["bufferline"] then
			pcall(require, "bufferline")
		end
		if vim.o.showtabline == 0 then
			vim.o.showtabline = 2
		end
	end
end

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
	for _, entry in ipairs(type(all) == "table" and all or {}) do
		if entry.chat and vim.api.nvim_buf_is_valid(entry.chat.bufnr) then
			return entry.chat
		end
	end
	return nil
end

---Repair or recreate the left sidebar + right main pane inside `state.tab` without leaving `sidebar_win` missing.
---@return boolean
function M.ensure_workspace_layout()
	if state.in_layout_repair then
		return state_mod.is_workspace_valid()
	elseif not state.tab or not vim.api.nvim_tabpage_is_valid(state.tab) then
		return false
	end
	state.in_layout_repair = true
	local ok_repair, res = pcall(function()
		vim.api.nvim_set_current_tabpage(state.tab)
		label_workspace_tab()
		ensure_sidebar_buf()

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
			local mwin = vim.api.nvim_get_current_win()
			state.main_win = mwin
			local fallback_chat = find_fallback_chat()
			if fallback_chat and fallback_chat.ui and vim.api.nvim_buf_is_valid(fallback_chat.bufnr) then
				mount_chat_in_win(mwin, fallback_chat)
			else
				vim.api.nvim_win_set_buf(mwin, get_empty_main_buf())
				projects.sync_win_lcd(mwin, nil)
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
	mount_chat_in_win(state.main_win, chat)
	M.configure_sidebar_win()
	focus_workspace_pane(focus_main)
	if state_mod.is_current_tab() then
		local wt = state_mod.get_wt()
		if wt and type(wt.mark_read) == "function" then
			pcall(wt.mark_read, chat.bufnr)
		end
	end
	render.render()
	state_mod.refresh_winbars()
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
	local target_cwd = history_restore.resolve_new_chat_cwd(project_path)
	state.last_selected_project = target_cwd
	local chat = history_restore.create_scoped_chat(target_cwd)
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
			state.collapsed_worktrees[norm], state.focus_worktree_path = false, norm
		else
			state.focus_project_path = norm_repo
		end
	else
		state.collapsed_projects[norm], state.focus_project_path = false, norm
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
			if projects.normalize_project_path(vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(tp))) == norm then
				state.prev_tab = tp
				vim.api.nvim_set_current_tabpage(tp)
				return
			end
		end
	end
	if state_mod.is_current_tab() and state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
		pcall(vim.api.nvim_set_current_win, state.sidebar_win)
	end
	vim.cmd("tabnew")
	local new_tab = vim.api.nvim_get_current_tabpage()
	state_mod.mark_tabnew_scratch(vim.api.nvim_get_current_buf())
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
		for _, entry in ipairs(type(all) == "table" and all or {}) do
			if entry.chat and entry.chat.bufnr ~= closing_bufnr and vim.api.nvim_buf_is_valid(entry.chat.bufnr) then
				table.insert(candidates, entry.chat)
			end
		end
		table.sort(candidates, function(a, b)
			return a.bufnr < b.bufnr
		end)
	end

	local ws_next = candidates[1]
	if state_mod.is_workspace_valid() and vim.api.nvim_win_get_buf(state.main_win) == closing_bufnr then
		if ws_next then
			mount_chat_in_win(state.main_win, ws_next)
		else
			mount_empty_main_win()
		end
	end

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
					mount_chat_in_win(w, cur_next)
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
		if vim.api.nvim_win_is_valid(w) and vim.bo[vim.api.nvim_win_get_buf(w)].filetype ~= "codecompanion" then
			local tp = vim.api.nvim_win_get_tabpage(w)
			projects.sync_win_lcd(w, vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(tp)))
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

local function open_fallback_code_tab()
	vim.cmd("tabnew")
	local new_tab = vim.api.nvim_get_current_tabpage()
	local blank_buf = vim.api.nvim_get_current_buf()
	state_mod.mark_tabnew_scratch(blank_buf)
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
	return new_tab
end

---Switch back to the previous code tabpage (creating one if AI Workspace is the sole tabpage; never stops running chats).
function M.leave()
	state_mod.stop_timer()
	if state.prev_tab and vim.api.nvim_tabpage_is_valid(state.prev_tab) and state.prev_tab ~= state.tab then
		vim.api.nvim_set_current_tabpage(state.prev_tab)
	elseif #vim.api.nvim_list_tabpages() > 1 then
		vim.cmd("tabprevious")
	elseif state_mod.is_current_tab() then
		state.prev_tab = open_fallback_code_tab()
		label_workspace_tab()
	end
end

---Close the workspace tab completely (creating a normal code tab first if it was the last tabpage).
function M.close()
	state_mod.stop_timer()
	local ws_tab, prev_tab = state.tab, state.prev_tab
	state.tab, state.sidebar_win, state.main_win = nil, nil, nil
	if ws_tab and vim.api.nvim_tabpage_is_valid(ws_tab) then
		if #vim.api.nvim_list_tabpages() == 1 then
			vim.api.nvim_set_current_tabpage(ws_tab)
			open_fallback_code_tab()
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
			state.prev_tab, state.needs_focus_sync = cur_tab, true
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
		focus_workspace_pane(focus_main)
		render.render()
		return
	end

	state.prev_tab, state.needs_focus_sync = cur_tab, true
	vim.cmd("tabnew")
	local ws_scratch_buf = vim.api.nvim_get_current_buf()
	state_mod.mark_tabnew_scratch(ws_scratch_buf)
	state.tab = vim.api.nvim_get_current_tabpage()
	state.main_win = vim.api.nvim_get_current_win()
	label_workspace_tab()
	ensure_sidebar_buf()

	vim.cmd("topleft vsplit")
	state.sidebar_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(state.sidebar_win, state.sidebar_buf)
	M.configure_sidebar_win()

	require("codecompanion")
	patches.patch_history_ui()
	patches.patch_codecompanion_cwd()
	local chat_mod = require("codecompanion.interactions.chat")
	local initial = target_proj and projects.find_active_chat_for_project(target_proj) or chat_mod.last_chat()
	if initial and vim.api.nvim_buf_is_valid(initial.bufnr) then
		M.show_chat(initial, focus_main)
	elseif opts.skip_auto_chat then
		mount_empty_main_win()
	else
		M.new_chat(focus_main, target_proj)
	end

	if vim.api.nvim_buf_is_valid(ws_scratch_buf) and vim.fn.bufwinid(ws_scratch_buf) == -1 then
		pcall(vim.api.nvim_buf_delete, ws_scratch_buf, { force = true })
	end
	focus_workspace_pane(focus_main)
	render.render()
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
