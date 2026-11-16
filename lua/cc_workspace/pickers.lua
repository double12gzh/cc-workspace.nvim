local icons = require("cc_workspace.icons")
local layout = require("cc_workspace.layout")
local projects = require("cc_workspace.projects")
local render = require("cc_workspace.render")
local state_mod = require("cc_workspace.state")

local state = state_mod.state

local M = {}

---Handle interactive path string entered by the user (creating missing directory if confirmed).
---@param input string|nil
local function handle_interactive_project_path(input)
	if input == nil then
		return
	end
	local trimmed = vim.trim(input)
	if trimmed == "" then
		return
	end
	local expanded = projects.expand_raw_dir_path(trimmed)
	if not expanded then
		local added = projects.add_project(trimmed)
		if added then
			layout.activate_project(added.path, true)
		end
		return
	end
	if vim.fn.isdirectory(expanded) ~= 1 and vim.uv.fs_lstat(expanded) == nil then
		local choice = vim.fn.confirm(
			string.format("Directory does not exist:\n%s\n\nCreate it and add as Project?", expanded),
			"&Create & Add\n&Cancel",
			2
		)
		if choice == 1 then
			local added = projects.add_project(expanded, { create = true })
			if added then
				layout.activate_project(added.path, true)
			end
		end
		return
	end
	local added = projects.add_project(expanded)
	if added then
		layout.activate_project(added.path, true)
	end
end

---Prompt for a directory path with native `<Tab>` directory completion and add it as a Project.
---@param default_text? string
function M.prompt_add_project_input(default_text)
	if vim.fn.mode():sub(1, 1) == "i" then
		vim.cmd("stopinsert")
	end
	local base = default_text
	if type(base) ~= "string" or base == "" then
		local parent = vim.fs.dirname(projects.get_global_cwd())
		local home = vim.uv.os_homedir() or vim.fn.expand("~")
		base = (parent and parent ~= "") and (vim.fn.fnamemodify(parent, ":~") .. "/") or (home .. "/")
	end
	vim.ui.input({
		prompt = "Add Project directory: ",
		default = base,
		completion = "dir",
	}, handle_interactive_project_path)
end

---Format a project row for Telescope with display-width-accurate column alignment (CJK-safe).
---@param name string
---@param path_short string
---@param suffix string
---@return string
local function format_picker_project_row(name, path_short, suffix)
	local fit_name = state_mod.truncate_display(name, 24)
	local pad = math.max(1, 25 - vim.fn.strdisplaywidth(fit_name))
	return string.format(" %s %s%s%s%s", icons.ui.Folder, fit_name, string.rep(" ", pad), path_short, suffix)
end

---Build Telescope entries for `prompt_add_project`.
---@param candidates table[]
---@return table[]
local function build_add_project_entries(candidates)
	local entries = {
		{
			is_custom_input = true,
			display = " + Browse / type custom directory path (Tab completion)…",
			ordinal = "custom input browse path directory add new",
		},
	}
	for _, c in ipairs(candidates) do
		local bname = projects.project_basename(c.path)
		local short = vim.fn.fnamemodify(c.path, ":~")
		local tags = {}
		if c.is_cwd then
			table.insert(tags, "cwd")
		end
		if c.is_git then
			table.insert(tags, "git")
		end
		if c.pinned then
			table.insert(tags, "added")
		else
			table.insert(tags, c.source)
		end
		local suffix = #tags > 0 and string.format("  [%s]", table.concat(tags, ", ")) or ""
		table.insert(entries, {
			path = c.path,
			short = short,
			pinned = c.pinned,
			display = format_picker_project_row(bname, short, suffix),
			ordinal = string.format("%s %s %s", bname, short, c.path),
		})
	end
	return entries
end

---Process `<Tab>` multi-selected entries in `prompt_add_project`.
---@param multi table[]
---@param selection table|nil
---@return boolean handled
local function handle_multi_selected_add_projects(multi, selection)
	if type(multi) ~= "table" or #multi == 0 then
		return false
	end
	local multi_paths = {}
	local multi_seen = {}
	for _, entry in ipairs(multi) do
		local val = type(entry) == "table" and (entry.value or entry) or nil
		local p = (type(val) == "table" and not val.is_custom_input) and val.path or nil
		if type(p) == "string" and p ~= "" and not multi_seen[p] then
			multi_seen[p] = true
			table.insert(multi_paths, p)
		end
	end
	if #multi_paths == 0 then
		return false
	end

	local added_paths = {}
	local added_set = {}
	for _, p in ipairs(multi_paths) do
		local added = projects.add_project(p, { silent = true, skip_render = true, skip_save = true })
		if added and added.path then
			state.collapsed_projects[added.path] = false
			if not added_set[added.path] then
				added_set[added.path] = true
				table.insert(added_paths, added.path)
			end
		end
	end
	if #added_paths == 0 then
		return true
	end

	local ok_save, save_err = projects.save_projects_store(projects.load_projects_store())
	state_mod.clear_path_caches()
	if not ok_save then
		vim.notify("Failed to save projects: " .. tostring(save_err), vim.log.levels.ERROR, { title = "AI Workspace" })
		return true
	end

	local cur_val = type(selection) == "table" and (selection.value or selection) or nil
	local cur_norm = (type(cur_val) == "table" and cur_val.path) and projects.normalize_project_path(cur_val.path)
		or nil
	local open_target = (cur_norm and added_set[cur_norm]) and cur_norm or added_paths[1]
	vim.notify(
		string.format("Added %d project%s to AI Workspace", #added_paths, #added_paths == 1 and "" or "s"),
		vim.log.levels.INFO,
		{ title = "AI Workspace" }
	)
	if not layout.activate_project(open_target, true) and state_mod.is_workspace_valid() then
		render.render()
	end
	return true
end

---Handle `<CR>` confirmation inside `prompt_add_project` Telescope picker.
---@param prompt_bufnr integer
---@param actions table
---@param action_state table
local function handle_add_project_confirm(prompt_bufnr, actions, action_state)
	local picker = action_state.get_current_picker(prompt_bufnr)
	local multi = (picker and type(picker.get_multi_selection) == "function") and picker:get_multi_selection() or {}
	local sel_row = (picker and type(picker.get_selection_row) == "function") and picker:get_selection_row() or 0
	local selection = action_state.get_selected_entry()
	local prompt_line = vim.trim(action_state.get_current_line() or "")
	if picker then
		pcall(actions.close, prompt_bufnr)
	end
	if vim.fn.mode():sub(1, 1) == "i" then
		vim.cmd("stopinsert")
	end

	if handle_multi_selected_add_projects(multi, selection) then
		return
	end

	local looks_like_path = prompt_line ~= ""
		and (prompt_line:match("^[~/%.$]") or prompt_line:match("^['\"][~/%.$]") or prompt_line:match("^%a:[/\\]"))
	local expanded_prompt = looks_like_path and projects.expand_raw_dir_path(prompt_line) or nil

	-- If user typed a literal path without arrowing down to a specific candidate row:
	-- 1) If that typed path is an existing directory (not bare `~` or `/`), prefer the exact typed directory.
	-- 2) If that typed path is not even a literal substring of the fuzzy-selected candidate, treat as custom path.
	if expanded_prompt and sel_row == 0 then
		local is_bare_root = (
			prompt_line == "/"
			or prompt_line == "~"
			or prompt_line == "~/"
			or prompt_line == "."
			or prompt_line == "./"
		)
		if not is_bare_root and vim.fn.isdirectory(expanded_prompt) == 1 then
			local added = projects.add_project(expanded_prompt)
			if added then
				layout.activate_project(added.path, true)
			end
			return
		end
		if selection and selection.value and selection.value.path then
			local cand_p = selection.value.path:lower()
			local cand_s = (selection.value.short or ""):lower()
			local pl_lc = prompt_line:lower()
			if not cand_p:find(pl_lc, 1, true) and not cand_s:find(pl_lc, 1, true) then
				vim.schedule(function()
					handle_interactive_project_path(prompt_line)
				end)
				return
			end
		end
	end

	if selection and selection.value then
		if selection.value.is_custom_input then
			if expanded_prompt and prompt_line ~= "~" and prompt_line ~= "~/" and prompt_line ~= "/" then
				vim.schedule(function()
					handle_interactive_project_path(prompt_line)
				end)
				return
			end
			local seed = (looks_like_path or prompt_line:find("/", 1, true)) and prompt_line or nil
			vim.schedule(function()
				M.prompt_add_project_input(seed)
			end)
			return
		end
		if selection.value.path then
			local was_pinned = selection.value.pinned == true
			local added = projects.add_project(selection.value.path, { silent = was_pinned })
			local target_path = (added and added.path) or selection.value.path
			layout.activate_project(target_path, true)
			return
		end
	end

	if prompt_line ~= "" then
		vim.schedule(function()
			handle_interactive_project_path(prompt_line)
		end)
	end
end

---Open an interactive picker (Telescope or fallback input) to add Project(s) to AI Workspace and open in `main_win`.
function M.prompt_add_project()
	if vim.fn.mode():sub(1, 1) == "i" then
		vim.cmd("stopinsert")
	end
	local ok_pickers, pickers = pcall(require, "telescope.pickers")
	local ok_finders, finders = pcall(require, "telescope.finders")
	local ok_conf, conf_mod = pcall(require, "telescope.config")
	local ok_actions, actions = pcall(require, "telescope.actions")
	local ok_state, action_state = pcall(require, "telescope.actions.state")
	if not (ok_pickers and ok_finders and ok_conf and ok_actions and ok_state) then
		M.prompt_add_project_input()
		return
	end

	local entries = build_add_project_entries(projects.get_candidate_projects())

	pickers
		.new({}, {
			prompt_title = "Add Project to AI Workspace (<Tab>: multi · <CR>: add & open · <C-g>: path)",
			finder = finders.new_table({
				results = entries,
				entry_maker = function(item)
					return {
						value = item,
						display = item.display,
						ordinal = item.ordinal,
					}
				end,
			}),
			sorter = conf_mod.values.generic_sorter({}),
			layout_strategy = "horizontal",
			layout_config = {
				width = 0.68,
				height = 0.62,
				prompt_position = "top",
			},
			sorting_strategy = "ascending",
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					handle_add_project_confirm(prompt_bufnr, actions, action_state)
				end)
				local function switch_to_dir_input()
					local prompt_line = vim.trim(action_state.get_current_line() or "")
					if action_state.get_current_picker(prompt_bufnr) then
						pcall(actions.close, prompt_bufnr)
					end
					vim.schedule(function()
						M.prompt_add_project_input(prompt_line ~= "" and prompt_line or nil)
					end)
				end
				map("i", "<C-g>", switch_to_dir_input)
				map("n", "<C-g>", switch_to_dir_input)
				return true
			end,
		})
		:find()
end

---Build selectable Project items for `prompt_new_project_chat`.
---@return table[]
local function build_new_project_chat_items()
	local store = projects.load_projects_store()
	local pinned_map = projects.get_pinned_map(store)
	local seen = {}
	local descriptors = {}

	local function push_proj(p, tag)
		local norm = projects.normalize_project_path(p)
		if not norm or seen[norm] or vim.fn.isdirectory(norm) ~= 1 then
			return
		end
		seen[norm] = true
		local pinned = pinned_map[norm]
		table.insert(descriptors, {
			path = norm,
			custom_name = pinned and pinned.name or nil,
			tag = tag,
		})
	end

	push_proj(projects.get_global_cwd(), "cwd")
	for _, e in ipairs(store.projects) do
		push_proj(e.path, "project")
	end
	local cc = package.loaded["codecompanion"]
	local history_ext = cc and cc.extensions and cc.extensions.history
	local saved_map = state_mod.get_cached_history_chats(history_ext)
	for _, item in pairs(saved_map) do
		if type(item) == "table" then
			push_proj(projects.resolve_item_project_path(item.cwd, item.project_root, pinned_map), "history")
		end
	end

	projects.assign_project_display_names(descriptors)

	local items = {}
	for _, d in ipairs(descriptors) do
		local short = vim.fn.fnamemodify(d.path, ":~")
		local suffix = d.tag and string.format("  [%s]", d.tag) or ""
		table.insert(items, {
			path = d.path,
			display = format_picker_project_row(d.display_name, short, suffix),
			ordinal = string.format("%s %s %s", d.display_name, short, d.path),
			label = string.format("%s  (%s)%s", d.display_name, short, suffix),
		})
	end
	table.insert(items, {
		add_new = true,
		display = " + Add another Project directory…",
		ordinal = "add another new project directory",
		label = "+ Add another Project directory…",
	})
	return items
end

---Handle single project choice in `prompt_new_project_chat`.
---@param choice table|nil
local function on_new_project_chat_choice(choice)
	if not choice then
		return
	end
	if choice.add_new then
		M.prompt_add_project()
		return
	end
	if choice.path then
		if not state_mod.is_current_tab() then
			layout.enter(false, { skip_auto_chat = true })
		end
		layout.new_chat(true, choice.path)
	end
end

---Spawn conversations across `<Tab>` multi-selected projects in `prompt_new_project_chat`.
---@param multi table[]
---@param selection table|nil
---@return boolean handled
local function handle_multi_selected_project_chats(multi, selection)
	if type(multi) ~= "table" or #multi == 0 then
		return false
	end
	local multi_paths = {}
	local multi_seen = {}
	for _, entry in ipairs(multi) do
		local val = type(entry) == "table" and (entry.value or entry) or nil
		local p = (type(val) == "table" and not val.add_new) and val.path or nil
		if type(p) == "string" and p ~= "" and not multi_seen[p] then
			multi_seen[p] = true
			table.insert(multi_paths, p)
		end
	end
	if #multi_paths == 0 then
		return false
	end

	if not state_mod.is_current_tab() or not state_mod.is_workspace_valid() then
		layout.enter(true, { skip_auto_chat = true })
	end
	local cur_val = type(selection) == "table" and (selection.value or selection) or nil
	local cur_p = (type(cur_val) == "table" and cur_val.path and multi_seen[cur_val.path]) and cur_val.path
		or multi_paths[#multi_paths]
	local focus_chat = nil
	for _, p in ipairs(multi_paths) do
		local created = layout.new_chat(false, p, { skip_show = true })
		if p == cur_p and created then
			focus_chat = created
		elseif created and not focus_chat then
			focus_chat = created
		end
	end
	if focus_chat then
		layout.show_chat(focus_chat, true)
	elseif state_mod.is_workspace_valid() then
		render.render()
	end
	if #multi_paths > 1 then
		vim.notify(
			string.format("Started %d conversations across selected projects", #multi_paths),
			vim.log.levels.INFO,
			{ title = "AI Workspace" }
		)
	end
	return true
end

---Handle `<CR>` confirmation inside `prompt_new_project_chat` Telescope picker.
---@param prompt_bufnr integer
---@param actions table
---@param action_state table
local function handle_new_project_chat_confirm(prompt_bufnr, actions, action_state)
	local picker = action_state.get_current_picker(prompt_bufnr)
	local multi = (picker and type(picker.get_multi_selection) == "function") and picker:get_multi_selection() or {}
	local selection = action_state.get_selected_entry()
	if picker then
		pcall(actions.close, prompt_bufnr)
	end
	if vim.fn.mode():sub(1, 1) == "i" then
		vim.cmd("stopinsert")
	end
	if handle_multi_selected_project_chats(multi, selection) then
		return
	end
	if selection and selection.value then
		vim.schedule(function()
			on_new_project_chat_choice(selection.value)
		end)
	end
end

---Pick Project(s) (supporting `<Tab>` multi-selection) and start a new conversation in each.
function M.prompt_new_project_chat()
	if vim.fn.mode():sub(1, 1) == "i" then
		vim.cmd("stopinsert")
	end
	local items = build_new_project_chat_items()

	local ok_pickers, pickers = pcall(require, "telescope.pickers")
	local ok_finders, finders = pcall(require, "telescope.finders")
	local ok_conf, conf_mod = pcall(require, "telescope.config")
	local ok_actions, actions = pcall(require, "telescope.actions")
	local ok_state, action_state = pcall(require, "telescope.actions.state")
	if not (ok_pickers and ok_finders and ok_conf and ok_actions and ok_state) then
		vim.ui.select(items, {
			prompt = "Start new conversation in Project:",
			format_item = function(item)
				return item.label
			end,
		}, on_new_project_chat_choice)
		return
	end

	pickers
		.new({}, {
			prompt_title = "New Conversation in Project (<Tab>: multi · <CR>: start)",
			finder = finders.new_table({
				results = items,
				entry_maker = function(item)
					return {
						value = item,
						display = item.display,
						ordinal = item.ordinal,
					}
				end,
			}),
			sorter = conf_mod.values.generic_sorter({}),
			layout_strategy = "horizontal",
			layout_config = {
				width = 0.62,
				height = 0.52,
				prompt_position = "top",
			},
			sorting_strategy = "ascending",
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					handle_new_project_chat_confirm(prompt_bufnr, actions, action_state)
				end)
				return true
			end,
		})
		:find()
end

---Launch `wt.prompt_create_worktree` for `repo_root` and spawn an Agent Chat in the created worktree.
---@param wt table
---@param repo_root string
local function launch_worktree_for_repo(wt, repo_root)
	wt.prompt_create_worktree(repo_root, function(info)
		if not info or type(info.path) ~= "string" or info.path == "" then
			return
		end
		local wt_path = projects.normalize_project_path(info.path) or info.path
		state.collapsed_projects[repo_root] = false
		state.collapsed_worktrees[wt_path] = false
		state.last_selected_project = wt_path
		state.focus_worktree_path = wt_path
		if not state_mod.is_current_tab() or not state_mod.is_workspace_valid() then
			layout.enter(true, { skip_auto_chat = true })
		end
		layout.new_chat(true, wt_path)
	end)
end

---Collect ordered candidate paths to resolve the focused Git repository for worktree creation.
---@return string[] candidates, table|nil direct_project_act
local function collect_worktree_context_candidates()
	local candidates = {}
	if state_mod.is_current_tab() and state_mod.is_workspace_valid() then
		local row = state_mod.get_sidebar_row()
		local act = row and state.row_actions[row] or nil
		if act then
			if act.kind == "project" and act.path and act.path ~= "Other" then
				return candidates, act
			end
			if act.repo_root then
				table.insert(candidates, act.repo_root)
			end
			if act.worktree_path then
				table.insert(candidates, act.worktree_path)
			end
			if act.chat then
				local ccwd = projects.get_valid_chat_cwd(act.chat)
				if ccwd then
					table.insert(candidates, ccwd)
				end
			end
			if act.path and act.path ~= "Other" then
				table.insert(candidates, act.path)
			end
			if act.project_path and act.project_path ~= "Other" then
				table.insert(candidates, act.project_path)
			end
		end
		if state.main_win and vim.api.nvim_win_is_valid(state.main_win) then
			local chat_mod = package.loaded["codecompanion.interactions.chat"]
			local mbuf = vim.api.nvim_win_get_buf(state.main_win)
			local mchat = chat_mod and chat_mod.buf_get_chat(mbuf) or nil
			local mcwd = mchat and projects.get_valid_chat_cwd(mchat) or nil
			if mcwd then
				table.insert(candidates, mcwd)
			end
		end
	else
		local ctx_dir = projects.resolve_context_project_dir(vim.api.nvim_get_current_buf())
		if ctx_dir then
			table.insert(candidates, ctx_dir)
		end
	end
	if state.last_selected_project then
		table.insert(candidates, state.last_selected_project)
	end
	table.insert(candidates, projects.get_global_cwd())
	return candidates, nil
end

---Collect fallback Git repositories from rendered sidebar projects and pinned projects.
---@param wt table
---@return string[]
local function collect_fallback_git_repos(wt)
	local git_repos = {}
	local seen_repos = {}
	local store = projects.load_projects_store()
	local pool = {}
	for _, p in ipairs(state.rendered_project_paths or {}) do
		table.insert(pool, p)
	end
	for _, e in ipairs(store.projects) do
		table.insert(pool, e.path)
	end
	for _, p in ipairs(pool) do
		local r = (p ~= "Other" and type(wt.get_repo_root) == "function") and wt.get_repo_root(p) or nil
		local nr = r and projects.normalize_project_path(r) or nil
		if nr and not seen_repos[nr] and vim.fn.isdirectory(nr) == 1 then
			seen_repos[nr] = true
			table.insert(git_repos, nr)
		end
	end
	return git_repos
end

---Interactive Git Worktree creation flow (`w` / `[+w]` / `:CodeCompanionWorkspaceWorktree`) that spawns a chat in the new worktree.
---@param repo_or_dir? string
function M.prompt_create_worktree_chat(repo_or_dir)
	if vim.fn.mode():sub(1, 1) == "i" then
		vim.cmd("stopinsert")
	end
	local wt = state_mod.get_wt()
	if not wt or type(wt.prompt_create_worktree) ~= "function" then
		vim.notify("Git Worktree module is unavailable", vim.log.levels.ERROR, { title = "AI Workspace" })
		return
	end
	if type(wt.setup) == "function" then
		pcall(wt.setup)
	end

	if type(repo_or_dir) == "string" and vim.trim(repo_or_dir) ~= "" then
		local expanded = projects.expand_raw_dir_path(repo_or_dir) or projects.normalize_project_path(repo_or_dir)
		if not expanded or vim.fn.isdirectory(expanded) ~= 1 then
			vim.notify(
				"Directory does not exist: " .. tostring(repo_or_dir),
				vim.log.levels.WARN,
				{ title = "Git Worktree" }
			)
			return
		end
		local r = type(wt.get_repo_root) == "function" and wt.get_repo_root(expanded) or nil
		if not r then
			vim.notify("Not a Git repository: " .. expanded, vim.log.levels.WARN, { title = "Git Worktree" })
			return
		end
		launch_worktree_for_repo(wt, projects.normalize_project_path(r) or r)
		return
	end

	local candidates, direct_proj_act = collect_worktree_context_candidates()
	if direct_proj_act then
		local direct_r = type(wt.get_repo_root) == "function" and wt.get_repo_root(direct_proj_act.path) or nil
		if not direct_r then
			vim.notify(
				string.format("Project '%s' is not a Git repository", direct_proj_act.name or direct_proj_act.path),
				vim.log.levels.WARN,
				{ title = "Git Worktree" }
			)
			return
		end
		launch_worktree_for_repo(wt, projects.normalize_project_path(direct_r) or direct_r)
		return
	end

	for _, cand in ipairs(candidates) do
		local r = type(wt.get_repo_root) == "function" and wt.get_repo_root(cand) or nil
		if r and vim.fn.isdirectory(r) == 1 then
			launch_worktree_for_repo(wt, projects.normalize_project_path(r) or r)
			return
		end
	end

	local git_repos = collect_fallback_git_repos(wt)
	if #git_repos == 1 then
		launch_worktree_for_repo(wt, git_repos[1])
		return
	elseif #git_repos > 1 then
		vim.ui.select(git_repos, {
			prompt = "Select Git repository for new worktree:",
			format_item = function(r)
				return string.format("%s  (%s)", projects.project_basename(r), vim.fn.fnamemodify(r, ":~"))
			end,
		}, function(chosen)
			if chosen then
				launch_worktree_for_repo(wt, chosen)
			end
		end)
		return
	end

	vim.notify("No Git repository focused or pinned in AI Workspace", vim.log.levels.WARN, { title = "Git Worktree" })
end
M.create_worktree_chat = M.prompt_create_worktree_chat

state.actions.prompt_add_project = M.prompt_add_project
state.actions.prompt_create_worktree_chat = M.prompt_create_worktree_chat

return M
