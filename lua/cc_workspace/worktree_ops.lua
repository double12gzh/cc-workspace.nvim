-- Bounded asynchronous Git worktree discovery queue, directory naming,
-- creation, interactive Telescope/input prompt, and safe worktree removal.

local config = require("cc_workspace.config")
local git = require("cc_workspace.git")
local icons = require("cc_workspace.icons")

local M = {}

local WORKTREE_STALE_MS = 15000
local MAX_CONCURRENT_GIT_REFRESH = 4

local ops_state = {
	worktrees_base_dir = nil, ---@type string|nil
	worktrees_cache = {}, ---@type table<string, table>
	inflight_by_root = {}, ---@type table<string, table>
	orphaned_cbs = {}, ---@type table<string, function[]>
	refresh_queue = {}, ---@type { repo_root: string, cache_entry: table }[]
	active_refresh_jobs = 0,
}

local function push_unique_cbs(dst, src)
	if type(src) == "function" then
		if not vim.tbl_contains(dst, src) then
			table.insert(dst, src)
		end
	elseif type(src) == "table" then
		for _, cb in ipairs(src) do
			if type(cb) == "function" and not vim.tbl_contains(dst, cb) then
				table.insert(dst, cb)
			end
		end
	end
end

local function add_pending_cb(entry, src)
	entry.pending_cbs = entry.pending_cbs or {}
	push_unique_cbs(entry.pending_cbs, src)
end

local function stash_orphaned_cbs(root, cbs)
	if type(root) == "string" and root ~= "" and type(cbs) == "table" and #cbs > 0 then
		ops_state.orphaned_cbs[root] = ops_state.orphaned_cbs[root] or {}
		push_unique_cbs(ops_state.orphaned_cbs[root], cbs)
	end
end

git.on_invalidate(function(clear_roots)
	local kept_queue = {}
	for _, item in ipairs(ops_state.refresh_queue) do
		if not clear_roots or clear_roots[item.repo_root] then
			if item.cache_entry then
				item.cache_entry.queued = false
				stash_orphaned_cbs(item.repo_root, item.cache_entry.pending_cbs)
				item.cache_entry.pending_cbs = {}
			end
		else
			table.insert(kept_queue, item)
		end
	end
	ops_state.refresh_queue = kept_queue
	for root, entry in pairs(ops_state.worktrees_cache) do
		if not clear_roots or clear_roots[root] then
			if not entry.inflight then
				stash_orphaned_cbs(root, entry.pending_cbs)
			end
			ops_state.worktrees_cache[root] = nil
		end
	end
end)

local function worktree_lists_equal(a, b, ui_only)
	if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then
		return false
	end
	for i = 1, #a do
		local x, y = a[i], b[i]
		if not x or not y then
			return false
		end
		local x_br, y_br = x.branch or "", y.branch or ""
		local x_hd = ui_only and (x_br == "" and (x.head or "") or "") or (x.head or "")
		local y_hd = ui_only and (y_br == "" and (y.head or "") or "") or (y.head or "")
		if
			x.path ~= y.path
			or x_br ~= y_br
			or x_hd ~= y_hd
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

local enqueue_refresh
local pump_refresh_queue

local function start_refresh_job(repo_root, cache_entry)
	if vim.fn.executable("git") ~= 1 then
		local had_unloaded = not cache_entry.async_loaded
		cache_entry.async_loaded, cache_entry.fetched_at = true, git.now_ms()
		cache_entry.inflight, cache_entry.rerun = false, false
		if ops_state.inflight_by_root[repo_root] == cache_entry then
			ops_state.inflight_by_root[repo_root] = nil
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

	cache_entry.inflight, cache_entry.rerun = true, false
	ops_state.inflight_by_root[repo_root] = cache_entry
	ops_state.active_refresh_jobs = ops_state.active_refresh_jobs + 1
	local job_started_ms = git.now_ms()
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
			ops_state.active_refresh_jobs = math.max(0, ops_state.active_refresh_jobs - 1)
			if ops_state.inflight_by_root[repo_root] == cache_entry then
				ops_state.inflight_by_root[repo_root] = nil
			end
			if updated_list then
				cache_entry.dirty_change = (cache_entry.dirty_change == true)
					or not worktree_lists_equal(cache_entry.list, updated_list, false)
				cache_entry.ui_change = (cache_entry.ui_change == true)
					or not worktree_lists_equal(cache_entry.list, updated_list, true)
				cache_entry.list = updated_list
			end
			cache_entry.async_loaded, cache_entry.fetched_at, cache_entry.inflight = true, git.now_ms(), false

			if ops_state.orphaned_cbs[repo_root] then
				add_pending_cb(cache_entry, ops_state.orphaned_cbs[repo_root])
				ops_state.orphaned_cbs[repo_root] = nil
			end

			local active_entry = ops_state.worktrees_cache[repo_root]
			if active_entry and active_entry ~= cache_entry then
				add_pending_cb(active_entry, cache_entry.pending_cbs)
				cache_entry.pending_cbs = {}
				cache_entry.rerun, cache_entry.dirty_change, cache_entry.ui_change = false, false, false
				if not active_entry.inflight and not active_entry.queued then
					enqueue_refresh(repo_root, active_entry, active_entry.pending_explicit == true)
					active_entry.pending_explicit = false
				end
				return pump_refresh_queue()
			end

			if cache_entry.rerun then
				cache_entry.rerun = false
				enqueue_refresh(repo_root, cache_entry, true)
				return pump_refresh_queue()
			end

			local any_changed, any_ui_changed = cache_entry.dirty_change == true, cache_entry.ui_change == true
			cache_entry.dirty_change, cache_entry.ui_change = false, false
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

	local list_cmd = { "git", "--no-optional-locks", "-C", repo_root, "worktree", "list", "--porcelain" }
	git.run_git_async(list_cmd, git.GIT_SUBPROCESS_TIMEOUT_MS, function(res)
		if not res or res.code ~= 0 or type(res.stdout) ~= "string" then
			return finalize(nil)
		end
		vim.schedule(function()
			local parsed = git.parse_worktree_porcelain(res.stdout, repo_root, prev_dirty)
			local remaining = 0
			for _, wt in ipairs(parsed) do
				if not wt.prunable and vim.fn.isdirectory(wt.path) == 1 then
					remaining = remaining + 1
				else
					wt.dirty = false
				end
			end
			if remaining == 0 then
				return finalize(parsed)
			end
			local rem_ms = math.max(500, math.floor(git.GIT_SUBPROCESS_TIMEOUT_MS - (git.now_ms() - job_started_ms)))
			for _, wt in ipairs(parsed) do
				if not wt.prunable and vim.fn.isdirectory(wt.path) == 1 then
					local st_cmd = { "git", "--no-optional-locks", "-C", wt.path, "status", "--porcelain", "-unormal" }
					git.run_git_async(st_cmd, rem_ms, function(st_res)
						if st_res and st_res.code == 0 and type(st_res.stdout) == "string" then
							wt.dirty = vim.trim(st_res.stdout) ~= ""
						end
						remaining = remaining - 1
						if remaining <= 0 then
							finalize(parsed)
						end
					end)
				end
			end
		end)
	end)
end

pump_refresh_queue = function()
	while ops_state.active_refresh_jobs < MAX_CONCURRENT_GIT_REFRESH and #ops_state.refresh_queue > 0 do
		local item = table.remove(ops_state.refresh_queue, 1)
		local entry = item.cache_entry
		entry.queued = false
		local active_entry = ops_state.worktrees_cache[item.repo_root]
		local inflight_entry = ops_state.inflight_by_root[item.repo_root]
		if inflight_entry then
			local dst = (active_entry and active_entry ~= inflight_entry) and active_entry or inflight_entry
			add_pending_cb(dst, entry.pending_cbs)
			if entry ~= dst then
				entry.pending_cbs = {}
			end
			if dst == inflight_entry then
				inflight_entry.rerun = true
			end
		elseif active_entry ~= entry then
			if active_entry then
				add_pending_cb(active_entry, entry.pending_cbs)
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

enqueue_refresh = function(repo_root, cache_entry, is_explicit)
	local inflight_entry = ops_state.inflight_by_root[repo_root]
	if inflight_entry then
		if inflight_entry == cache_entry then
			cache_entry.rerun = cache_entry.rerun or is_explicit
		else
			cache_entry.pending_explicit = (cache_entry.pending_explicit == true) or is_explicit
		end
		return
	elseif cache_entry.inflight then
		cache_entry.rerun = cache_entry.rerun or is_explicit
		return
	elseif cache_entry.queued then
		if is_explicit then
			for i, item in ipairs(ops_state.refresh_queue) do
				if item.cache_entry == cache_entry then
					if i > 1 then
						table.insert(ops_state.refresh_queue, 1, table.remove(ops_state.refresh_queue, i))
					end
					break
				end
			end
		end
		return
	end
	cache_entry.queued = true
	local job = { repo_root = repo_root, cache_entry = cache_entry }
	table.insert(ops_state.refresh_queue, is_explicit and 1 or (#ops_state.refresh_queue + 1), job)
	pump_refresh_queue()
end

---Return cached list of `{ path, branch, head, is_main, dirty, locked, prunable }` for `repo_path`.
---@param repo_path string|nil
---@param opts? { refresh?: boolean, on_update?: fun(list: CcWorktreeInfo[], changed?: boolean, ui_changed?: boolean) }
---@return CcWorktreeInfo[]
function M.list_worktrees(repo_path, opts)
	opts = opts or {}
	local info = git.resolve_git_info(repo_path)
	if not info or not info.repo_root then
		if type(opts.on_update) == "function" and opts.refresh then
			vim.schedule(function()
				opts.on_update({}, false)
			end)
		end
		return {}
	end

	local root = info.repo_root
	local entry = ops_state.worktrees_cache[root]
	if not entry then
		entry = { list = git.seed_worktrees_from_dot_git(info), fetched_at = 0, async_loaded = false, pending_cbs = {} }
		if ops_state.orphaned_cbs[root] then
			add_pending_cb(entry, ops_state.orphaned_cbs[root])
			ops_state.orphaned_cbs[root] = nil
		end
		ops_state.worktrees_cache[root] = entry
	else
		for _, wt in ipairs(entry.list) do
			if not wt.prunable then
				local live_branch, live_detached, live_sha = git.get_worktree_branch(wt.path)
				if live_branch and live_branch ~= "" then
					wt.branch, wt.detached = live_branch, live_detached == true
					wt.head = (live_sha and live_sha ~= "") and live_sha or wt.head
				end
			end
		end
	end

	local explicit_refresh = opts.refresh == true
	local stale = (not entry.async_loaded) or ((git.now_ms() - entry.fetched_at) > WORKTREE_STALE_MS)
	if explicit_refresh or stale or entry.inflight or entry.queued or ops_state.inflight_by_root[root] ~= nil then
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
	ops_state.worktrees_base_dir = (type(dir) == "string" and dir ~= "") and git.normalize_path(dir) or nil
end

---Return base directory under which managed git worktrees are stored.
---@return string
function M.get_worktrees_base_dir()
	if ops_state.worktrees_base_dir and ops_state.worktrees_base_dir ~= "" then
		return ops_state.worktrees_base_dir
	end
	local cfg_dir = config.options and config.options.worktrees_base_dir or nil
	if type(cfg_dir) == "string" and cfg_dir ~= "" then
		return git.normalize_path(cfg_dir) or cfg_dir
	end
	return vim.fs.joinpath(vim.fn.stdpath("data"), "cc-worktrees")
end

---Sanitize a git branch name into a clean single-segment directory name (`feat/auth` -> `feat-auth`).
---@param branch string|nil
---@return string
function M.sanitize_branch_dir(branch)
	local stripped = vim.trim(tostring(branch or "")):gsub("^refs/heads/", ""):gsub("^refs/remotes/origin/", "")
	local clean = stripped:gsub("^origin/", ""):gsub("[^%w%._%-]+", "-"):gsub("%-+", "-")
	clean = clean:gsub("^[%.%-]+", ""):gsub("[%.%-]+$", "")
	return clean ~= "" and clean or "worktree"
end

---Compute clean default worktree directory: `stdpath("data")/cc-worktrees/<repo_basename>-<hash6>/<sanitized_branch>`.
---@param repo_path string
---@param branch string
---@return string
function M.default_worktree_dir(repo_path, branch)
	local root = git.get_repo_root(repo_path) or git.normalize_path(repo_path) or tostring(repo_path or "repo")
	local safe_repo = (vim.fs.basename(root) or "repo"):gsub("[^%w%._%-]+", "-")
	safe_repo = safe_repo:gsub("^[%.%-]+", ""):gsub("[%.%-]+$", "")
	safe_repo = safe_repo ~= "" and safe_repo or "repo"
	local repo_bucket = string.format("%s-%s", safe_repo, vim.fn.sha256(root):sub(1, 6))
	return vim.fs.joinpath(M.get_worktrees_base_dir(), repo_bucket, M.sanitize_branch_dir(branch))
end

local function format_git_error(res, fallback)
	local raw = res and vim.trim((res.stderr and res.stderr ~= "" and res.stderr) or res.stdout or "") or ""
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
	opts = type(opts) == "string" and { branch = opts } or (opts or {})
	local function done(wt_info, err)
		if type(cb) == "function" then
			vim.schedule(function()
				cb(wt_info, err)
			end)
		end
	end

	local root = git.get_repo_root(repo_path)
	if not root then
		return done(nil, "Not a git repository: " .. tostring(repo_path))
	end
	local raw_branch = vim.trim(opts.branch or ""):gsub("^refs/heads/", "")
	if raw_branch == "" then
		return done(nil, "Branch name cannot be empty")
	end
	local had_origin_prefix = raw_branch:match("^remotes/origin/") ~= nil or raw_branch:match("^origin/") ~= nil
	local clean_branch = raw_branch:gsub("^remotes/origin/", ""):gsub("^origin/", "")
	if clean_branch == "" then
		return done(nil, "Invalid branch name: " .. raw_branch)
	end
	local target_dir = (type(opts.target_dir) == "string" and vim.trim(opts.target_dir) ~= "")
			and git.normalize_path(opts.target_dir)
		or M.default_worktree_dir(root, clean_branch)
	if not target_dir then
		return done(nil, "Could not resolve target directory for worktree")
	end
	local parent_dir = vim.fs.dirname(target_dir)
	if parent_dir and parent_dir ~= "" then
		pcall(vim.fn.mkdir, parent_dir, "p")
	end

	local local_ref, remote_ref = "refs/heads/" .. clean_branch, "refs/remotes/origin/" .. clean_branch
	local ref_cmd =
		{ "git", "--no-optional-locks", "-C", root, "for-each-ref", "--format=%(refname)", local_ref, remote_ref }
	git.run_git_async(ref_cmd, git.GIT_SUBPROCESS_TIMEOUT_MS, function(ref_res)
		local has_local, has_remote = false, false
		if ref_res and ref_res.code == 0 and type(ref_res.stdout) == "string" then
			for line in ref_res.stdout:gmatch("[^\r\n]+") do
				local ref = vim.trim(line)
				has_local = has_local or (ref == local_ref)
				has_remote = has_remote or (ref == remote_ref)
			end
		end

		local cmd = { "git", "-C", root, "worktree", "add" }
		if has_local then
			vim.list_extend(cmd, { target_dir, clean_branch })
		elseif has_remote or had_origin_prefix then
			vim.list_extend(cmd, { "--track", "-b", clean_branch, target_dir, "origin/" .. clean_branch })
		else
			vim.list_extend(cmd, { "-b", clean_branch, target_dir })
			local base_ref = type(opts.base_ref) == "string" and vim.trim(opts.base_ref) or ""
			if base_ref ~= "" then
				table.insert(cmd, base_ref)
			end
		end

		git.run_git_async(cmd, git.GIT_MUTATION_TIMEOUT_MS, function(add_res)
			if not add_res or add_res.code ~= 0 then
				return done(nil, format_git_error(add_res, "git worktree add failed"))
			end
			vim.schedule(function()
				git.invalidate_git_cache(root)
				local norm_target = git.normalize_path(target_dir) or target_dir
				M.list_worktrees(root, {
					refresh = true,
					on_update = function(list)
						for _, wt in ipairs(list) do
							if wt.path == norm_target or wt.branch == clean_branch then
								return done(wt, nil)
							end
						end
						local fb = {
							path = norm_target,
							branch = clean_branch,
							head = "",
							is_main = false,
							dirty = false,
							locked = false,
							prunable = false,
						}
						done(fb, nil)
					end,
				})
			end)
		end)
	end)
end

---Interactive Orca-style worktree creator (Telescope branch/custom input or `vim.ui.input` fallback).
---@param repo_path? string
---@param cb? fun(wt_info: CcWorktreeInfo)
function M.prompt_create_worktree(repo_path, cb)
	if vim.fn.mode():sub(1, 1) == "i" then
		vim.cmd("stopinsert")
	end
	local probe = (type(repo_path) == "string" and repo_path ~= "") and repo_path or vim.fn.getcwd()
	local root = git.get_repo_root(probe)
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
				local emsg = "Failed to create worktree: " .. tostring(err or "unknown error")
				vim.notify(emsg, vim.log.levels.ERROR, { title = "Git Worktree" })
				return
			end
			local tilde = vim.fn.fnamemodify(wt_info.path, ":~")
			vim.notify(
				string.format("Created worktree %s %s (%s)", branch_icon, wt_info.branch, tilde),
				vim.log.levels.INFO,
				{ title = "Git Worktree" }
			)
			if type(cb) == "function" then
				cb(wt_info)
			end
		end)
	end

	local function fallback_input(default_text)
		local iopts =
			{ prompt = string.format("New Git Worktree branch (%s): ", repo_name), default = default_text or "" }
		vim.ui.input(iopts, function(input)
			if type(input) == "string" and vim.trim(input) ~= "" then
				run_create(input)
			end
		end)
	end

	local ok_p, pickers = pcall(require, "telescope.pickers")
	local ok_f, finders = pcall(require, "telescope.finders")
	local ok_c, conf_mod = pcall(require, "telescope.config")
	local ok_a, actions = pcall(require, "telescope.actions")
	local ok_s, action_state = pcall(require, "telescope.actions.state")
	if #vim.api.nvim_list_uis() == 0 or not (ok_p and ok_f and ok_c and ok_a and ok_s) then
		return fallback_input("")
	end

	local wt_by_branch = {}
	for _, wt in ipairs(M.list_worktrees(root)) do
		if wt.branch and wt.branch ~= "" then
			wt_by_branch[wt.branch] = wt
		end
	end

	local function on_refs_loaded(res)
		local new_disp = " + Create new branch worktree (type branch name above or press <CR>)…"
		local items = { { create_new = true, display = new_disp, ordinal = "create new branch worktree feat fix" } }
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
						local disp =
							string.format(" %s %-24s %-13s %s  %s", branch_icon, short_br, tag, sha or "", clean_subj)
						local ord = string.format("%s %s %s", short_br, tag, clean_subj)
						table.insert(
							items,
							{ branch = short_br, existing_wt = active_wt, display = disp, ordinal = ord }
						)
					end
				end
			end
		end

		local function attach_mappings(prompt_bufnr)
			actions.select_default:replace(function()
				local prompt_line = vim.trim(action_state.get_current_line() or "")
				local sel = action_state.get_selected_entry()
				actions.close(prompt_bufnr)
				vim.schedule(function()
					local val = sel and sel.value or nil
					if val then
						if val.create_new then
							if prompt_line ~= "" then
								run_create(prompt_line)
							else
								fallback_input("feat/")
							end
							return
						elseif val.existing_wt then
							local tilde = vim.fn.fnamemodify(val.existing_wt.path, ":~")
							local msg =
								string.format("Using existing worktree %s %s (%s)", branch_icon, val.branch, tilde)
							vim.notify(msg, vim.log.levels.INFO, { title = "Git Worktree" })
							if type(cb) == "function" then
								cb(val.existing_wt)
							end
							return
						elseif val.branch then
							return run_create(val.branch)
						end
					end
					if prompt_line ~= "" then
						run_create(prompt_line)
					end
				end)
			end)
			return true
		end

		local finder = finders.new_table({
			results = items,
			entry_maker = function(it)
				return { value = it, display = it.display, ordinal = it.ordinal }
			end,
		})
		pickers
			.new({}, {
				prompt_title = string.format("Git Worktree (%s) — Type new branch or select existing", repo_name),
				finder = finder,
				sorter = conf_mod.values.generic_sorter({}),
				layout_strategy = "horizontal",
				layout_config = { width = 0.66, height = 0.54, prompt_position = "top" },
				sorting_strategy = "ascending",
				attach_mappings = attach_mappings,
			})
			:find()
	end

	local fmt = "--format=%(refname)\t%(objectname:short)\t%(subject)"
	local ref_cmd = { "git", "--no-optional-locks", "-C", root, "for-each-ref", "--count=400", "--sort=-committerdate" }
	vim.list_extend(ref_cmd, { fmt, "refs/heads", "refs/remotes/origin" })
	git.run_git_async(ref_cmd, git.GIT_SUBPROCESS_TIMEOUT_MS, vim.schedule_wrap(on_refs_loaded))
end

---Asynchronously remove a linked git worktree (refusing `is_main`, checking dirty status unless `opts.force`, and pruning).
---@param wt_path string
---@param opts? { force?: boolean }|fun(ok: boolean, err: string|nil)
---@param cb? fun(ok: boolean, err: string|nil)
function M.remove_worktree(wt_path, opts, cb)
	if type(opts) == "function" then
		cb, opts = opts, {}
	end
	opts = opts or {}
	local function done(ok, err)
		if type(cb) == "function" then
			vim.schedule(function()
				cb(ok, err)
			end)
		end
	end

	local norm_wt = git.normalize_path(wt_path)
	if not norm_wt then
		return done(false, "Invalid worktree path")
	end

	local info = git.resolve_git_info(norm_wt)
	local root = info and info.repo_root or nil
	if info and (info.is_main or info.worktree_root == info.repo_root) then
		return done(false, "Refusing to remove main repository worktree: " .. norm_wt)
	end

	if not root then
		for cached_root, entry in pairs(ops_state.worktrees_cache) do
			for _, wt in ipairs(entry.list or {}) do
				if wt.path == norm_wt then
					if wt.is_main then
						return done(false, "Refusing to remove main repository worktree: " .. norm_wt)
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
		return done(false, "Not a linked git worktree: " .. norm_wt)
	elseif norm_wt == root then
		return done(false, "Refusing to remove main repository worktree: " .. norm_wt)
	end

	local target_wt = (info and info.worktree_root) or norm_wt
	local function run_git_remove()
		local cmd = opts.force and { "git", "-C", root, "worktree", "remove", "--force", "--force", target_wt }
			or { "git", "-C", root, "worktree", "remove", target_wt }
		git.run_git_async(cmd, git.GIT_MUTATION_TIMEOUT_MS, function(rm_res)
			if not rm_res or rm_res.code ~= 0 then
				return done(false, format_git_error(rm_res, "git worktree remove failed"))
			end
			git.run_git_async({ "git", "-C", root, "worktree", "prune" }, git.GIT_SUBPROCESS_TIMEOUT_MS, function()
				vim.schedule(function()
					local parent = vim.fs.dirname(target_wt)
					local base = M.get_worktrees_base_dir()
					if parent and base and parent:sub(1, #base + 1) == base .. "/" then
						pcall(vim.uv.fs_rmdir, parent)
					end
					git.invalidate_git_cache(root)
					local function on_pruned()
						done(true, nil)
					end
					M.list_worktrees(root, { refresh = true, on_update = on_pruned })
				end)
			end)
		end)
	end

	if not opts.force and vim.fn.isdirectory(target_wt) == 1 then
		local st_cmd = { "git", "--no-optional-locks", "-C", target_wt, "status", "--porcelain", "-unormal" }
		git.run_git_async(st_cmd, git.GIT_SUBPROCESS_TIMEOUT_MS, function(st_res)
			if st_res and st_res.code == 0 and type(st_res.stdout) == "string" and vim.trim(st_res.stdout) ~= "" then
				return done(false, "Worktree has uncommitted or untracked changes (use force = true to remove)")
			end
			run_git_remove()
		end)
	else
		run_git_remove()
	end
end

return M
