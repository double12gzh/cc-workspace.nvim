local config = require("cc_workspace.config")
local icons = require("cc_workspace.icons")

local unpack_fn = table.unpack or unpack

local M = {}

M.SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local GIT_INFO_TTL_MS = 5000
local GIT_INFO_FAST_MS = 1000
local HEAD_FAST_TTL_MS = 500
local REALPATH_TTL_MS = 1000
local WORKTREE_STALE_MS = 15000
local MAX_CONCURRENT_GIT_REFRESH = 4
local GIT_SUBPROCESS_TIMEOUT_MS = 5000
local GIT_MUTATION_TIMEOUT_MS = 15000

local GIT_ENV = {
	GIT_TERMINAL_PROMPT = "0",
	GIT_OPTIONAL_LOCKS = "0",
}

local VALID_STATES = {
	thinking = true,
	streaming = true,
	waiting = true,
	error = true,
	unread = true,
	idle = true,
}

local ATTENTION_PRIORITY = {
	waiting = 1,
	error = 2,
	unread = 3,
	streaming = 4,
	thinking = 4,
}

local state = {
	setup_done = false,
	notifications = true,
	worktrees_base_dir = nil,
	last_bg_bufnr = nil,
	anim_idx = 1,
	spinner_timer = nil,
	realpath_cache = {},
	git_info_cache = {},
	head_cache = {},
	worktrees_cache = {},
	inflight_by_root = {},
	orphaned_cbs = {},
	refresh_queue = {},
	active_refresh_jobs = 0,
	ui_refresh_scheduled = false,
	pending_listener_events = {},
	chats = {},
	other_requests = {},
	tools_running = {},
	listeners = {},
}

---Return monotonic time in milliseconds.
---@return number
local function now_ms()
	return vim.uv.hrtime() / 1e6
end

---Run an asynchronous `git` command with non-interactive env and a hard `SIGKILL` watchdog timer
---so child processes or wrappers holding stdout/stderr pipes open cannot wedge past `timeout_ms`.
---@param cmd string[]
---@param timeout_ms integer
---@param on_done fun(res: { code: integer, signal: integer, stdout: string, stderr: string }|nil)
---@return boolean started
local function run_git_async(cmd, timeout_ms, on_done)
	if vim.in_fast_event() then
		vim.schedule(function()
			run_git_async(cmd, timeout_ms, on_done)
		end)
		return true
	end

	local finished = false
	local timer = vim.uv.new_timer()
	local sysobj = nil

	local function finish(res)
		if finished then
			return
		end
		finished = true
		if timer then
			timer:stop()
			if not timer:is_closing() then
				timer:close()
			end
			timer = nil
		end
		if vim.in_fast_event() then
			vim.schedule(function()
				on_done(res)
			end)
		else
			on_done(res)
		end
	end

	local ok, obj = pcall(vim.system, cmd, {
		text = true,
		env = GIT_ENV,
		timeout = timeout_ms,
	}, function(res)
		finish(res)
	end)
	if not ok then
		finish(nil)
		return false
	end
	sysobj = obj

	if timer and timeout_ms and timeout_ms > 0 then
		timer:start(timeout_ms, 0, function()
			if finished then
				return
			end
			if sysobj then
				pcall(sysobj.kill, sysobj, "sigkill")
			end
			finish({
				code = 124,
				signal = 9,
				stdout = "",
				stderr = string.format("git command timed out after %dms", timeout_ms),
			})
		end)
	end
	return true
end

---Read up to `max_bytes` from a file synchronously via libuv without spawning subprocesses.
---@param path string
---@param max_bytes? integer
---@return string|nil
local function read_small_file(path, max_bytes)
	local fd = vim.uv.fs_open(path, "r", 438)
	if not fd then
		return nil
	end
	local content = vim.uv.fs_read(fd, max_bytes or 512, 0)
	vim.uv.fs_close(fd)
	if type(content) ~= "string" then
		return nil
	end
	return content
end

---Format a libuv stat structure into a compact cache key.
---@param st table|nil
---@return string|nil
local function stat_mtime_key(st)
	if not st then
		return nil
	end
	local sec = st.mtime and st.mtime.sec or 0
	local nsec = st.mtime and st.mtime.nsec or 0
	return string.format("%s:%d:%d:%d", st.type or "", sec, nsec, st.size or 0)
end

---Normalize a filesystem path (expanding `~`, resolving relative paths and symlinks when present).
---@param raw_path string|nil
---@return string|nil
function M.normalize_path(raw_path)
	if type(raw_path) ~= "string" then
		return nil
	end
	local trimmed = vim.trim(raw_path)
	if trimmed == "" or trimmed == "Other" then
		return nil
	end
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
		local base = vim.fn.getcwd(-1, -1)
		if type(base) ~= "string" or base == "" then
			base = vim.uv.cwd() or ""
		end
		if base ~= "" then
			expanded = vim.fs.normalize(vim.fs.joinpath(base, expanded))
		end
	end
	if #expanded > 1 then
		expanded = expanded:gsub("/+$", "")
	end
	local t_now = now_ms()
	local cached_real = state.realpath_cache[expanded]
	if cached_real and (t_now - cached_real.ts) < REALPATH_TTL_MS then
		return cached_real.norm
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
	state.realpath_cache[expanded] = { norm = norm, ts = t_now }
	if norm ~= expanded then
		state.realpath_cache[norm] = { norm = norm, ts = t_now }
	end
	return norm
end

---Resolve a potentially relative path against `base_dir` and normalize it.
---@param base_dir string
---@param target string
---@return string|nil
local function resolve_relative_path(base_dir, target)
	local clean = vim.trim(target or "")
	if clean == "" then
		return nil
	end
	if clean:match("^/") or clean:match("^%a:[/\\]") then
		return M.normalize_path(clean)
	end
	return M.normalize_path(vim.fs.joinpath(base_dir, clean))
end

---@class CcGitInfo
---@field worktree_root string
---@field git_dir string
---@field common_git_dir string
---@field repo_root string
---@field dot_git_path string
---@field dot_git_mtime string|nil
---@field is_main boolean

---Check `state.git_info_cache[key]` with a sub-second fast-path before `fs_stat(dot_git_path)`.
---@param key string
---@param t_now number
---@return CcGitInfo|nil info, boolean hit
local function get_fresh_cached_git_info(key, t_now)
	local cached = state.git_info_cache[key]
	if not cached or (t_now - cached.ts) >= GIT_INFO_TTL_MS then
		return nil, false
	end
	if cached.info == false then
		return nil, true
	end
	local info = cached.info
	if info and info.dot_git_path then
		if (t_now - cached.checked_at) < GIT_INFO_FAST_MS then
			return info, true
		end
		local cur_st = vim.uv.fs_stat(info.dot_git_path)
		if cur_st and stat_mtime_key(cur_st) == info.dot_git_mtime then
			cached.checked_at = t_now
			return info, true
		end
	end
	return nil, false
end

---Synchronously inspect `.git` directory or linked-worktree `.git` file in pure Lua/libuv with TTL+mtime caching.
---@param raw_path string|nil
---@return CcGitInfo|nil
local function resolve_git_info(raw_path)
	local norm = M.normalize_path(raw_path)
	if not norm then
		return nil
	end

	local t_now = now_ms()
	local fast_info, fast_hit = get_fresh_cached_git_info(norm, t_now)
	if fast_hit then
		return fast_info
	end

	local st_input = vim.uv.fs_stat(norm)
	local start_dir = norm
	if st_input and st_input.type ~= "directory" then
		start_dir = vim.fs.dirname(norm) or norm
		if start_dir ~= norm then
			local dir_info, dir_hit = get_fresh_cached_git_info(start_dir, t_now)
			if dir_hit then
				return dir_info
			end
		end
	end

	local home = M.normalize_path("~")
	local cur = start_dir
	local resolved = nil

	while cur and cur ~= "" do
		if cur ~= start_dir and (cur == "/" or (home and cur == home)) then
			break
		end

		local dot_git = cur == "/" and "/.git" or (cur .. "/.git")
		local st = vim.uv.fs_stat(dot_git)
		if st then
			if st.type == "directory" then
				local wt_root = M.normalize_path(cur) or cur
				local gdir = M.normalize_path(dot_git) or dot_git
				resolved = {
					worktree_root = wt_root,
					git_dir = gdir,
					common_git_dir = gdir,
					repo_root = wt_root,
					dot_git_path = dot_git,
					dot_git_mtime = stat_mtime_key(st),
					is_main = true,
				}
				break
			elseif st.type == "file" then
				local raw = read_small_file(dot_git, 1024)
				local first_line = raw and raw:match("[^\r\n]+") or nil
				local gitdir_spec = first_line and first_line:match("^gitdir:%s*(.+)$") or nil
				local gdir = gitdir_spec and resolve_relative_path(cur, gitdir_spec) or nil
				if gdir and vim.uv.fs_stat(gdir) then
					local commondir_raw = read_small_file(gdir .. "/commondir", 512)
					local commondir_line = commondir_raw and commondir_raw:match("[^\r\n]+") or nil
					local common_dir = commondir_line and resolve_relative_path(gdir, commondir_line) or nil
					if not common_dir then
						local parent_wt = gdir:match("^(.+)/worktrees/[^/]+$")
						if parent_wt then
							common_dir = M.normalize_path(parent_wt)
						else
							common_dir = gdir
						end
					end

					local wt_root = M.normalize_path(cur) or cur
					local is_linked = (common_dir ~= gdir)
					local repo_root = wt_root
					if is_linked then
						if vim.fs.basename(common_dir) == ".git" then
							repo_root = M.normalize_path(vim.fs.dirname(common_dir)) or common_dir
						else
							repo_root = common_dir
						end
					end

					resolved = {
						worktree_root = wt_root,
						git_dir = gdir,
						common_git_dir = common_dir,
						repo_root = repo_root,
						dot_git_path = dot_git,
						dot_git_mtime = stat_mtime_key(st),
						is_main = not is_linked,
					}
					break
				end
			end
		elseif
			vim.uv.fs_stat(cur .. "/HEAD")
			and vim.uv.fs_stat(cur .. "/refs")
			and vim.uv.fs_stat(cur .. "/objects")
		then
			local norm_cur = M.normalize_path(cur) or cur
			if vim.fs.basename(norm_cur) == ".git" then
				local parent_repo = M.normalize_path(vim.fs.dirname(norm_cur)) or norm_cur
				resolved = {
					worktree_root = parent_repo,
					git_dir = norm_cur,
					common_git_dir = norm_cur,
					repo_root = parent_repo,
					dot_git_path = norm_cur,
					dot_git_mtime = stat_mtime_key(vim.uv.fs_stat(norm_cur)),
					is_main = true,
				}
			else
				resolved = {
					worktree_root = norm_cur,
					git_dir = norm_cur,
					common_git_dir = norm_cur,
					repo_root = norm_cur,
					dot_git_path = norm_cur .. "/HEAD",
					dot_git_mtime = stat_mtime_key(vim.uv.fs_stat(norm_cur .. "/HEAD")),
					is_main = true,
				}
			end
			break
		end

		local parent = vim.fs.dirname(cur)
		if not parent or parent == cur then
			break
		end
		cur = parent
	end

	state.git_info_cache[start_dir] = {
		info = resolved or false,
		ts = t_now,
		checked_at = t_now,
	}
	return resolved
end

---Preserve deduplicated `on_update` callbacks across cache invalidations so queued callers are never dropped.
---@param root string
---@param cbs function[]|nil
local function stash_orphaned_cbs(root, cbs)
	if type(root) ~= "string" or root == "" or type(cbs) ~= "table" or #cbs == 0 then
		return
	end
	local bucket = state.orphaned_cbs[root]
	if not bucket then
		bucket = {}
		state.orphaned_cbs[root] = bucket
	end
	for _, cb in ipairs(cbs) do
		if type(cb) == "function" then
			local dup = false
			for _, existing in ipairs(bucket) do
				if existing == cb then
					dup = true
					break
				end
			end
			if not dup then
				table.insert(bucket, cb)
			end
		end
	end
end

---Invalidate cached git/worktree metadata (for a path or globally when omitted).
---@param path? string
function M.invalidate_git_cache(path)
	if not path then
		for _, item in ipairs(state.refresh_queue) do
			if item.cache_entry then
				item.cache_entry.queued = false
				stash_orphaned_cbs(item.repo_root, item.cache_entry.pending_cbs)
				item.cache_entry.pending_cbs = {}
			end
		end
		state.refresh_queue = {}
		for root, entry in pairs(state.worktrees_cache) do
			if not entry.inflight then
				stash_orphaned_cbs(root, entry.pending_cbs)
			end
		end
		state.realpath_cache = {}
		state.git_info_cache = {}
		state.head_cache = {}
		state.worktrees_cache = {}
		return
	end
	state.realpath_cache = {}
	local info = resolve_git_info(path)
	local norm = M.normalize_path(path)
	state.git_info_cache = {}
	state.head_cache = {}
	local clear_roots = {}
	if info and info.repo_root then
		clear_roots[info.repo_root] = true
	end
	if norm then
		clear_roots[norm] = true
	end
	if next(clear_roots) ~= nil then
		local kept_queue = {}
		for _, item in ipairs(state.refresh_queue) do
			if clear_roots[item.repo_root] then
				if item.cache_entry then
					item.cache_entry.queued = false
					stash_orphaned_cbs(item.repo_root, item.cache_entry.pending_cbs)
					item.cache_entry.pending_cbs = {}
				end
			else
				table.insert(kept_queue, item)
			end
		end
		state.refresh_queue = kept_queue
		for root in pairs(clear_roots) do
			local entry = state.worktrees_cache[root]
			if entry and not entry.inflight then
				stash_orphaned_cbs(root, entry.pending_cbs)
			end
			state.worktrees_cache[root] = nil
		end
	end
end

---Resolve both a normal git repo directory AND a linked git worktree directory back to the canonical main repo root.
---Pure Lua/libuv with mtime/TTL cache — spawns ZERO subprocesses.
---@param path string|nil
---@return string|nil
function M.get_repo_root(path)
	local info = resolve_git_info(path)
	return info and info.repo_root or nil
end

---Resolve `path` to its enclosing worktree working directory (main or linked), or nil if outside git.
---@param path string|nil
---@return string|nil
function M.get_worktree_root(path)
	local info = resolve_git_info(path)
	return info and info.worktree_root or nil
end

---Return true when `path` lies inside a linked (non-main) git worktree.
---@param path string|nil
---@return boolean
function M.is_linked_worktree(path)
	local info = resolve_git_info(path)
	return info ~= nil and not info.is_main
end

---Read branch name (or 7-char detached SHA) and optional commit SHA from a `HEAD` file with mtime caching.
---@param head_file string
---@param common_git_dir? string
---@return string|nil branch, string|nil sha, boolean detached
local function read_head_details(head_file, common_git_dir)
	local t_now = now_ms()
	local cached = state.head_cache[head_file]
	if cached and cached.checked_at and (t_now - cached.checked_at) < HEAD_FAST_TTL_MS then
		return cached.branch, cached.sha, cached.detached
	end
	local st = vim.uv.fs_stat(head_file)
	if not st then
		state.head_cache[head_file] = nil
		return nil, nil, false
	end
	local mkey = stat_mtime_key(st)
	if cached and cached.mtime == mkey then
		cached.checked_at = t_now
		return cached.branch, cached.sha, cached.detached
	end

	local raw = read_small_file(head_file, 512)
	local line = raw and vim.trim(raw:match("[^\r\n]+") or "") or ""
	if line == "" then
		return nil, nil, false
	end

	local branch = nil
	local sha = nil
	local detached = false

	local ref = line:match("^ref:%s*(.+)$")
	if ref then
		ref = vim.trim(ref)
		branch = ref:match("^refs/heads/(.+)$") or ref:match("^refs/(.+)$") or ref
		if common_git_dir then
			local loose = read_small_file(vim.fs.joinpath(common_git_dir, ref), 128)
			if loose then
				local s = vim.trim(loose:match("[^\r\n]+") or "")
				if s:match("^[0-9a-fA-F]+$") then
					sha = s
				end
			end
		end
	elseif line:match("^[0-9a-fA-F]+$") then
		detached = true
		sha = line
		branch = line:sub(1, 7)
	else
		branch = line
	end

	state.head_cache[head_file] = {
		mtime = mkey,
		checked_at = t_now,
		branch = branch,
		sha = sha,
		detached = detached,
	}
	return branch, sha, detached
end

---Return fast cached branch name (or detached short SHA), detached state, and commit SHA read synchronously from `HEAD`.
---@param path string|nil
---@return string|nil branch, boolean detached, string|nil sha
function M.get_worktree_branch(path)
	local info = resolve_git_info(path)
	if not info or not info.git_dir then
		return nil, false, nil
	end
	local branch, sha, detached = read_head_details(info.git_dir .. "/HEAD", info.common_git_dir)
	return branch, detached == true, sha
end

---@class CcWorktreeInfo
---@field path string
---@field branch string
---@field head string
---@field is_main boolean
---@field dirty boolean
---@field locked boolean
---@field prunable boolean
---@field detached? boolean

---Sort worktrees deterministically with `is_main` always first.
---@param list CcWorktreeInfo[]
local function sort_worktree_list(list)
	table.sort(list, function(a, b)
		if a.is_main ~= b.is_main then
			return a.is_main
		end
		if (a.branch or "") ~= (b.branch or "") then
			return (a.branch or "") < (b.branch or "")
		end
		return (a.path or "") < (b.path or "")
	end)
end

---Synchronously seed the initial worktree list from `.git` and `.git/worktrees/*` without spawning subprocesses.
---@param info CcGitInfo
---@return CcWorktreeInfo[]
local function seed_worktrees_from_dot_git(info)
	local list = {}
	local seen = {}

	local main_branch, main_sha, main_detached = read_head_details(info.common_git_dir .. "/HEAD", info.common_git_dir)
	seen[info.repo_root] = true
	table.insert(list, {
		path = info.repo_root,
		branch = main_branch or "HEAD",
		head = main_sha or "",
		is_main = true,
		dirty = false,
		locked = false,
		prunable = vim.fn.isdirectory(info.repo_root) ~= 1,
		detached = main_detached,
	})

	local wt_admin_root = info.common_git_dir .. "/worktrees"
	local scan = vim.uv.fs_scandir(wt_admin_root)
	if scan then
		while true do
			local name, entry_type = vim.uv.fs_scandir_next(scan)
			if not name then
				break
			end
			local admin_dir = wt_admin_root .. "/" .. name
			if not entry_type then
				local st = vim.uv.fs_stat(admin_dir)
				entry_type = st and st.type or nil
			end
			if entry_type == "directory" then
				local gitdir_raw = read_small_file(admin_dir .. "/gitdir", 1024)
				local gitdir_line = gitdir_raw and vim.trim(gitdir_raw:match("[^\r\n]+") or "") or ""
				if gitdir_line ~= "" then
					local dot_git_target = resolve_relative_path(admin_dir, gitdir_line) or gitdir_line
					local wt_dir_raw = vim.fs.basename(dot_git_target) == ".git" and vim.fs.dirname(dot_git_target)
						or dot_git_target
					local wt_path = M.normalize_path(wt_dir_raw) or vim.fs.normalize(wt_dir_raw)
					if wt_path and wt_path ~= "" and not seen[wt_path] then
						seen[wt_path] = true
						local br, sha, det = read_head_details(admin_dir .. "/HEAD", info.common_git_dir)
						local exists = vim.fn.isdirectory(wt_path) == 1
						local locked = vim.uv.fs_stat(admin_dir .. "/locked") ~= nil
						table.insert(list, {
							path = wt_path,
							branch = br or name,
							head = sha or "",
							is_main = false,
							dirty = false,
							locked = locked,
							prunable = not exists,
							detached = det,
						})
					end
				end
			end
		end
	end

	sort_worktree_list(list)
	return list
end

---Parse `git worktree list --porcelain` stdout into structured worktree records.
---@param stdout string
---@param repo_root string
---@param prev_dirty_map table<string, boolean>
---@return CcWorktreeInfo[]
local function parse_worktree_porcelain(stdout, repo_root, prev_dirty_map)
	local entries = {}
	local cur = nil
	local idx = 0

	local function flush_cur()
		if not cur or not cur.path or cur.bare then
			cur = nil
			return
		end
		idx = idx + 1
		local is_main = (cur.path == repo_root) or (idx == 1)
		local branch = cur.branch
		if not branch or branch == "" then
			branch = (cur.head and cur.head ~= "") and cur.head:sub(1, 7) or "HEAD"
		end
		table.insert(entries, {
			path = cur.path,
			branch = branch,
			head = cur.head or "",
			is_main = is_main,
			dirty = prev_dirty_map[cur.path] == true,
			locked = cur.locked == true,
			prunable = cur.prunable == true or vim.fn.isdirectory(cur.path) ~= 1,
			detached = cur.detached == true,
		})
		cur = nil
	end

	for line in (stdout .. "\n"):gmatch("(.-)\r?\n") do
		if line == "" then
			flush_cur()
		elseif line:sub(1, 9) == "worktree " then
			flush_cur()
			local raw_p = line:sub(10)
			cur = {
				path = M.normalize_path(raw_p) or vim.fs.normalize(raw_p),
			}
		elseif cur then
			if line:sub(1, 5) == "HEAD " then
				cur.head = vim.trim(line:sub(6))
			elseif line:sub(1, 7) == "branch " then
				local ref = vim.trim(line:sub(8))
				cur.branch = ref:match("^refs/heads/(.+)$") or ref
			elseif line == "detached" then
				cur.detached = true
			elseif line == "bare" then
				cur.bare = true
			elseif line == "locked" or line:sub(1, 7) == "locked " then
				cur.locked = true
			elseif line == "prunable" or line:sub(1, 9) == "prunable " then
				cur.prunable = true
			end
		end
	end
	flush_cur()

	sort_worktree_list(entries)
	return entries
end

---Compare two worktree record arrays for structural equality.
---@param a CcWorktreeInfo[]|nil
---@param b CcWorktreeInfo[]|nil
---@return boolean
local function worktree_lists_equal(a, b)
	if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then
		return false
	end
	for i = 1, #a do
		local x, y = a[i], b[i]
		if
			not x
			or not y
			or x.path ~= y.path
			or x.branch ~= y.branch
			or x.head ~= y.head
			or (x.is_main == true) ~= (y.is_main == true)
			or (x.dirty == true) ~= (y.dirty == true)
			or (x.locked == true) ~= (y.locked == true)
			or (x.prunable == true) ~= (y.prunable == true)
			or (x.detached == true) ~= (y.detached == true)
		then
			return false
		end
	end
	return true
end

---Compare two worktree record arrays for UI-visible equality (`head` only matters when `branch == ""`).
---@param a CcWorktreeInfo[]|nil
---@param b CcWorktreeInfo[]|nil
---@return boolean
local function worktree_lists_ui_equal(a, b)
	if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then
		return false
	end
	for i = 1, #a do
		local x, y = a[i], b[i]
		if not x or not y then
			return false
		end
		local x_br = x.branch or ""
		local y_br = y.branch or ""
		local x_disp_head = x_br == "" and (x.head or "") or ""
		local y_disp_head = y_br == "" and (y.head or "") or ""
		if
			x.path ~= y.path
			or x_br ~= y_br
			or x_disp_head ~= y_disp_head
			or (x.is_main == true) ~= (y.is_main == true)
			or (x.dirty == true) ~= (y.dirty == true)
			or (x.locked == true) ~= (y.locked == true)
			or (x.prunable == true) ~= (y.prunable == true)
			or (x.detached == true) ~= (y.detached == true)
		then
			return false
		end
	end
	return true
end

---Append an `on_update` callback to `entry.pending_cbs` without duplicating identical function references.
---@param entry table
---@param cb function|nil
local function add_pending_cb(entry, cb)
	if type(cb) ~= "function" then
		return
	end
	entry.pending_cbs = entry.pending_cbs or {}
	for _, existing in ipairs(entry.pending_cbs) do
		if existing == cb then
			return
		end
	end
	table.insert(entry.pending_cbs, cb)
end

local enqueue_refresh
local pump_refresh_queue

---Execute a single bounded asynchronous `git worktree list --porcelain` + per-worktree `git status --porcelain -unormal`.
---@param repo_root string
---@param cache_entry table
local function start_refresh_job(repo_root, cache_entry)
	if vim.fn.executable("git") ~= 1 then
		local had_unloaded = not cache_entry.async_loaded
		cache_entry.async_loaded = true
		cache_entry.fetched_at = now_ms()
		cache_entry.inflight = false
		cache_entry.rerun = false
		if state.inflight_by_root[repo_root] == cache_entry then
			state.inflight_by_root[repo_root] = nil
		end
		local cbs = cache_entry.pending_cbs or {}
		cache_entry.pending_cbs = {}
		if #cbs > 0 then
			local snapshot = vim.deepcopy(cache_entry.list or {})
			vim.schedule(function()
				for _, cb in ipairs(cbs) do
					pcall(cb, snapshot, had_unloaded)
				end
			end)
		end
		return
	end

	cache_entry.inflight = true
	cache_entry.rerun = false
	state.inflight_by_root[repo_root] = cache_entry
	state.active_refresh_jobs = state.active_refresh_jobs + 1
	local job_started_ms = now_ms()

	local prev_dirty = {}
	for _, item in ipairs(cache_entry.list or {}) do
		if item.path then
			prev_dirty[item.path] = item.dirty == true
		end
	end

	local job_done = false
	local function finalize(updated_list)
		if job_done then
			return
		end
		job_done = true
		vim.schedule(function()
			state.active_refresh_jobs = math.max(0, state.active_refresh_jobs - 1)
			if state.inflight_by_root[repo_root] == cache_entry then
				state.inflight_by_root[repo_root] = nil
			end
			local changed = false
			local ui_changed = false
			if updated_list then
				changed = not worktree_lists_equal(cache_entry.list, updated_list)
				ui_changed = not worktree_lists_ui_equal(cache_entry.list, updated_list)
				cache_entry.list = updated_list
			end
			cache_entry.dirty_change = (cache_entry.dirty_change == true) or changed
			cache_entry.ui_change = (cache_entry.ui_change == true) or ui_changed
			cache_entry.async_loaded = true
			cache_entry.fetched_at = now_ms()
			cache_entry.inflight = false

			local orphaned = state.orphaned_cbs[repo_root]
			if orphaned then
				state.orphaned_cbs[repo_root] = nil
				for _, cb in ipairs(orphaned) do
					add_pending_cb(cache_entry, cb)
				end
			end

			local active_entry = state.worktrees_cache[repo_root]
			if active_entry and active_entry ~= cache_entry then
				for _, cb in ipairs(cache_entry.pending_cbs or {}) do
					add_pending_cb(active_entry, cb)
				end
				cache_entry.pending_cbs = {}
				cache_entry.rerun = false
				cache_entry.dirty_change = false
				cache_entry.ui_change = false
				if not active_entry.inflight and not active_entry.queued then
					enqueue_refresh(repo_root, active_entry, active_entry.pending_explicit == true)
					active_entry.pending_explicit = false
				end
				pump_refresh_queue()
				return
			end

			if cache_entry.rerun then
				cache_entry.rerun = false
				enqueue_refresh(repo_root, cache_entry, true)
				pump_refresh_queue()
				return
			end

			local any_changed = cache_entry.dirty_change == true
			local any_ui_changed = cache_entry.ui_change == true
			cache_entry.dirty_change = false
			cache_entry.ui_change = false
			local cbs = cache_entry.pending_cbs or {}
			cache_entry.pending_cbs = {}
			pump_refresh_queue()

			if #cbs > 0 then
				local snapshot = vim.deepcopy(cache_entry.list or {})
				for _, cb in ipairs(cbs) do
					pcall(cb, snapshot, any_changed, any_ui_changed)
				end
			end
		end)
	end

	run_git_async(
		{ "git", "--no-optional-locks", "-C", repo_root, "worktree", "list", "--porcelain" },
		GIT_SUBPROCESS_TIMEOUT_MS,
		function(res)
			if not res or res.code ~= 0 or type(res.stdout) ~= "string" then
				finalize(nil)
				return
			end

			vim.schedule(function()
				local parsed = parse_worktree_porcelain(res.stdout, repo_root, prev_dirty)
				if #parsed == 0 then
					finalize(parsed)
					return
				end

				local remaining = 0
				for _, wt in ipairs(parsed) do
					if not wt.prunable and vim.fn.isdirectory(wt.path) == 1 then
						remaining = remaining + 1
					else
						wt.dirty = false
					end
				end

				if remaining == 0 then
					finalize(parsed)
					return
				end

				local rem_timeout = math.max(500, math.floor(GIT_SUBPROCESS_TIMEOUT_MS - (now_ms() - job_started_ms)))
				for _, wt in ipairs(parsed) do
					if not wt.prunable and vim.fn.isdirectory(wt.path) == 1 then
						run_git_async(
							{ "git", "--no-optional-locks", "-C", wt.path, "status", "--porcelain", "-unormal" },
							rem_timeout,
							function(st_res)
								if st_res and st_res.code == 0 and type(st_res.stdout) == "string" then
									wt.dirty = vim.trim(st_res.stdout) ~= ""
								end
								remaining = remaining - 1
								if remaining <= 0 then
									finalize(parsed)
								end
							end
						)
					end
				end
			end)
		end
	)
end

pump_refresh_queue = function()
	while state.active_refresh_jobs < MAX_CONCURRENT_GIT_REFRESH and #state.refresh_queue > 0 do
		local item = table.remove(state.refresh_queue, 1)
		local entry = item.cache_entry
		entry.queued = false
		local active_entry = state.worktrees_cache[item.repo_root]
		local inflight_entry = state.inflight_by_root[item.repo_root]
		if inflight_entry then
			if active_entry and active_entry ~= inflight_entry then
				for _, cb in ipairs(entry.pending_cbs or {}) do
					add_pending_cb(active_entry, cb)
				end
				if entry ~= active_entry then
					entry.pending_cbs = {}
				end
			else
				for _, cb in ipairs(entry.pending_cbs or {}) do
					add_pending_cb(inflight_entry, cb)
				end
				if entry ~= inflight_entry then
					entry.pending_cbs = {}
				end
				inflight_entry.rerun = true
			end
		elseif active_entry ~= entry then
			if active_entry then
				for _, cb in ipairs(entry.pending_cbs or {}) do
					add_pending_cb(active_entry, cb)
				end
				entry.pending_cbs = {}
				if not active_entry.inflight and not active_entry.queued then
					enqueue_refresh(item.repo_root, active_entry, true)
				end
			else
				stash_orphaned_cbs(item.repo_root, entry.pending_cbs)
				entry.pending_cbs = {}
			end
		elseif not entry.inflight then
			start_refresh_job(item.repo_root, entry)
		end
	end
end

---Enqueue a repository worktree refresh with bounded concurrency and explicit-refresh priority.
---@param repo_root string
---@param cache_entry table
---@param is_explicit boolean
enqueue_refresh = function(repo_root, cache_entry, is_explicit)
	local inflight_entry = state.inflight_by_root[repo_root]
	if inflight_entry then
		if inflight_entry == cache_entry then
			if is_explicit then
				cache_entry.rerun = true
			end
		else
			cache_entry.pending_explicit = (cache_entry.pending_explicit == true) or is_explicit
		end
		return
	end
	if cache_entry.inflight then
		if is_explicit then
			cache_entry.rerun = true
		end
		return
	end
	if cache_entry.queued then
		if is_explicit then
			for i, item in ipairs(state.refresh_queue) do
				if item.cache_entry == cache_entry then
					if i > 1 then
						table.remove(state.refresh_queue, i)
						table.insert(state.refresh_queue, 1, item)
					end
					break
				end
			end
		end
		return
	end
	cache_entry.queued = true
	local job = { repo_root = repo_root, cache_entry = cache_entry }
	if is_explicit then
		table.insert(state.refresh_queue, 1, job)
	else
		table.insert(state.refresh_queue, job)
	end
	pump_refresh_queue()
end

---Return cached list of `{ path, branch, head, is_main, dirty, locked, prunable }` for `repo_path`.
---Seeds synchronously from `.git` on first access so UI never blocks, and refreshes asynchronously when stale (>15s) or `opts.refresh == true`.
---@param repo_path string|nil
---@param opts? { refresh?: boolean, on_update?: fun(list: CcWorktreeInfo[], changed?: boolean, ui_changed?: boolean) }
---@return CcWorktreeInfo[]
function M.list_worktrees(repo_path, opts)
	opts = opts or {}
	local info = resolve_git_info(repo_path)
	if not info or not info.repo_root then
		if type(opts.on_update) == "function" and opts.refresh then
			vim.schedule(function()
				opts.on_update({}, false)
			end)
		end
		return {}
	end

	local root = info.repo_root
	local entry = state.worktrees_cache[root]
	if not entry then
		entry = {
			list = seed_worktrees_from_dot_git(info),
			fetched_at = 0,
			async_loaded = false,
			inflight = false,
			queued = false,
			rerun = false,
			pending_explicit = false,
			dirty_change = false,
			pending_cbs = {},
		}
		local orphaned = state.orphaned_cbs[root]
		if orphaned then
			state.orphaned_cbs[root] = nil
			for _, cb in ipairs(orphaned) do
				add_pending_cb(entry, cb)
			end
		end
		state.worktrees_cache[root] = entry
	else
		for _, wt in ipairs(entry.list) do
			if not wt.prunable then
				local live_branch, live_detached, live_sha = M.get_worktree_branch(wt.path)
				if live_branch and live_branch ~= "" then
					wt.branch = live_branch
					wt.detached = live_detached == true
					if live_sha and live_sha ~= "" then
						wt.head = live_sha
					end
				end
			end
		end
	end

	local explicit_refresh = opts.refresh == true
	local stale = (not entry.async_loaded) or ((now_ms() - entry.fetched_at) > WORKTREE_STALE_MS)
	local root_inflight = state.inflight_by_root[root] ~= nil
	if explicit_refresh or stale or entry.inflight or entry.queued or root_inflight then
		add_pending_cb(entry, opts.on_update)
		if explicit_refresh then
			enqueue_refresh(root, entry, true)
		elseif stale and not entry.inflight and not entry.queued then
			enqueue_refresh(root, entry, false)
		end
	end

	return vim.deepcopy(entry.list)
end

---Override base directory under which managed git worktrees are created (useful for isolated tests).
---@param dir string|nil
function M.set_worktrees_base_dir(dir)
	state.worktrees_base_dir = (type(dir) == "string" and dir ~= "") and M.normalize_path(dir) or nil
end

---Return base directory under which managed git worktrees are stored.
---@return string
function M.get_worktrees_base_dir()
	if state.worktrees_base_dir and state.worktrees_base_dir ~= "" then
		return state.worktrees_base_dir
	end
	local cfg_dir = config.options and config.options.worktrees_base_dir or nil
	if type(cfg_dir) == "string" and cfg_dir ~= "" then
		return M.normalize_path(cfg_dir) or cfg_dir
	end
	return vim.fs.joinpath(vim.fn.stdpath("data"), "cc-worktrees")
end

---Sanitize a git branch name into a clean single-segment directory name (`feat/auth` -> `feat-auth`).
---@param branch string|nil
---@return string
function M.sanitize_branch_dir(branch)
	local s = vim.trim(tostring(branch or ""))
	s = s:gsub("^refs/heads/", ""):gsub("^refs/remotes/origin/", ""):gsub("^origin/", "")
	s = s:gsub("[^%w%._%-]+", "-"):gsub("%-+", "-"):gsub("^[%.%-]+", ""):gsub("[%.%-]+$", "")
	return s ~= "" and s or "worktree"
end

---Compute clean default worktree directory: `stdpath("data")/cc-worktrees/<repo_basename>-<hash6>/<sanitized_branch>`.
---@param repo_path string
---@param branch string
---@return string
function M.default_worktree_dir(repo_path, branch)
	local root = M.get_repo_root(repo_path) or M.normalize_path(repo_path) or tostring(repo_path or "repo")
	local raw_base = vim.fs.basename(root) or "repo"
	local safe_repo = raw_base:gsub("[^%w%._%-]+", "-"):gsub("^[%.%-]+", ""):gsub("[%.%-]+$", "")
	if safe_repo == "" then
		safe_repo = "repo"
	end
	local hash6 = vim.fn.sha256(root):sub(1, 6)
	local safe_branch = M.sanitize_branch_dir(branch)
	return vim.fs.joinpath(M.get_worktrees_base_dir(), string.format("%s-%s", safe_repo, hash6), safe_branch)
end

---Extract concise single-line error message from `vim.system` output.
---@param res table|nil
---@param fallback string
---@return string
local function format_git_error(res, fallback)
	if not res then
		return fallback
	end
	local raw = vim.trim((res.stderr and res.stderr ~= "" and res.stderr) or res.stdout or "")
	if raw == "" then
		return fallback
	end
	local lines = vim.split(raw, "\n", { plain = true, trimempty = true })
	return lines[#lines] or raw
end

---Asynchronously create a git worktree for an existing local/remote branch or a new branch (`-b`).
---@param repo_path string
---@param opts { branch: string, base_ref?: string, target_dir?: string }|string
---@param cb? fun(wt_info: CcWorktreeInfo|nil, err: string|nil)
function M.create_worktree(repo_path, opts, cb)
	if type(opts) == "string" then
		opts = { branch = opts }
	end
	opts = opts or {}

	local function done(wt_info, err)
		if type(cb) == "function" then
			vim.schedule(function()
				cb(wt_info, err)
			end)
		end
	end

	local root = M.get_repo_root(repo_path)
	if not root then
		done(nil, "Not a git repository: " .. tostring(repo_path))
		return
	end

	local raw_branch = vim.trim(opts.branch or "")
	raw_branch = raw_branch:gsub("^refs/heads/", "")
	if raw_branch == "" then
		done(nil, "Branch name cannot be empty")
		return
	end

	local had_origin_prefix = raw_branch:match("^remotes/origin/") ~= nil or raw_branch:match("^origin/") ~= nil
	local clean_branch = raw_branch:gsub("^remotes/origin/", ""):gsub("^origin/", "")
	if clean_branch == "" then
		done(nil, "Invalid branch name: " .. raw_branch)
		return
	end

	local target_dir = (type(opts.target_dir) == "string" and vim.trim(opts.target_dir) ~= "")
			and M.normalize_path(opts.target_dir)
		or M.default_worktree_dir(root, clean_branch)
	if not target_dir then
		done(nil, "Could not resolve target directory for worktree")
		return
	end

	local parent_dir = vim.fs.dirname(target_dir)
	if parent_dir and parent_dir ~= "" then
		pcall(vim.fn.mkdir, parent_dir, "p")
	end

	run_git_async(
		{
			"git",
			"--no-optional-locks",
			"-C",
			root,
			"for-each-ref",
			"--format=%(refname)",
			"refs/heads/" .. clean_branch,
			"refs/remotes/origin/" .. clean_branch,
		},
		GIT_SUBPROCESS_TIMEOUT_MS,
		function(ref_res)
			local has_local = false
			local has_remote = false
			if ref_res and ref_res.code == 0 and type(ref_res.stdout) == "string" then
				for line in ref_res.stdout:gmatch("[^\r\n]+") do
					local ref = vim.trim(line)
					if ref == "refs/heads/" .. clean_branch then
						has_local = true
					elseif ref == "refs/remotes/origin/" .. clean_branch then
						has_remote = true
					end
				end
			end

			local cmd = { "git", "-C", root, "worktree", "add" }
			if has_local then
				table.insert(cmd, target_dir)
				table.insert(cmd, clean_branch)
			elseif has_remote or had_origin_prefix then
				table.insert(cmd, "--track")
				table.insert(cmd, "-b")
				table.insert(cmd, clean_branch)
				table.insert(cmd, target_dir)
				table.insert(cmd, "origin/" .. clean_branch)
			else
				table.insert(cmd, "-b")
				table.insert(cmd, clean_branch)
				table.insert(cmd, target_dir)
				local base_ref = type(opts.base_ref) == "string" and vim.trim(opts.base_ref) or ""
				if base_ref ~= "" then
					table.insert(cmd, base_ref)
				end
			end

			run_git_async(cmd, GIT_MUTATION_TIMEOUT_MS, function(add_res)
				if not add_res or add_res.code ~= 0 then
					done(nil, format_git_error(add_res, "git worktree add failed"))
					return
				end

				vim.schedule(function()
					M.invalidate_git_cache(root)
					local norm_target = M.normalize_path(target_dir) or target_dir
					M.list_worktrees(root, {
						refresh = true,
						on_update = function(list)
							local matched = nil
							for _, wt in ipairs(list) do
								if wt.path == norm_target or wt.branch == clean_branch then
									matched = wt
									break
								end
							end
							if not matched then
								matched = {
									path = norm_target,
									branch = clean_branch,
									head = "",
									is_main = false,
									dirty = false,
									locked = false,
									prunable = false,
								}
							end
							done(matched, nil)
						end,
					})
				end)
			end)
		end
	)
end

---Interactive Orca-style worktree creator (Telescope branch/custom input or `vim.ui.input` fallback).
---@param repo_path? string
---@param cb? fun(wt_info: CcWorktreeInfo)
function M.prompt_create_worktree(repo_path, cb)
	if vim.fn.mode():sub(1, 1) == "i" then
		vim.cmd("stopinsert")
	end

	local probe = repo_path
	if type(probe) ~= "string" or probe == "" then
		probe = vim.fn.getcwd()
	end
	local root = M.get_repo_root(probe)
	if not root then
		vim.notify("Current project is not a Git repository", vim.log.levels.WARN, { title = "Git Worktree" })
		return
	end

	local repo_name = vim.fs.basename(root) or "repo"
	local branch_icon = icons.git.Branch

	local function run_create(branch_name)
		local trimmed = vim.trim(branch_name or "")
		if trimmed == "" then
			return
		end
		M.create_worktree(root, { branch = trimmed }, function(wt_info, err)
			if err or not wt_info then
				vim.notify(
					"Failed to create worktree: " .. tostring(err or "unknown error"),
					vim.log.levels.ERROR,
					{ title = "Git Worktree" }
				)
				return
			end
			vim.notify(
				string.format(
					"Created worktree %s %s (%s)",
					branch_icon,
					wt_info.branch,
					vim.fn.fnamemodify(wt_info.path, ":~")
				),
				vim.log.levels.INFO,
				{ title = "Git Worktree" }
			)
			if type(cb) == "function" then
				cb(wt_info)
			end
		end)
	end

	local function fallback_input(default_text)
		vim.ui.input({
			prompt = string.format("New Git Worktree branch (%s): ", repo_name),
			default = default_text or "",
		}, function(input)
			if type(input) == "string" and vim.trim(input) ~= "" then
				run_create(input)
			end
		end)
	end

	local ok_pickers, pickers = pcall(require, "telescope.pickers")
	local ok_finders, finders = pcall(require, "telescope.finders")
	local ok_conf, conf_mod = pcall(require, "telescope.config")
	local ok_actions, actions = pcall(require, "telescope.actions")
	local ok_state, action_state = pcall(require, "telescope.actions.state")

	if #vim.api.nvim_list_uis() == 0 or not (ok_pickers and ok_finders and ok_conf and ok_actions and ok_state) then
		fallback_input("")
		return
	end

	local existing_wts = M.list_worktrees(root)
	local wt_by_branch = {}
	for _, wt in ipairs(existing_wts) do
		if wt.branch and wt.branch ~= "" then
			wt_by_branch[wt.branch] = wt
		end
	end

	run_git_async(
		{
			"git",
			"--no-optional-locks",
			"-C",
			root,
			"for-each-ref",
			"--count=400",
			"--sort=-committerdate",
			"--format=%(refname)\t%(objectname:short)\t%(subject)",
			"refs/heads",
			"refs/remotes/origin",
		},
		GIT_SUBPROCESS_TIMEOUT_MS,
		vim.schedule_wrap(function(res)
			local items = {
				{
					create_new = true,
					display = " + Create new branch worktree (type branch name above or press <CR>)…",
					ordinal = "create new branch worktree feat fix",
				},
			}

			local seen_branches = {}
			if res and res.code == 0 and type(res.stdout) == "string" then
				for line in res.stdout:gmatch("[^\r\n]+") do
					local ref, sha, subj = line:match("^(.-)\t(.-)\t(.*)$")
					if ref and ref ~= "refs/remotes/origin/HEAD" then
						local is_remote = ref:sub(1, 20) == "refs/remotes/origin/"
						local short_br = is_remote and ref:sub(21) or (ref:match("^refs/heads/(.+)$") or ref)
						if short_br ~= "" and short_br ~= "HEAD" and not seen_branches[short_br] then
							seen_branches[short_br] = true
							local active_wt = wt_by_branch[short_br]
							local tag = active_wt and "[checked out]" or (is_remote and "[origin]" or "[local]")
							local clean_subj = (subj or ""):gsub("%s+", " "):sub(1, 44)
							table.insert(items, {
								branch = short_br,
								existing_wt = active_wt,
								display = string.format(
									" %s %-24s %-13s %s  %s",
									branch_icon,
									short_br,
									tag,
									sha or "",
									clean_subj
								),
								ordinal = string.format("%s %s %s", short_br, tag, clean_subj),
							})
						end
					end
				end
			end

			pickers
				.new({}, {
					prompt_title = string.format("Git Worktree (%s) — Type new branch or select existing", repo_name),
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
						width = 0.66,
						height = 0.54,
						prompt_position = "top",
					},
					sorting_strategy = "ascending",
					attach_mappings = function(prompt_bufnr)
						actions.select_default:replace(function()
							local prompt_line = vim.trim(action_state.get_current_line() or "")
							local selection = action_state.get_selected_entry()
							actions.close(prompt_bufnr)

							vim.schedule(function()
								if selection and selection.value then
									if selection.value.create_new then
										if prompt_line ~= "" then
											run_create(prompt_line)
										else
											fallback_input("feat/")
										end
										return
									end
									if selection.value.existing_wt then
										vim.notify(
											string.format(
												"Using existing worktree %s %s (%s)",
												branch_icon,
												selection.value.branch,
												vim.fn.fnamemodify(selection.value.existing_wt.path, ":~")
											),
											vim.log.levels.INFO,
											{ title = "Git Worktree" }
										)
										if type(cb) == "function" then
											cb(selection.value.existing_wt)
										end
										return
									end
									if selection.value.branch then
										run_create(selection.value.branch)
										return
									end
								end

								if prompt_line ~= "" then
									run_create(prompt_line)
								end
							end)
						end)
						return true
					end,
				})
				:find()
		end)
	)
end

---Asynchronously remove a linked git worktree (refusing `is_main`, checking dirty status unless `opts.force`, and pruning).
---@param wt_path string
---@param opts? { force?: boolean }|fun(ok: boolean, err: string|nil)
---@param cb? fun(ok: boolean, err: string|nil)
function M.remove_worktree(wt_path, opts, cb)
	if type(opts) == "function" then
		cb = opts
		opts = {}
	end
	opts = opts or {}

	local function done(ok, err)
		if type(cb) == "function" then
			vim.schedule(function()
				cb(ok, err)
			end)
		end
	end

	local norm_wt = M.normalize_path(wt_path)
	if not norm_wt then
		done(false, "Invalid worktree path")
		return
	end

	local info = resolve_git_info(norm_wt)
	local root = info and info.repo_root or nil
	if info and (info.is_main or info.worktree_root == info.repo_root) then
		done(false, "Refusing to remove main repository worktree: " .. norm_wt)
		return
	end

	if not root then
		for cached_root, entry in pairs(state.worktrees_cache) do
			for _, wt in ipairs(entry.list or {}) do
				if wt.path == norm_wt then
					if wt.is_main then
						done(false, "Refusing to remove main repository worktree: " .. norm_wt)
						return
					end
					root = cached_root
					break
				end
			end
			if root then
				break
			end
		end
	end

	if not root then
		done(false, "Not a linked git worktree: " .. norm_wt)
		return
	end

	if norm_wt == root then
		done(false, "Refusing to remove main repository worktree: " .. norm_wt)
		return
	end

	local target_wt = (info and info.worktree_root) or norm_wt

	local function run_git_remove()
		local cmd = { "git", "-C", root, "worktree", "remove" }
		if opts.force then
			table.insert(cmd, "--force")
			table.insert(cmd, "--force")
		end
		table.insert(cmd, target_wt)

		run_git_async(cmd, GIT_MUTATION_TIMEOUT_MS, function(rm_res)
			if not rm_res or rm_res.code ~= 0 then
				done(false, format_git_error(rm_res, "git worktree remove failed"))
				return
			end

			run_git_async({ "git", "-C", root, "worktree", "prune" }, GIT_SUBPROCESS_TIMEOUT_MS, function()
				vim.schedule(function()
					local parent = vim.fs.dirname(target_wt)
					local base = M.get_worktrees_base_dir()
					if parent and base and parent:sub(1, #base + 1) == base .. "/" then
						pcall(vim.uv.fs_rmdir, parent)
					end
					M.invalidate_git_cache(root)
					M.list_worktrees(root, {
						refresh = true,
						on_update = function()
							done(true, nil)
						end,
					})
				end)
			end)
		end)
	end

	if not opts.force and vim.fn.isdirectory(target_wt) == 1 then
		run_git_async(
			{ "git", "--no-optional-locks", "-C", target_wt, "status", "--porcelain", "-unormal" },
			GIT_SUBPROCESS_TIMEOUT_MS,
			function(st_res)
				if
					st_res
					and st_res.code == 0
					and type(st_res.stdout) == "string"
					and vim.trim(st_res.stdout) ~= ""
				then
					done(false, "Worktree has uncommitted or untracked changes (use force = true to remove)")
					return
				end
				run_git_remove()
			end
		)
	else
		run_git_remove()
	end
end

-- ============================================================================
-- 2. Unified Agent Request Tracking, Status & Notification Engine
-- ============================================================================

---Define Orca/Herdr agent lifecycle highlight groups (refreshed on `ColorScheme`).
function M.setup_highlights()
	local links = {
		CcAgentThinking = "DiagnosticWarn",
		CcAgentStreaming = "DiagnosticOk",
		CcAgentWaiting = "DiagnosticError",
		CcAgentError = "DiagnosticError",
		CcAgentActive = "DiagnosticInfo",
		CcAgentIdle = "Comment",
	}
	for group, target in pairs(links) do
		vim.api.nvim_set_hl(0, group, { link = target, default = true })
	end

	local ok_ok, diag_ok = pcall(vim.api.nvim_get_hl, 0, { name = "DiagnosticOk", link = false })
	local unread_fg = (ok_ok and type(diag_ok) == "table" and diag_ok.fg) and string.format("#%06x", diag_ok.fg) or nil
	if not unread_fg then
		unread_fg = vim.o.background == "light" and "#2e7d32" or "#89b482"
	end
	vim.api.nvim_set_hl(0, "CcAgentUnread", { fg = unread_fg, bold = true })
end

---Register a callback invoked whenever an agent chat's status changes.
---@param cb fun(bufnr: integer, state_name: string)
---@return fun() unsubscribe
function M.on_change(cb)
	if type(cb) ~= "function" then
		return function() end
	end
	table.insert(state.listeners, cb)
	return function()
		for i = #state.listeners, 1, -1 do
			if state.listeners[i] == cb then
				table.remove(state.listeners, i)
				break
			end
		end
	end
end

---Return the current spinner animation frame index (`1..#M.SPINNER_FRAMES`).
---@return integer
function M.get_anim_idx()
	return state.anim_idx
end

---Return the most recently completed/errored/waiting background chat buffer number, if any.
---@return integer|nil
function M.get_last_background_bufnr()
	if state.last_bg_bufnr and vim.api.nvim_buf_is_valid(state.last_bg_bufnr) then
		return state.last_bg_bufnr
	end
	state.last_bg_bufnr = nil
	return nil
end

---Clear the tracked last background chat buffer number.
function M.clear_last_background_bufnr()
	state.last_bg_bufnr = nil
end

---Count currently running (`thinking` or `streaming`) agent requests across chats and non-chat interactions.
---@return integer
local function count_running_requests()
	local n = 0
	for bufnr, entry in pairs(state.chats) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			if entry.state == "thinking" or entry.state == "streaming" then
				n = n + 1
			end
		else
			state.chats[bufnr] = nil
			state.tools_running[bufnr] = nil
		end
	end
	for key, req in pairs(state.other_requests) do
		if req.bufnr and not vim.api.nvim_buf_is_valid(req.bufnr) then
			state.other_requests[key] = nil
		else
			n = n + 1
		end
	end
	return n
end

local function stop_spinner_timer()
	if state.spinner_timer then
		state.spinner_timer:stop()
		if not state.spinner_timer:is_closing() then
			state.spinner_timer:close()
		end
		state.spinner_timer = nil
	end
end

local function ensure_spinner_timer()
	if state.spinner_timer then
		return
	end
	local timer = vim.uv.new_timer()
	if not timer then
		return
	end
	state.spinner_timer = timer
	timer:start(
		140,
		140,
		vim.schedule_wrap(function()
			if count_running_requests() <= 0 then
				stop_spinner_timer()
				return
			end
			state.anim_idx = (state.anim_idx % #M.SPINNER_FRAMES) + 1
			pcall(function()
				require("cc_workspace.winbar").refresh()
			end)
			pcall(vim.cmd.redrawstatus)
		end)
	)
end

---Schedule coalesced UI chrome refreshes (winbar, statusline, workspace sidebar, subscribers).
---@param bufnr integer
---@param state_name string
local function notify_ui_changed(bufnr, state_name)
	table.insert(state.pending_listener_events, { bufnr = bufnr, state_name = state_name })
	if state.ui_refresh_scheduled then
		return
	end
	state.ui_refresh_scheduled = true
	vim.schedule(function()
		state.ui_refresh_scheduled = false
		local events = state.pending_listener_events
		state.pending_listener_events = {}

		pcall(function()
			require("cc_workspace.winbar").refresh()
		end)
		local ws = package.loaded["cc_workspace"]
		if type(ws) == "table" and type(ws.is_current_tab) == "function" and ws.is_current_tab() then
			if type(ws.schedule_render) == "function" then
				pcall(ws.schedule_render)
			elseif type(ws.render) == "function" then
				pcall(ws.render)
			end
		end
		pcall(vim.cmd.redrawstatus)
		if #state.listeners > 0 then
			for _, ev in ipairs(events) do
				for _, fn in ipairs(state.listeners) do
					pcall(fn, ev.bufnr, ev.state_name)
				end
			end
		end
	end)
end

---Extract readable adapter display name from an event or chat adapter payload.
---@param raw_adapter any
---@return string|nil
local function extract_adapter_name(raw_adapter)
	if type(raw_adapter) == "table" then
		local name = raw_adapter.name or raw_adapter.formatted_name
		if type(name) == "string" and name ~= "" then
			return name
		end
	elseif type(raw_adapter) == "string" and raw_adapter ~= "" then
		return raw_adapter
	end
	return nil
end

---@class CcActiveRequest
---@field bufnr integer|nil
---@field interaction string
---@field adapter string
---@field phase "thinking"|"streaming"
---@field started_at number
---@field elapsed integer

---Return all currently active (`thinking` or `streaming`) requests sorted by `bufnr`.
---@return CcActiveRequest[]
function M.get_active_requests()
	local now_hr = vim.uv.hrtime()
	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	local list = {}

	for bufnr, entry in pairs(state.chats) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			if entry.state == "thinking" or entry.state == "streaming" then
				local started_at = entry.started_at or now_hr
				local adapter_name = entry.adapter
				if
					(not adapter_name or adapter_name == "")
					and chat_mod
					and type(chat_mod.buf_get_chat) == "function"
				then
					local c = chat_mod.buf_get_chat(bufnr)
					if c and c.adapter then
						adapter_name = extract_adapter_name(c.adapter)
					end
				end
				table.insert(list, {
					bufnr = bufnr,
					interaction = "chat",
					adapter = adapter_name or "AI",
					phase = entry.state,
					started_at = started_at,
					elapsed = math.max(0, math.floor((now_hr - started_at) / 1e9)),
				})
			end
		else
			state.chats[bufnr] = nil
			state.tools_running[bufnr] = nil
		end
	end

	for key, req in pairs(state.other_requests) do
		if req.bufnr and not vim.api.nvim_buf_is_valid(req.bufnr) then
			state.other_requests[key] = nil
		else
			local started_at = req.started_at or now_hr
			table.insert(list, {
				bufnr = req.bufnr,
				interaction = req.interaction or "other",
				adapter = req.adapter or "AI",
				phase = req.phase == "streaming" and "streaming" or "thinking",
				started_at = started_at,
				elapsed = math.max(0, math.floor((now_hr - started_at) / 1e9)),
			})
		end
	end

	table.sort(list, function(a, b)
		local ab = a.bufnr or math.huge
		local bb = b.bufnr or math.huge
		if ab ~= bb then
			return ab < bb
		end
		return (a.started_at or 0) < (b.started_at or 0)
	end)
	return list
end

---Return true when `bufnr` currently has an active (`thinking` or `streaming`) request.
---@param bufnr integer|nil
---@return boolean
function M.has_active_request(bufnr)
	if type(bufnr) ~= "number" or bufnr <= 0 or not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	local entry = state.chats[bufnr]
	if entry and (entry.state == "thinking" or entry.state == "streaming") then
		return true
	end
	for _, req in pairs(state.other_requests) do
		if req.bufnr == bufnr then
			return true
		end
	end
	return false
end

---Build and emit an Orca/Herdr toast notification for background agent state transitions.
---@param bufnr integer
---@param state_name "unread"|"error"|"waiting"
---@param entry table
local function emit_transition_notification(bufnr, state_name, entry)
	if not state.notifications then
		return
	end
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local function fire_toast()
		if not state.notifications or not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end
		local chat_mod = package.loaded["codecompanion.interactions.chat"]
		local chat = chat_mod and chat_mod.buf_get_chat(bufnr) or nil
		local ok_ws, ws = pcall(require, "cc_workspace")

		local chat_cwd = nil
		if chat then
			chat_cwd = (type(chat.opts) == "table" and chat.opts.cwd) or chat.cwd
		end
		if (not chat_cwd or chat_cwd == "") and ok_ws and ws and chat then
			chat_cwd = ws.get_valid_chat_cwd(chat)
		end

		local proj_name = nil
		local proj_path = nil
		if ok_ws and ws and chat and type(ws.get_chat_project_name) == "function" then
			proj_name, proj_path = ws.get_chat_project_name(chat)
		end
		local repo_root = M.get_repo_root(chat_cwd or proj_path)
		if (not proj_name or proj_name == "" or proj_name == "Other") and repo_root then
			proj_name = vim.fs.basename(repo_root)
		end
		if not proj_name or proj_name == "" then
			proj_name = (chat_cwd and vim.fs.basename(chat_cwd)) or "Workspace"
		end

		local branch = M.get_worktree_branch(chat_cwd or proj_path)
		local scope = (branch and branch ~= "") and string.format("[%s · %s %s]", proj_name, icons.git.Branch, branch)
			or string.format("[%s]", proj_name)

		local title = entry.title
		if (not title or title == "") and ok_ws and ws and chat and type(ws.get_chat_title) == "function" then
			title = ws.truncate_display(ws.get_chat_title(chat), 36)
		elseif not title or title == "" then
			title = (chat and ((chat.opts and chat.opts.title) or chat.title)) or string.format("Chat #%d", bufnr)
			if #title > 36 then
				title = title:sub(1, 35) .. "…"
			end
		end

		local elapsed = math.max(0, tonumber(entry.elapsed) or 0)
		local suffix
		local level
		if state_name == "unread" then
			suffix = string.format("✓ Completed (%ds)", elapsed)
			level = vim.log.levels.INFO
		elseif state_name == "waiting" then
			suffix = icons.diagnostics.Warning .. " Waiting"
			level = vim.log.levels.WARN
		else
			suffix = "✗ Failed"
			level = vim.log.levels.ERROR
		end

		local msg = string.format("%s %s — %s", scope, title, suffix)
		vim.notify(msg, level, { title = "AI Workspace" })
	end

	if vim.in_fast_event() then
		vim.schedule(fire_toast)
	else
		fire_toast()
	end
end

---Return whether agent background notifications are currently enabled.
---@return boolean
function M.notifications_enabled()
	return state.notifications == true
end

---Explicitly enable or disable agent background notifications.
---@param enabled boolean
function M.set_notifications(enabled)
	state.notifications = enabled == true
end

---Toggle agent background toast notifications on/off.
---@param silent? boolean
---@return boolean enabled
function M.toggle_notifications(silent)
	state.notifications = not state.notifications
	if not silent then
		vim.notify(
			string.format("AI Agent notifications %s", state.notifications and "enabled" or "disabled"),
			vim.log.levels.INFO,
			{ title = "AI Workspace" }
		)
	end
	return state.notifications
end

---Update per-`bufnr` agent lifecycle state (`thinking`, `streaming`, `waiting`, `error`, `unread`, `idle`).
---@param bufnr integer
---@param state_name "thinking"|"streaming"|"waiting"|"error"|"unread"|"idle"
---@param extra? { started_at?: number, elapsed?: number, error?: string, tool?: string, title?: string, adapter?: string, notify?: boolean }
function M.set_chat_state(bufnr, state_name, extra)
	if type(bufnr) ~= "number" or bufnr <= 0 or not VALID_STATES[state_name] then
		return
	end
	extra = extra or {}

	local now_hr = vim.uv.hrtime()
	local prev = state.chats[bufnr]
	local prev_state = prev and prev.state or "idle"
	local was_running = (prev_state == "thinking" or prev_state == "streaming" or prev_state == "waiting")

	local started_at = prev and prev.started_at or nil
	if state_name == "thinking" or state_name == "streaming" then
		if extra.started_at then
			started_at = extra.started_at
		elseif not was_running or not started_at then
			started_at = now_hr
		end
	end

	local elapsed = extra.elapsed
	if elapsed == nil then
		if (state_name == "unread" or state_name == "error" or state_name == "idle") and started_at and was_running then
			elapsed = math.max(0, math.floor((now_hr - started_at) / 1e9))
		elseif prev and type(prev.elapsed) == "number" and state_name == prev_state then
			elapsed = prev.elapsed
		else
			elapsed = 0
		end
	end

	if state_name == "idle" then
		started_at = nil
	end

	local entry = {
		bufnr = bufnr,
		state = state_name,
		adapter = extra.adapter or (prev and prev.adapter or nil),
		prev_running_phase = (state_name == "waiting")
				and ((prev_state == "streaming" or prev_state == "thinking") and prev_state or (prev and prev.prev_running_phase))
			or nil,
		started_at = started_at,
		elapsed = elapsed,
		updated_at = now_hr,
		error = extra.error or (state_name == "error" and prev and prev.error or nil),
		tool = extra.tool or (state_name == "waiting" and prev and prev.tool or nil),
		title = extra.title or (prev and prev.title or nil),
	}
	state.chats[bufnr] = entry

	if state_name == "thinking" or state_name == "streaming" then
		ensure_spinner_timer()
	elseif count_running_requests() <= 0 then
		stop_spinner_timer()
	end

	if
		prev_state ~= state_name
		and (state_name == "unread" or state_name == "error" or state_name == "waiting")
		and extra.notify ~= false
	then
		local is_bg = vim.api.nvim_get_current_buf() ~= bufnr
		if is_bg then
			state.last_bg_bufnr = bufnr
			emit_transition_notification(bufnr, state_name, entry)
		end
	end

	if prev_state ~= state_name then
		notify_ui_changed(bufnr, state_name)
	end
end

---Clear `"unread"`, `"error"`, or `"waiting"` state back to `"idle"` when the user views `bufnr`.
---Never clobbers an actively `"thinking"` or `"streaming"` request.
---@param bufnr integer|nil
function M.mark_read(bufnr)
	if type(bufnr) ~= "number" or bufnr <= 0 then
		return
	end
	local entry = state.chats[bufnr]
	if not entry then
		return
	end
	if entry.state == "unread" or entry.state == "error" or entry.state == "waiting" then
		entry.state = "idle"
		entry.error = nil
		entry.tool = nil
		entry.updated_at = vim.uv.hrtime()
		if state.last_bg_bufnr == bufnr then
			state.last_bg_bufnr = nil
		end
		notify_ui_changed(bufnr, "idle")
	end
end

---Resolve spinner glyph from explicit `anim_idx` or internal timer index.
---@param anim_idx? integer
---@return string
local function resolve_spinner(anim_idx)
	local idx = type(anim_idx) == "number" and anim_idx or state.anim_idx
	local wrapped = ((math.max(1, math.floor(idx)) - 1) % #M.SPINNER_FRAMES) + 1
	return M.SPINNER_FRAMES[wrapped]
end

---@class CcAgentChatStatus
---@field state "thinking"|"streaming"|"waiting"|"error"|"unread"|"idle"
---@field phase "thinking"|"streaming"|"waiting"|"error"|"unread"|"idle"
---@field icon string
---@field badge string
---@field short string
---@field hl string
---@field badge_hl string
---@field started_at number|nil
---@field elapsed integer

---Return Orca/Herdr status symbols, badges, highlights, and elapsed time for `bufnr`.
---@param bufnr integer
---@param is_cur? boolean
---@param anim_idx? integer
---@return CcAgentChatStatus
function M.get_chat_status(bufnr, is_cur, anim_idx)
	local entry = type(bufnr) == "number" and state.chats[bufnr] or nil
	local st = (entry and entry.state) or "idle"
	local spin = resolve_spinner(anim_idx)
	local warn_icon = icons.diagnostics.Warning

	if st == "thinking" then
		local elapsed = entry
				and entry.started_at
				and math.max(0, math.floor((vim.uv.hrtime() - entry.started_at) / 1e9))
			or 0
		return {
			state = "thinking",
			phase = "thinking",
			icon = spin,
			badge = string.format("%s T%ds", spin, elapsed),
			short = spin,
			hl = "CcAgentThinking",
			badge_hl = "CcAgentThinking",
			started_at = entry and entry.started_at or nil,
			elapsed = elapsed,
		}
	elseif st == "streaming" then
		local elapsed = entry
				and entry.started_at
				and math.max(0, math.floor((vim.uv.hrtime() - entry.started_at) / 1e9))
			or 0
		return {
			state = "streaming",
			phase = "streaming",
			icon = "⚡",
			badge = string.format("%s S%ds", spin, elapsed),
			short = "⚡",
			hl = "CcAgentStreaming",
			badge_hl = "CcAgentStreaming",
			started_at = entry and entry.started_at or nil,
			elapsed = elapsed,
		}
	elseif st == "waiting" then
		local elapsed = entry
				and entry.started_at
				and math.max(0, math.floor((vim.uv.hrtime() - entry.started_at) / 1e9))
			or (entry and entry.elapsed or 0)
		return {
			state = "waiting",
			phase = "waiting",
			icon = warn_icon,
			badge = warn_icon .. " Wait",
			short = warn_icon,
			hl = "CcAgentWaiting",
			badge_hl = "CcAgentWaiting",
			started_at = entry and entry.started_at or nil,
			elapsed = elapsed,
		}
	elseif st == "error" then
		local elapsed = (entry and entry.elapsed) or 0
		return {
			state = "error",
			phase = "error",
			icon = "✗",
			badge = "✗ Err",
			short = "✗",
			hl = "CcAgentError",
			badge_hl = "CcAgentError",
			started_at = nil,
			elapsed = elapsed,
		}
	elseif st == "unread" then
		local elapsed = (entry and entry.elapsed) or 0
		return {
			state = "unread",
			phase = "unread",
			icon = "✓",
			badge = "✓ Done",
			short = "✓",
			hl = "CcAgentUnread",
			badge_hl = "CcAgentUnread",
			started_at = nil,
			elapsed = elapsed,
		}
	end

	local cur = is_cur == true
	local icon = cur and "◆" or "○"
	local hl = cur and "CcAgentActive" or "CcAgentIdle"
	return {
		state = "idle",
		phase = "idle",
		icon = icon,
		badge = cur and "Active" or "Idle",
		short = icon,
		hl = hl,
		badge_hl = hl,
		started_at = nil,
		elapsed = 0,
	}
end

---Collect all valid open CodeCompanion chat buffer numbers when `bufnrs` is omitted.
---@return integer[]
local function collect_all_chat_bufnrs()
	local seen = {}
	local result = {}
	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	if chat_mod and type(chat_mod.buf_get_chat) == "function" then
		local all = chat_mod.buf_get_chat()
		if type(all) == "table" then
			for _, item in ipairs(all) do
				local b = item and item.chat and item.chat.bufnr
				if type(b) == "number" and vim.api.nvim_buf_is_valid(b) and not seen[b] then
					seen[b] = true
					table.insert(result, b)
				end
			end
		end
	end
	for b, _ in pairs(state.chats) do
		if type(b) == "number" and vim.api.nvim_buf_is_valid(b) and not seen[b] then
			seen[b] = true
			table.insert(result, b)
		end
	end
	table.sort(result)
	return result
end

---@class CcAgentRollup
---@field thinking integer
---@field streaming integer
---@field running integer
---@field waiting integer
---@field unread integer
---@field error integer
---@field idle integer
---@field total integer
---@field badge string

---Aggregate status counts and compact Orca/Herdr badge (`"1 ✗1 ✓2 ⠋1"` or `""`) across `bufnrs` (or all chats when nil).
---@param bufnrs? (integer|table)[]
---@param anim_idx? integer
---@return CcAgentRollup
function M.get_rollup(bufnrs, anim_idx)
	local list = bufnrs or collect_all_chat_bufnrs()
	local counts = {
		thinking = 0,
		streaming = 0,
		running = 0,
		waiting = 0,
		unread = 0,
		error = 0,
		idle = 0,
		total = 0,
		badge = "",
	}

	local seen = {}
	for _, item in ipairs(list) do
		local b = type(item) == "table" and item.bufnr or item
		if type(b) == "number" and b > 0 and not seen[b] and vim.api.nvim_buf_is_valid(b) then
			seen[b] = true
			counts.total = counts.total + 1
			local st = (state.chats[b] and state.chats[b].state) or "idle"
			if st == "thinking" then
				counts.thinking = counts.thinking + 1
				counts.running = counts.running + 1
			elseif st == "streaming" then
				counts.streaming = counts.streaming + 1
				counts.running = counts.running + 1
			elseif st == "waiting" then
				counts.waiting = counts.waiting + 1
			elseif st == "unread" then
				counts.unread = counts.unread + 1
			elseif st == "error" then
				counts.error = counts.error + 1
			else
				counts.idle = counts.idle + 1
			end
		end
	end

	local parts = {}
	if counts.waiting > 0 then
		table.insert(parts, string.format("%s%d", icons.diagnostics.Warning, counts.waiting))
	end
	if counts.error > 0 then
		table.insert(parts, string.format("✗%d", counts.error))
	end
	if counts.unread > 0 then
		table.insert(parts, string.format("✓%d", counts.unread))
	end
	if counts.running > 0 then
		local spin = resolve_spinner(anim_idx)
		table.insert(parts, string.format("%s%d", spin, counts.running))
	end
	counts.badge = table.concat(parts, " ")
	return counts
end

---Return valid chat `bufnr`s requiring user attention or actively running, ordered:
---`waiting` -> `error` -> `unread` -> `running` (`streaming`/`thinking`).
---@return integer[]
function M.get_attention_chats()
	local items = {}
	for bufnr, entry in pairs(state.chats) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			local prio = ATTENTION_PRIORITY[entry.state]
			if prio then
				table.insert(items, {
					bufnr = bufnr,
					prio = prio,
					updated_at = entry.updated_at or 0,
				})
			end
		else
			state.chats[bufnr] = nil
			state.tools_running[bufnr] = nil
		end
	end

	table.sort(items, function(a, b)
		if a.prio ~= b.prio then
			return a.prio < b.prio
		end
		if a.updated_at ~= b.updated_at then
			return a.updated_at > b.updated_at
		end
		return a.bufnr < b.bufnr
	end)

	local result = {}
	for _, it in ipairs(items) do
		table.insert(result, it.bufnr)
	end
	return result
end

---Jump directly to the highest-priority attention/unread/running chat and mark it read.
---@param opts? { silent?: boolean }
---@return boolean jumped
function M.jump_to_attention(opts)
	opts = opts or {}
	local attention = M.get_attention_chats()
	if #attention == 0 then
		local last_bg = M.get_last_background_bufnr()
		if last_bg then
			attention = { last_bg }
		end
	end
	if #attention == 0 then
		if not opts.silent then
			vim.notify(
				"No unread or active AI chats needing attention",
				vim.log.levels.INFO,
				{ title = "AI Workspace" }
			)
		end
		return false
	end

	local cur_buf = vim.api.nvim_get_current_buf()
	local target_bufnr = attention[1]
	if target_bufnr == cur_buf and #attention > 1 then
		target_bufnr = attention[2]
	end

	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	local target_chat = chat_mod and chat_mod.buf_get_chat(target_bufnr) or nil
	local ok_ws, ws = pcall(require, "cc_workspace")

	local jumped = false
	if ok_ws and ws and target_chat then
		if type(ws.is_current_tab) == "function" and ws.is_current_tab() and type(ws.show_chat) == "function" then
			pcall(ws.show_chat, target_chat, true)
			jumped = (vim.api.nvim_get_current_buf() == target_bufnr)
		else
			local wins = vim.fn.win_findbuf(target_bufnr)
			if type(wins) == "table" then
				for _, w in ipairs(wins) do
					if vim.api.nvim_win_is_valid(w) then
						local ok_cfg, cfg = pcall(vim.api.nvim_win_get_config, w)
						if ok_cfg and (cfg.relative == nil or cfg.relative == "") then
							local tp = vim.api.nvim_win_get_tabpage(w)
							if vim.api.nvim_tabpage_is_valid(tp) and tp ~= vim.api.nvim_get_current_tabpage() then
								vim.api.nvim_set_current_tabpage(tp)
							end
							vim.api.nvim_set_current_win(w)
							jumped = (vim.api.nvim_get_current_buf() == target_bufnr)
							break
						end
					end
				end
			end
			if not jumped and type(ws.focus_or_open_chat) == "function" then
				pcall(ws.focus_or_open_chat, target_chat)
				if vim.api.nvim_get_current_buf() ~= target_bufnr then
					local after_wins = vim.fn.win_findbuf(target_bufnr)
					if type(after_wins) == "table" and after_wins[1] and vim.api.nvim_win_is_valid(after_wins[1]) then
						local tp = vim.api.nvim_win_get_tabpage(after_wins[1])
						if vim.api.nvim_tabpage_is_valid(tp) and tp ~= vim.api.nvim_get_current_tabpage() then
							vim.api.nvim_set_current_tabpage(tp)
						end
						vim.api.nvim_set_current_win(after_wins[1])
					end
				end
				jumped = (vim.api.nvim_get_current_buf() == target_bufnr)
			end
		end
	end

	if not jumped and vim.api.nvim_buf_is_valid(target_bufnr) then
		local wins = vim.fn.win_findbuf(target_bufnr)
		if type(wins) == "table" and wins[1] and vim.api.nvim_win_is_valid(wins[1]) then
			local tp = vim.api.nvim_win_get_tabpage(wins[1])
			if vim.api.nvim_tabpage_is_valid(tp) then
				vim.api.nvim_set_current_tabpage(tp)
			end
			vim.api.nvim_set_current_win(wins[1])
		else
			vim.api.nvim_set_current_buf(target_bufnr)
		end
		jumped = true
	end

	if jumped then
		state.last_bg_bufnr = nil
		M.mark_read(target_bufnr)
	end
	return jumped
end

---Reset all tracked per-buffer agent states (primarily for isolated tests).
function M.reset_states()
	state.chats = {}
	state.other_requests = {}
	state.tools_running = {}
	state.last_bg_bufnr = nil
	stop_spinner_timer()
end

---Return whether an event payload targets a CodeCompanion chat buffer (vs inline/cmd/cli).
---@param data table
---@return integer|nil
local function resolve_event_chat_bufnr(data)
	local bufnr = type(data) == "table" and data.bufnr or nil
	if type(bufnr) ~= "number" or bufnr <= 0 or not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	local interaction = data.interaction
	if interaction ~= nil and interaction ~= "chat" then
		return nil
	end
	return bufnr
end

---Compute a stable tracking key for non-chat CodeCompanion requests (`inline`, `cmd`, `cli`).
---@param data table
---@return string
local function resolve_other_request_key(data)
	if data.id ~= nil and tostring(data.id) ~= "" then
		return "id:" .. tostring(data.id)
	end
	return string.format("%s:%s", tostring(data.interaction or "other"), tostring(data.bufnr or "0"))
end

---Return true when a `CodeCompanionRequestFinished` event payload represents a failed turn.
---@param data table
---@return boolean, string|nil
local function is_error_finish(data)
	if type(data) ~= "table" then
		return false, nil
	end
	if data.error ~= nil and data.error ~= false and data.error ~= "" then
		local msg = type(data.error) == "string" and data.error
			or (type(data.error) == "table" and data.error.message)
			or "Request error"
		return true, msg
	end
	local st = type(data.status) == "string" and data.status:lower() or ""
	if st == "error" or st == "failed" or st == "refusal" or st == "max_tokens" or st == "max_turn_requests" then
		return true, st
	end
	return false, nil
end

---Register idempotent autocmds for CodeCompanion agent lifecycle tracking & auto-read on buffer view.
---@param opts? { notifications?: boolean, worktrees_base_dir?: string }
function M.setup(opts)
	opts = opts or {}
	if opts.notifications ~= nil then
		state.notifications = opts.notifications == true
	elseif not state.setup_done and config.options and config.options.notifications ~= nil then
		state.notifications = config.options.notifications == true
	end
	if type(opts.worktrees_base_dir) == "string" and opts.worktrees_base_dir ~= "" then
		M.set_worktrees_base_dir(opts.worktrees_base_dir)
	end

	M.setup_highlights()

	local group = vim.api.nvim_create_augroup("CcWorkspaceWorktree", { clear = true })

	vim.api.nvim_create_autocmd("ColorScheme", {
		group = group,
		callback = function()
			M.setup_highlights()
		end,
	})

	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = {
			"CodeCompanionRequestStarted",
			"CodeCompanionRequestStreaming",
			"CodeCompanionRequestFinished",
			"CodeCompanionChatCreated",
			"CodeCompanionChatOpened",
			"CodeCompanionChatSubmitted",
			"CodeCompanionChatStopped",
			"CodeCompanionChatCleared",
			"CodeCompanionChatClosed",
			"CodeCompanionTool*",
		},
		callback = function(args)
			local ev = args.match or ""
			local data = type(args.data) == "table" and args.data or {}
			local adapter_name = extract_adapter_name(data.adapter)
			local bufnr = resolve_event_chat_bufnr(data)
			if not bufnr then
				if ev == "CodeCompanionChatClosed" and type(data.bufnr) == "number" then
					state.chats[data.bufnr] = nil
					state.tools_running[data.bufnr] = nil
					return
				end
				if ev == "CodeCompanionRequestStarted" then
					local key = resolve_other_request_key(data)
					state.other_requests[key] = {
						key = key,
						bufnr = type(data.bufnr) == "number" and data.bufnr or nil,
						interaction = data.interaction or "other",
						adapter = adapter_name or "AI",
						phase = "thinking",
						started_at = vim.uv.hrtime(),
					}
					ensure_spinner_timer()
					notify_ui_changed(type(data.bufnr) == "number" and data.bufnr or 0, "thinking")
				elseif ev == "CodeCompanionRequestStreaming" then
					local key = resolve_other_request_key(data)
					local req = state.other_requests[key]
					if req then
						if req.phase ~= "streaming" then
							req.phase = "streaming"
							notify_ui_changed(req.bufnr or 0, "streaming")
						end
					else
						state.other_requests[key] = {
							key = key,
							bufnr = type(data.bufnr) == "number" and data.bufnr or nil,
							interaction = data.interaction or "other",
							adapter = adapter_name or "AI",
							phase = "streaming",
							started_at = vim.uv.hrtime(),
						}
						notify_ui_changed(type(data.bufnr) == "number" and data.bufnr or 0, "streaming")
					end
					ensure_spinner_timer()
				elseif ev == "CodeCompanionRequestFinished" then
					local key = resolve_other_request_key(data)
					if state.other_requests[key] then
						state.other_requests[key] = nil
					else
						for k, req in pairs(state.other_requests) do
							if
								(data.bufnr and req.bufnr == data.bufnr)
								or (data.interaction and req.interaction == data.interaction)
							then
								state.other_requests[k] = nil
								break
							end
						end
					end
					if count_running_requests() <= 0 then
						stop_spinner_timer()
					end
					notify_ui_changed(type(data.bufnr) == "number" and data.bufnr or 0, "idle")
				end
				return
			end

			if ev == "CodeCompanionChatCreated" then
				if not state.chats[bufnr] then
					M.set_chat_state(bufnr, "idle", { adapter = adapter_name, notify = false })
				end
			elseif ev == "CodeCompanionChatOpened" then
				if vim.api.nvim_get_current_buf() == bufnr then
					M.mark_read(bufnr)
				end
			elseif ev == "CodeCompanionChatSubmitted" then
				state.tools_running[bufnr] = nil
				M.set_chat_state(bufnr, "thinking", { adapter = adapter_name, notify = false })
			elseif ev == "CodeCompanionRequestStarted" then
				M.set_chat_state(bufnr, "thinking", { adapter = adapter_name, notify = false })
			elseif ev == "CodeCompanionRequestStreaming" then
				M.set_chat_state(bufnr, "streaming", { adapter = adapter_name, notify = false })
			elseif ev == "CodeCompanionRequestFinished" then
				local is_err, err_msg = is_error_finish(data)
				local st = type(data.status) == "string" and data.status:lower() or ""
				if is_err then
					state.tools_running[bufnr] = nil
					M.set_chat_state(bufnr, "error", { adapter = adapter_name, error = err_msg })
				elseif st == "cancelled" or st == "canceled" then
					state.tools_running[bufnr] = nil
					M.set_chat_state(bufnr, "idle", { adapter = adapter_name, notify = false })
				elseif state.tools_running[bufnr] then
					-- Mid-turn HTTP tool execution is still running; wait until tools finish or next request completes
					local cur_entry = state.chats[bufnr]
					if not cur_entry or cur_entry.state ~= "waiting" then
						M.set_chat_state(bufnr, "thinking", { adapter = adapter_name, notify = false })
					end
				elseif vim.api.nvim_get_current_buf() ~= bufnr then
					M.set_chat_state(bufnr, "unread", { adapter = adapter_name })
				else
					M.set_chat_state(bufnr, "idle", { adapter = adapter_name, notify = false })
				end
			elseif ev == "CodeCompanionChatStopped" or ev == "CodeCompanionChatCleared" then
				state.tools_running[bufnr] = nil
				local cur_entry = state.chats[bufnr]
				if not cur_entry or cur_entry.state ~= "error" then
					M.set_chat_state(bufnr, "idle", { adapter = adapter_name, notify = false })
				end
			elseif ev == "CodeCompanionChatClosed" then
				state.chats[bufnr] = nil
				state.tools_running[bufnr] = nil
				if state.last_bg_bufnr == bufnr then
					state.last_bg_bufnr = nil
				end
				if count_running_requests() <= 0 then
					stop_spinner_timer()
				end
				notify_ui_changed(bufnr, "closed")
			elseif
				ev == "CodeCompanionToolApprovalRequested"
				or ev == "CodeCompanionToolQuestionAsked"
				or ev == "CodeCompanionToolWaiting"
				or ev:match("^CodeCompanionToolConfirm")
			then
				M.set_chat_state(bufnr, "waiting", {
					adapter = adapter_name,
					tool = data.name or data.header or data.tool,
				})
			elseif ev == "CodeCompanionToolApprovalFinished" or ev == "CodeCompanionToolQuestionAnswered" then
				local choice = type(data.choice) == "string" and data.choice:lower() or ""
				if choice == "cancelled" or choice == "cancel" then
					state.tools_running[bufnr] = nil
					M.set_chat_state(bufnr, "idle", { adapter = adapter_name, notify = false })
				else
					local prev_entry = state.chats[bufnr]
					local resume_phase = (prev_entry and prev_entry.prev_running_phase) or "thinking"
					M.set_chat_state(bufnr, resume_phase, { adapter = adapter_name, notify = false })
				end
			elseif ev == "CodeCompanionToolsStarted" or ev == "CodeCompanionToolStarted" then
				state.tools_running[bufnr] = true
				local cur_entry = state.chats[bufnr]
				if not cur_entry or (cur_entry.state ~= "waiting" and cur_entry.state ~= "streaming") then
					M.set_chat_state(bufnr, "thinking", { adapter = adapter_name, notify = false })
				end
			elseif ev == "CodeCompanionToolsFinished" then
				state.tools_running[bufnr] = nil
				local is_err, err_msg = is_error_finish(data)
				if is_err then
					M.set_chat_state(bufnr, "error", { adapter = adapter_name, error = err_msg })
				end
			end
		end,
	})

	vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "TabEnter" }, {
		group = group,
		callback = function()
			local buf = vim.api.nvim_get_current_buf()
			if not vim.api.nvim_buf_is_valid(buf) then
				return
			end
			if vim.bo[buf].filetype == "codecompanion" or state.chats[buf] ~= nil then
				if vim.fn.bufwinid(buf) ~= -1 then
					M.mark_read(buf)
				end
			end
		end,
	})

	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		callback = function(args)
			if state.chats[args.buf] or state.tools_running[args.buf] then
				state.chats[args.buf] = nil
				state.tools_running[args.buf] = nil
				if state.last_bg_bufnr == args.buf then
					state.last_bg_bufnr = nil
				end
				if count_running_requests() <= 0 then
					stop_spinner_timer()
				end
			end
		end,
	})

	state.setup_done = true
end

return M
