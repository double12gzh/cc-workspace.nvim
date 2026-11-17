-- Safe directory/buffer path normalization, ephemeral `/tmp` detection,
-- project marker root resolution, ancestor disambiguation, and window `lcd` scoping.

local state_mod = require("cc_workspace.state")

local state = state_mod.state
local unpack_fn = table.unpack or unpack

local M = {}

---Expand a raw user/stored directory string (`~`, relative path) without Vim wildcard globbing or `%`/`#` substitution.
---@param raw_path string|nil
---@return string|nil
function M.expand_raw_dir_path(raw_path)
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
	state.norm_path_cache[expanded] = { norm = norm, ts = t_now }
	if norm ~= expanded then
		state.norm_path_cache[norm] = { norm = norm, ts = t_now }
	end
	return norm
end

---Check whether a path resides under an ephemeral temp directory (`/tmp`, `/private/tmp`, macOS `/var/folders/.../T`, or `$TMPDIR`).
---@param raw_path string|nil
---@return boolean
function M.is_ephemeral_tmp_path(raw_path)
	return state_mod.is_ephemeral_tmp_path(raw_path)
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

---Return a chat's validated existing working directory on disk, or nil if unset/missing.
---@param chat table|nil
---@return string|nil
function M.get_valid_chat_cwd(chat)
	if type(chat) ~= "table" then
		return nil
	end
	local raw = (type(chat.opts) == "table" and chat.opts.cwd) or chat.cwd
	local norm = M.normalize_project_path(raw)
	return (norm and vim.fn.isdirectory(norm) == 1) and norm or nil
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
	local norm_root = (ok_r and type(root) == "string" and root ~= "") and M.normalize_project_path(root) or nil
	local home = M.normalize_project_path("~")
	if not norm_root or (norm_root ~= norm_start and (norm_root == "/" or (home and norm_root == home))) then
		state.project_root_cache[norm_start] = { root = false, ts = t_now }
		return nil
	end
	state.project_root_cache[norm_start] = { root = norm_root, ts = t_now }
	return norm_root
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
	local ok_c, cwd = pcall(vim.fn.getcwd, vim.api.nvim_win_get_number(win), vim.api.nvim_tabpage_get_number(tp))
	return (ok_c and type(cwd) == "string" and cwd ~= "") and (M.normalize_project_path(cwd) or cwd) or nil
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
	if type(target) ~= "string" or target == "" or vim.fn.isdirectory(target) ~= 1 or M.get_win_cwd(win) == target then
		return
	end
	local active_cwd = M.get_win_cwd(vim.api.nvim_get_current_win())
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
	local norm = M.normalize_project_path(vim.api.nvim_buf_get_name(buf))
	if not norm then
		return false
	end
	return dir == "/" or norm == dir or norm:sub(1, #dir + 1) == dir .. "/"
end

---Compute a file path for `src_buf` relative to `base_dir` (or `~`-shortened if outside `base_dir`).
---@param src_buf integer|nil
---@param base_dir string|nil
---@return string
function M.compute_buf_rel_path(src_buf, base_dir)
	if not src_buf or not vim.api.nvim_buf_is_valid(src_buf) then
		return ""
	end
	local raw_name = vim.api.nvim_buf_get_name(src_buf)
	if raw_name == "" then
		return ""
	end
	local norm_file = M.normalize_project_path(raw_name) or vim.fs.normalize(raw_name)
	local norm_base = M.normalize_project_path(base_dir)
	if norm_file and norm_base then
		local rel = vim.fs.relpath(norm_base, norm_file)
		return (rel and rel ~= "") and rel or vim.fn.fnamemodify(norm_file, ":~")
	end
	return vim.fn.fnamemodify(raw_name, ":.")
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
	for p_path in pairs(pinned_map) do
		if (dir == p_path or dir:sub(1, #p_path + 1) == p_path .. "/") and (not best or #p_path > #best) then
			best = p_path
		end
	end
	return best
end

local function get_project_ancestors(path, home)
	if type(path) ~= "string" or path == "" or path == "/" or path == "Other" then
		return {}
	end
	local norm = path:gsub("/+$", "")
	local parent = vim.fs.dirname(norm)
	if not parent or parent == "" or parent == "." or parent == norm then
		return {}
	elseif home ~= "" and parent == home then
		return { "~" }
	end
	local in_home = home ~= "" and parent:sub(1, #home + 1) == home .. "/"
	local rel = in_home and parent:sub(#home + 2) or parent:gsub("^/+", "")
	local top_down = { in_home and "~" or "/" }
	for seg in rel:gmatch("[^/]+") do
		table.insert(top_down, seg)
	end
	local bottom_up = {}
	for i = #top_down, 1, -1 do
		table.insert(bottom_up, top_down[i])
	end
	return bottom_up
end

local function format_disambiguated_name(anc, base_name, depth, span)
	if #anc == 0 then
		return base_name
	end
	local bot = math.min(depth, #anc)
	local top = math.min(#anc, bot + span - 1)
	if bot == top and bot > 1 and (anc[top] == "~" or anc[top] == "/") then
		bot = bot - 1
	end
	local has_root_slash, parts = false, {}
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
	return has_root_slash and ("/" .. joined) or joined
end

---Assign collision-free display names to a list of project descriptors using tail-aware ancestor disambiguation.
---@param projects table[]
function M.assign_project_display_names(projects)
	local home = (M.normalize_project_path("~") or vim.uv.os_homedir() or ""):gsub("/+$", "")
	local init_counts = {}
	for _, proj in ipairs(projects) do
		proj.base_name = M.project_basename(proj.path)
		proj.display_name = (proj.custom_name and proj.custom_name ~= "") and proj.custom_name or proj.base_name
		init_counts[proj.display_name] = (init_counts[proj.display_name] or 0) + 1
	end

	local locked, used_locked, anc_by_idx = {}, {}, {}
	local max_anc, remaining = 0, 0
	for i, proj in ipairs(projects) do
		local has_custom = proj.custom_name ~= nil and proj.custom_name ~= ""
		if has_custom or proj.path == "/" or proj.path == "Other" or (init_counts[proj.display_name] or 0) <= 1 then
			locked[i], used_locked[proj.display_name] = true, true
		else
			local anc = get_project_ancestors(proj.path, home)
			anc_by_idx[i] = anc
			max_anc = math.max(max_anc, #anc)
			remaining = remaining + 1
		end
	end
	if remaining == 0 then
		return
	end

	for span = 1, math.max(1, max_anc) do
		for depth = 1, math.max(1, max_anc) do
			if remaining == 0 then
				break
			end
			local cand_by_idx, cand_paths = {}, {}
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
						proj.display_name, locked[i], used_locked[cand] = cand, true, true
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

return M
