local icons = require("cc_workspace.icons")
local layout = require("cc_workspace.layout")
local patches = require("cc_workspace.patches")
local pickers = require("cc_workspace.pickers")
local projects = require("cc_workspace.projects")
local render = require("cc_workspace.render")
local state_mod = require("cc_workspace.state")

local state = state_mod.state

local M = {}

---Open CodeCompanion history picker with workspace CWD/UI patches applied.
local function open_full_history()
	require("codecompanion")
	patches.patch_history_ui()
	pcall(function()
		vim.cmd("CodeCompanionHistory")
	end)
end

---Prompt for a keyword to filter sidebar conversations and projects.
local function prompt_filter()
	vim.ui.input({
		prompt = "Filter projects & conversations (empty to clear): ",
		default = state.filter or "",
	}, function(input)
		if input == nil then
			return
		end
		state.filter = vim.trim(input)
		render.render()
	end)
end

---Show a compact floating help card for AI Workspace shortcuts.
function M.show_help_float()
	local help_lines = {
		" AI Workspace Sidebar Shortcuts ",
		" ──────────────────────────────────────────── ",
		"  <CR> / l    Open / new chat / toggle group  ",
		"  p / <Space> Peek conversation (keep focus)  ",
		"  a / +       Add Project (<Tab> multi + <CR>)",
		"  A           Add Project (path Tab-complete) ",
		"  w           New Git Worktree + Agent Chat   ",
		"  n           New chat (in Worktree/Project)  ",
		"  N           Pick Project(s) & start chat    ",
		"  u           Jump to next unread / attention ",
		"  o           Open Worktree/Project code tab  ",
		"  r           Rename chat or Project alias    ",
		"  d / x       Close chat / rm Worktree / Proj ",
		"  K           Inspect Project/Worktree/chat   ",
		"  y / Y       Copy item path / all repo paths  ",
		"  h / za      Collapse / toggle tree group    ",
		"  zM / zR     Collapse all / expand all       ",
		"  1 - 9       Jump to active conversation 1-9 ",
		"  <Tab>/<S-Tab> Next / previous item          ",
		"  f / F       Filter by keyword / clear       ",
		"  s / gh      Full-text history picker        ",
		"  R           Refresh worktrees & sidebar     ",
		"  q / Q       Back to code / close Workspace  ",
		"",
		" Agent Status Legend ",
		" ──────────────────────────────────────────── ",
		string.format("  ⠋ Thinking  ⚡ Streaming  %s Waiting  ✓ Unread", icons.diagnostics.Warning),
		"  ✗ Error     ◆ Active     ○ Idle             ",
		"",
		" Inside Chat Pane (Right) ",
		" ──────────────────────────────────────────── ",
		"  <CR> / <C-s> Send prompt                    ",
		"  q           Stop request, or focus sidebar  ",
		"  ga          Change adapter / model          ",
		"  } / {       Cycle next / previous chat      ",
		"  ?           Show all CodeCompanion options  ",
	}
	local w = math.min(48, math.max(30, vim.o.columns - 4))
	local h = math.min(#help_lines, math.max(8, vim.o.lines - 4))
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].undolevels = -1
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, help_lines)
	vim.bo[buf].modifiable = false

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		title = " Help (q/<Esc> to close) ",
		title_pos = "center",
		width = w,
		height = h,
		row = math.max(1, math.floor((vim.o.lines - h) / 2)),
		col = math.max(1, math.floor((vim.o.columns - w) / 2)),
		zindex = 80,
	})
	local function close_help()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end
	for _, k in ipairs({ "q", "<Esc>", "?", "<CR>" }) do
		vim.keymap.set("n", k, close_help, { buffer = buf, nowait = true, silent = true })
	end
	vim.api.nvim_create_autocmd("BufLeave", { buffer = buf, once = true, callback = close_help })
end

---Activate the action bound to a specific sidebar line.
---@param row number|nil
---@param focus_main boolean
---@param click_col? integer
function M.activate_row(row, focus_main, click_col)
	if not row then
		return
	end
	local act = state.row_actions[row]
	if not act then
		return
	end
	if act.kind == "new_chat" then
		if click_col and act.help_col_1idx and click_col >= act.help_col_1idx then
			M.show_help_float()
		else
			layout.new_chat(focus_main)
		end
	elseif act.kind == "new_project_chat" then
		layout.new_chat(focus_main, act.path)
	elseif act.kind == "add_project" then
		pickers.prompt_add_project()
	elseif act.kind == "projects_header" then
		if click_col and act.search_col_1idx and click_col >= act.search_col_1idx then
			open_full_history()
		elseif click_col and act.worktree_col_1idx and click_col >= act.worktree_col_1idx then
			pickers.prompt_create_worktree_chat()
		else
			pickers.prompt_add_project()
		end
	elseif act.kind == "filter" then
		prompt_filter()
	elseif act.kind == "help" then
		M.show_help_float()
	elseif act.kind == "history_picker" then
		open_full_history()
	elseif act.kind == "active_chat" then
		layout.show_chat(act.chat, focus_main)
	elseif act.kind == "history_chat" then
		layout.open_history_chat(act.save_id, focus_main)
	elseif act.kind == "toggle_project_all" then
		state.expanded_all_projects[act.path] = not state.expanded_all_projects[act.path]
		render.render()
	elseif act.kind == "toggle_worktree_all" then
		state.expanded_all_worktrees[act.path] = not state.expanded_all_worktrees[act.path]
		render.render()
	elseif act.kind == "worktree" then
		state.last_selected_project = act.path or state.last_selected_project
		if act.is_empty_leaf or (click_col and act.plus_col_1idx and click_col >= act.plus_col_1idx) then
			layout.new_chat(focus_main, act.path)
		else
			state.collapsed_worktrees[act.path] = not act.collapsed
			render.render()
		end
	elseif act.kind == "project" then
		state.last_selected_project = act.path ~= "Other" and act.path or state.last_selected_project
		if act.is_empty_leaf or (click_col and act.plus_col_1idx and click_col >= act.plus_col_1idx) then
			layout.new_chat(focus_main, act.path ~= "Other" and act.path or nil)
		else
			state.collapsed_projects[act.path] = not act.collapsed
			render.render()
		end
	end
end

---Jump cursor to the next or previous actionable sidebar row.
---@param delta integer
local function step_action_row(delta)
	if not state_mod.is_workspace_valid() or #state.action_rows == 0 then
		return
	end
	local cur = state_mod.get_sidebar_row()
	if not cur then
		return
	end
	if delta > 0 then
		for _, r in ipairs(state.action_rows) do
			if r > cur then
				vim.api.nvim_win_set_cursor(state.sidebar_win, { r, 0 })
				return
			end
		end
		vim.api.nvim_win_set_cursor(state.sidebar_win, { state.action_rows[1], 0 })
	else
		for i = #state.action_rows, 1, -1 do
			local r = state.action_rows[i]
			if r < cur then
				vim.api.nvim_win_set_cursor(state.sidebar_win, { r, 0 })
				return
			end
		end
		vim.api.nvim_win_set_cursor(state.sidebar_win, { state.action_rows[#state.action_rows], 0 })
	end
end

---Rename an active/saved conversation or a Project display alias under the cursor.
local function rename_current_row()
	if not state_mod.is_workspace_valid() then
		return
	end
	local row = state_mod.get_sidebar_row()
	local act = row and state.row_actions[row] or nil
	if not act then
		return
	end

	if act.kind == "project" then
		if act.path == "Other" then
			return
		end
		vim.ui.input({
			prompt = "Project display name (empty to reset to folder name): ",
			default = act.custom_name or act.name or "",
		}, function(new_name)
			if new_name == nil then
				return
			end
			projects.rename_project(act.path, new_name)
		end)
		return
	end

	if act.kind ~= "active_chat" and act.kind ~= "history_chat" then
		return
	end

	local current_title = act.title or (act.chat and state_mod.get_chat_title(act.chat)) or ""
	vim.ui.input({
		prompt = "Rename conversation: ",
		default = current_title,
	}, function(new_title)
		if not new_title then
			return
		end
		local trimmed = vim.trim(new_title)
		if trimmed == "" or trimmed == current_title then
			return
		end

		local cc = package.loaded["codecompanion"]
		local history_ext = cc and cc.extensions and cc.extensions.history
		local loc = history_ext and history_ext.get_location and history_ext.get_location()
		local saved_map = (history_ext and history_ext.get_chats) and history_ext.get_chats() or {}

		if act.kind == "active_chat" and act.chat then
			act.chat.opts = act.chat.opts or {}
			act.chat.opts.title = trimmed
			pcall(function()
				act.chat:set_title(trimmed)
			end)
			local save_id = act.chat.opts.save_id
			if save_id and loc and saved_map[save_id] ~= nil then
				local ok_s, Storage = pcall(require, "codecompanion._extensions.history.storage")
				if ok_s and Storage then
					Storage.new({ dir_to_save = loc }):rename_chat(save_id, trimmed)
				end
			end
		elseif act.kind == "history_chat" and act.save_id and loc then
			local ok_s, Storage = pcall(require, "codecompanion._extensions.history.storage")
			if ok_s and Storage then
				Storage.new({ dir_to_save = loc }):rename_chat(act.save_id, trimmed)
			end
		end

		state_mod.invalidate_history_cache()
		render.render()
		state_mod.refresh_winbars()
	end)
end

---Retarget any code tabpages whose `tcd` pointed at a deleted worktree back to `repo_root`.
---@param wt_path string
---@param repo_root string|nil
local function retarget_worktree_tabs_to_repo(wt_path, repo_root)
	if not repo_root or vim.fn.isdirectory(repo_root) ~= 1 then
		return
	end
	local cur_tp = vim.api.nvim_get_current_tabpage()
	for _, tp in ipairs(vim.api.nvim_list_tabpages()) do
		if tp ~= state.tab and vim.api.nvim_tabpage_is_valid(tp) then
			local tp_nr = vim.api.nvim_tabpage_get_number(tp)
			local tp_cwd = projects.normalize_project_path(vim.fn.getcwd(-1, tp_nr))
			if tp_cwd == wt_path then
				pcall(function()
					vim.api.nvim_set_current_tabpage(tp)
					vim.cmd("silent! tcd " .. vim.fn.fnameescape(repo_root))
					pcall(vim.api.nvim_tabpage_set_var, tp, "name", projects.project_basename(repo_root))
				end)
			end
		end
	end
	if vim.api.nvim_tabpage_is_valid(cur_tp) and vim.api.nvim_get_current_tabpage() ~= cur_tp then
		pcall(vim.api.nvim_set_current_tabpage, cur_tp)
	end
end

---Confirm and remove a linked Git Worktree row, closing its active chats and handling dirty retries.
---@param act table
local function delete_worktree_row(act)
	if act.is_main then
		vim.notify(
			"Cannot remove the main repository worktree (press d on the Project header to unpin/remove project)",
			vim.log.levels.WARN,
			{ title = "Git Worktree" }
		)
		return
	end
	local wt = state_mod.get_wt()
	if not wt or type(wt.remove_worktree) ~= "function" then
		return
	end
	local wt_path = act.path
	local wt_chats = {}
	for _, c in ipairs(state.active_chats or {}) do
		if c and vim.api.nvim_buf_is_valid(c.bufnr) then
			local ccwd = projects.get_valid_chat_cwd(c)
			if ccwd and (ccwd == wt_path or ccwd:sub(1, #wt_path + 1) == wt_path .. "/") then
				table.insert(wt_chats, c)
			end
		end
	end
	local br_icon = icons.git.Branch
	local br_label = act.branch or projects.project_basename(wt_path)
	local short_wt = vim.fn.fnamemodify(wt_path, ":~")
	local prompt_msg = #wt_chats > 0
			and string.format(
				"Remove Git worktree '%s %s' (%s) and close %d active conversation(s)?",
				br_icon,
				br_label,
				short_wt,
				#wt_chats
			)
		or string.format("Remove Git worktree '%s %s' (%s)?", br_icon, br_label, short_wt)
	local buttons = act.dirty and "&Force remove (discard uncommitted changes)\n&Cancel" or "&Remove worktree\n&Cancel"
	local choice = vim.fn.confirm(prompt_msg, buttons, 2)
	if choice ~= 1 then
		return
	end
	for _, c in ipairs(wt_chats) do
		layout.close_chat(c, true)
	end

	local function on_removed(ok, err, used_force)
		if ok then
			state.collapsed_worktrees[wt_path] = nil
			state.expanded_all_worktrees[wt_path] = nil
			if state.last_selected_project == wt_path then
				state.last_selected_project = act.repo_root
			end
			retarget_worktree_tabs_to_repo(wt_path, act.repo_root)
			vim.notify(
				string.format("Removed Git worktree '%s %s'", br_icon, br_label),
				vim.log.levels.INFO,
				{ title = "Git Worktree" }
			)
			render.render()
			return
		end
		local err_str = tostring(err or "unknown error")
		local err_lc = err_str:lower()
		local is_dirty_err = err_lc:find("uncommitted", 1, true)
			or err_lc:find("modified", 1, true)
			or err_lc:find("untracked", 1, true)
			or err_lc:find("dirty", 1, true)
		if not used_force and is_dirty_err then
			local retry = vim.fn.confirm(
				string.format("Worktree '%s %s' has uncommitted changes. Force remove anyway?", br_icon, br_label),
				"&Force remove\n&Cancel",
				2
			)
			if retry == 1 then
				wt.remove_worktree(wt_path, { force = true }, function(ok2, err2)
					on_removed(ok2, err2, true)
				end)
			end
			return
		end
		vim.notify("Failed to remove worktree: " .. err_str, vim.log.levels.ERROR, { title = "Git Worktree" })
	end

	wt.remove_worktree(wt_path, { force = act.dirty == true }, function(ok, err)
		on_removed(ok, err, act.dirty == true)
	end)
end

---Confirm and remove/unpin/hide a Project row under the cursor.
---@param act table
local function delete_project_row(act)
	local active_n = act.active_count or 0
	local hist_n = act.history_count or 0
	local is_cur_cwd = (act.path == projects.get_global_cwd())
	local disp = act.name or act.path
	if hist_n == 0 and active_n == 0 then
		local choice = vim.fn.confirm("Remove project '" .. disp .. "' from AI Workspace?", "&Yes\n&No", 2)
		if choice == 1 then
			projects.remove_project(act.path, { hide = is_cur_cwd or act.path == "Other" })
		end
		return
	end
	if hist_n == 0 and active_n > 0 then
		if act.pinned then
			local choice = vim.fn.confirm(
				string.format("Project '%s' has %d active conversation(s):", disp, active_n),
				"&Remove & close active chat(s)\n&Unpin only (keep active)\n&Cancel",
				3
			)
			if choice == 1 then
				projects.remove_project(act.path, { hide = is_cur_cwd or act.path == "Other", close_active = true })
			elseif choice == 2 then
				projects.remove_project(act.path, { hide = is_cur_cwd or act.path == "Other", close_active = false })
			end
		else
			local choice = vim.fn.confirm(
				string.format("Remove project '%s' and close %d active conversation(s)?", disp, active_n),
				"&Yes\n&No",
				2
			)
			if choice == 1 then
				projects.remove_project(act.path, { hide = is_cur_cwd or act.path == "Other", close_active = true })
			end
		end
		return
	end

	local prompt_msg = active_n > 0
			and string.format("Project '%s' has %d active and %d saved conversation(s):", disp, active_n, hist_n)
		or string.format("Project '%s' has %d saved conversation(s):", disp, hist_n)
	local choice =
		vim.fn.confirm(prompt_msg, "&Remove from sidebar (keep history)\n&Delete project & saved chats\n&Cancel", 3)
	if choice == 1 then
		projects.remove_project(act.path, { hide = true, delete_chats = false, close_active = active_n > 0 })
	elseif choice == 2 then
		projects.remove_project(
			act.path,
			{ hide = is_cur_cwd or act.path == "Other", delete_chats = true, close_active = true }
		)
	end
end

---Close an active chat, delete a history chat, remove a Git Worktree, or remove/hide a Project at the current row.
local function delete_current_row()
	if not state_mod.is_workspace_valid() then
		return
	end
	local row = state_mod.get_sidebar_row()
	local act = row and state.row_actions[row] or nil
	if not act then
		return
	end

	if act.kind == "worktree" then
		delete_worktree_row(act)
		return
	end
	if act.kind == "project" then
		delete_project_row(act)
		return
	end
	if act.kind == "active_chat" and act.chat then
		local wt = state_mod.get_wt()
		local has_req = wt and type(wt.has_active_request) == "function" and wt.has_active_request(act.chat.bufnr)
			or false
		local st = state_mod.get_chat_status_info(act.chat.bufnr, false)
		if has_req or st.state == "thinking" or st.state == "streaming" then
			local ok = vim.fn.confirm(
				"Conversation is still running. Stop and close '" .. state_mod.get_chat_title(act.chat) .. "'?",
				"&Yes\n&No",
				2
			)
			if ok ~= 1 then
				return
			end
		end
		layout.close_chat(act.chat, true)
	elseif act.kind == "history_chat" and act.save_id then
		local choice = vim.fn.confirm("Delete saved chat '" .. (act.title or act.save_id) .. "'?", "&Yes\n&No", 2)
		if choice == 1 then
			local cc = package.loaded["codecompanion"]
			if cc and cc.extensions and cc.extensions.history and cc.extensions.history.delete_chat then
				cc.extensions.history.delete_chat(act.save_id)
			end
			state_mod.invalidate_history_cache()
			render.render()
		end
	end
end

---Display detailed path and status metadata for the Project, Worktree, or conversation under cursor.
local function inspect_current_row()
	local row = state_mod.get_sidebar_row()
	local act = row and state.row_actions[row] or nil
	if not act then
		return
	end
	local br_icon = icons.git.Branch
	if act.kind == "project" then
		local exists = (act.path ~= "Other" and vim.fn.isdirectory(act.path) == 1) and "yes" or "missing"
		local wt = state_mod.get_wt()
		local wt_line = (act.worktree_count and act.worktree_count > 0)
				and string.format("\nGit Worktrees: %d", act.worktree_count)
			or ""
		local wt_details = ""
		if wt and type(wt.list_worktrees) == "function" and act.path ~= "Other" then
			local wts = wt.list_worktrees(act.repo_root or act.path)
			if type(wts) == "table" and #wts > 0 then
				local parts = {}
				for _, w in ipairs(wts) do
					local wp = projects.normalize_project_path(w.path) or w.path
					local br = (w.branch and w.branch ~= "") and w.branch or (w.head or "HEAD")
					local dirty_mark = w.dirty and "*" or ""
					table.insert(parts, string.format("  • %s %s%s: %s", br_icon, br, dirty_mark, wp))
				end
				wt_details = "\nWorktrees:\n" .. table.concat(parts, "\n")
			end
		end
		vim.notify(
			string.format(
				"Project: %s\nPath: %s\nPinned: %s · Exists: %s%s\nConversations: %d active, %d saved%s",
				act.name or act.path,
				act.path,
				act.pinned and "yes" or "auto",
				exists,
				wt_line,
				act.active_count or 0,
				act.history_count or 0,
				wt_details
			),
			vim.log.levels.INFO,
			{ title = "AI Workspace Project" }
		)
	elseif act.kind == "worktree" then
		vim.notify(
			string.format(
				"Branch: %s %s%s%s\nWorktree: %s\nRepository: %s\nConversations: %d active, %d saved",
				br_icon,
				act.branch or projects.project_basename(act.path),
				act.is_main and " (main)" or " (linked)",
				act.dirty and " · dirty*" or "",
				act.path,
				act.repo_root or act.project_path or "",
				act.active_count or 0,
				act.history_count or 0
			),
			vim.log.levels.INFO,
			{ title = "Git Worktree" }
		)
	elseif act.kind == "active_chat" and act.chat then
		local pname, ppath = projects.get_chat_project_name(act.chat)
		local ccwd = projects.get_valid_chat_cwd(act.chat) or ppath
		local wt = state_mod.get_wt()
		local br = (wt and ccwd and type(wt.get_worktree_branch) == "function") and wt.get_worktree_branch(ccwd) or nil
		local st = state_mod.get_chat_status_info(act.chat.bufnr, false)
		vim.notify(
			string.format(
				"Title: %s\nProject: %s%s\nWorking Dir: %s\nStatus: %s %s · Buffer: #%d",
				state_mod.get_chat_title(act.chat),
				pname,
				(br and br ~= "") and string.format(" · %s %s", br_icon, br) or "",
				ccwd,
				st.icon,
				st.state,
				act.chat.bufnr
			),
			vim.log.levels.INFO,
			{ title = "Active Agent Conversation" }
		)
	elseif act.kind == "history_chat" then
		vim.notify(
			string.format(
				"Title: %s\nProject: %s%s\nSave ID: %s",
				act.title or "Untitled",
				act.project_path or "Other",
				act.worktree_path and ("\nWorktree: " .. act.worktree_path) or "",
				tostring(act.save_id)
			),
			vim.log.levels.INFO,
			{ title = "Saved Conversation" }
		)
	end
end

---Collect unique repository + worktree paths for `base_path`.
---@param wt table|nil
---@param base_path string
---@return string[]
local function collect_repo_paths(wt, base_path)
	local out = {}
	local seen = {}
	local function push(p)
		local np = projects.normalize_project_path(p) or p
		if type(np) == "string" and np ~= "" and np ~= "Other" and not seen[np] then
			seen[np] = true
			table.insert(out, np)
		end
	end

	local norm_base = projects.normalize_project_path(base_path)
	if not norm_base or norm_base == "Other" then
		return out
	end
	local repo_root = (wt and type(wt.get_repo_root) == "function" and wt.get_repo_root(norm_base)) or norm_base
	push(norm_base)
	if wt and type(wt.list_worktrees) == "function" then
		local wts = wt.list_worktrees(repo_root)
		if type(wts) == "table" then
			for _, w in ipairs(wts) do
				if type(w) == "table" and w.path then
					push(projects.normalize_project_path(w.path) or w.path)
				end
			end
		end
	end
	return out
end

---Collect unique repository/worktree paths or copy the current sidebar item's path to clipboard registers.
---@param all_paths? boolean When true, copy all worktree paths for the cursor project or all rendered projects from the PROJECTS header.
---@return string[]|nil
function M.yank_row_path(all_paths)
	local wt = state_mod.get_wt()
	local row = state_mod.get_sidebar_row()
	local act = row and state.row_actions[row] or nil
	local paths = {}
	local seen = {}
	local function add_unique(p)
		if type(p) == "string" and p ~= "" and p ~= "Other" and not seen[p] then
			seen[p] = true
			table.insert(paths, p)
		end
	end

	if all_paths then
		if not act or act.kind == "projects_header" then
			for _, p in ipairs(state.rendered_project_paths or {}) do
				if p ~= "Other" then
					for _, rp in ipairs(collect_repo_paths(wt, p)) do
						add_unique(rp)
					end
				end
			end
		else
			local proj_p = act.repo_root or act.project_path or act.path
			if type(proj_p) == "string" and proj_p ~= "" and proj_p ~= "Other" then
				for _, rp in ipairs(collect_repo_paths(wt, proj_p)) do
					add_unique(rp)
				end
			end
		end
	elseif act and act.kind == "projects_header" then
		for _, p in ipairs(state.rendered_project_paths or {}) do
			if p ~= "Other" then
				add_unique(projects.normalize_project_path(p) or p)
			end
		end
	elseif act then
		local target = nil
		if act.kind == "worktree" then
			target = act.path
		elseif act.kind == "active_chat" and act.chat then
			target = projects.get_valid_chat_cwd(act.chat) or act.worktree_path or act.project_path
		elseif type(act.worktree_path) == "string" and act.worktree_path ~= "" and act.worktree_path ~= "Other" then
			target = act.worktree_path
		elseif type(act.path) == "string" and act.path ~= "" and act.path ~= "Other" then
			target = act.path
		elseif type(act.project_path) == "string" and act.project_path ~= "" and act.project_path ~= "Other" then
			target = act.project_path
		end
		if target then
			add_unique(projects.normalize_project_path(target) or target)
		end
	end

	if #paths == 0 then
		vim.notify("No path on current line", vim.log.levels.WARN, { title = "AI Workspace" })
		return nil
	end

	local text = table.concat(paths, "\n")
	vim.fn.setreg('"', text)
	pcall(vim.fn.setreg, "+", text)
	pcall(vim.fn.setreg, "*", text)

	if #paths == 1 then
		vim.notify("Copied path: " .. paths[1], vim.log.levels.INFO, { title = "AI Workspace" })
	else
		local bullets = {}
		for _, p in ipairs(paths) do
			table.insert(bullets, "• " .. p)
		end
		vim.notify(
			string.format("Copied %d paths:\n%s", #paths, table.concat(bullets, "\n")),
			vim.log.levels.INFO,
			{ title = "AI Workspace" }
		)
	end
	return paths
end

---Resolve the specific Worktree or Project directory under the sidebar cursor (`n` / `o`).
---@return string|nil
local function cursor_target_path()
	local row = state_mod.get_sidebar_row()
	local act = row and state.row_actions[row] or nil
	if not act then
		return nil
	end
	if type(act.worktree_path) == "string" and act.worktree_path ~= "" and act.worktree_path ~= "Other" then
		return act.worktree_path
	end
	if
		(act.kind == "worktree" or act.kind == "project" or act.kind == "new_project_chat")
		and type(act.path) == "string"
		and act.path ~= ""
		and act.path ~= "Other"
	then
		return act.path
	end
	if act.kind == "active_chat" and act.chat then
		local ccwd = projects.get_valid_chat_cwd(act.chat)
		if ccwd and ccwd ~= "" then
			return ccwd
		end
	end
	local p = act.project_path or act.path
	if type(p) == "string" and p ~= "" and p ~= "Other" then
		return p
	end
	return nil
end

---Resolve the parent Project path under the sidebar cursor (`zM` / `zR`).
---@return string|nil
local function cursor_project_path()
	local row = state_mod.get_sidebar_row()
	local act = row and state.row_actions[row] or nil
	if not act then
		return nil
	end
	local p = act.project_path or act.path
	if type(p) == "string" and p ~= "" and p ~= "Other" then
		return p
	end
	return nil
end

---Handle `l` / `<Right>` in sidebar: expand collapsed group, step into child, or activate row.
local function handle_key_expand_or_open()
	local row = state_mod.get_sidebar_row()
	local act = row and state.row_actions[row] or nil
	if not act then
		return
	end
	if act.kind == "project" then
		if act.is_empty_leaf then
			layout.new_chat(true, act.path ~= "Other" and act.path or nil)
		elseif act.collapsed then
			state.collapsed_projects[act.path] = false
			render.render()
		elseif state.row_actions[row + 1] and state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
			pcall(vim.api.nvim_win_set_cursor, state.sidebar_win, { row + 1, 0 })
		end
	elseif act.kind == "worktree" then
		if act.is_empty_leaf then
			layout.new_chat(true, act.path)
		elseif act.collapsed then
			state.collapsed_worktrees[act.path] = false
			render.render()
		elseif state.row_actions[row + 1] and state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
			pcall(vim.api.nvim_win_set_cursor, state.sidebar_win, { row + 1, 0 })
		end
	else
		M.activate_row(row, true)
	end
end

---Handle `h` / `<Left>` in sidebar: collapse open group or jump up to parent group row.
local function handle_key_collapse_or_parent()
	local row = state_mod.get_sidebar_row()
	local act = row and state.row_actions[row] or nil
	if not act then
		return
	end
	if act.kind == "project" then
		if not act.is_empty_leaf and not act.collapsed then
			state.collapsed_projects[act.path] = true
			render.render()
		end
	elseif act.kind == "worktree" then
		if not act.is_empty_leaf and not act.collapsed then
			state.collapsed_worktrees[act.path] = true
			render.render()
		elseif act.project_row and state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
			pcall(vim.api.nvim_win_set_cursor, state.sidebar_win, { act.project_row, 0 })
		end
	elseif act.worktree_path and act.worktree_row then
		state.collapsed_worktrees[act.worktree_path] = true
		if state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
			pcall(vim.api.nvim_win_set_cursor, state.sidebar_win, { act.worktree_row, 0 })
		end
		render.render()
	elseif act.project_path and act.project_row then
		state.collapsed_projects[act.project_path] = true
		if state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
			pcall(vim.api.nvim_win_set_cursor, state.sidebar_win, { act.project_row, 0 })
		end
		render.render()
	end
end

---Handle `za` fold toggle on project, worktree, or child rows.
local function handle_key_toggle_fold()
	local row = state_mod.get_sidebar_row()
	local act = row and state.row_actions[row] or nil
	if not act then
		return
	end
	if act.kind == "project" then
		if not act.is_empty_leaf then
			state.collapsed_projects[act.path] = not act.collapsed
			render.render()
		end
	elseif act.kind == "worktree" then
		if not act.is_empty_leaf then
			state.collapsed_worktrees[act.path] = not act.collapsed
			render.render()
		end
	elseif act.worktree_path and act.worktree_row then
		local parent_act = state.row_actions[act.worktree_row]
		local next_collapsed = not (parent_act and parent_act.collapsed == true)
		state.collapsed_worktrees[act.worktree_path] = next_collapsed
		if next_collapsed and state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
			pcall(vim.api.nvim_win_set_cursor, state.sidebar_win, { act.worktree_row, 0 })
		end
		render.render()
	elseif act.project_path and act.project_row then
		local parent_act = state.row_actions[act.project_row]
		local next_collapsed = not (parent_act and parent_act.collapsed == true)
		state.collapsed_projects[act.project_path] = next_collapsed
		if next_collapsed and state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
			pcall(vim.api.nvim_win_set_cursor, state.sidebar_win, { act.project_row, 0 })
		end
		render.render()
	end
end

---Determine whether a mouse click at `(act, clicked_col)` should keep focus in the sidebar rather than jumping to `main_win`.
---@param act table|nil
---@param clicked_col integer
---@return boolean
local function should_mouse_keep_sidebar(act, clicked_col)
	local clicked_plus = act ~= nil and act.plus_col_1idx ~= nil and clicked_col >= act.plus_col_1idx
	local clicked_help = act ~= nil and act.help_col_1idx ~= nil and clicked_col >= act.help_col_1idx
	if clicked_help then
		return true
	end
	if clicked_plus then
		return false
	end
	return act == nil
		or (act.kind == "project" and not act.is_empty_leaf)
		or (act.kind == "worktree" and not act.is_empty_leaf)
		or act.kind == "projects_header"
		or act.kind == "add_project"
		or act.kind == "toggle_project_all"
		or act.kind == "toggle_worktree_all"
		or act.kind == "filter"
		or act.kind == "help"
		or act.kind == "history_picker"
end

---Execute a scheduled mouse click inside the sidebar window.
---@param clicked_line integer
---@param clicked_col integer
local function handle_sidebar_mouse_click(clicked_line, clicked_col)
	if vim.fn.mode():sub(1, 1) == "i" then
		vim.cmd("stopinsert")
	end
	if state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
		pcall(vim.api.nvim_win_set_cursor, state.sidebar_win, { clicked_line, 0 })
	end
	local act = state.row_actions[clicked_line]
	local keep_sidebar = should_mouse_keep_sidebar(act, clicked_col)
	M.activate_row(clicked_line, not keep_sidebar, clicked_col)
end

---Build an expr-keymap handler intercepting clicks targeting `state.sidebar_win`.
---@param fallback_key string
---@return fun(): string
local function make_sidebar_mouse_expr(fallback_key)
	return function()
		if state_mod.is_current_tab() and state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
			local pos = vim.fn.getmousepos()
			if pos.winid == state.sidebar_win and pos.line >= 1 then
				local clicked_line = pos.line
				local clicked_col = pos.column
				vim.schedule(function()
					handle_sidebar_mouse_click(clicked_line, clicked_col)
				end)
				if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
					return "<C-\\><C-n>"
				end
				return "<Ignore>"
			end
		end
		return fallback_key
	end
end

---Configure sidebar buffer options and keymaps.
---@param buf number
function M.setup_sidebar_buf(buf)
	vim.bo[buf].filetype = "cc-workspace"
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].buflisted = false
	vim.bo[buf].undolevels = -1
	vim.bo[buf].modifiable = false
	state.sidebar_buf_ready = buf

	local sb_group = vim.api.nvim_create_augroup("CcWorkspaceSidebarBuf", { clear = true })
	vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
		group = sb_group,
		buffer = buf,
		callback = function()
			vim.cmd("stopinsert")
		end,
	})

	local opts = { buffer = buf, nowait = true, silent = true }
	vim.keymap.set("n", "<CR>", function()
		M.activate_row(state_mod.get_sidebar_row(), true)
	end, opts)
	vim.keymap.set("n", "l", handle_key_expand_or_open, opts)
	vim.keymap.set("n", "<Right>", function()
		vim.api.nvim_feedkeys("l", "m", false)
	end, opts)
	vim.keymap.set("n", "h", handle_key_collapse_or_parent, opts)
	vim.keymap.set("n", "<Left>", function()
		vim.api.nvim_feedkeys("h", "m", false)
	end, opts)
	vim.keymap.set("n", "za", handle_key_toggle_fold, opts)
	vim.keymap.set("n", "zM", function()
		state.focus_project_path = cursor_project_path() or state.focus_project_path
		for _, p in ipairs(state.rendered_project_paths or {}) do
			state.collapsed_projects[p] = true
		end
		for _, wp in ipairs(state.rendered_worktree_paths or {}) do
			state.collapsed_worktrees[wp] = true
		end
		render.render()
	end, opts)
	vim.keymap.set("n", "zR", function()
		state.focus_project_path = cursor_project_path() or state.focus_project_path
		state.collapsed_projects = {}
		for _, p in ipairs(state.rendered_project_paths or {}) do
			state.collapsed_projects[p] = false
		end
		state.collapsed_worktrees = {}
		render.render()
	end, opts)
	vim.keymap.set("n", "p", function()
		M.activate_row(state_mod.get_sidebar_row(), false)
	end, opts)
	vim.keymap.set("n", "<Space>", function()
		M.activate_row(state_mod.get_sidebar_row(), false)
	end, opts)
	vim.keymap.set("n", "<Tab>", function()
		step_action_row(1)
	end, opts)
	vim.keymap.set("n", "<S-Tab>", function()
		step_action_row(-1)
	end, opts)
	vim.keymap.set("n", "]c", function()
		step_action_row(1)
	end, opts)
	vim.keymap.set("n", "[c", function()
		step_action_row(-1)
	end, opts)
	for idx = 1, 9 do
		vim.keymap.set("n", tostring(idx), function()
			local target = state.active_chats[idx]
			if target and vim.api.nvim_buf_is_valid(target.bufnr) then
				layout.show_chat(target, true)
			end
		end, opts)
	end
	vim.keymap.set("n", "n", function()
		layout.new_chat(true, cursor_target_path())
	end, opts)
	vim.keymap.set("n", "N", function()
		pickers.prompt_new_project_chat()
	end, opts)
	vim.keymap.set("n", "w", function()
		pickers.prompt_create_worktree_chat()
	end, opts)
	vim.keymap.set("n", "u", function()
		local wt = state_mod.get_wt()
		if wt and type(wt.jump_to_attention) == "function" then
			wt.jump_to_attention()
		end
	end, opts)
	vim.keymap.set("n", "a", function()
		pickers.prompt_add_project()
	end, opts)
	vim.keymap.set("n", "+", function()
		pickers.prompt_add_project()
	end, opts)
	vim.keymap.set("n", "A", function()
		pickers.prompt_add_project_input()
	end, opts)
	vim.keymap.set("n", "o", function()
		local p = cursor_target_path()
		if p then
			layout.open_project_in_code_tab(p)
		end
	end, opts)
	vim.keymap.set("n", "r", rename_current_row, opts)
	vim.keymap.set("n", "d", delete_current_row, opts)
	vim.keymap.set("n", "x", delete_current_row, opts)
	vim.keymap.set("n", "K", inspect_current_row, opts)
	vim.keymap.set("n", "y", function()
		M.yank_row_path(false)
	end, opts)
	vim.keymap.set("n", "gy", function()
		M.yank_row_path(false)
	end, opts)
	vim.keymap.set("n", "Y", function()
		M.yank_row_path(true)
	end, opts)
	vim.keymap.set("n", "f", prompt_filter, opts)
	vim.keymap.set("n", "F", function()
		if state.filter ~= "" then
			state.filter = ""
			render.render()
		end
	end, opts)
	vim.keymap.set("n", "s", open_full_history, opts)
	vim.keymap.set("n", "gh", open_full_history, opts)
	vim.keymap.set("n", "R", function()
		state_mod.clear_path_caches()
		local wt = state_mod.get_wt()
		if wt and type(wt.invalidate_git_cache) == "function" then
			pcall(wt.invalidate_git_cache)
		end
		render.render()
	end, opts)
	vim.keymap.set("n", "?", M.show_help_float, opts)
	vim.keymap.set("n", "g?", M.show_help_float, opts)
	vim.keymap.set("n", "q", layout.leave, opts)
	vim.keymap.set("n", "Q", layout.close, opts)

	local mouse_opts = { buffer = buf, nowait = true, silent = true, expr = true }
	vim.keymap.set("n", "<LeftMouse>", make_sidebar_mouse_expr("<LeftMouse>"), mouse_opts)
	vim.keymap.set("n", "<2-LeftMouse>", make_sidebar_mouse_expr("<2-LeftMouse>"), mouse_opts)
	vim.keymap.set({ "n", "i" }, "<LeftMouse>", make_sidebar_mouse_expr("<LeftMouse>"), { silent = true, expr = true })
end

state.actions.setup_sidebar_buf = M.setup_sidebar_buf
if
	state.sidebar_buf
	and vim.api.nvim_buf_is_valid(state.sidebar_buf)
	and state.sidebar_buf_ready ~= state.sidebar_buf
then
	M.setup_sidebar_buf(state.sidebar_buf)
end

return M
