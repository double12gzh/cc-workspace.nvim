local config = require("cc_workspace.config")

local M = {}

M.SIDEBAR_WIDTH = 38
M.MAX_HISTORY_PER_PROJECT = 10
M.NORM_PATH_TTL_MS = 1000
M.PROJECT_ROOT_TTL_MS = 2000
M.PROJECT_MARKERS = {
	".git",
	"package.json",
	"Cargo.toml",
	"pyproject.toml",
	"go.mod",
	"pom.xml",
	"Makefile",
	"README.md",
}

M.animate_chars = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local state = {
	setup_done = false,
	tab = nil,
	prev_tab = nil,
	prev_code_buf = nil,
	sidebar_win = nil,
	sidebar_buf = nil,
	sidebar_buf_ready = nil,
	main_win = nil,
	empty_buf = nil,
	timer = nil,
	filter = "",
	needs_focus_sync = false,
	collapsed_projects = {},
	expanded_all_projects = {},
	collapsed_worktrees = {},
	expanded_all_worktrees = {},
	last_selected_project = nil,
	focus_project_path = nil,
	focus_worktree_path = nil,
	rendered_project_paths = {},
	rendered_worktree_paths = {},
	projects_file = nil,
	projects_cache = nil,
	projects_mtime = nil,
	history_chats_cache = nil,
	history_chats_mtime = nil,
	norm_path_cache = {},
	project_root_cache = {},
	history_proj_cache = {},
	title_cache = setmetatable({}, { __mode = "k" }),
	render_scheduled = false,
	last_render_ms = 0,
	last_rendered_buf = nil,
	last_rendered_tick = nil,
	last_rendered_lines = nil,
	last_rendered_hls = nil,
	layout_sync_scheduled = false,
	in_layout_repair = false,
	zoxide_cache = nil,
	zoxide_ts = 0,
	zoxide_inflight = false,
	last_save_id_sec = 0,
	last_save_id_seq = 0,
	anim_idx = 1,
	row_actions = {},
	action_rows = {},
	active_chats = {},
	actions = {},
	ns = vim.api.nvim_create_namespace("CcWorkspace"),
}

M.state = state

local EPHEMERAL_TMP_PREFIXES = (function()
	local prefixes = {
		"/tmp",
		"/private/tmp",
		"/var/tmp",
		"/private/var/tmp",
		"/var/folders",
		"/private/var/folders",
	}
	local seen = {}
	local out = {}
	local function add_pref(p)
		if type(p) ~= "string" or p == "" or p == "/" then
			return
		end
		local norm = vim.fs.normalize(p):gsub("/+$", "")
		if norm ~= "" and norm ~= "/" and not seen[norm] then
			seen[norm] = true
			table.insert(out, norm)
		end
	end
	for _, p in ipairs(prefixes) do
		add_pref(p)
	end
	local ok_td, td = pcall(vim.uv.os_tmpdir)
	if ok_td and type(td) == "string" and td ~= "" then
		add_pref(td)
		local ok_rp, rp = pcall(vim.uv.fs_realpath, td)
		if ok_rp and type(rp) == "string" and rp ~= "" then
			add_pref(rp)
		end
	end
	return out
end)()

---Return monotonic time in milliseconds.
---@return number
function M.now_ms()
	return vim.uv.hrtime() / 1e6
end

---Return configured maximum history entries shown per collapsed project/worktree before `See all`.
---@return integer
function M.get_max_history_per_project()
	local cfg_max = config.options and tonumber(config.options.max_history_per_project) or nil
	if cfg_max and cfg_max >= 1 then
		return math.floor(cfg_max)
	end
	return M.MAX_HISTORY_PER_PROJECT
end

---Compute responsive sidebar width so narrow terminals (<95 cols) don't starve the chat pane.
---@return integer
function M.get_sidebar_width()
	local base_w = (config.options and tonumber(config.options.sidebar_width)) or M.SIDEBAR_WIDTH
	if vim.o.columns < 95 then
		return math.max(24, math.min(base_w, math.floor(vim.o.columns * 0.34)))
	end
	return base_w
end

---Invalidate cached `codecompanion-history` index entries so mutations (rename/delete/save) reload immediately.
function M.invalidate_history_cache()
	state.history_chats_cache = nil
	state.history_chats_mtime = nil
end

---Clear cached normalized paths, project roots, and history chat mappings.
function M.clear_path_caches()
	state.norm_path_cache = {}
	state.project_root_cache = {}
	state.history_proj_cache = {}
	M.invalidate_history_cache()
end

---Schedule winbar refresh via `cc_workspace.winbar`.
function M.refresh_winbars()
	vim.schedule(function()
		pcall(function()
			require("cc_workspace.winbar").refresh()
		end)
	end)
end

---Read `codecompanion-history` chat index with `index.json` mtime+size caching to avoid re-reading/decoding JSON on every render.
---@param history_ext table|nil
---@return table<string, table>
function M.get_cached_history_chats(history_ext)
	if not history_ext or type(history_ext.get_chats) ~= "function" then
		return {}
	end
	local loc = type(history_ext.get_location) == "function" and history_ext.get_location() or nil
	if type(loc) ~= "string" or loc == "" then
		return history_ext.get_chats() or {}
	end
	local index_path = loc:gsub("/+$", "") .. "/index.json"
	local st = vim.uv.fs_stat(index_path)
	local mkey = st
			and string.format(
				"%s:%d:%d:%d",
				index_path,
				st.mtime and st.mtime.sec or 0,
				st.mtime and st.mtime.nsec or 0,
				st.size or 0
			)
		or (index_path .. ":missing")
	if state.history_chats_cache and state.history_chats_mtime == mkey then
		return state.history_chats_cache
	end
	local data = history_ext.get_chats() or {}
	state.history_chats_cache = data
	state.history_chats_mtime = mkey
	return data
end

---Generate a unique string `save_id` so multiple chats created within the same wall-clock second never collide in `codecompanion-history`.
---@return string
function M.next_unique_save_id()
	local used = {}
	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	if chat_mod and type(chat_mod.buf_get_chat) == "function" then
		local ok_all, all = pcall(chat_mod.buf_get_chat)
		if ok_all and type(all) == "table" then
			for _, entry in ipairs(all) do
				local sid = entry and entry.chat and entry.chat.opts and entry.chat.opts.save_id or nil
				if type(sid) == "string" and sid ~= "" then
					used[sid] = true
				end
			end
		end
	end
	local cc = package.loaded["codecompanion"]
	local history_ext = cc and cc.extensions and cc.extensions.history
	local saved_map = M.get_cached_history_chats(history_ext)
	if type(saved_map) == "table" then
		for sid in pairs(saved_map) do
			used[tostring(sid)] = true
		end
	end

	local sec = os.time()
	if sec ~= state.last_save_id_sec then
		state.last_save_id_sec = sec
		state.last_save_id_seq = 0
		local plain = tostring(sec)
		if not used[plain] then
			return plain
		end
	end
	while true do
		state.last_save_id_seq = (state.last_save_id_seq or 0) + 1
		local candidate = string.format("%d_%d", sec, state.last_save_id_seq)
		if not used[candidate] then
			return candidate
		end
	end
end

---Safely load the shared `cc_workspace.worktree` Git Worktree & Agent Lifecycle Status engine.
---@return table|nil
function M.get_wt()
	local ok, mod = pcall(require, "cc_workspace.worktree")
	if ok and type(mod) == "table" then
		return mod
	end
	return nil
end

---Mark a transient `:tabnew` `[No Name]` buffer unlisted and wipe-on-hide so it never leaks into bufferline.
---@param buf integer|nil
function M.mark_tabnew_scratch(buf)
	if
		not buf
		or not vim.api.nvim_buf_is_valid(buf)
		or vim.api.nvim_buf_get_name(buf) ~= ""
		or vim.bo[buf].modified
		or vim.bo[buf].buftype ~= ""
	then
		return
	end
	vim.bo[buf].buflisted = false
	vim.bo[buf].bufhidden = "wipe"
	vim.api.nvim_create_autocmd("BufModifiedSet", {
		buffer = buf,
		once = true,
		callback = function()
			if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
				vim.bo[buf].buflisted = true
				vim.bo[buf].bufhidden = ""
			end
		end,
	})
end

---Check whether a path resides under an ephemeral temp directory (`/tmp`, `/private/tmp`, macOS `/var/folders/.../T`, or `$TMPDIR`).
---@param raw_path string|nil
---@return boolean
function M.is_ephemeral_tmp_path(raw_path)
	if type(raw_path) ~= "string" then
		return false
	end
	local trimmed = vim.trim(raw_path)
	if trimmed == "" or trimmed == "Other" then
		return false
	end
	local norm = vim.fs.normalize(trimmed):gsub("/+$", "")
	for _, pref in ipairs(EPHEMERAL_TMP_PREFIXES) do
		if norm == pref or norm:sub(1, #pref + 1) == pref .. "/" then
			return true
		end
	end
	return false
end

---Format a unix timestamp as compact relative age (e.g. "now", "12m", "3h", "2d").
---@param ts number|nil
---@return string
function M.format_age(ts)
	if type(ts) ~= "number" or ts <= 0 then
		return ""
	end
	local diff = math.max(0, os.time() - ts)
	if diff < 60 then
		return "now"
	elseif diff < 3600 then
		return string.format("%dm", math.floor(diff / 60))
	elseif diff < 86400 then
		return string.format("%dh", math.floor(diff / 3600))
	else
		return string.format("%dd", math.floor(diff / 86400))
	end
end

---Truncate text by display width (CJK/UTF-8 safe), appending "…" when shortened.
---@param text string
---@param max_cols number
---@return string
function M.truncate_display(text, max_cols)
	if type(text) ~= "string" or text == "" then
		return ""
	end
	if max_cols <= 1 then
		return "…"
	end
	if vim.fn.strdisplaywidth(text) <= max_cols then
		return text
	end
	local chars = vim.fn.strcharpart
	local len = vim.fn.strchars(text)
	local lo, hi = 0, len
	while lo < hi do
		local mid = math.floor((lo + hi + 1) / 2)
		local sub = chars(text, 0, mid)
		if vim.fn.strdisplaywidth(sub) <= max_cols - 1 then
			lo = mid
		else
			hi = mid - 1
		end
	end
	return chars(text, 0, lo) .. "…"
end

---Compose a two-column line with `right` flush-aligned to `total_cols`.
---@param left string
---@param right string
---@param total_cols number
---@return string
function M.format_columns(left, right, total_cols)
	if right == "" then
		return M.truncate_display(left, total_cols)
	end
	local right_w = vim.fn.strdisplaywidth(right)
	local left_budget = math.max(4, total_cols - right_w - 2)
	local left_fit = M.truncate_display(left, left_budget)
	local left_w = vim.fn.strdisplaywidth(left_fit)
	local pad = math.max(1, total_cols - left_w - right_w)
	return left_fit .. string.rep(" ", pad) .. right
end

---Extract short readable title from an active Chat (`chat.opts.title`, `chat.title`, or prompt).
---@param chat table
---@return string
function M.get_chat_title(chat)
	if not chat then
		return "Untitled"
	end
	local opt_title = chat.opts and chat.opts.title
	if type(opt_title) == "string" and opt_title ~= "" then
		return opt_title
	end
	if type(chat.title) == "string" and chat.title ~= "" then
		return chat.title
	end
	if type(chat.messages) == "table" then
		local msg_len = #chat.messages
		local cached = state.title_cache[chat]
		if cached and cached.msg_len == msg_len then
			local m_ref = cached.msg_ref
			if m_ref and m_ref.content == cached.raw_content then
				return cached.title
			elseif m_ref == nil and msg_len == 0 then
				return cached.title
			end
		end
		for i = msg_len, 1, -1 do
			local m = chat.messages[i]
			local visible = not (m and m.opts and m.opts.visible == false)
			if visible and m and m.role == "user" and type(m.content) == "string" and m.content ~= "" then
				local raw_src = #m.content > 2048 and vim.fn.strcharpart(m.content, 0, 512) or m.content
				local cleaned = raw_src:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
				if
					cleaned ~= ""
					and not cleaned:match("^Sharing ")
					and not cleaned:match("^<rules>")
					and not cleaned:match("^<summary>")
				then
					state.title_cache[chat] = {
						msg_len = msg_len,
						msg_ref = m,
						raw_content = m.content,
						title = cleaned,
					}
					return cleaned
				end
			end
		end
	end
	return string.format("New Chat #%d", chat.bufnr or 0)
end

---Ensure custom highlight links are registered for the workspace sidebar and Orca/Herdr agent states.
function M.setup_highlights()
	local wt = M.get_wt()
	if wt and type(wt.setup_highlights) == "function" then
		pcall(wt.setup_highlights)
	end
	local links = {
		CcWsTitle = "Title",
		CcWsSection = "SpecialComment",
		CcWsAction = "Function",
		CcWsFilter = "DiagnosticHint",
		CcWsProject = "Directory",
		CcWsWorktree = "Special",
		CcWsDirty = "DiagnosticWarn",
		CcWsActive = "DiagnosticInfo",
		CcWsThinking = "DiagnosticWarn",
		CcWsStreaming = "DiagnosticOk",
		CcWsIdle = "Normal",
		CcWsMuted = "Comment",
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
	vim.api.nvim_set_hl(0, "CcAgentUnread", { fg = "#a9b665", bold = true, default = true })
end

---Query Orca/Herdr agent status for `bufnr`.
---@param bufnr integer
---@param is_cur boolean
---@return { state: string, icon: string, badge: string, short: string, hl: string, badge_hl: string, elapsed: integer }
function M.get_chat_status_info(bufnr, is_cur)
	local anim_idx = state.anim_idx or 1
	local wt = M.get_wt()
	if wt and type(wt.get_chat_status) == "function" then
		local ok, st = pcall(wt.get_chat_status, bufnr, is_cur, anim_idx)
		if ok and type(st) == "table" and type(st.icon) == "string" then
			return st
		end
	end
	return {
		state = "idle",
		icon = is_cur and "◆" or "○",
		badge = is_cur and "Active" or "Idle",
		short = is_cur and "◆" or "○",
		hl = is_cur and "CcAgentActive" or "CcAgentIdle",
		badge_hl = is_cur and "CcAgentActive" or "CcWsMuted",
		elapsed = 0,
	}
end

---Compute roll-up badge and priority highlight across a set of chat buffers.
---@param bufnrs integer[]
---@return { badge: string, hl: string, running: integer, unread: integer, waiting: integer, error: integer }
function M.get_rollup_info(bufnrs)
	if #bufnrs == 0 then
		return { badge = "", hl = "CcWsMuted", running = 0, unread = 0, waiting = 0, error = 0 }
	end
	local anim_idx = state.anim_idx or 1
	local wt = M.get_wt()
	local r = nil
	if wt and type(wt.get_rollup) == "function" then
		local ok, res = pcall(wt.get_rollup, bufnrs, anim_idx)
		if ok and type(res) == "table" then
			r = res
		end
	end
	if not r then
		return { badge = "", hl = "CcWsMuted", running = 0, unread = 0, waiting = 0, error = 0 }
	end
	local hl = "CcWsMuted"
	if (r.waiting or 0) > 0 then
		hl = "CcAgentWaiting"
	elseif (r.error or 0) > 0 then
		hl = "CcAgentError"
	elseif (r.unread or 0) > 0 then
		hl = "CcAgentUnread"
	elseif (r.streaming or 0) > 0 then
		hl = "CcAgentStreaming"
	elseif (r.running or 0) > 0 or (r.thinking or 0) > 0 then
		hl = "CcAgentThinking"
	end
	return {
		badge = type(r.badge) == "string" and r.badge or "",
		hl = hl,
		running = r.running or 0,
		unread = r.unread or 0,
		waiting = r.waiting or 0,
		error = r.error or 0,
	}
end

---Check whether the AI Workspace tab is currently the active tabpage.
---@return boolean
function M.is_current_tab()
	return state.tab ~= nil
		and vim.api.nvim_tabpage_is_valid(state.tab)
		and vim.api.nvim_get_current_tabpage() == state.tab
end

---Return `main_win` if valid inside the workspace tab.
---@return integer|nil
function M.get_main_win()
	if
		state.tab
		and vim.api.nvim_tabpage_is_valid(state.tab)
		and state.main_win
		and vim.api.nvim_win_is_valid(state.main_win)
		and vim.api.nvim_win_get_tabpage(state.main_win) == state.tab
	then
		return state.main_win
	end
	return nil
end

---Check whether the workspace tab and both its panes are still valid.
---@return boolean
function M.is_workspace_valid()
	return state.tab ~= nil
		and vim.api.nvim_tabpage_is_valid(state.tab)
		and state.sidebar_win ~= nil
		and vim.api.nvim_win_is_valid(state.sidebar_win)
		and vim.api.nvim_win_get_tabpage(state.sidebar_win) == state.tab
		and state.sidebar_buf ~= nil
		and vim.api.nvim_buf_is_valid(state.sidebar_buf)
		and vim.api.nvim_win_get_buf(state.sidebar_win) == state.sidebar_buf
		and state.main_win ~= nil
		and vim.api.nvim_win_is_valid(state.main_win)
		and vim.api.nvim_win_get_tabpage(state.main_win) == state.tab
		and state.main_win ~= state.sidebar_win
end

---Stop the live refresh timer if running.
function M.stop_timer()
	---@type any
	local timer = state.timer
	if timer then
		timer:stop()
		if not timer:is_closing() then
			timer:close()
		end
		state.timer = nil
	end
end

---Remember the user's last normal file buffer before entering the workspace tab.
function M.capture_prev_code_context()
	local buf = vim.api.nvim_get_current_buf()
	if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "" and vim.bo[buf].filetype ~= "codecompanion" then
		state.prev_code_buf = buf
	end
end

---Check whether `win` is a normal tiled window (not a floating overlay such as scrollview/notify).
---@param win integer
---@return boolean
function M.is_split_win(win)
	if not win or not vim.api.nvim_win_is_valid(win) then
		return false
	end
	local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
	return ok and (cfg.relative == nil or cfg.relative == "")
end

---Check whether any normal named file buffer exists outside the workspace's transient buffers.
---@return boolean
function M.has_real_code_buffers()
	if
		state.prev_code_buf
		and vim.api.nvim_buf_is_valid(state.prev_code_buf)
		and vim.bo[state.prev_code_buf].buftype == ""
		and vim.api.nvim_buf_get_name(state.prev_code_buf) ~= ""
	then
		return true
	end
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if
			vim.api.nvim_buf_is_loaded(buf)
			and vim.bo[buf].buftype == ""
			and vim.bo[buf].filetype ~= "codecompanion"
			and vim.api.nvim_buf_get_name(buf) ~= ""
		then
			return true
		end
	end
	return false
end

---Check whether `bufnr` is visible in any tabpage other than `exclude_tab`.
---@param bufnr integer
---@param exclude_tab integer
---@return boolean
function M.is_buf_visible_in_other_tab(bufnr, exclude_tab)
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		if M.is_split_win(w) and vim.api.nvim_win_get_buf(w) == bufnr then
			if vim.api.nvim_win_get_tabpage(w) ~= exclude_tab then
				return true
			end
		end
	end
	return false
end

---Check whether a title/project matches the active filter string.
---@param filter_lc string
---@param ... string|nil
---@return boolean
function M.matches_filter(filter_lc, ...)
	if filter_lc == "" then
		return true
	end
	for i = 1, select("#", ...) do
		local s = select(i, ...)
		if type(s) == "string" and s:lower():find(filter_lc, 1, true) then
			return true
		end
	end
	return false
end

---Compare two string arrays for exact equality.
---@param a string[]|nil
---@param b string[]|nil
---@return boolean
function M.string_lists_equal(a, b)
	if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

---Compare two sidebar highlight span arrays for exact equality.
---@param a table[]|nil
---@param b table[]|nil
---@return boolean
function M.hl_lists_equal(a, b)
	if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then
		return false
	end
	for i = 1, #a do
		local x, y = a[i], b[i]
		if
			not x
			or not y
			or x.row ~= y.row
			or x.col_start ~= y.col_start
			or x.col_end ~= y.col_end
			or x.group ~= y.group
		then
			return false
		end
	end
	return true
end

---Safely get the current cursor line in the sidebar window (nil if unavailable).
---@return integer|nil
function M.get_sidebar_row()
	if state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
		return vim.api.nvim_win_get_cursor(state.sidebar_win)[1]
	end
	if state.sidebar_buf and vim.api.nvim_get_current_buf() == state.sidebar_buf then
		return vim.api.nvim_win_get_cursor(0)[1]
	end
	return nil
end

return M
