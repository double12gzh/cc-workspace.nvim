-- Candidate project directory discovery from `cwd`, open buffers, workspace store,
-- saved CodeCompanion history, `project.nvim`, sibling directories, and async `zoxide`.

local paths = require("cc_workspace.paths")
local state_mod = require("cc_workspace.state")

local state = state_mod.state

local M = {}

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
			elseif not state.zoxide_cache then
				state.zoxide_cache = {}
				state.zoxide_ts = 0
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

---Collect frequent directory candidates from the asynchronously warmed `zoxide` cache.
---@param add_candidate fun(raw: any, source: string, force_keep: boolean)
local function collect_zoxide_candidates(add_candidate)
	if vim.fn.executable("zoxide") ~= 1 then
		return
	end
	local now_sec = os.time()
	if not state.zoxide_cache or (now_sec - (state.zoxide_ts or 0)) >= 30 then
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
		---@type string?, string?
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

---Resolve workspace store and pinned lookup map from `opts` or deferred `cc_workspace.projects`.
---@param opts? { store?: table, pinned_map?: table<string, table> }
---@return table store, table<string, table> pinned_map
local function resolve_store_and_pinned(opts)
	if type(opts) == "table" and type(opts.store) == "table" and type(opts.pinned_map) == "table" then
		return opts.store, opts.pinned_map
	end
	local ok_prj, prj = pcall(require, "cc_workspace.projects")
	if ok_prj and type(prj) == "table" and type(prj.load_projects_store) == "function" then
		local store = prj.load_projects_store()
		local pinned_map = type(prj.get_pinned_map) == "function" and prj.get_pinned_map(store) or {}
		return store, pinned_map
	end
	return { projects = {}, hidden = {} }, {}
end

---Discover candidate project directories from cwd, buffers, project.nvim, history, sibling folders, and zoxide.
---@param opts? { store?: table, pinned_map?: table<string, table> }
---@return { path: string, source: string, pinned: boolean, is_cwd: boolean, is_git: boolean, is_repo: boolean, rank: integer }[]
function M.get_candidate_projects(opts)
	local store, pinned_map = resolve_store_and_pinned(opts)
	local global_cwd = paths.get_global_cwd()
	local home = paths.normalize_project_path("~") or vim.uv.os_homedir() or ""
	local wt = state_mod.get_wt()
	local wt_base = (wt and type(wt.get_worktrees_base_dir) == "function") and wt.get_worktrees_base_dir() or nil
	local is_noisy_path = build_noisy_path_checker(home, wt_base)
	local seen = {}
	local candidates = {}

	local function add_candidate(raw, source, force_keep)
		local norm = paths.normalize_project_path(raw)
		if not norm or vim.fn.isdirectory(norm) ~= 1 then
			return
		end
		if not force_keep and wt and type(wt.is_linked_worktree) == "function" and wt.is_linked_worktree(norm) then
			local repo_root = type(wt.get_repo_root) == "function" and wt.get_repo_root(norm) or nil
			if type(repo_root) == "string" and repo_root ~= "" and vim.fn.isdirectory(repo_root) == 1 then
				norm = paths.normalize_project_path(repo_root) or repo_root
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
				local root = paths.detect_safe_project_root(bname)
				if root then
					add_candidate(root, "buffer", false)
				end
			end
		end
	end

	-- 2. Already pinned workspace projects
	for _, entry in ipairs(store.projects or {}) do
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
