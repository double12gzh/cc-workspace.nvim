-- Pure-Lua `.git` / worktree / `HEAD` / `packed-refs` inspector, mtime caches,
-- `.git/worktrees/*` seeding, and bounded async `git` runner (`SIGKILL` watchdog).

local unpack_fn = table.unpack or unpack

local M = {}

local GIT_INFO_TTL_MS = 5000
local GIT_INFO_FAST_MS = 1000
local HEAD_FAST_TTL_MS = 500
local PACKED_REFS_FAST_TTL_MS = 1000
local REALPATH_TTL_MS = 1000

M.GIT_SUBPROCESS_TIMEOUT_MS = 5000
M.GIT_MUTATION_TIMEOUT_MS = 15000
M.GIT_ENV = { GIT_TERMINAL_PROMPT = "0", GIT_OPTIONAL_LOCKS = "0" }

---@class CcGitInfo
---@field worktree_root string
---@field git_dir string
---@field common_git_dir string
---@field repo_root string
---@field dot_git_path string
---@field dot_git_mtime string|nil
---@field is_main boolean

---@class CcWorktreeInfo
---@field path string
---@field branch string
---@field head string
---@field is_main boolean
---@field dirty boolean
---@field locked boolean
---@field prunable boolean
---@field detached? boolean

local git_state = {
	realpath_cache = {}, ---@type table<string, { norm: string, ts: number }>
	git_info_cache = {}, ---@type table<string, { info: CcGitInfo|false, ts: number, checked_at: number }>
	head_cache = {}, ---@type table<string, { mtime: string|nil, checked_at: number, branch: string|nil, sha: string|nil, detached: boolean }>
	packed_refs_cache = {}, ---@type table<string, { mtime: string|nil, checked_at: number, refs: table<string, string> }>
	invalidate_hooks = {}, ---@type fun(clear_roots: table<string, boolean>|nil)[]
}

---Return monotonic time in milliseconds.
---@return number
function M.now_ms()
	return vim.uv.hrtime() / 1e6
end

---Register an internal cache invalidation hook invoked whenever `invalidate_git_cache` runs.
---@param cb fun(clear_roots: table<string, boolean>|nil)
function M.on_invalidate(cb)
	if type(cb) ~= "function" or vim.tbl_contains(git_state.invalidate_hooks, cb) then
		return
	end
	table.insert(git_state.invalidate_hooks, cb)
end

---Run an asynchronous `git` command with non-interactive env and a hard `SIGKILL` watchdog timer.
---@param cmd string[]
---@param timeout_ms integer
---@param on_done fun(res: { code: integer, signal: integer, stdout: string, stderr: string }|nil)
---@return boolean started
function M.run_git_async(cmd, timeout_ms, on_done)
	if vim.in_fast_event() then
		vim.schedule(function()
			M.run_git_async(cmd, timeout_ms, on_done)
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

	local ok, obj = pcall(vim.system, cmd, { text = true, env = M.GIT_ENV, timeout = timeout_ms }, finish)
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
function M.read_small_file(path, max_bytes)
	local fd = vim.uv.fs_open(path, "r", 438)
	if not fd then
		return nil
	end
	local content = vim.uv.fs_read(fd, max_bytes or 512, 0)
	vim.uv.fs_close(fd)
	return type(content) == "string" and content or nil
end

---Format a libuv stat structure into a compact cache key.
---@param st table|nil
---@return string|nil
function M.stat_mtime_key(st)
	if not st then
		return nil
	end
	return string.format(
		"%s:%d:%d:%d",
		st.type or "",
		st.mtime and st.mtime.sec or 0,
		st.mtime and st.mtime.nsec or 0,
		st.size or 0
	)
end

---Normalize a filesystem path (expanding `~`, resolving relative paths and symlinks when present).
---@param raw_path string|nil
---@return string|nil
function M.normalize_path(raw_path)
	if type(raw_path) ~= "string" then
		return nil
	end
	local trimmed = vim.trim(raw_path)
	if #trimmed >= 2 then
		local first, last = trimmed:sub(1, 1), trimmed:sub(-1)
		if ((first == "'" and last == "'") or (first == '"' and last == '"')) and vim.uv.fs_lstat(trimmed) == nil then
			trimmed = vim.trim(trimmed:sub(2, -2))
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
	local t_now = M.now_ms()
	local cached_real = git_state.realpath_cache[expanded]
	if cached_real and (t_now - cached_real.ts) < REALPATH_TTL_MS then
		return cached_real.norm
	end
	local real = vim.uv.fs_realpath(expanded)
	local norm = real and vim.fs.normalize(real) or expanded
	if not real then
		local tail, cur = {}, expanded
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
	git_state.realpath_cache[expanded] = { norm = norm, ts = t_now }
	if norm ~= expanded then
		git_state.realpath_cache[norm] = { norm = norm, ts = t_now }
	end
	return norm
end

---Resolve a potentially relative path against `base_dir` and normalize it.
---@param base_dir string
---@param target string
---@return string|nil
function M.resolve_relative_path(base_dir, target)
	local clean = vim.trim(target or "")
	if clean == "" then
		return nil
	end
	if clean:match("^/") or clean:match("^%a:[/\\]") then
		return M.normalize_path(clean)
	end
	return M.normalize_path(vim.fs.joinpath(base_dir, clean))
end

local function get_fresh_cached_git_info(key, t_now)
	local cached = git_state.git_info_cache[key]
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
		if cur_st and M.stat_mtime_key(cur_st) == info.dot_git_mtime then
			cached.checked_at = t_now
			return info, true
		end
	end
	return nil, false
end

---Synchronously inspect `.git` directory or linked-worktree `.git` file in pure Lua/libuv with TTL+mtime caching.
---@param raw_path string|nil
---@return CcGitInfo|nil
function M.resolve_git_info(raw_path)
	local norm = M.normalize_path(raw_path)
	if not norm then
		return nil
	end
	local t_now = M.now_ms()
	local fast_info, fast_hit = get_fresh_cached_git_info(norm, t_now)
	if fast_hit then
		return fast_info
	end

	local st_input = vim.uv.fs_stat(norm)
	local start_dir = (st_input and st_input.type ~= "directory") and (vim.fs.dirname(norm) or norm) or norm
	if start_dir ~= norm then
		local dir_info, dir_hit = get_fresh_cached_git_info(start_dir, t_now)
		if dir_hit then
			return dir_info
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
					dot_git_mtime = M.stat_mtime_key(st),
					is_main = true,
				}
				break
			elseif st.type == "file" then
				local raw = M.read_small_file(dot_git, 1024)
				local gitdir_spec = raw and (raw:match("[^\r\n]+") or ""):match("^gitdir:%s*(.+)$") or nil
				local gdir = gitdir_spec and M.resolve_relative_path(cur, gitdir_spec) or nil
				if gdir and vim.uv.fs_stat(gdir) then
					local c_raw = M.read_small_file(gdir .. "/commondir", 512)
					local c_line = c_raw and c_raw:match("[^\r\n]+") or nil
					local common_dir = c_line and M.resolve_relative_path(gdir, c_line) or nil
					if not common_dir then
						local p_wt = gdir:match("^(.+)/worktrees/[^/]+$")
						common_dir = p_wt and (M.normalize_path(p_wt) or p_wt) or gdir
					end
					local wt_root = M.normalize_path(cur) or cur
					local is_linked = (common_dir ~= gdir)
					local repo_root = wt_root
					if is_linked then
						repo_root = vim.fs.basename(common_dir) == ".git"
								and (M.normalize_path(vim.fs.dirname(common_dir)) or common_dir)
							or common_dir
					end
					resolved = {
						worktree_root = wt_root,
						git_dir = gdir,
						common_git_dir = common_dir,
						repo_root = repo_root,
						dot_git_path = dot_git,
						dot_git_mtime = M.stat_mtime_key(st),
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
			local is_dot = vim.fs.basename(norm_cur) == ".git"
			local root_dir = is_dot and (M.normalize_path(vim.fs.dirname(norm_cur)) or norm_cur) or norm_cur
			local dpath = is_dot and norm_cur or (norm_cur .. "/HEAD")
			resolved = {
				worktree_root = root_dir,
				git_dir = norm_cur,
				common_git_dir = norm_cur,
				repo_root = root_dir,
				dot_git_path = dpath,
				dot_git_mtime = M.stat_mtime_key(vim.uv.fs_stat(dpath)),
				is_main = true,
			}
			break
		end

		local parent = vim.fs.dirname(cur)
		if not parent or parent == cur then
			break
		end
		cur = parent
	end

	git_state.git_info_cache[start_dir] = { info = resolved or false, ts = t_now, checked_at = t_now }
	return resolved
end

---Read a packed ref SHA from `<common_git_dir>/packed-refs` in pure Lua with mtime caching.
---@param common_git_dir string
---@param ref string
---@return string|nil sha
function M.read_packed_ref(common_git_dir, ref)
	local packed_path = vim.fs.joinpath(common_git_dir, "packed-refs")
	local t_now = M.now_ms()
	local cached = git_state.packed_refs_cache[packed_path]
	if cached and cached.checked_at and (t_now - cached.checked_at) < PACKED_REFS_FAST_TTL_MS then
		return cached.refs[ref]
	end
	local st = vim.uv.fs_stat(packed_path)
	if not st or st.type ~= "file" then
		git_state.packed_refs_cache[packed_path] = nil
		return nil
	end
	local mkey = M.stat_mtime_key(st)
	if cached and cached.mtime == mkey then
		cached.checked_at = t_now
		return cached.refs[ref]
	end
	local max_read = math.min(st.size or 0, 262144)
	local raw = max_read > 0 and M.read_small_file(packed_path, max_read) or nil
	local refs = {}
	if raw then
		for line in raw:gmatch("[^\r\n]+") do
			local c1 = line:sub(1, 1)
			if c1 ~= "#" and c1 ~= "^" then
				local sha, rname = line:match("^([0-9a-fA-F]+)%s+(%S+)$")
				if sha and rname then
					refs[rname] = sha
				end
			end
		end
	end
	git_state.packed_refs_cache[packed_path] = { mtime = mkey, checked_at = t_now, refs = refs }
	return refs[ref]
end

---Read branch name (or 7-char detached SHA) and optional commit SHA from a `HEAD` file with mtime caching.
---@param head_file string
---@param common_git_dir? string
---@return string|nil branch, string|nil sha, boolean detached
function M.read_head_details(head_file, common_git_dir)
	local t_now = M.now_ms()
	local cached = git_state.head_cache[head_file]
	if cached and cached.checked_at and (t_now - cached.checked_at) < HEAD_FAST_TTL_MS then
		return cached.branch, cached.sha, cached.detached
	end
	local st = vim.uv.fs_stat(head_file)
	if not st then
		git_state.head_cache[head_file] = nil
		return nil, nil, false
	end
	local mkey = M.stat_mtime_key(st)
	if cached and cached.mtime == mkey then
		cached.checked_at = t_now
		return cached.branch, cached.sha, cached.detached
	end

	local raw = M.read_small_file(head_file, 512)
	local line = raw and vim.trim(raw:match("[^\r\n]+") or "") or ""
	if line == "" then
		return nil, nil, false
	end

	local branch, sha, detached = nil, nil, false
	local ref = line:match("^ref:%s*(.+)$")
	if ref then
		ref = vim.trim(ref)
		branch = ref:match("^refs/heads/(.+)$") or ref:match("^refs/(.+)$") or ref
		if common_git_dir then
			local loose = M.read_small_file(vim.fs.joinpath(common_git_dir, ref), 128)
			local s = loose and vim.trim(loose:match("[^\r\n]+") or "") or ""
			sha = s:match("^[0-9a-fA-F]+$") and s or M.read_packed_ref(common_git_dir, ref)
		end
	elseif line:match("^[0-9a-fA-F]+$") then
		detached, sha, branch = true, line, line:sub(1, 7)
	else
		branch = line
	end

	git_state.head_cache[head_file] =
		{ mtime = mkey, checked_at = t_now, branch = branch, sha = sha, detached = detached }
	return branch, sha, detached
end

---Sort worktrees deterministically with `is_main` always first.
---@param list CcWorktreeInfo[]
function M.sort_worktree_list(list)
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
function M.seed_worktrees_from_dot_git(info)
	local main_branch, main_sha, main_detached =
		M.read_head_details(info.common_git_dir .. "/HEAD", info.common_git_dir)
	local seen = { [info.repo_root] = true }
	local list = {
		{
			path = info.repo_root,
			branch = main_branch or "HEAD",
			head = main_sha or "",
			is_main = true,
			dirty = false,
			locked = false,
			prunable = vim.fn.isdirectory(info.repo_root) ~= 1,
			detached = main_detached,
		},
	}

	local wt_admin_root = info.common_git_dir .. "/worktrees"
	local scan = vim.uv.fs_scandir(wt_admin_root)
	if scan then
		while true do
			---@type string?, string?
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
				local gitdir_raw = M.read_small_file(admin_dir .. "/gitdir", 1024)
				local gitdir_line = gitdir_raw and vim.trim(gitdir_raw:match("[^\r\n]+") or "") or ""
				if gitdir_line ~= "" then
					local dot_git_target = M.resolve_relative_path(admin_dir, gitdir_line) or gitdir_line
					local wt_dir_raw = vim.fs.basename(dot_git_target) == ".git" and vim.fs.dirname(dot_git_target)
						or dot_git_target
					local wt_path = M.normalize_path(wt_dir_raw) or vim.fs.normalize(wt_dir_raw)
					if wt_path and wt_path ~= "" and not seen[wt_path] then
						seen[wt_path] = true
						local br, sha, det = M.read_head_details(admin_dir .. "/HEAD", info.common_git_dir)
						table.insert(list, {
							path = wt_path,
							branch = br or name,
							head = sha or "",
							is_main = false,
							dirty = false,
							locked = vim.uv.fs_stat(admin_dir .. "/locked") ~= nil,
							prunable = vim.fn.isdirectory(wt_path) ~= 1,
							detached = det,
						})
					end
				end
			end
		end
	end
	M.sort_worktree_list(list)
	return list
end

---Parse `git worktree list --porcelain` stdout into structured worktree records.
---@param stdout string
---@param repo_root string
---@param prev_dirty_map table<string, boolean>
---@return CcWorktreeInfo[]
function M.parse_worktree_porcelain(stdout, repo_root, prev_dirty_map)
	local entries, cur, idx = {}, nil, 0
	local function flush_cur()
		if cur and cur.path and not cur.bare then
			idx = idx + 1
			local br = (cur.branch and cur.branch ~= "") and cur.branch
				or ((cur.head and cur.head ~= "") and cur.head:sub(1, 7) or "HEAD")
			table.insert(entries, {
				path = cur.path,
				branch = br,
				head = cur.head or "",
				is_main = (cur.path == repo_root) or (idx == 1),
				dirty = prev_dirty_map[cur.path] == true,
				locked = cur.locked == true,
				prunable = cur.prunable == true or vim.fn.isdirectory(cur.path) ~= 1,
				detached = cur.detached == true,
			})
		end
		cur = nil
	end

	for line in (stdout .. "\n"):gmatch("(.-)\r?\n") do
		if line == "" then
			flush_cur()
		elseif line:sub(1, 9) == "worktree " then
			flush_cur()
			local raw_p = line:sub(10)
			cur = { path = M.normalize_path(raw_p) or vim.fs.normalize(raw_p) }
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
	M.sort_worktree_list(entries)
	return entries
end

---Invalidate cached git/worktree metadata (for a path or globally when omitted).
---@param path? string
function M.invalidate_git_cache(path)
	if not path then
		for _, hook in ipairs(git_state.invalidate_hooks) do
			hook(nil)
		end
		git_state.realpath_cache = {}
		git_state.git_info_cache = {}
		git_state.head_cache = {}
		git_state.packed_refs_cache = {}
		return
	end
	git_state.realpath_cache = {}
	local info = M.resolve_git_info(path)
	local norm = M.normalize_path(path)
	git_state.git_info_cache = {}
	git_state.head_cache = {}
	git_state.packed_refs_cache = {}
	local clear_roots = {}
	if info and info.repo_root then
		clear_roots[info.repo_root] = true
	end
	if norm then
		clear_roots[norm] = true
	end
	if next(clear_roots) ~= nil then
		for _, hook in ipairs(git_state.invalidate_hooks) do
			hook(clear_roots)
		end
	end
end

---Resolve both a normal git repo directory AND a linked git worktree directory back to the canonical main repo root.
---@param path string|nil
---@return string|nil
function M.get_repo_root(path)
	local info = M.resolve_git_info(path)
	return info and info.repo_root or nil
end

---Resolve `path` to its enclosing worktree working directory (main or linked), or nil if outside git.
---@param path string|nil
---@return string|nil
function M.get_worktree_root(path)
	local info = M.resolve_git_info(path)
	return info and info.worktree_root or nil
end

---Return true when `path` lies inside a linked (non-main) git worktree.
---@param path string|nil
---@return boolean
function M.is_linked_worktree(path)
	local info = M.resolve_git_info(path)
	return info ~= nil and not info.is_main
end

---Return fast cached branch name (or detached short SHA), detached state, and commit SHA read synchronously from `HEAD`.
---@param path string|nil
---@return string|nil branch, boolean detached, string|nil sha
function M.get_worktree_branch(path)
	local info = M.resolve_git_info(path)
	if not info or not info.git_dir then
		return nil, false, nil
	end
	local branch, sha, detached = M.read_head_details(info.git_dir .. "/HEAD", info.common_git_dir)
	return branch, detached == true, sha
end

return M
