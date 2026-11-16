local config = require("cc_workspace.config")
local state_mod = require("cc_workspace.state")

local state = state_mod.state
local unpack_fn = table.unpack or unpack

local M = {}

---Expand a raw user/stored directory string (`~`, `$ENV`, relative path) without Vim wildcard globbing or `%`/`#` substitution.
---@param raw_path string|nil
---@return string|nil
function M.expand_raw_dir_path(raw_path)
	if type(raw_path) ~= "string" then
		return nil
	end
	local trimmed = vim.trim(raw_path)
	if #trimmed >= 2 then
		local first, last = trimmed:sub(1, 1), trimmed:sub(-1)
		if (first == "'" and last == "'") or (first == '"' and last == '"') then
			if vim.uv.fs_lstat(trimmed) == nil then
				trimmed = vim.trim(trimmed:sub(2, -2))
			end
		end
	end
	if trimmed == "" or trimmed == "Other" then
		return nil
	end
	local expanded = trimmed
	if expanded == "~" or expanded:sub(1, 2) == "~/" then
		local home = vim.uv.os_homedir()
		if type(home) == "string" and home ~= "" then
			expanded = home .. expanded:sub(2)
		end
	end
	expanded = vim.fs.normalize(expanded)
	if expanded == "" then
		return nil
	end
	if not expanded:match("^/") and not expanded:match("^%a:[/\\]") then
		local base_cwd = vim.fn.getcwd()
		if type(base_cwd) ~= "string" or base_cwd == "" then
			base_cwd = vim.fn.getcwd(-1, -1)
		end
		if type(base_cwd) == "string" and base_cwd ~= "" then
			expanded = vim.fs.normalize(vim.fs.joinpath(base_cwd, expanded))
		end
	end
	if #expanded > 1 then
		expanded = expanded:gsub("/+$", "")
	end
	return expanded ~= "" and expanded or nil
end

---Normalize a filesystem directory path (expanding `~`, resolving relative paths and symlinks when present).
---@param raw_path string|nil
---@return string|nil
function M.normalize_project_path(raw_path)
	local expanded = M.expand_raw_dir_path(raw_path)
	if not expanded then
		return nil
	end
	local t_now = state_mod.now_ms()
	local cached = state.norm_path_cache[expanded]
	if cached and (t_now - cached.ts) < state_mod.NORM_PATH_TTL_MS then
		return cached.norm
	end
	local real = vim.uv.fs_realpath(expanded)
	local norm
	if real then
		norm = vim.fs.normalize(real)
	else
		norm = expanded
		local tail = {}
		local cur = expanded
		while cur and cur ~= "" and cur ~= "/" do
			table.insert(tail, 1, vim.fs.basename(cur))
			local parent = vim.fs.dirname(cur)
			if not parent or parent == cur then
				break
			end
			local preal = vim.uv.fs_realpath(parent)
			if preal then
				norm = vim.fs.normalize(vim.fs.joinpath(preal, unpack_fn(tail)))
				break
			end
			cur = parent
		end
	end
	if #norm > 1 then
		norm = norm:gsub("/+$", "")
	end
	if norm == "" then
		return nil
	end
	state.norm_path_cache[expanded] = { norm = norm, ts = t_now }
	if norm ~= expanded then
		state.norm_path_cache[norm] = { norm = norm, ts = t_now }
	end
	return norm
end

---Return Neovim's canonical global working directory (unaffected by window-local `lcd` or tab-local `tcd`).
---@return string
function M.get_global_cwd()
	local raw = vim.fn.getcwd(-1, -1)
	if type(raw) ~= "string" or raw == "" then
		raw = vim.uv.cwd() or ""
	end
	return M.normalize_project_path(raw) or raw
end

---Extract short folder name from a normalized project path.
---@param path string|nil
---@return string
function M.project_basename(path)
	if type(path) ~= "string" or path == "" or path == "Other" then
		return "Other"
	end
	if path == "/" then
		return "/"
	end
	local base = vim.fs.basename(path)
	return (type(base) == "string" and base ~= "") and base or path
end

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

---Decode raw JSON text into a normalized projects store structure.
---@param raw string
---@return { version: integer, projects: { path: string, name?: string, added_at: integer, [string]: any }[], hidden: table<string, boolean> }
local function decode_projects_payload(raw)
	local store = { version = 1, projects = {}, hidden = {} }
	local ok, decoded = pcall(vim.json.decode, raw)
	if not ok or type(decoded) ~= "table" then
		return store
	end
	local seen = {}
	local raw_projects = type(decoded.projects) == "table" and decoded.projects or decoded
	for _, item in ipairs(raw_projects) do
		local p = type(item) == "table" and M.normalize_project_path(item.path)
			or (type(item) == "string" and M.normalize_project_path(item))
			or nil
		if p and not seen[p] then
			seen[p] = true
			local custom_name = (type(item) == "table" and type(item.name) == "string" and vim.trim(item.name) ~= "")
					and vim.trim(item.name)
				or nil
			local added_at = (type(item) == "table" and type(item.added_at) == "number") and item.added_at or 0
			table.insert(store.projects, {
				path = p,
				name = custom_name,
				added_at = added_at,
			})
		end
	end
	if type(decoded.hidden) == "table" then
		for k, v in pairs(decoded.hidden) do
			if type(k) == "string" and v == true then
				local hp = M.normalize_project_path(k) or k
				store.hidden[hp] = true
			elseif type(v) == "string" then
				local hp = M.normalize_project_path(v) or v
				store.hidden[hp] = true
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
		state.projects_cache = empty
		state.projects_mtime = "missing"
		state.history_proj_cache = {}
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

	state.projects_cache = store
	state.projects_mtime = mtime_key
	state.history_proj_cache = {}
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
	local payload = {
		version = 1,
		projects = store.projects or {},
		hidden = store.hidden or {},
	}
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
	local ncwd = M.normalize_project_path(raw_cwd)
	local nroot = M.normalize_project_path(raw_project_root)
	if ncwd then
		if pinned_map[ncwd] then
			return ncwd
		end
		local best_pinned = nil
		for p, _ in pairs(pinned_map) do
			if p ~= "/" and ncwd:sub(1, #p + 1) == p .. "/" then
				if not best_pinned or #p > #best_pinned then
					best_pinned = p
				end
			end
		end
		if best_pinned and (not nroot or #best_pinned >= #nroot) then
			return best_pinned
		end
		local wt = state_mod.get_wt()
		if wt and type(wt.get_repo_root) == "function" then
			local repo_root = wt.get_repo_root(ncwd)
			if type(repo_root) == "string" and repo_root ~= "" then
				return M.normalize_project_path(repo_root) or repo_root
			end
		end
	end
	if nroot then
		local wt = state_mod.get_wt()
		if wt and type(wt.get_repo_root) == "function" then
			local repo_root = wt.get_repo_root(nroot)
			if type(repo_root) == "string" and repo_root ~= "" then
				return M.normalize_project_path(repo_root) or repo_root
			end
		end
	end
	return nroot or ncwd or "Other"
end

---Split a project path's parent chain into bottom-up ancestor tokens (`anc[1]` = immediate parent).
---@param path string
---@param home string
---@return string[]
local function get_project_ancestors(path, home)
	if type(path) ~= "string" or path == "" or path == "/" or path == "Other" then
		return {}
	end
	local norm = path:gsub("/+$", "")
	local parent = vim.fs.dirname(norm)
	if not parent or parent == "" or parent == "." or parent == norm then
		return {}
	end
	if home ~= "" and parent == home then
		return { "~" }
	end
	local rel
	local root_tok
	if home ~= "" and parent:sub(1, #home + 1) == home .. "/" then
		rel = parent:sub(#home + 2)
		root_tok = "~"
	else
		rel = parent:gsub("^/+", "")
		root_tok = "/"
	end
	local top_down = {}
	if root_tok then
		table.insert(top_down, root_tok)
	end
	for seg in rel:gmatch("[^/]+") do
		table.insert(top_down, seg)
	end
	local bottom_up = {}
	for i = #top_down, 1, -1 do
		table.insert(bottom_up, top_down[i])
	end
	return bottom_up
end

---Format a compact `<diff_ancestor>/…/<base_name>` label from bottom-up ancestors.
---@param anc string[]
---@param base_name string
---@param depth integer
---@param span integer
---@return string
local function format_disambiguated_name(anc, base_name, depth, span)
	if #anc == 0 then
		return base_name
	end
	local bot = math.min(depth, #anc)
	local top = math.min(#anc, bot + span - 1)
	if bot == top and bot > 1 and (anc[top] == "~" or anc[top] == "/") then
		bot = bot - 1
	end
	local has_root_slash = false
	local parts = {}
	for i = top, bot, -1 do
		if anc[i] == "/" then
			has_root_slash = true
		else
			table.insert(parts, anc[i])
		end
	end
	if bot > 1 then
		table.insert(parts, "…")
	end
	table.insert(parts, base_name)
	local joined = table.concat(parts, "/")
	if has_root_slash then
		return "/" .. joined
	end
	return joined
end

---Assign collision-free display names to a list of project descriptors using tail-aware ancestor disambiguation.
---@param projects table[]
function M.assign_project_display_names(projects)
	local home = (M.normalize_project_path("~") or vim.fn.expand("~") or ""):gsub("/+$", "")
	local init_counts = {}
	for _, proj in ipairs(projects) do
		proj.base_name = M.project_basename(proj.path)
		if proj.custom_name and proj.custom_name ~= "" then
			proj.display_name = proj.custom_name
		else
			proj.display_name = proj.base_name
		end
		init_counts[proj.display_name] = (init_counts[proj.display_name] or 0) + 1
	end

	local locked = {}
	local used_locked = {}
	local anc_by_idx = {}
	local max_anc = 0
	local remaining = 0
	for i, proj in ipairs(projects) do
		local has_custom = proj.custom_name ~= nil and proj.custom_name ~= ""
		if has_custom or proj.path == "/" or proj.path == "Other" or (init_counts[proj.display_name] or 0) <= 1 then
			locked[i] = true
			used_locked[proj.display_name] = true
		else
			local anc = get_project_ancestors(proj.path, home)
			anc_by_idx[i] = anc
			if #anc > max_anc then
				max_anc = #anc
			end
			remaining = remaining + 1
		end
	end

	if remaining == 0 then
		return
	end

	for span = 1, math.max(1, max_anc) do
		if remaining == 0 then
			break
		end
		for depth = 1, math.max(1, max_anc) do
			if remaining == 0 then
				break
			end
			local cand_by_idx = {}
			local cand_paths = {}
			for i, proj in ipairs(projects) do
				if not locked[i] then
					local cand = format_disambiguated_name(anc_by_idx[i], proj.base_name, depth, span)
					cand_by_idx[i] = cand
					if not cand_paths[cand] then
						cand_paths[cand] = { [proj.path] = true, _distinct = 1 }
					elseif not cand_paths[cand][proj.path] then
						cand_paths[cand][proj.path] = true
						cand_paths[cand]._distinct = cand_paths[cand]._distinct + 1
					end
				end
			end
			for i, proj in ipairs(projects) do
				if not locked[i] then
					local cand = cand_by_idx[i]
					if cand_paths[cand]._distinct == 1 and not used_locked[cand] then
						proj.display_name = cand
						locked[i] = true
						used_locked[cand] = true
						remaining = remaining - 1
					end
				end
			end
		end
	end

	for i, proj in ipairs(projects) do
		if not locked[i] then
			proj.display_name = vim.fn.fnamemodify(proj.path, ":~")
		end
	end
end

---Return a deep copy of explicitly added (pinned) workspace projects with disambiguated `display_name`.
---@return { path: string, name?: string, custom_name?: string, base_name: string, display_name: string, added_at: integer }[]
function M.list_projects()
	local list = vim.deepcopy(M.load_projects_store().projects)
	for _, entry in ipairs(list) do
		entry.custom_name = entry.name
	end
	M.assign_project_display_names(list)
	return list
end

---Return a chat's validated existing working directory on disk, or nil if unset/missing.
---@param chat table|nil
---@return string|nil
function M.get_valid_chat_cwd(chat)
	if type(chat) ~= "table" then
		return nil
	end
	local raw = (type(chat.opts) == "table" and chat.opts.cwd) or chat.cwd
	local norm = M.normalize_project_path(raw)
	if norm and vim.fn.isdirectory(norm) == 1 then
		return norm
	end
	return nil
end

---Detect project marker root without collapsing subdirectories into `$HOME` or `/`.
---@param start_path string|nil
---@return string|nil
function M.detect_safe_project_root(start_path)
	if type(start_path) ~= "string" or start_path == "" then
		return nil
	end
	local norm_start = M.normalize_project_path(start_path) or start_path
	local t_now = state_mod.now_ms()
	local cached = state.project_root_cache[norm_start]
	if cached and (t_now - cached.ts) < state_mod.PROJECT_ROOT_TTL_MS then
		return cached.root or nil
	end
	local ok_r, root = pcall(vim.fs.root, norm_start, state_mod.PROJECT_MARKERS)
	if not ok_r or type(root) ~= "string" or root == "" then
		state.project_root_cache[norm_start] = { root = false, ts = t_now }
		return nil
	end
	local norm_root = M.normalize_project_path(root)
	if not norm_root then
		state.project_root_cache[norm_start] = { root = false, ts = t_now }
		return nil
	end
	local home = M.normalize_project_path("~")
	if norm_root ~= norm_start and (norm_root == "/" or (home and norm_root == home)) then
		state.project_root_cache[norm_start] = { root = false, ts = t_now }
		return nil
	end
	state.project_root_cache[norm_start] = { root = norm_root, ts = t_now }
	return norm_root
end

---Resolve the canonical project directory path associated with an active chat.
---@param chat table|nil
---@param pinned_map? table<string, table>
---@return string
function M.get_chat_project_path(chat, pinned_map)
	if type(chat) ~= "table" then
		return M.get_global_cwd()
	end
	local raw_cwd = (type(chat.opts) == "table" and chat.opts.cwd) or chat.cwd
	if type(raw_cwd) ~= "string" or raw_cwd == "" then
		local ctx_path = type(chat.buffer_context) == "table" and chat.buffer_context.path or nil
		if type(ctx_path) == "string" and ctx_path ~= "" then
			raw_cwd = M.detect_safe_project_root(ctx_path) or vim.fs.dirname(ctx_path)
		else
			raw_cwd = M.get_global_cwd()
		end
	end
	local detected_root = nil
	local norm_cwd = M.normalize_project_path(raw_cwd)
	if norm_cwd and vim.fn.isdirectory(norm_cwd) == 1 then
		detected_root = M.detect_safe_project_root(norm_cwd)
	end
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
	end
	if proj_path == "" or proj_path == "Other" then
		return "Other", proj_path
	end

	local seen = {}
	local descriptors = {}
	local function push_desc(p)
		if type(p) ~= "string" or p == "" or seen[p] then
			return
		end
		seen[p] = true
		local pin = pinned_map[p]
		table.insert(descriptors, {
			path = p,
			custom_name = pin and pin.name or nil,
		})
	end

	push_desc(proj_path)
	push_desc(M.get_global_cwd())
	for _, entry in ipairs(store.projects) do
		push_desc(entry.path)
	end
	for _, p in ipairs(state.rendered_project_paths or {}) do
		push_desc(p)
	end
	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	if chat_mod then
		local all = chat_mod.buf_get_chat()
		if type(all) == "table" then
			for _, entry in ipairs(all) do
				if entry.chat and vim.api.nvim_buf_is_valid(entry.chat.bufnr) then
					push_desc(M.get_chat_project_path(entry.chat, pinned_map))
				end
			end
		end
	end

	M.assign_project_display_names(descriptors)
	for _, d in ipairs(descriptors) do
		if d.path == proj_path then
			return d.display_name or M.project_basename(proj_path), proj_path
		end
	end
	return M.project_basename(proj_path), proj_path
end

---Safely query a window's effective working directory across any tabpage.
---@param win integer|nil
---@return string|nil
function M.get_win_cwd(win)
	if not win or not vim.api.nvim_win_is_valid(win) then
		return nil
	end
	local ok_t, tp = pcall(vim.api.nvim_win_get_tabpage, win)
	if not ok_t or not tp or not vim.api.nvim_tabpage_is_valid(tp) then
		return nil
	end
	local winnr = vim.api.nvim_win_get_number(win)
	local tabnr = vim.api.nvim_tabpage_get_number(tp)
	local ok_c, cwd = pcall(vim.fn.getcwd, winnr, tabnr)
	if ok_c and type(cwd) == "string" and cwd ~= "" then
		return M.normalize_project_path(cwd) or cwd
	end
	return nil
end

---Synchronize a window's local working directory (`lcd`) without firing `DirChanged` or polluting other windows.
---@param win integer|nil
---@param dir string|nil
function M.sync_win_lcd(win, dir)
	if not win or not vim.api.nvim_win_is_valid(win) then
		return
	end
	local norm_dir = (type(dir) == "string" and dir ~= "") and M.normalize_project_path(dir) or nil
	local target = (norm_dir and vim.fn.isdirectory(norm_dir) == 1) and norm_dir or M.get_global_cwd()
	if type(target) ~= "string" or target == "" or vim.fn.isdirectory(target) ~= 1 then
		return
	end
	local cur_win_cwd = M.get_win_cwd(win)
	if cur_win_cwd == target then
		return
	end
	local active_win = vim.api.nvim_get_current_win()
	local active_cwd = M.get_win_cwd(active_win)
	pcall(vim.api.nvim_win_call, win, function()
		vim.cmd("silent! noautocmd lcd " .. vim.fn.fnameescape(target))
	end)
	if vim.api.nvim_get_current_win() ~= win and type(active_cwd) == "string" and active_cwd ~= "" then
		pcall(vim.uv.chdir, active_cwd)
	end
end

---Run `fn` with process cwd temporarily switched to `dir`, always restoring previous cwd afterward.
---@param dir string|nil
---@param fn fun(): any
---@return any
function M.with_temp_cwd(dir, fn)
	if type(dir) ~= "string" or dir == "" or vim.fn.isdirectory(dir) ~= 1 then
		return fn()
	end
	local prev = vim.uv.cwd()
	if prev == dir then
		return fn()
	end
	pcall(vim.uv.chdir, dir)
	local ok, res = pcall(fn)
	if type(prev) == "string" and prev ~= "" then
		pcall(vim.uv.chdir, prev)
	end
	if not ok then
		error(res)
	end
	return res
end

---Check whether a loaded file buffer lies inside `dir`.
---@param buf integer
---@param dir string|nil
---@return boolean
function M.buf_within_dir(buf, dir)
	if not dir or dir == "" then
		return true
	end
	local name = vim.api.nvim_buf_get_name(buf)
	local norm = M.normalize_project_path(name)
	if not norm then
		return false
	end
	if dir == "/" then
		return true
	end
	return norm == dir or norm:sub(1, #dir + 1) == dir .. "/"
end

---Find the most specific pinned Project directory that encloses `dir` (if any).
---@param dir string|nil
---@param pinned_map table<string, table>|nil
---@return string|nil
function M.find_pinned_ancestor(dir, pinned_map)
	if not dir or not pinned_map then
		return nil
	end
	local best = nil
	for p_path, _ in pairs(pinned_map) do
		if dir == p_path or dir:sub(1, #p_path + 1) == p_path .. "/" then
			if not best or #p_path > #best then
				best = p_path
			end
		end
	end
	return best
end

---Resolve the working directory for a chat started from `code_buf` (preserving exact Git worktree roots).
---@param code_buf? integer
---@return string
function M.resolve_context_project_dir(code_buf)
	local pinned_map = M.get_pinned_map()
	local wt = state_mod.get_wt()
	local fallback = M.normalize_project_path(vim.fn.getcwd()) or M.get_global_cwd()
	if
		code_buf
		and vim.api.nvim_buf_is_valid(code_buf)
		and vim.bo[code_buf].buftype == ""
		and vim.bo[code_buf].filetype ~= "codecompanion"
	then
		local bname = vim.api.nvim_buf_get_name(code_buf)
		if bname ~= "" then
			local bdir = M.normalize_project_path(vim.fs.dirname(bname))
			local wt_root = (wt and bdir and type(wt.get_worktree_root) == "function")
					and M.normalize_project_path(wt.get_worktree_root(bdir))
				or nil
			local pinned = M.find_pinned_ancestor(bdir, pinned_map)
			if pinned and (not wt_root or #pinned >= #wt_root) and vim.fn.isdirectory(pinned) == 1 then
				return pinned
			end
			if wt_root and vim.fn.isdirectory(wt_root) == 1 then
				return wt_root
			end
			local root = M.detect_safe_project_root(bname)
			if root and vim.fn.isdirectory(root) == 1 then
				return root
			end
			if bdir and vim.fn.isdirectory(bdir) == 1 then
				return bdir
			end
		end
	end
	local wt_fb = (wt and type(wt.get_worktree_root) == "function")
			and M.normalize_project_path(wt.get_worktree_root(fallback))
		or nil
	local pinned_fb = M.find_pinned_ancestor(fallback, pinned_map)
	if pinned_fb and (not wt_fb or #pinned_fb >= #wt_fb) and vim.fn.isdirectory(pinned_fb) == 1 then
		return pinned_fb
	end
	if wt_fb and vim.fn.isdirectory(wt_fb) == 1 then
		return wt_fb
	end
	local root_fb = M.detect_safe_project_root(fallback)
	if root_fb and vim.fn.isdirectory(root_fb) == 1 then
		return root_fb
	end
	return fallback
end

---Find an open CodeCompanion chat belonging to `proj_dir` (preferring exact `cwd` match, then `last_chat()`).
---@param proj_dir string|nil
---@return table|nil
function M.find_active_chat_for_project(proj_dir)
	if type(proj_dir) ~= "string" or proj_dir == "" then
		return nil
	end
	local norm_dir = M.normalize_project_path(proj_dir) or proj_dir
	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	if not chat_mod then
		return nil
	end
	local pinned_map = M.get_pinned_map()
	local last = chat_mod.last_chat()
	if last and vim.api.nvim_buf_is_valid(last.bufnr) and M.get_valid_chat_cwd(last) == norm_dir then
		return last
	end
	local all = chat_mod.buf_get_chat()
	if type(all) == "table" then
		for i = #all, 1, -1 do
			local c = all[i] and all[i].chat
			if c and vim.api.nvim_buf_is_valid(c.bufnr) and M.get_valid_chat_cwd(c) == norm_dir then
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
	end
	local trimmed = vim.trim(raw_path)
	if trimmed == "Other" then
		return nil, "Invalid project path: Other"
	end
	local expanded = M.expand_raw_dir_path(raw_path)
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
		end
		if opts.create then
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

	local norm = M.normalize_project_path(expanded)
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
			if custom_name then
				entry.name = custom_name
			end
			target_entry = entry
			break
		end
	end
	if not target_entry then
		target_entry = {
			path = norm,
			name = custom_name,
			added_at = os.time(),
		}
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
		vim.notify(
			string.format(
				"Project added: %s (%s)",
				target_entry.name or M.project_basename(norm),
				vim.fn.fnamemodify(norm, ":~")
			),
			vim.log.levels.INFO,
			{ title = "AI Workspace" }
		)
	end
	return vim.deepcopy(target_entry), nil
end

---Remove or hide a Project from the AI Workspace, optionally closing active chats and/or deleting saved chats.
---@param raw_path string
---@param opts? { hide?: boolean, delete_chats?: boolean, close_active?: boolean, silent?: boolean }
---@return boolean
function M.remove_project(raw_path, opts)
	opts = opts or {}
	local norm = raw_path == "Other" and "Other" or M.normalize_project_path(raw_path)
	if not norm then
		return false
	end

	local store = M.load_projects_store()
	local pinned_before = M.get_pinned_map(store)

	-- Collect active chats owned by this project BEFORE unpinning (so monorepo subproject ownership matches)
	local owned_active = {}
	if opts.close_active or opts.delete_chats then
		local chat_mod = package.loaded["codecompanion.interactions.chat"]
		if chat_mod then
			local all = chat_mod.buf_get_chat()
			if type(all) == "table" then
				for _, entry in ipairs(all) do
					if entry.chat and vim.api.nvim_buf_is_valid(entry.chat.bufnr) then
						if M.get_chat_project_path(entry.chat, pinned_before) == norm then
							table.insert(owned_active, entry.chat)
						end
					end
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
	if opts.hide then
		store.hidden[norm] = true
	else
		store.hidden[norm] = nil
	end
	M.save_projects_store(store)

	-- Close matching active chats first so auto-save on open buffers cannot resurrect deleted history
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
			local saved_map = history_ext.get_chats() or {}
			for save_id, item in pairs(saved_map) do
				if type(item) == "table" then
					local owner = M.resolve_item_project_path(item.cwd, item.project_root, pinned_before)
					if owner == norm then
						pcall(history_ext.delete_chat, save_id)
					end
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
	local norm = M.normalize_project_path(raw_path)
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
		table.insert(store.projects, 1, {
			path = norm,
			name = trimmed,
			added_at = os.time(),
		})
	end
	M.save_projects_store(store)
	state_mod.clear_path_caches()
	if state_mod.is_workspace_valid() and state.actions.render then
		state.actions.render()
	end
	state_mod.refresh_winbars()
	return true
end

---Warm the cached `zoxide query -l` list asynchronously so opening Add Project never stalls the UI.
function M.warm_zoxide_cache()
	if state.zoxide_inflight or vim.fn.executable("zoxide") ~= 1 then
		return
	end
	local now_sec = os.time()
	if state.zoxide_cache and (now_sec - (state.zoxide_ts or 0)) < 30 then
		return
	end
	state.zoxide_inflight = true
	pcall(vim.system, { "zoxide", "query", "-l" }, { text = true, timeout = 500 }, function(res)
		vim.schedule(function()
			state.zoxide_inflight = false
			if res and res.code == 0 and type(res.stdout) == "string" then
				local lines = {}
				for line in res.stdout:gmatch("[^\r\n]+") do
					table.insert(lines, line)
					if #lines >= 80 then
						break
					end
				end
				state.zoxide_cache = lines
				state.zoxide_ts = os.time()
			end
		end)
	end)
end

---Check whether `p` equals `prefix` or is nested beneath `prefix .. "/"`.
---@param p string
---@param prefix string|nil
---@return boolean
local function path_has_prefix(p, prefix)
	if type(prefix) ~= "string" or prefix == "" then
		return false
	end
	if prefix == "/" then
		return true
	end
	return p == prefix or p:sub(1, #prefix + 1) == prefix .. "/"
end

---Detect bare `.git` directories (`*.git` without a `.git` working-tree entry, or bare repo layouts).
---@param p string
---@return boolean
local function is_bare_git_dir(p)
	if p:sub(-5) == "/.git" or p:find("/.git/", 1, true) ~= nil then
		return true
	end
	if p:match("%.git$") and vim.uv.fs_stat(vim.fs.joinpath(p, ".git")) == nil then
		return true
	end
	if
		vim.uv.fs_stat(vim.fs.joinpath(p, ".git")) == nil
		and vim.uv.fs_stat(vim.fs.joinpath(p, "HEAD")) ~= nil
		and vim.uv.fs_stat(vim.fs.joinpath(p, "objects")) ~= nil
		and vim.uv.fs_stat(vim.fs.joinpath(p, "refs")) ~= nil
	then
		return true
	end
	return false
end

---Build a predicate rejecting noisy system, cache, and bare-git paths during candidate discovery.
---@param home string
---@param wt_base string|nil
---@return fun(p: string): boolean
local function build_noisy_path_checker(home, wt_base)
	local noisy_prefixes = {
		"/tmp",
		"/private/tmp",
		"/private/var/folders",
		"/var/tmp",
		wt_base,
	}
	if home ~= "" then
		vim.list_extend(noisy_prefixes, {
			home .. "/.ssh",
			home .. "/.opencode",
			home .. "/Downloads",
			home .. "/Library/Mobile Documents",
			home .. "/Desktop",
		})
	end
	return function(p)
		if p == "/" or (home ~= "" and p == home) then
			return true
		end
		if is_bare_git_dir(p) then
			return true
		end
		if
			p:find("/node_modules", 1, true) ~= nil
			or p:find("/opt/homebrew", 1, true) ~= nil
			or p:find("/Cellar/", 1, true) ~= nil
			or p:find("/.local/bin", 1, true) ~= nil
			or p:find("/.local/share", 1, true) ~= nil
			or p:find("/.cache", 1, true) ~= nil
		then
			return true
		end
		for _, pref in ipairs(noisy_prefixes) do
			if path_has_prefix(p, pref) then
				return true
			end
		end
		return false
	end
end

---Read recent project paths from `project.nvim` history files (`project_history.json` & `project_history`).
---@param add_candidate fun(raw: any, source: string, force_keep: boolean)
local function collect_project_nvim_candidates(add_candidate)
	local data_dir = vim.fn.stdpath("data")
	local pj_json = vim.fs.joinpath(data_dir, "project_nvim", "project_history.json")
	local fj = io.open(pj_json, "r")
	if fj then
		local ok_d, arr = pcall(vim.json.decode, fj:read("*a"))
		fj:close()
		if ok_d and type(arr) == "table" then
			for i = #arr, 1, -1 do
				local it = arr[i]
				add_candidate(type(it) == "table" and it.path or it, "recent", false)
			end
		end
	end
	local pj_txt = vim.fs.joinpath(data_dir, "project_nvim", "project_history")
	local ft = io.open(pj_txt, "r")
	if ft then
		local raw_lines = {}
		for line in ft:lines() do
			if line ~= "" then
				table.insert(raw_lines, line)
			end
		end
		ft:close()
		for i = #raw_lines, 1, -1 do
			add_candidate(raw_lines[i], "recent", false)
		end
	end
end

---Collect frequent directory candidates from cached or bounded-timeout `zoxide`.
---@param add_candidate fun(raw: any, source: string, force_keep: boolean)
local function collect_zoxide_candidates(add_candidate)
	if vim.fn.executable("zoxide") ~= 1 then
		return
	end
	local now_sec = os.time()
	if not state.zoxide_cache then
		local ok_z, res = pcall(function()
			return vim.system({ "zoxide", "query", "-l" }, { text = true, timeout = 100 }):wait()
		end)
		if ok_z and res and res.code == 0 and type(res.stdout) == "string" then
			local zlines = {}
			for line in res.stdout:gmatch("[^\r\n]+") do
				table.insert(zlines, line)
				if #zlines >= 80 then
					break
				end
			end
			state.zoxide_cache = zlines
			state.zoxide_ts = now_sec
		else
			state.zoxide_cache = {}
			state.zoxide_ts = 0
			M.warm_zoxide_cache()
		end
	elseif (now_sec - (state.zoxide_ts or 0)) >= 30 then
		M.warm_zoxide_cache()
	end
	for _, line in ipairs(state.zoxide_cache or {}) do
		add_candidate(line, "zoxide", false)
	end
end

---Scan sibling directories in parent folder of `global_cwd` (skipping `$HOME` to avoid macOS TCC scans).
---@param global_cwd string
---@param home string
---@param add_candidate fun(raw: any, source: string, force_keep: boolean)
local function collect_sibling_candidates(global_cwd, home, add_candidate)
	local parent_dir = global_cwd ~= "/" and vim.fs.dirname(global_cwd) or nil
	if
		not parent_dir
		or parent_dir == "/"
		or (home ~= "" and parent_dir == home)
		or parent_dir == "/tmp"
		or parent_dir == "/private/tmp"
	then
		return
	end
	local handle = vim.uv.fs_scandir(parent_dir)
	if not handle then
		return
	end
	local scanned = 0
	while scanned < 60 do
		local name, typ = vim.uv.fs_scandir_next(handle)
		if not name then
			break
		end
		scanned = scanned + 1
		if not name:match("^%.") then
			local full = vim.fs.joinpath(parent_dir, name)
			if typ == "directory" or (typ == "link" and vim.fn.isdirectory(full) == 1) then
				add_candidate(full, "sibling", false)
			end
		end
	end
end

---Discover candidate project directories from cwd, buffers, project.nvim, history, sibling folders, and zoxide.
---@return { path: string, source: string, pinned: boolean, is_cwd: boolean, is_git: boolean, is_repo: boolean, rank: integer }[]
function M.get_candidate_projects()
	local store = M.load_projects_store()
	local pinned_map = M.get_pinned_map(store)
	local global_cwd = M.get_global_cwd()
	local home = M.normalize_project_path("~") or vim.uv.os_homedir() or ""
	local wt = state_mod.get_wt()
	local wt_base = (wt and type(wt.get_worktrees_base_dir) == "function") and wt.get_worktrees_base_dir() or nil
	local is_noisy_path = build_noisy_path_checker(home, wt_base)
	local seen = {}
	local candidates = {}

	local function add_candidate(raw, source, force_keep)
		local norm = M.normalize_project_path(raw)
		if not norm or vim.fn.isdirectory(norm) ~= 1 then
			return
		end
		if not force_keep and wt and type(wt.is_linked_worktree) == "function" and wt.is_linked_worktree(norm) then
			local repo_root = type(wt.get_repo_root) == "function" and wt.get_repo_root(norm) or nil
			if type(repo_root) == "string" and repo_root ~= "" and vim.fn.isdirectory(repo_root) == 1 then
				norm = M.normalize_project_path(repo_root) or repo_root
			else
				return
			end
		end
		if seen[norm] then
			return
		end
		local keep_any = force_keep or (norm == global_cwd) or (pinned_map[norm] ~= nil)
		if not keep_any and is_noisy_path(norm) then
			return
		end
		seen[norm] = true
		local is_git = vim.uv.fs_stat(vim.fs.joinpath(norm, ".git")) ~= nil
			or (wt ~= nil and type(wt.get_repo_root) == "function" and wt.get_repo_root(norm) == norm)
		local has_marker = is_git
		if not has_marker then
			for _, m in ipairs(state_mod.PROJECT_MARKERS) do
				if vim.uv.fs_stat(vim.fs.joinpath(norm, m)) ~= nil then
					has_marker = true
					break
				end
			end
		end
		table.insert(candidates, {
			path = norm,
			source = source,
			pinned = pinned_map[norm] ~= nil,
			is_cwd = (norm == global_cwd),
			is_git = is_git,
			is_repo = has_marker,
			rank = #candidates + 1,
		})
	end

	-- 1. Current global cwd & open buffer roots
	add_candidate(global_cwd, "cwd", true)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
			local bname = vim.api.nvim_buf_get_name(buf)
			if bname ~= "" then
				local root = M.detect_safe_project_root(bname)
				if root then
					add_candidate(root, "buffer", false)
				end
			end
		end
	end

	-- 2. Already pinned workspace projects
	for _, entry in ipairs(store.projects) do
		add_candidate(entry.path, "workspace", true)
	end

	-- 3. Saved CodeCompanion history projects
	local cc = package.loaded["codecompanion"]
	local history_ext = cc and cc.extensions and cc.extensions.history
	local saved_map = state_mod.get_cached_history_chats(history_ext)
	for _, item in pairs(saved_map) do
		if type(item) == "table" then
			add_candidate(item.cwd or item.project_root, "history", false)
			if item.project_root and item.project_root ~= item.cwd then
				add_candidate(item.project_root, "history", false)
			end
		end
	end

	-- 4. project.nvim history, 5. zoxide, 6. sibling directories
	collect_project_nvim_candidates(add_candidate)
	collect_zoxide_candidates(add_candidate)
	collect_sibling_candidates(global_cwd, home, add_candidate)

	table.sort(candidates, function(a, b)
		if a.pinned ~= b.pinned then
			return not a.pinned
		end
		if a.is_cwd ~= b.is_cwd then
			return a.is_cwd
		end
		if a.is_git ~= b.is_git then
			return a.is_git
		end
		if a.is_repo ~= b.is_repo then
			return a.is_repo
		end
		return (a.rank or 0) < (b.rank or 0)
	end)

	return candidates
end

return M
