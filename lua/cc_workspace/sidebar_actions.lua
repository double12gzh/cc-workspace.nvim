local icons = require("cc_workspace.icons")
local layout = require("cc_workspace.layout")
local patches = require("cc_workspace.patches")
local projects = require("cc_workspace.projects")
local render = require("cc_workspace.render")
local state_mod = require("cc_workspace.state")

local state = state_mod.state

local M = {}

---Open CodeCompanion history picker with workspace CWD/UI patches applied.
function M.open_full_history()
	require("codecompanion")
	patches.patch_history_ui()
	pcall(function()
		vim.cmd("CodeCompanionHistory")
	end)
end

---Prompt for a keyword to filter sidebar conversations and projects.
function M.prompt_filter()
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

---Clear any active keyword filter and re-render the sidebar.
function M.clear_filter()
	if state.filter ~= "" then
		state.filter = ""
		render.render()
	end
end

---Invalidate cached paths/worktrees and force an immediate sidebar re-render.
function M.refresh_sidebar()
	state_mod.clear_path_caches()
	local wt = state_mod.get_wt()
	if wt and type(wt.invalidate_git_cache) == "function" then
		pcall(wt.invalidate_git_cache)
	end
	render.render()
end

---Rename an active/saved conversation or a Project display alias under the cursor.
function M.rename_current_row()
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
	if vim.fn.confirm(prompt_msg, buttons, 2) ~= 1 then
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
		if vim.fn.confirm("Remove project '" .. disp .. "' from AI Workspace?", "&Yes\n&No", 2) == 1 then
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
		elseif
			vim.fn.confirm(
				string.format("Remove project '%s' and close %d active conversation(s)?", disp, active_n),
				"&Yes\n&No",
				2
			) == 1
		then
			projects.remove_project(act.path, { hide = is_cur_cwd or act.path == "Other", close_active = true })
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
function M.delete_current_row()
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
	elseif act.kind == "project" then
		delete_project_row(act)
	elseif act.kind == "active_chat" and act.chat then
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
		if vim.fn.confirm("Delete saved chat '" .. (act.title or act.save_id) .. "'?", "&Yes\n&No", 2) == 1 then
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
function M.inspect_current_row()
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
					table.insert(parts, string.format("  • %s %s%s: %s", br_icon, br, w.dirty and "*" or "", wp))
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
	local out, seen = {}, {}
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
---@param all_paths? boolean
---@return string[]|nil
function M.yank_row_path(all_paths)
	local wt = state_mod.get_wt()
	local row = state_mod.get_sidebar_row()
	local act = row and state.row_actions[row] or nil
	local paths, seen = {}, {}
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
function M.cursor_target_path()
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
	return (type(p) == "string" and p ~= "" and p ~= "Other") and p or nil
end

---Resolve the parent Project path under the sidebar cursor (`zM` / `zR`).
---@return string|nil
function M.cursor_project_path()
	local row = state_mod.get_sidebar_row()
	local act = row and state.row_actions[row] or nil
	if not act then
		return nil
	end
	local p = act.project_path or act.path
	return (type(p) == "string" and p ~= "" and p ~= "Other") and p or nil
end

return M
