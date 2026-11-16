local config = require("cc_workspace.config")
local icons = require("cc_workspace.icons")

local M = {}

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local CLICK_MOD = "v:lua.require'cc_workspace.winbar'"

local wb_state = {
	enabled = true,
	anim_idx = 1,
	spinner_timer = nil,
	refresh_scheduled = false,
	wt_unsub = nil,
}

---Safely require `cc_workspace` facade on demand to avoid circular module loading.
---@return table|nil
local function get_ws()
	local ok, ws = pcall(require, "cc_workspace")
	if ok and type(ws) == "table" then
		return ws
	end
	return nil
end

---Safely require `cc_workspace.worktree` and attach change listener once.
---@return table|nil
local function get_wt()
	local ok, wt = pcall(require, "cc_workspace.worktree")
	if not ok or type(wt) ~= "table" then
		return nil
	end
	if not wb_state.wt_unsub and type(wt.on_change) == "function" then
		local ok_sub, unsub = pcall(wt.on_change, function()
			if wb_state.enabled then
				M.ensure_spinner()
				M.schedule_refresh()
			end
		end)
		if ok_sub and type(unsub) == "function" then
			wb_state.wt_unsub = unsub
		end
	end
	return wt
end

---Open the floating agent switcher (`cc_workspace.switcher`).
local function open_switcher()
	if vim.fn.mode():sub(1, 1) == "i" then
		vim.cmd("stopinsert")
	end
	vim.schedule(function()
		local ok, switcher = pcall(require, "cc_workspace.switcher")
		if ok and type(switcher) == "table" and type(switcher.open) == "function" then
			switcher.open()
		end
	end)
end

---Resolve a hex foreground color from a highlight group with a fallback.
---@param hl_name string
---@param fallback string
---@return string
local function resolve_hl_fg(hl_name, fallback)
	local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = hl_name, link = false })
	if ok and type(hl) == "table" and hl.fg then
		return string.format("#%06x", hl.fg)
	end
	return fallback
end

---Resolve a hex background color from a highlight group with a fallback.
---@param hl_name string
---@param fallback string
---@return string
local function resolve_hl_bg(hl_name, fallback)
	local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = hl_name, link = false })
	if ok and type(hl) == "table" and hl.bg then
		return string.format("#%06x", hl.bg)
	end
	return fallback
end

---Parse a `#rrggbb` string into r, g, b integers (0-255).
---@param hex string
---@return integer, integer, integer
local function parse_hex_rgb(hex)
	local clean = type(hex) == "string" and hex:gsub("^#", "") or ""
	if #clean ~= 6 then
		return 40, 40, 40
	end
	local r = tonumber(clean:sub(1, 2), 16) or 40
	local g = tonumber(clean:sub(3, 4), 16) or 40
	local b = tonumber(clean:sub(5, 6), 16) or 40
	return r, g, b
end

---Blend `fg_hex` over `bg_hex` by `alpha` (0.0 .. 1.0).
---@param fg_hex string
---@param bg_hex string
---@param alpha number
---@return string
local function blend_hex(fg_hex, bg_hex, alpha)
	local fr, fg_c, fb = parse_hex_rgb(fg_hex)
	local br, bg_c, bb = parse_hex_rgb(bg_hex)
	local r = math.min(255, math.max(0, math.floor(fr * alpha + br * (1 - alpha) + 0.5)))
	local g = math.min(255, math.max(0, math.floor(fg_c * alpha + bg_c * (1 - alpha) + 0.5)))
	local b = math.min(255, math.max(0, math.floor(fb * alpha + bb * (1 - alpha) + 0.5)))
	return string.format("#%02x%02x%02x", r, g, b)
end

---Define dedicated high-contrast Winbar pill highlight groups (refreshed on `ColorScheme`).
function M.setup_highlights()
	local is_light = (vim.o.background == "light")
	local is_gruvbox = (vim.g.colors_name == "gruvbox-material")
	local is_default_theme = (vim.g.colors_name == nil or vim.g.colors_name == "" or vim.g.colors_name == "default")
	local bar_bg = resolve_hl_bg("WinBar", resolve_hl_bg("StatusLine", is_light and "#ebdbb2" or "#32302f"))
	local warn_fg = resolve_hl_fg("DiagnosticWarn", is_light and "#b57614" or "#d8a657")
	local ok_fg = resolve_hl_fg("DiagnosticOk", is_light and "#79740e" or "#a9b665")
	local err_fg = resolve_hl_fg("DiagnosticError", is_light and "#9d0006" or "#ea6962")
	local info_fg = resolve_hl_fg("DiagnosticInfo", is_light and "#076678" or "#7daea3")
	local muted_fg = resolve_hl_fg("Comment", is_light and "#7c6f64" or "#928374")
	local dir_fg = resolve_hl_fg("Directory", is_light and "#427b58" or "#89b482")
	local wait_fg = is_light and "#af3a03" or "#e78a4e"

	local active_bg = is_light and info_fg or ((is_gruvbox or is_default_theme) and "#d8a657" or warn_fg)
	local active_fg = is_light and "#fbf1c7" or "#1d2021"
	local unread_fg = (not is_light and (is_gruvbox or is_default_theme)) and "#a9b665" or ok_fg
	local inactive_fg = is_light and "#665c54" or (is_gruvbox and "#a89984" or muted_fg)
	local inactive_bg = blend_hex(muted_fg, bar_bg, is_light and 0.14 or 0.18)

	vim.api.nvim_set_hl(0, "CcWinbarSep", { fg = muted_fg, bg = bar_bg })
	vim.api.nvim_set_hl(0, "CcWinbarActive", { fg = active_fg, bg = active_bg, bold = true })
	vim.api.nvim_set_hl(0, "CcWinbarRunning", {
		fg = warn_fg,
		bg = blend_hex(warn_fg, bar_bg, is_light and 0.18 or 0.24),
		bold = true,
	})
	vim.api.nvim_set_hl(0, "CcWinbarUnread", {
		fg = unread_fg,
		bg = blend_hex(unread_fg, bar_bg, is_light and 0.18 or 0.26),
		bold = true,
	})
	vim.api.nvim_set_hl(0, "CcWinbarError", {
		fg = err_fg,
		bg = blend_hex(err_fg, bar_bg, is_light and 0.18 or 0.26),
		bold = true,
	})
	vim.api.nvim_set_hl(0, "CcWinbarWaiting", {
		fg = wait_fg,
		bg = blend_hex(wait_fg, bar_bg, is_light and 0.18 or 0.26),
		bold = true,
	})
	vim.api.nvim_set_hl(0, "CcWinbarInactive", { fg = inactive_fg, bg = inactive_bg })
	vim.api.nvim_set_hl(0, "CcWinbarOverflow", {
		fg = info_fg,
		bg = blend_hex(info_fg, bar_bg, is_light and 0.16 or 0.22),
		bold = true,
	})
	vim.api.nvim_set_hl(0, "CcWinbarAction", {
		fg = dir_fg,
		bg = blend_hex(dir_fg, bar_bg, is_light and 0.14 or 0.18),
		bold = true,
	})
end

---Compute pure terminal cell width of `str` (unaffected by window `wrap`/`showbreak`/`breakindent`).
---@param str string|nil
---@return integer
local function cell_width(str)
	if type(str) ~= "string" or str == "" then
		return 0
	end
	local clean = str:gsub("[%c]", " ")
	local ok, w = pcall(vim.api.nvim_strwidth, clean)
	if ok and type(w) == "number" then
		return w
	end
	return #clean
end

---Truncate `str` to at most `max_w` display cells using `…`, unaffected by window `showbreak`.
---@param str string|nil
---@param max_w integer
---@return string
local function truncate_cells(str, max_w)
	if type(str) ~= "string" or str == "" or max_w <= 0 then
		return ""
	end
	local clean = str:gsub("[%c]", " ")
	if cell_width(clean) <= max_w then
		return clean
	end
	if max_w == 1 then
		return "…"
	end
	local target = max_w - 1
	local nchars = vim.fn.strchars(clean)
	local used = 0
	local out = {}
	for i = 0, nchars - 1 do
		local ch = vim.fn.strcharpart(clean, i, 1)
		local cw = cell_width(ch)
		if used + cw > target then
			break
		end
		table.insert(out, ch)
		used = used + cw
	end
	return table.concat(out) .. "…"
end

---Measure rendered display width of a statusline/winbar format string.
---@param winbar_str string
---@return integer
function M.measure_width(winbar_str)
	if type(winbar_str) ~= "string" or winbar_str == "" then
		return 0
	end
	local plain = winbar_str
		:gsub("%%%%", "\1")
		:gsub("%%#[^#]*#", "")
		:gsub("%%%d*@[^@]*@", "")
		:gsub("%%[X*=]", "")
		:gsub("\1", "%%")
	return cell_width(plain)
end

---Collect valid open CodeCompanion chat instances sorted by `bufnr`.
---@return table[], integer[]
local function collect_open_chats()
	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	local chats = {}
	local bufnrs = {}
	if not chat_mod or type(chat_mod.buf_get_chat) ~= "function" then
		return chats, bufnrs
	end
	local all_entries = chat_mod.buf_get_chat()
	if type(all_entries) == "table" then
		for _, entry in ipairs(all_entries) do
			if entry.chat and vim.api.nvim_buf_is_valid(entry.chat.bufnr) then
				table.insert(chats, entry.chat)
			end
		end
	end
	table.sort(chats, function(a, b)
		return a.bufnr < b.bufnr
	end)
	for _, c in ipairs(chats) do
		table.insert(bufnrs, c.bufnr)
	end
	return chats, bufnrs
end

---Build a lookup map of active requests keyed by `bufnr` from `cc_workspace.worktree`.
---@param wt table|nil
---@return table<integer, table>, integer
local function get_active_requests_map(wt)
	local by_buf = {}
	local count = 0
	if not wt then
		return by_buf, 0
	end
	if type(wt.get_active_requests) == "function" then
		local ok, list = pcall(wt.get_active_requests)
		if ok and type(list) == "table" then
			if #list > 0 then
				for _, req in ipairs(list) do
					if type(req) == "table" then
						count = count + 1
						if type(req.bufnr) == "number" and req.bufnr > 0 then
							by_buf[req.bufnr] = req
						end
					end
				end
			else
				for k, req in pairs(list) do
					if type(req) == "table" then
						count = count + 1
						local b = type(req.bufnr) == "number" and req.bufnr or (type(k) == "number" and k or nil)
						if b and b > 0 then
							by_buf[b] = req
						end
					end
				end
			end
		end
	end
	if count == 0 and type(wt.get_rollup) == "function" then
		local ok_r, rollup = pcall(wt.get_rollup, nil, wb_state.anim_idx)
		if ok_r and type(rollup) == "table" and type(rollup.running) == "number" then
			count = rollup.running
		end
	end
	return by_buf, count
end

---Resolve unified Orca/Herdr lifecycle state for a chat buffer.
---@param bufnr integer
---@param is_cur boolean
---@param wt table|nil
---@param req_by_buf table<integer, table>
---@return { state: string, icon: string, elapsed: integer }
local function resolve_chat_status(bufnr, is_cur, wt, req_by_buf)
	local req = req_by_buf and req_by_buf[bufnr] or nil
	local st_info = nil
	if wt and type(wt.get_chat_status) == "function" then
		local ok_s, res = pcall(wt.get_chat_status, bufnr, is_cur, wb_state.anim_idx)
		if ok_s and type(res) == "table" then
			st_info = res
		end
	end
	if req and (req.started_at or req.elapsed) then
		local elapsed = type(req.elapsed) == "number" and req.elapsed
			or math.max(0, math.floor((vim.uv.hrtime() - req.started_at) / 1e9))
		local phase = (req.phase == "streaming" or req.state == "streaming") and "streaming" or "thinking"
		if st_info and (st_info.state == "waiting" or st_info.state == "error") then
			return {
				state = st_info.state,
				icon = st_info.icon or (st_info.state == "waiting" and "" or "✗"),
				elapsed = st_info.elapsed or elapsed,
			}
		end
		return {
			state = phase,
			icon = phase == "streaming" and "⚡" or SPINNER_FRAMES[wb_state.anim_idx],
			elapsed = (st_info and type(st_info.elapsed) == "number" and st_info.elapsed > 0) and st_info.elapsed
				or elapsed,
		}
	end
	if st_info and type(st_info.state) == "string" then
		return {
			state = st_info.state,
			icon = st_info.icon or (is_cur and "◆" or "○"),
			elapsed = type(st_info.elapsed) == "number" and st_info.elapsed or 0,
		}
	end
	return {
		state = "idle",
		icon = is_cur and "◆" or "○",
		elapsed = 0,
	}
end

---Return non-floating visible CodeCompanion chat windows.
---@return { win: integer, buf: integer }[]
local function list_visible_chat_wins()
	local chat_wins = {}
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local ok_cfg, cfg = pcall(vim.api.nvim_win_get_config, win)
		if ok_cfg and (cfg.relative == nil or cfg.relative == "") then
			local buf = vim.api.nvim_win_get_buf(win)
			if vim.bo[buf].filetype == "codecompanion" then
				table.insert(chat_wins, { win = win, buf = buf })
			end
		end
	end
	return chat_wins
end

---Stop the winbar animation timer when no chat requests are running.
local function stop_spinner_timer()
	if wb_state.spinner_timer then
		wb_state.spinner_timer:stop()
		if not wb_state.spinner_timer:is_closing() then
			wb_state.spinner_timer:close()
		end
		wb_state.spinner_timer = nil
	end
end

---Ensure the 150ms winbar animation timer is running while active requests exist.
function M.ensure_spinner()
	if not wb_state.enabled or wb_state.spinner_timer then
		return
	end
	local wt = get_wt()
	local _, running_count = get_active_requests_map(wt)
	if running_count <= 0 then
		return
	end
	local timer = vim.uv.new_timer()
	if not timer then
		return
	end
	wb_state.spinner_timer = timer
	timer:start(
		150,
		150,
		vim.schedule_wrap(function()
			if not wb_state.enabled then
				stop_spinner_timer()
				return
			end
			local cur_wt = get_wt()
			local _, n = get_active_requests_map(cur_wt)
			if n <= 0 or #list_visible_chat_wins() == 0 then
				stop_spinner_timer()
				return
			end
			wb_state.anim_idx = (wb_state.anim_idx % #SPINNER_FRAMES) + 1
			M.refresh()
			pcall(vim.cmd.redrawstatus)
		end)
	)
end

---Determine maximum simultaneously rendered chat pills for a window width (`<= 7`).
---@param win_w integer
---@return integer
local function max_pills_for_width(win_w)
	if win_w > 160 then
		return 7
	elseif win_w >= 115 then
		return 6
	elseif win_w >= 88 then
		return 4
	elseif win_w >= 64 then
		return 3
	elseif win_w >= 44 then
		return 2
	end
	return 1
end

---Compute off-screen attention rollup and highest-priority target chat for a hidden slice `[from_i .. to_i]`.
---@param chats table[]
---@param statuses table<integer, table>
---@param from_i integer
---@param to_i integer
---@param fallback_idx integer
---@return string, integer
local function summarize_overflow_slice(chats, statuses, from_i, to_i, fallback_idx)
	local wait_n, err_n, unread_n, run_n = 0, 0, 0, 0
	local best_idx = nil
	local best_prio = 99
	for i = from_i, to_i do
		local c = chats[i]
		if c then
			local st = statuses[c.bufnr]
			local sname = st and st.state or "idle"
			if sname == "waiting" then
				wait_n = wait_n + 1
				if best_prio > 1 then
					best_prio = 1
					best_idx = i
				end
			elseif sname == "error" then
				err_n = err_n + 1
				if best_prio > 2 then
					best_prio = 2
					best_idx = i
				end
			elseif sname == "unread" then
				unread_n = unread_n + 1
				if best_prio > 3 then
					best_prio = 3
					best_idx = i
				end
			elseif sname == "thinking" or sname == "streaming" then
				run_n = run_n + 1
				if best_prio > 4 then
					best_prio = 4
					best_idx = i
				end
			end
		end
	end
	local parts = {}
	if wait_n > 0 then
		table.insert(parts, "" .. tostring(wait_n))
	end
	if err_n > 0 then
		table.insert(parts, "✗" .. tostring(err_n))
	end
	if unread_n > 0 then
		table.insert(parts, "✓" .. tostring(unread_n))
	end
	if run_n > 0 then
		table.insert(parts, SPINNER_FRAMES[wb_state.anim_idx] .. tostring(run_n))
	end
	local target_chat = chats[best_idx or fallback_idx] or chats[from_i]
	return table.concat(parts, " "), (target_chat and target_chat.bufnr or 0)
end

---Click handler for chat pills (`%<bufnr>@v:lua.require'cc_workspace.winbar'.on_tab_click@`).
---@param target_bufnr integer
---@param _clicks integer
---@param button? string
function M.on_tab_click(target_bufnr, _clicks, button)
	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	if not chat_mod or type(target_bufnr) ~= "number" or target_bufnr <= 0 then
		return
	end
	local target = chat_mod.buf_get_chat(target_bufnr)
	if not target then
		return
	end
	local ws = get_ws()
	if not ws then
		return
	end
	local wt = get_wt()
	if button == "m" then
		local req_by_buf = get_active_requests_map(wt)
		local st = resolve_chat_status(target_bufnr, false, wt, req_by_buf)
		if req_by_buf[target_bufnr] or st.state == "thinking" or st.state == "streaming" then
			local ok = vim.fn.confirm(
				"Conversation is running. Stop and close '" .. ws.get_chat_title(target) .. "'?",
				"&Yes\n&No",
				2
			)
			if ok ~= 1 then
				return
			end
		end
		ws.close_chat_safely(target, false)
		return
	end
	if button == "r" then
		open_switcher()
		return
	end
	if button ~= nil and button ~= "l" then
		return
	end
	local mpos = vim.fn.getmousepos()
	local clicked_win = (mpos and type(mpos.winid) == "number" and mpos.winid > 0) and mpos.winid or nil
	ws.focus_or_open_chat(target, clicked_win)
	if wt and type(wt.mark_read) == "function" then
		pcall(wt.mark_read, target_bufnr)
	end
	M.schedule_refresh()
end

---Click handler for `‹ +N` / `+M ›` overflow badges (`%<bufnr>@v:lua.require'cc_workspace.winbar'.on_overflow_click@`).
---@param target_bufnr integer
---@param clicks integer
---@param button? string
function M.on_overflow_click(target_bufnr, clicks, button)
	if button == "r" then
		open_switcher()
		return
	end
	if button ~= nil and button ~= "l" then
		return
	end
	M.on_tab_click(target_bufnr, clicks, "l")
end

---Click handler for `[idx/total ▾]` switcher button.
---@param _minwid integer
---@param _clicks integer
---@param button? string
function M.on_switcher_click(_minwid, _clicks, button)
	if button ~= nil and button ~= "l" and button ~= "r" then
		return
	end
	open_switcher()
end

---Click handler for `+` new chat button.
---@param _minwid integer
---@param _clicks integer
---@param button? string
function M.on_new_click(_minwid, _clicks, button)
	if button ~= nil and button ~= "l" then
		return
	end
	local ws = get_ws()
	if ws and type(ws.new_smart_chat) == "function" then
		ws.new_smart_chat()
	end
end

---Click handler for `󰕮 WS` / `󰌍 Code` workspace toggle button.
---@param _minwid integer
---@param _clicks integer
---@param button? string
function M.on_ws_click(_minwid, _clicks, button)
	if button ~= nil and button ~= "l" then
		return
	end
	local ws = get_ws()
	if ws and type(ws.toggle) == "function" then
		ws.toggle()
	end
end

---Click handler for ` project ·  branch` badge (left-click: new chat in project; right-click: add project).
---@param _minwid integer
---@param _clicks integer
---@param button? string
function M.on_proj_click(_minwid, _clicks, button)
	if button ~= nil and button ~= "l" and button ~= "r" then
		return
	end
	if vim.fn.mode():sub(1, 1) == "i" then
		vim.cmd("stopinsert")
	end
	vim.schedule(function()
		local ws = get_ws()
		if not ws then
			return
		end
		if button == "r" then
			ws.enter(false, { skip_auto_chat = true })
			ws.prompt_add_project()
			return
		end
		ws.prompt_new_project_chat()
	end)
end

---Compute total width of right-aligned buttons plus separators and minimum `%=` gap.
---@param sw_w integer
---@param proj_w integer
---@param ws_w integer
---@return integer
local function compute_right_width(sw_w, proj_w, ws_w)
	local count = 0
	local sum = 0
	if sw_w > 0 then
		count = count + 1
		sum = sum + sw_w
	end
	if proj_w > 0 then
		count = count + 1
		sum = sum + proj_w
	end
	if ws_w > 0 then
		count = count + 1
		sum = sum + ws_w
	end
	if count == 0 then
		return 0
	end
	return sum + (count - 1) + 1
end

---Join non-empty right-side button strings with `sep_str`.
---@param sw_btn string
---@param proj_btn string
---@param ws_btn string
---@param sep_str string
---@return string
local function join_right_buttons(sw_btn, proj_btn, ws_btn, sep_str)
	local items = {}
	if sw_btn ~= "" then
		table.insert(items, sw_btn)
	end
	if proj_btn ~= "" then
		table.insert(items, proj_btn)
	end
	if ws_btn ~= "" then
		table.insert(items, ws_btn)
	end
	return table.concat(items, sep_str)
end

---Update winbar on all visible CodeCompanion chat windows with high-contrast paginated pills,
---clickable overflow badges, `[idx/total ▾]` switcher, `+`, Project/Worktree badge, and Workspace toggle.
function M.refresh()
	if not wb_state.enabled then
		return
	end
	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	if not chat_mod or type(chat_mod.buf_get_chat) ~= "function" then
		return
	end
	local chat_wins = list_visible_chat_wins()
	if #chat_wins == 0 then
		return
	end

	local ws = get_ws()
	if not ws then
		return
	end
	local wt = get_wt()
	local req_by_buf, running_count = get_active_requests_map(wt)
	if running_count > 0 then
		M.ensure_spinner()
	end

	local global_cwd = ws.normalize_project_path(vim.fn.getcwd(-1, -1))
	local chats = collect_open_chats()

	local aichat_icons = icons.get("aichat", true)
	local ui_icons = icons.get("ui", true)
	local ws_glyph = icons.ui.Workspace ~= "" and icons.ui.Workspace or "󰕮"
	local code_glyph = icons.ui.Code ~= "" and icons.ui.Code or "󰌍"
	local branch_glyph = icons.git.Branch ~= "" and icons.git.Branch or ""

	local icon_raw = " " .. (aichat_icons.Chat ~= "" and aichat_icons.Chat or "󱜸 ")
	local icon_w = cell_width(icon_raw)
	local icon_part = string.format("%%#CcWinbarSep#%s%%*", icon_raw:gsub("%%", "%%%%"))
	local sep_str = "%#CcWinbarSep# %*"

	for _, cw in ipairs(chat_wins) do
		local win = cw.win
		local buf = cw.buf
		if vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(buf) then
			local cur_chat = chat_mod.buf_get_chat(buf)
			if cur_chat then
				local win_w = vim.api.nvim_win_get_width(win)
				local in_ws = (ws.get_main_win() == win)

				local cur_idx = 1
				local statuses = {}
				for idx, c in ipairs(chats) do
					local is_cur = (c.bufnr == buf)
					if is_cur then
						cur_idx = idx
					end
					statuses[c.bufnr] = resolve_chat_status(c.bufnr, is_cur, wt, req_by_buf)
				end

				local ws_raw
				if win_w < 24 then
					ws_raw = ""
				elseif win_w < 44 then
					ws_raw = in_ws and (" " .. code_glyph .. " ") or (" " .. ws_glyph .. " ")
				else
					ws_raw = in_ws and (" " .. code_glyph .. " Code ") or (" " .. ws_glyph .. " WS ")
				end
				local ws_w = cell_width(ws_raw)
				local ws_btn = ws_w > 0
						and string.format(
							"%%#CcWinbarAction#%%@%s.on_ws_click@%s%%X%%*",
							CLICK_MOD,
							ws_raw:gsub("%%", "%%%%")
						)
					or ""

				local proj_raw = ""
				local proj_w = 0
				if win_w >= 54 then
					local proj_name, proj_path = ws.get_chat_project_name(cur_chat)
					local chat_dir = ws.get_valid_chat_cwd(cur_chat)
						or (proj_path ~= "" and proj_path ~= "Other" and proj_path or nil)
					local branch = (wt and type(wt.get_worktree_branch) == "function" and chat_dir)
							and wt.get_worktree_branch(chat_dir)
						or nil
					if type(branch) == "string" and branch == "" then
						branch = nil
					end
					local show_proj = proj_name ~= ""
						and (
							in_ws
							or branch ~= nil
							or (proj_path ~= "" and proj_path ~= "Other" and proj_path ~= global_cwd)
						)
					if show_proj then
						if branch then
							if win_w >= 110 then
								proj_raw = string.format(
									" %s%s · %s %s ",
									ui_icons.Folder,
									truncate_cells(proj_name, 15),
									branch_glyph,
									truncate_cells(branch, 22)
								)
							elseif win_w >= 78 then
								proj_raw = string.format(
									" %s%s · %s %s ",
									ui_icons.Folder,
									truncate_cells(proj_name, 11),
									branch_glyph,
									truncate_cells(branch, 13)
								)
							else
								proj_raw = string.format(" %s %s ", branch_glyph, truncate_cells(branch, 12))
							end
						else
							local max_proj_w = win_w >= 84 and 18 or 12
							proj_raw = string.format(" %s%s ", ui_icons.Folder, truncate_cells(proj_name, max_proj_w))
						end
						proj_w = cell_width(proj_raw)
					end
				end
				local proj_btn = proj_w > 0
						and string.format(
							"%%#CcWinbarAction#%%@%s.on_proj_click@%s%%X%%*",
							CLICK_MOD,
							proj_raw:gsub("%%", "%%%%")
						)
					or ""

				local sw_raw = (#chats > 1 and win_w >= 64) and string.format(" [%d/%d ▾] ", cur_idx, #chats) or ""
				local sw_w = cell_width(sw_raw)
				local sw_btn = sw_w > 0
						and string.format(
							"%%#CcWinbarAction#%%@%s.on_switcher_click@%s%%X%%*",
							CLICK_MOD,
							sw_raw:gsub("%%", "%%%%")
						)
					or ""

				local new_raw = win_w >= 26 and " + " or ""
				local new_w = cell_width(new_raw)
				local new_btn = new_w > 0
						and string.format("%%#CcWinbarAction#%%@%s.on_new_click@%s%%X%%*", CLICK_MOD, new_raw)
					or ""

				local right_total_w = compute_right_width(sw_w, proj_w, ws_w)
				local avail_group = win_w - icon_w - right_total_w - (new_w > 0 and (new_w + 1) or 0)
				if avail_group < 24 and sw_w > 0 then
					sw_raw, sw_btn, sw_w = "", "", 0
					right_total_w = compute_right_width(0, proj_w, ws_w)
					avail_group = win_w - icon_w - right_total_w - (new_w > 0 and (new_w + 1) or 0)
				end
				if avail_group < 14 and proj_w > 0 then
					proj_raw, proj_btn, proj_w = "", "", 0
					right_total_w = compute_right_width(sw_w, 0, ws_w)
					avail_group = win_w - icon_w - right_total_w - (new_w > 0 and (new_w + 1) or 0)
				end
				if avail_group < 8 and new_w > 0 then
					new_raw, new_btn, new_w = "", "", 0
					avail_group = win_w - icon_w - right_total_w
				end

				local total_chats = math.max(1, #chats)
				local max_k = math.min(total_chats, max_pills_for_width(win_w))
				local min_pill_w = win_w >= 72 and 15 or (win_w >= 48 and 12 or 8)

				local start_i, end_i = 1, total_chats
				local left_txt, right_txt = "", ""
				local left_target, right_target = 0, 0
				local pills_avail = avail_group

				for k = max_k, 1, -1 do
					local half_left = math.floor((k - 1) / 2)
					local s = cur_idx - half_left
					local e = s + k - 1
					if s < 1 then
						s = 1
						e = math.min(total_chats, k)
					end
					if e > total_chats then
						e = total_chats
						s = math.max(1, e - k + 1)
					end

					local l_roll, l_buf, r_roll, r_buf = "", 0, "", 0
					local l_str, r_str = "", ""
					if s > 1 and #chats > 0 then
						local prev_page_idx = math.max(1, s - (k - math.floor((k - 1) / 2)))
						l_roll, l_buf = summarize_overflow_slice(chats, statuses, 1, s - 1, prev_page_idx)
						if l_roll ~= "" and win_w >= 88 then
							l_str = string.format(" ‹ +%d (%s) ", s - 1, l_roll)
						elseif win_w >= 44 then
							l_str = string.format(" ‹ +%d ", s - 1)
						else
							l_str = string.format("‹+%d", s - 1)
						end
					end
					if e < #chats then
						local next_page_idx = math.min(#chats, e + 1 + math.floor((k - 1) / 2))
						r_roll, r_buf = summarize_overflow_slice(chats, statuses, e + 1, #chats, next_page_idx)
						if r_roll ~= "" and win_w >= 88 then
							r_str = string.format(" +%d (%s) › ", #chats - e, r_roll)
						elseif win_w >= 44 then
							r_str = string.format(" +%d › ", #chats - e)
						else
							r_str = string.format("+%d›", #chats - e)
						end
					end

					local lw = cell_width(l_str)
					local rw = cell_width(r_str)
					local item_cnt = (lw > 0 and 1 or 0) + k + (rw > 0 and 1 or 0)
					local seps_w = math.max(0, item_cnt - 1)
					local rem = avail_group - lw - rw - seps_w

					if rem < k * min_pill_w and (l_roll ~= "" or r_roll ~= "") then
						if s > 1 then
							l_str = win_w >= 44 and string.format(" ‹ +%d ", s - 1) or string.format("‹+%d", s - 1)
							lw = cell_width(l_str)
						end
						if e < #chats then
							r_str = win_w >= 44 and string.format(" +%d › ", #chats - e)
								or string.format("+%d›", #chats - e)
							rw = cell_width(r_str)
						end
						rem = avail_group - lw - rw - seps_w
					end

					if rem >= k * min_pill_w or k == 1 then
						start_i, end_i = s, e
						left_txt, right_txt = l_str, r_str
						left_target, right_target = l_buf, r_buf
						pills_avail = math.max(4, rem)
						break
					end
				end

				local left_items = {}
				if left_txt ~= "" and left_target > 0 then
					table.insert(
						left_items,
						string.format(
							"%%#CcWinbarOverflow#%%%d@%s.on_overflow_click@%s%%X%%*",
							left_target,
							CLICK_MOD,
							left_txt:gsub("%%", "%%%%")
						)
					)
				end

				if #chats > 0 then
					local visible_count = math.max(1, end_i - start_i + 1)
					local active_bonus = (visible_count > 1 and pills_avail >= visible_count * 16 + 6) and 6 or 0
					local base_pill_w = math.max(4, math.floor((pills_avail - active_bonus) / visible_count))
					local max_inactive_w = 24
					local max_active_w = 34

					for idx = start_i, end_i do
						local c = chats[idx]
						local is_cur = (c.bufnr == buf)
						local st = statuses[c.bufnr] or { state = "idle", icon = "○", elapsed = 0 }
						local pill_budget = is_cur and math.min(max_active_w, base_pill_w + active_bonus)
							or math.min(max_inactive_w, base_pill_w)

						local hl
						local prefix
						local run_str = ""
						if is_cur then
							hl = "CcWinbarActive"
							prefix = #chats > 1 and string.format("◆ %d/%d", idx, #chats)
								or string.format("◆ %d", idx)
							if st.state == "thinking" or st.state == "streaming" then
								local r_icon = st.state == "streaming" and "⚡" or SPINNER_FRAMES[wb_state.anim_idx]
								local full_r = string.format(" %s %ds", r_icon, st.elapsed)
								local short_r = " " .. r_icon
								if cell_width(prefix) + cell_width(full_r) + 2 <= pill_budget then
									run_str = full_r
								elseif cell_width(prefix) + cell_width(short_r) + 2 <= pill_budget then
									run_str = short_r
								end
							elseif st.state == "waiting" then
								run_str = " "
							elseif st.state == "error" then
								run_str = " ✗"
							end
						else
							if st.state == "thinking" or st.state == "streaming" then
								hl = "CcWinbarRunning"
								local r_icon = st.state == "streaming" and "⚡" or SPINNER_FRAMES[wb_state.anim_idx]
								prefix = string.format("%s %d", r_icon, idx)
								local full_r = string.format(" %ds", st.elapsed)
								if cell_width(prefix) + cell_width(full_r) + 2 <= pill_budget then
									run_str = full_r
								end
							elseif st.state == "unread" then
								hl = "CcWinbarUnread"
								prefix = string.format("✓ %d", idx)
							elseif st.state == "waiting" then
								hl = "CcWinbarWaiting"
								prefix = string.format(" %d", idx)
							elseif st.state == "error" then
								hl = "CcWinbarError"
								prefix = string.format("✗ %d", idx)
							else
								hl = "CcWinbarInactive"
								prefix = string.format("○ %d", idx)
							end
						end

						local prefix_w = cell_width(prefix)
						local run_w = cell_width(run_str)
						local inner_budget = pill_budget - 2 - prefix_w - run_w
						local label = prefix
						if inner_budget >= 7 and is_cur then
							local short_title = truncate_cells(ws.get_chat_title(c), inner_budget - 3)
							if short_title ~= "" then
								label = string.format("%s · %s", prefix, short_title)
							end
						elseif inner_budget >= 4 then
							local short_title = truncate_cells(ws.get_chat_title(c), inner_budget - 1)
							if short_title ~= "" then
								label = string.format("%s·%s", prefix, short_title)
							end
						elseif pill_budget < prefix_w + 2 then
							label = truncate_cells(prefix, math.max(1, pill_budget - 2))
							run_str = ""
						end

						local raw_pill = string.format(" %s%s ", label, run_str)
						if cell_width(raw_pill) > pill_budget then
							raw_pill = truncate_cells(vim.trim(raw_pill), math.max(2, pill_budget))
						end
						table.insert(
							left_items,
							string.format(
								"%%#%s#%%%d@%s.on_tab_click@%s%%X%%*",
								hl,
								c.bufnr,
								CLICK_MOD,
								raw_pill:gsub("%%", "%%%%")
							)
						)
					end
				end

				if right_txt ~= "" and right_target > 0 then
					table.insert(
						left_items,
						string.format(
							"%%#CcWinbarOverflow#%%%d@%s.on_overflow_click@%s%%X%%*",
							right_target,
							CLICK_MOD,
							right_txt:gsub("%%", "%%%%")
						)
					)
				end

				if new_btn ~= "" then
					table.insert(left_items, new_btn)
				end

				local left_joined = table.concat(left_items, sep_str)
				local right_joined = join_right_buttons(sw_btn, proj_btn, ws_btn, sep_str)
				local bar = right_joined ~= "" and string.format("%s%s%%=%s", icon_part, left_joined, right_joined)
					or string.format("%s%s", icon_part, left_joined)

				if M.measure_width(bar) > win_w and sw_btn ~= "" then
					right_joined = join_right_buttons("", proj_btn, ws_btn, sep_str)
					bar = right_joined ~= "" and string.format("%s%s%%=%s", icon_part, left_joined, right_joined)
						or string.format("%s%s", icon_part, left_joined)
				end
				if M.measure_width(bar) > win_w and proj_btn ~= "" then
					right_joined = join_right_buttons("", "", ws_btn, sep_str)
					bar = right_joined ~= "" and string.format("%s%s%%=%s", icon_part, left_joined, right_joined)
						or string.format("%s%s", icon_part, left_joined)
				end
				if M.measure_width(bar) > win_w and ws_btn ~= "" then
					bar = string.format("%s%s", icon_part, left_joined)
				end
				if M.measure_width(bar) > win_w then
					local fallback_inner = truncate_cells(
						string.format("◆ %d/%d %s", cur_idx, total_chats, ws.get_chat_title(cur_chat)),
						math.max(1, win_w - 2)
					)
					local fallback_pill = win_w >= 4 and (" " .. fallback_inner .. " ")
						or truncate_cells(fallback_inner, math.max(1, win_w))
					bar = string.format(
						"%%#CcWinbarActive#%%%d@%s.on_tab_click@%s%%X%%*",
						cur_chat.bufnr,
						CLICK_MOD,
						fallback_pill:gsub("%%", "%%%%")
					)
				end
				if vim.wo[win].winbar ~= bar then
					vim.wo[win].winbar = bar
				end
			end
		end
	end
end

---Schedule a coalesced Winbar refresh and statusline redraw on the next event-loop tick.
function M.schedule_refresh()
	if not wb_state.enabled or wb_state.refresh_scheduled then
		return
	end
	wb_state.refresh_scheduled = true
	vim.schedule(function()
		wb_state.refresh_scheduled = false
		if wb_state.enabled then
			M.refresh()
			pcall(vim.cmd.redrawstatus)
		end
	end)
end

---Initialize standalone CodeCompanion chat winbars (decoupled from `lualine.nvim`).
---@param opts? boolean|{ enabled?: boolean }
function M.setup(opts)
	local group = vim.api.nvim_create_augroup("CcWorkspaceWinbar", { clear = true })
	local cfg_wb = type(config.options) == "table" and config.options.winbar or nil
	if opts == false or cfg_wb == false or (type(opts) == "table" and opts.enabled == false) then
		wb_state.enabled = false
		stop_spinner_timer()
		return
	end

	wb_state.enabled = true
	M.setup_highlights()
	get_wt()

	vim.api.nvim_create_autocmd("ColorScheme", {
		group = group,
		callback = function()
			M.setup_highlights()
			M.schedule_refresh()
		end,
	})

	vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "WinEnter", "TabEnter", "VimResized", "WinResized" }, {
		group = group,
		callback = function()
			M.schedule_refresh()
		end,
	})

	vim.api.nvim_create_autocmd("User", {
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
			"CodeCompanionChatTitle",
			"CodeCompanionHistoryTitleSet",
			"CodeCompanionHistoryTitleRenamed",
			"CodeCompanionTool*",
		},
		group = group,
		callback = function(args)
			get_wt()
			if args.match == "CodeCompanionRequestStarted" or args.match == "CodeCompanionRequestStreaming" then
				M.ensure_spinner()
			end
			M.schedule_refresh()
		end,
	})

	M.schedule_refresh()
end

return M
