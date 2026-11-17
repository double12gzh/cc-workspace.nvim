-- Workspace project store CRUD (`cc-workspace-projects.json`), active chat project
-- ownership resolution, and backwards-compatible re-exports from `paths` & `candidates`.

local candidates = require("cc_workspace.candidates")
local config = require("cc_workspace.config")
local paths = require("cc_workspace.paths")
local state_mod = require("cc_workspace.state")

local state = state_mod.state

local M = {
	-- Re-exported path, ancestor disambiguation & CWD isolation helpers (`paths.lua`)
	expand_raw_dir_path = paths.expand_raw_dir_path,
	normalize_project_path = paths.normalize_project_path,
	is_ephemeral_tmp_path = paths.is_ephemeral_tmp_path,
	get_global_cwd = paths.get_global_cwd,
	project_basename = paths.project_basename,
	get_valid_chat_cwd = paths.get_valid_chat_cwd,
	detect_safe_project_root = paths.detect_safe_project_root,
	get_win_cwd = paths.get_win_cwd,
	sync_win_lcd = paths.sync_win_lcd,
	with_temp_cwd = paths.with_temp_cwd,
	buf_within_dir = paths.buf_within_dir,
	compute_buf_rel_path = paths.compute_buf_rel_path,
	find_pinned_ancestor = paths.find_pinned_ancestor,
	assign_project_display_names = paths.assign_project_display_names,

	-- Re-exported candidate discovery (`candidates.lua`)
	warm_zoxide_cache = candidates.warm_zoxide_cache,
}

---Return the JSON file path used to persist AI Workspace projects.
---@return string
function M.get_projects_file()
	if type(state.projects_file) == "string" and state.projects_file ~= "" then
		return state.projects_file
	end
	local cfg_file = config.options and config.options.projects_file or nil
	if type(cfg_file) == "string" and cfg_file ~= "" then
		return cfg_file
	end
	return vim.fs.joinpath(vim.fn.stdpath("data"), "cc-workspace-projects.json")
end

---Override the JSON file path used to persist AI Workspace projects (useful for isolated tests).
---@param path string|nil
function M.set_projects_file(path)
	state.projects_file = (type(path) == "string" and path ~= "") and path or nil
	state.projects_cache = nil
	state.projects_mtime = nil
	state_mod.clear_path_caches()
end

local function decode_projects_payload(raw)
	local store = { version = 1, projects = {}, hidden = {} }
	local ok, decoded = pcall(vim.json.decode, raw)
	if not ok or type(decoded) ~= "table" then
		return store
	end
	local seen = {}
	local raw_projects = type(decoded.projects) == "table" and decoded.projects or decoded
	for _, item in ipairs(raw_projects) do
		local p = type(item) == "table" and paths.normalize_project_path(item.path)
			or (type(item) == "string" and paths.normalize_project_path(item))
			or nil
		if p and not seen[p] then
			seen[p] = true
			local custom_name = (type(item) == "table" and type(item.name) == "string" and vim.trim(item.name) ~= "")
					and vim.trim(item.name)
				or nil
			local added_at = (type(item) == "table" and type(item.added_at) == "number") and item.added_at or 0
			table.insert(store.projects, { path = p, name = custom_name, added_at = added_at })
		end
	end
	if type(decoded.hidden) == "table" then
		for k, v in pairs(decoded.hidden) do
			if type(k) == "string" and v == true then
				store.hidden[paths.normalize_project_path(k) or k] = true
			elseif type(v) == "string" then
				store.hidden[paths.normalize_project_path(v) or v] = true
			end
		end
	end
	return store
end

---Load persisted project entries and hidden project paths from disk with mtime caching.
---@return { version: integer, projects: { path: string, name?: string, added_at: integer, [string]: any }[], hidden: table<string, boolean> }
function M.load_projects_store()
	local file = M.get_projects_file()
	local stat = vim.uv.fs_stat(file)
	if not stat then
		if state.projects_cache and state.projects_mtime == "missing" then
			return state.projects_cache
		end
		local empty = { version = 1, projects = {}, hidden = {} }
		state.projects_cache, state.projects_mtime, state.history_proj_cache = empty, "missing", {}
		return empty
	end
	local mtime_key = string.format("%d:%d:%d", stat.mtime.sec or 0, stat.mtime.nsec or 0, stat.size or 0)
	if state.projects_cache and state.projects_mtime == mtime_key then
		return state.projects_cache
	end

	local store = { version = 1, projects = {}, hidden = {} }
	local f = io.open(file, "r")
	if f then
		local raw = f:read("*a")
		f:close()
		store = decode_projects_payload(raw)
	end
	state.projects_cache, state.projects_mtime, state.history_proj_cache = store, mtime_key, {}
	return store
end

---Persist the workspace projects store to disk.
---@param store { version?: integer, projects: table[], hidden?: table<string, boolean> }
---@return boolean ok, string|nil err
function M.save_projects_store(store)
	local file = M.get_projects_file()
	local parent = vim.fs.dirname(file)
	if parent and parent ~= "" then
		pcall(vim.fn.mkdir, parent, "p")
	end
	local payload = { version = 1, projects = store.projects or {}, hidden = store.hidden or {} }
	local ok_enc, encoded = pcall(vim.json.encode, payload)
	if not ok_enc or type(encoded) ~= "string" then
		return false, "Failed to encode projects JSON"
	end
	local f, open_err = io.open(file, "w")
	if not f then
		return false, open_err or ("Cannot write " .. file)
	end
	f:write(encoded)
	f:close()
	local stat = vim.uv.fs_stat(file)
	state.projects_cache = payload
	state.projects_mtime = stat and string.format("%d:%d:%d", stat.mtime.sec or 0, stat.mtime.nsec or 0, stat.size or 0)
		or nil
	return true, nil
end

---Build lookup map of pinned projects keyed by canonical path.
---@param store? table
---@return table<string, { path: string, name?: string, added_at: integer }>
function M.get_pinned_map(store)
	store = store or M.load_projects_store()
	local map = {}
	for _, entry in ipairs(store.projects) do
		map[entry.path] = entry
	end
	return map
end

---Resolve which project group path owns a chat/history item (`cwd` + `project_root`), grouping git worktrees under their parent repository.
---@param raw_cwd string|nil
---@param raw_project_root string|nil
---@param pinned_map? table<string, table>
---@return string
function M.resolve_item_project_path(raw_cwd, raw_project_root, pinned_map)
	pinned_map = pinned_map or M.get_pinned_map()
	local ncwd = paths.normalize_project_path(raw_cwd)
	local nroot = paths.normalize_project_path(raw_project_root)
	if ncwd then
		if pinned_map[ncwd] then
			return ncwd
		end
		local best_pinned = nil
		for p in pairs(pinned_map) do
			if p ~= "/" and ncwd:sub(1, #p + 1) == p .. "/" and (not best_pinned or #p > #best_pinned) then
				best_pinned = p
			end
		end
		if best_pinned and (not nroot or #best_pinned >= #nroot) then
			return best_pinned
		end
		local wt = state_mod.get_wt()
		if wt and type(wt.get_repo_root) == "function" then
			local repo_root = wt.get_repo_root(ncwd)
			if type(repo_root) == "string" and repo_root ~= "" then
				return paths.normalize_project_path(repo_root) or repo_root
			end
		end
	end
	if nroot then
		local wt = state_mod.get_wt()
		if wt and type(wt.get_repo_root) == "function" then
			local repo_root = wt.get_repo_root(nroot)
			if type(repo_root) == "string" and repo_root ~= "" then
				return paths.normalize_project_path(repo_root) or repo_root
			end
		end
	end
	return nroot or ncwd or "Other"
end

---Return a deep copy of explicitly added (pinned) workspace projects with disambiguated `display_name`.
---@return { path: string, name?: string, custom_name?: string, base_name: string, display_name: string, added_at: integer }[]
function M.list_projects()
	local list = vim.deepcopy(M.load_projects_store().projects)
	for _, entry in ipairs(list) do
		entry.custom_name = entry.name
	end
	paths.assign_project_display_names(list)
	return list
end

---Resolve the canonical project directory path associated with an active chat.
---@param chat table|nil
---@param pinned_map? table<string, table>
---@return string
function M.get_chat_project_path(chat, pinned_map)
	if type(chat) ~= "table" then
		return paths.get_global_cwd()
	end
	local raw_cwd = (type(chat.opts) == "table" and chat.opts.cwd) or chat.cwd
	if type(raw_cwd) ~= "string" or raw_cwd == "" then
		local ctx_path = type(chat.buffer_context) == "table" and chat.buffer_context.path or nil
		raw_cwd = (type(ctx_path) == "string" and ctx_path ~= "")
				and (paths.detect_safe_project_root(ctx_path) or vim.fs.dirname(ctx_path))
			or paths.get_global_cwd()
	end
	local norm_cwd = paths.normalize_project_path(raw_cwd)
	local detected_root = (norm_cwd and vim.fn.isdirectory(norm_cwd) == 1) and paths.detect_safe_project_root(norm_cwd)
		or nil
	return M.resolve_item_project_path(norm_cwd, detected_root, pinned_map)
end

---Return the collision-free display name (custom alias or disambiguated folder name) for a chat's project.
---@param chat table|nil
---@return string, string
function M.get_chat_project_name(chat)
	local store = M.load_projects_store()
	local pinned_map = M.get_pinned_map(store)
	local proj_path = M.get_chat_project_path(chat, pinned_map)
	local pinned = pinned_map[proj_path]
	if pinned and pinned.name and pinned.name ~= "" then
		return pinned.name, proj_path
	elseif proj_path == "" or proj_path == "Other" then
		return "Other", proj_path
	end

	local seen, descriptors = {}, {}
	local function push_desc(p)
		if type(p) == "string" and p ~= "" and not seen[p] then
			seen[p] = true
			local pin = pinned_map[p]
			table.insert(descriptors, { path = p, custom_name = pin and pin.name or nil })
		end
	end

	push_desc(proj_path)
	push_desc(paths.get_global_cwd())
	for _, entry in ipairs(store.projects) do
		push_desc(entry.path)
	end
	for _, p in ipairs(state.rendered_project_paths or {}) do
		push_desc(p)
	end
	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	if chat_mod then
		local all = chat_mod.buf_get_chat()
		for _, entry in ipairs(type(all) == "table" and all or {}) do
			if entry.chat and vim.api.nvim_buf_is_valid(entry.chat.bufnr) then
				push_desc(M.get_chat_project_path(entry.chat, pinned_map))
			end
		end
	end

	paths.assign_project_display_names(descriptors)
	for _, d in ipairs(descriptors) do
		if d.path == proj_path then
			return d.display_name or paths.project_basename(proj_path), proj_path
		end
	end
	return paths.project_basename(proj_path), proj_path
end

---Resolve the working directory for a chat started from `code_buf` (preserving exact Git worktree roots).
---@param code_buf? integer
---@return string
function M.resolve_context_project_dir(code_buf)
	local pinned_map = M.get_pinned_map()
	local wt = state_mod.get_wt()
	local fallback = paths.normalize_project_path(vim.fn.getcwd()) or paths.get_global_cwd()
	if
		code_buf
		and vim.api.nvim_buf_is_valid(code_buf)
		and vim.bo[code_buf].buftype == ""
		and vim.bo[code_buf].filetype ~= "codecompanion"
	then
		local bname = vim.api.nvim_buf_get_name(code_buf)
		if bname ~= "" then
			local bdir = paths.normalize_project_path(vim.fs.dirname(bname))
			local wt_root = (wt and bdir and type(wt.get_worktree_root) == "function")
					and paths.normalize_project_path(wt.get_worktree_root(bdir))
				or nil
			local pinned = paths.find_pinned_ancestor(bdir, pinned_map)
			if pinned and (not wt_root or #pinned >= #wt_root) and vim.fn.isdirectory(pinned) == 1 then
				return pinned
			elseif wt_root and vim.fn.isdirectory(wt_root) == 1 then
				return wt_root
			end
			local root = paths.detect_safe_project_root(bname)
			if root and vim.fn.isdirectory(root) == 1 then
				return root
			elseif bdir and vim.fn.isdirectory(bdir) == 1 then
				return bdir
			end
		end
	end
	local wt_fb = (wt and type(wt.get_worktree_root) == "function")
			and paths.normalize_project_path(wt.get_worktree_root(fallback))
		or nil
	local pinned_fb = paths.find_pinned_ancestor(fallback, pinned_map)
	if pinned_fb and (not wt_fb or #pinned_fb >= #wt_fb) and vim.fn.isdirectory(pinned_fb) == 1 then
		return pinned_fb
	elseif wt_fb and vim.fn.isdirectory(wt_fb) == 1 then
		return wt_fb
	end
	local root_fb = paths.detect_safe_project_root(fallback)
	return (root_fb and vim.fn.isdirectory(root_fb) == 1) and root_fb or fallback
end

---Find an open CodeCompanion chat belonging to `proj_dir` (preferring exact `cwd` match, then `last_chat()`).
---@param proj_dir string|nil
---@return table|nil
function M.find_active_chat_for_project(proj_dir)
	if type(proj_dir) ~= "string" or proj_dir == "" then
		return nil
	end
	local norm_dir = paths.normalize_project_path(proj_dir) or proj_dir
	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	if not chat_mod then
		return nil
	end
	local pinned_map = M.get_pinned_map()
	local last = chat_mod.last_chat()
	if last and vim.api.nvim_buf_is_valid(last.bufnr) and paths.get_valid_chat_cwd(last) == norm_dir then
		return last
	end
	local all = chat_mod.buf_get_chat()
	if type(all) == "table" then
		for i = #all, 1, -1 do
			local c = all[i] and all[i].chat
			if c and vim.api.nvim_buf_is_valid(c.bufnr) and paths.get_valid_chat_cwd(c) == norm_dir then
				return c
			end
		end
	end
	if last and vim.api.nvim_buf_is_valid(last.bufnr) and M.get_chat_project_path(last, pinned_map) == norm_dir then
		return last
	end
	if type(all) == "table" then
		for i = #all, 1, -1 do
			local c = all[i] and all[i].chat
			if c and vim.api.nvim_buf_is_valid(c.bufnr) and M.get_chat_project_path(c, pinned_map) == norm_dir then
				return c
			end
		end
	end
	return nil
end

---Add or pin a Project directory into the AI Workspace.
---@param raw_path string
---@param opts? { name?: string, create?: boolean, silent?: boolean, skip_save?: boolean, skip_render?: boolean }
---@return { path: string, name?: string, added_at: integer }|nil, string|nil
function M.add_project(raw_path, opts)
	opts = opts or {}
	if type(raw_path) ~= "string" or vim.trim(raw_path) == "" then
		return nil, "Project path cannot be empty"
	elseif vim.trim(raw_path) == "Other" then
		return nil, "Invalid project path: Other"
	end
	local expanded = paths.expand_raw_dir_path(raw_path)
	if not expanded then
		return nil, "Invalid project path"
	end

	if vim.fn.isdirectory(expanded) ~= 1 then
		local lstat = vim.uv.fs_lstat(expanded)
		if lstat ~= nil then
			local err = lstat.type == "link" and ("Broken symlink (target missing): " .. expanded)
				or ("Not a directory: " .. expanded)
			if not opts.silent then
				vim.notify(err, vim.log.levels.WARN, { title = "AI Workspace" })
			end
			return nil, err
		elseif opts.create then
			local ok_mk = pcall(vim.fn.mkdir, expanded, "p")
			if not ok_mk or vim.fn.isdirectory(expanded) ~= 1 then
				local err = "Failed to create directory: " .. expanded
				if not opts.silent then
					vim.notify(err, vim.log.levels.ERROR, { title = "AI Workspace" })
				end
				return nil, err
			end
		else
			local err = "Directory does not exist: " .. expanded
			if not opts.silent then
				vim.notify(err, vim.log.levels.WARN, { title = "AI Workspace" })
			end
			return nil, err
		end
	end

	local norm = paths.normalize_project_path(expanded)
	if not norm then
		return nil, "Invalid project path"
	end

	local custom_name = (type(opts.name) == "string" and vim.trim(opts.name) ~= "") and vim.trim(opts.name) or nil
	local store = M.load_projects_store()
	store.hidden[norm] = nil

	local target_entry = nil
	for _, entry in ipairs(store.projects) do
		if entry.path == norm then
			entry.added_at = os.time()
			entry.name = custom_name or entry.name
			target_entry = entry
			break
		end
	end
	if not target_entry then
		target_entry = { path = norm, name = custom_name, added_at = os.time() }
		table.insert(store.projects, 1, target_entry)
	end

	if not opts.skip_save then
		local ok_save, save_err = M.save_projects_store(store)
		if not ok_save then
			if not opts.silent then
				vim.notify(
					"Failed to save project: " .. tostring(save_err),
					vim.log.levels.ERROR,
					{ title = "AI Workspace" }
				)
			end
			return nil, save_err
		end
		state_mod.clear_path_caches()
	end

	state.collapsed_projects[norm] = false
	state.last_selected_project = norm
	state.focus_project_path = norm
	if not opts.skip_render then
		if state_mod.is_workspace_valid() and state.actions.render then
			state.actions.render()
		end
		state_mod.refresh_winbars()
	end
	if not opts.silent then
		local label = string.format(
			"Project added: %s (%s)",
			target_entry.name or paths.project_basename(norm),
			vim.fn.fnamemodify(norm, ":~")
		)
		vim.notify(label, vim.log.levels.INFO, { title = "AI Workspace" })
	end
	return vim.deepcopy(target_entry), nil
end

---Remove or hide a Project from the AI Workspace, optionally closing active chats and/or deleting saved chats.
---@param raw_path string
---@param opts? { hide?: boolean, delete_chats?: boolean, close_active?: boolean, silent?: boolean }
---@return boolean
function M.remove_project(raw_path, opts)
	opts = opts or {}
	local norm = raw_path == "Other" and "Other" or paths.normalize_project_path(raw_path)
	if not norm then
		return false
	end

	local store = M.load_projects_store()
	local pinned_before = M.get_pinned_map(store)

	local owned_active = {}
	if opts.close_active or opts.delete_chats then
		local chat_mod = package.loaded["codecompanion.interactions.chat"]
		if chat_mod then
			local all = chat_mod.buf_get_chat()
			for _, entry in ipairs(type(all) == "table" and all or {}) do
				if
					entry.chat
					and vim.api.nvim_buf_is_valid(entry.chat.bufnr)
					and M.get_chat_project_path(entry.chat, pinned_before) == norm
				then
					table.insert(owned_active, entry.chat)
				end
			end
		end
	end

	local kept = {}
	for _, entry in ipairs(store.projects) do
		if entry.path ~= norm then
			table.insert(kept, entry)
		end
	end
	store.projects = kept
	store.hidden[norm] = opts.hide and true or nil
	M.save_projects_store(store)

	for _, c in ipairs(owned_active) do
		if opts.delete_chats and c.opts then
			c.opts.save_id = nil
		end
		if state.actions.close_chat then
			state.actions.close_chat(c, true)
		else
			pcall(function()
				c:close()
			end)
		end
	end

	if opts.delete_chats then
		local cc = package.loaded["codecompanion"]
		local history_ext = cc and cc.extensions and cc.extensions.history
		if history_ext and history_ext.get_chats and history_ext.delete_chat then
			for save_id, item in pairs(history_ext.get_chats() or {}) do
				if
					type(item) == "table"
					and M.resolve_item_project_path(item.cwd, item.project_root, pinned_before) == norm
				then
					pcall(history_ext.delete_chat, save_id)
				end
			end
		end
	end

	state_mod.clear_path_caches()
	if state.last_selected_project == norm then
		state.last_selected_project = nil
	end
	if state_mod.is_workspace_valid() and state.actions.render then
		state.actions.render()
	end
	state_mod.refresh_winbars()
	return true
end

---Set or clear a custom display alias for a Project.
---@param raw_path string
---@param new_name string|nil
---@return boolean
function M.rename_project(raw_path, new_name)
	local norm = paths.normalize_project_path(raw_path)
	if not norm then
		return false
	end
	local trimmed = type(new_name) == "string" and vim.trim(new_name) or ""
	local store = M.load_projects_store()
	store.hidden[norm] = nil
	local found = false
	for _, entry in ipairs(store.projects) do
		if entry.path == norm then
			entry.name = trimmed ~= "" and trimmed or nil
			found = true
			break
		end
	end
	if not found and trimmed ~= "" then
		table.insert(store.projects, 1, { path = norm, name = trimmed, added_at = os.time() })
	end
	M.save_projects_store(store)
	state_mod.clear_path_caches()
	if state_mod.is_workspace_valid() and state.actions.render then
		state.actions.render()
	end
	state_mod.refresh_winbars()
	return true
end

---Discover candidate project directories from cwd, buffers, project.nvim, history, sibling folders, and zoxide.
---@return { path: string, source: string, pinned: boolean, is_cwd: boolean, is_git: boolean, is_repo: boolean, rank: integer }[]
function M.get_candidate_projects()
	local store = M.load_projects_store()
	return candidates.get_candidate_projects({ store = store, pinned_map = M.get_pinned_map(store) })
end

return M
