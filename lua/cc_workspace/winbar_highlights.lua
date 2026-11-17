local icons = require("cc_workspace.icons")

local M = {}

M.SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

---Resolve a hex foreground color from a highlight group with a fallback.
---@param hl_name string
---@param fallback string
---@return string
function M.resolve_hl_fg(hl_name, fallback)
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
function M.resolve_hl_bg(hl_name, fallback)
	local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = hl_name, link = false })
	if ok and type(hl) == "table" and hl.bg then
		return string.format("#%06x", hl.bg)
	end
	return fallback
end

---Parse a `#rrggbb` string into r, g, b integers (0-255).
---@param hex string
---@return integer, integer, integer
function M.parse_hex_rgb(hex)
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
function M.blend_hex(fg_hex, bg_hex, alpha)
	local fr, fg_c, fb = M.parse_hex_rgb(fg_hex)
	local br, bg_c, bb = M.parse_hex_rgb(bg_hex)
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
	local bar_bg = M.resolve_hl_bg("WinBar", M.resolve_hl_bg("StatusLine", is_light and "#ebdbb2" or "#32302f"))
	local warn_fg = M.resolve_hl_fg("DiagnosticWarn", is_light and "#b57614" or "#d8a657")
	local ok_fg = M.resolve_hl_fg("DiagnosticOk", is_light and "#79740e" or "#a9b665")
	local err_fg = M.resolve_hl_fg("DiagnosticError", is_light and "#9d0006" or "#ea6962")
	local info_fg = M.resolve_hl_fg("DiagnosticInfo", is_light and "#076678" or "#7daea3")
	local muted_fg = M.resolve_hl_fg("Comment", is_light and "#7c6f64" or "#928374")
	local dir_fg = M.resolve_hl_fg("Directory", is_light and "#427b58" or "#89b482")
	local wait_fg = is_light and "#af3a03" or "#e78a4e"

	local active_bg = is_light and info_fg or ((is_gruvbox or is_default_theme) and "#d8a657" or warn_fg)
	local active_fg = is_light and "#fbf1c7" or "#1d2021"
	local unread_fg = (not is_light and (is_gruvbox or is_default_theme)) and "#a9b665" or ok_fg
	local inactive_fg = is_light and "#665c54" or (is_gruvbox and "#a89984" or muted_fg)
	local inactive_bg = M.blend_hex(muted_fg, bar_bg, is_light and 0.14 or 0.18)

	vim.api.nvim_set_hl(0, "CcWinbarSep", { fg = muted_fg, bg = bar_bg })
	vim.api.nvim_set_hl(0, "CcWinbarActive", { fg = active_fg, bg = active_bg, bold = true })
	vim.api.nvim_set_hl(0, "CcWinbarRunning", {
		fg = warn_fg,
		bg = M.blend_hex(warn_fg, bar_bg, is_light and 0.18 or 0.24),
		bold = true,
	})
	vim.api.nvim_set_hl(0, "CcWinbarUnread", {
		fg = unread_fg,
		bg = M.blend_hex(unread_fg, bar_bg, is_light and 0.18 or 0.26),
		bold = true,
	})
	vim.api.nvim_set_hl(0, "CcWinbarError", {
		fg = err_fg,
		bg = M.blend_hex(err_fg, bar_bg, is_light and 0.18 or 0.26),
		bold = true,
	})
	vim.api.nvim_set_hl(0, "CcWinbarWaiting", {
		fg = wait_fg,
		bg = M.blend_hex(wait_fg, bar_bg, is_light and 0.18 or 0.26),
		bold = true,
	})
	vim.api.nvim_set_hl(0, "CcWinbarInactive", { fg = inactive_fg, bg = inactive_bg })
	vim.api.nvim_set_hl(0, "CcWinbarOverflow", {
		fg = info_fg,
		bg = M.blend_hex(info_fg, bar_bg, is_light and 0.16 or 0.22),
		bold = true,
	})
	vim.api.nvim_set_hl(0, "CcWinbarAction", {
		fg = dir_fg,
		bg = M.blend_hex(dir_fg, bar_bg, is_light and 0.14 or 0.18),
		bold = true,
	})
end

---Compute pure terminal cell width of `str` (unaffected by window `wrap`/`showbreak`/`breakindent`).
---@param str string|nil
---@return integer
function M.cell_width(str)
	if type(str) ~= "string" or str == "" then
		return 0
	end
	local clean = str:gsub("[%c]", " ")
	local ok, w = pcall(vim.api.nvim_strwidth, clean)
	return (ok and type(w) == "number") and w or #clean
end

---Truncate `str` to at most `max_w` display cells using `…`, unaffected by window `showbreak`.
---@param str string|nil
---@param max_w integer
---@return string
function M.truncate_cells(str, max_w)
	if type(str) ~= "string" or str == "" or max_w <= 0 then
		return ""
	end
	local clean = str:gsub("[%c]", " ")
	if M.cell_width(clean) <= max_w then
		return clean
	end
	if max_w == 1 then
		return "…"
	end
	local target = max_w - 1
	local nchars = vim.fn.strchars(clean)
	local used, out = 0, {}
	for i = 0, nchars - 1 do
		local ch = vim.fn.strcharpart(clean, i, 1)
		local cw = M.cell_width(ch)
		if used + cw > target then
			break
		end
		table.insert(out, ch)
		used = used + cw
	end
	return table.concat(out) .. "…"
end

---Format a two-column line (`left` + padding + `right`) within `total_w` display cells.
---@param left string
---@param right string
---@param total_w integer
---@return string
function M.format_cols(left, right, total_w)
	local rw = M.cell_width(right)
	if rw == 0 then
		return M.truncate_cells(left, total_w)
	end
	if rw >= total_w - 2 then
		return M.truncate_cells(right, total_w)
	end
	local lfit = M.truncate_cells(left, math.max(1, total_w - rw - 2))
	local pad = math.max(1, total_w - M.cell_width(lfit) - rw)
	return lfit .. string.rep(" ", pad) .. right
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
	return M.cell_width(plain)
end

---Compute total width of right-aligned buttons plus separators and minimum `%=` gap.
---@param sw_w integer
---@param proj_w integer
---@param ws_w integer
---@return integer
local function compute_right_width(sw_w, proj_w, ws_w)
	local count, sum = 0, 0
	for _, w in ipairs({ sw_w, proj_w, ws_w }) do
		if w > 0 then
			count, sum = count + 1, sum + w
		end
	end
	return count == 0 and 0 or (sum + (count - 1) + 1)
end

---Join non-empty right-side button strings with `sep_str`.
---@param sw_btn string
---@param proj_btn string
---@param ws_btn string
---@param sep_str string
---@return string
local function join_right_buttons(sw_btn, proj_btn, ws_btn, sep_str)
	local items = {}
	for _, btn in ipairs({ sw_btn, proj_btn, ws_btn }) do
		if btn ~= "" then
			table.insert(items, btn)
		end
	end
	return table.concat(items, sep_str)
end

---Build responsive right-aligned Winbar action badges (`[i/N ▾]`, `Folder · Branch`, `WS/Code`, `+`) and compute available pill width.
---@param ctx table
---@return { ws_btn: string, proj_btn: string, sw_btn: string, new_btn: string, avail_group: integer }
function M.build_action_badges(ctx)
	local win_w, in_ws, click_mod = ctx.win_w, ctx.in_ws, ctx.click_mod
	local ui_icons = icons.get("ui", true)
	local ws_glyph = icons.ui.Workspace ~= "" and icons.ui.Workspace or "󰕮"
	local code_glyph = icons.ui.Code ~= "" and icons.ui.Code or "󰌍"
	local branch_glyph = icons.git.Branch ~= "" and icons.git.Branch or ""

	local ws_raw = win_w < 24 and ""
		or (
			win_w < 44 and (in_ws and (" " .. code_glyph .. " ") or (" " .. ws_glyph .. " "))
			or (in_ws and (" " .. code_glyph .. " Code ") or (" " .. ws_glyph .. " WS "))
		)
	local ws_w = M.cell_width(ws_raw)
	local ws_btn = ws_w > 0
			and string.format("%%#CcWinbarAction#%%@%s.on_ws_click@%s%%X%%*", click_mod, ws_raw:gsub("%%", "%%%%"))
		or ""

	local proj_raw, proj_w = "", 0
	if win_w >= 54 and ctx.show_proj then
		local proj_name, branch = ctx.proj_name, ctx.branch
		if branch then
			if win_w >= 110 then
				proj_raw = string.format(
					" %s%s · %s %s ",
					ui_icons.Folder,
					M.truncate_cells(proj_name, 15),
					branch_glyph,
					M.truncate_cells(branch, 22)
				)
			elseif win_w >= 78 then
				proj_raw = string.format(
					" %s%s · %s %s ",
					ui_icons.Folder,
					M.truncate_cells(proj_name, 11),
					branch_glyph,
					M.truncate_cells(branch, 13)
				)
			else
				proj_raw = string.format(" %s %s ", branch_glyph, M.truncate_cells(branch, 12))
			end
		else
			proj_raw = string.format(" %s%s ", ui_icons.Folder, M.truncate_cells(proj_name, win_w >= 84 and 18 or 12))
		end
		proj_w = M.cell_width(proj_raw)
	end
	local proj_btn = proj_w > 0
			and string.format("%%#CcWinbarAction#%%@%s.on_proj_click@%s%%X%%*", click_mod, proj_raw:gsub("%%", "%%%%"))
		or ""

	local sw_raw = (ctx.chat_count > 1 and win_w >= 64) and string.format(" [%d/%d ▾] ", ctx.cur_idx, ctx.chat_count)
		or ""
	local sw_w = M.cell_width(sw_raw)
	local sw_btn = sw_w > 0
			and string.format(
				"%%#CcWinbarAction#%%@%s.on_switcher_click@%s%%X%%*",
				click_mod,
				sw_raw:gsub("%%", "%%%%")
			)
		or ""

	local new_raw = win_w >= 26 and " + " or ""
	local new_w = M.cell_width(new_raw)
	local new_btn = new_w > 0 and string.format("%%#CcWinbarAction#%%@%s.on_new_click@%s%%X%%*", click_mod, new_raw)
		or ""

	local right_total_w = compute_right_width(sw_w, proj_w, ws_w)
	local avail_group = win_w - ctx.icon_w - right_total_w - (new_w > 0 and (new_w + 1) or 0)
	if avail_group < 24 and sw_w > 0 then
		sw_btn, sw_w = "", 0
		right_total_w = compute_right_width(0, proj_w, ws_w)
		avail_group = win_w - ctx.icon_w - right_total_w - (new_w > 0 and (new_w + 1) or 0)
	end
	if avail_group < 14 and proj_w > 0 then
		proj_btn, proj_w = "", 0
		right_total_w = compute_right_width(sw_w, 0, ws_w)
		avail_group = win_w - ctx.icon_w - right_total_w - (new_w > 0 and (new_w + 1) or 0)
	end
	if avail_group < 8 and new_w > 0 then
		new_btn = ""
		avail_group = win_w - ctx.icon_w - right_total_w
	end
	return { ws_btn = ws_btn, proj_btn = proj_btn, sw_btn = sw_btn, new_btn = new_btn, avail_group = avail_group }
end

---Format a single clickable chat pill (`%#CcWinbar*#%<bufnr>@...@label%X%*`) within `pill_budget` display cells.
---@param opts table
---@return string
function M.format_chat_pill(opts)
	local is_cur, idx, chat_count, st, pill_budget = opts.is_cur, opts.idx, opts.chat_count, opts.st, opts.pill_budget
	local spin_frame = M.SPINNER_FRAMES[opts.anim_idx or 1]
	local hl, prefix, run_str = "", "", ""
	if is_cur then
		hl = "CcWinbarActive"
		prefix = chat_count > 1 and string.format("◆ %d/%d", idx, chat_count) or string.format("◆ %d", idx)
		if st.state == "thinking" or st.state == "streaming" then
			local r_icon = st.state == "streaming" and "⚡" or spin_frame
			local full_r, short_r = string.format(" %s %ds", r_icon, st.elapsed), " " .. r_icon
			if M.cell_width(prefix) + M.cell_width(full_r) + 2 <= pill_budget then
				run_str = full_r
			elseif M.cell_width(prefix) + M.cell_width(short_r) + 2 <= pill_budget then
				run_str = short_r
			end
		elseif st.state == "waiting" then
			run_str = " "
		elseif st.state == "error" then
			run_str = " ✗"
		end
	elseif st.state == "thinking" or st.state == "streaming" then
		hl = "CcWinbarRunning"
		prefix = string.format("%s %d", st.state == "streaming" and "⚡" or spin_frame, idx)
		local full_r = string.format(" %ds", st.elapsed)
		if M.cell_width(prefix) + M.cell_width(full_r) + 2 <= pill_budget then
			run_str = full_r
		end
	elseif st.state == "unread" then
		hl, prefix = "CcWinbarUnread", string.format("✓ %d", idx)
	elseif st.state == "waiting" then
		hl, prefix = "CcWinbarWaiting", string.format(" %d", idx)
	elseif st.state == "error" then
		hl, prefix = "CcWinbarError", string.format("✗ %d", idx)
	else
		hl, prefix = "CcWinbarInactive", string.format("○ %d", idx)
	end

	local prefix_w = M.cell_width(prefix)
	local inner_budget = pill_budget - 2 - prefix_w - M.cell_width(run_str)
	local label = prefix
	if inner_budget >= 7 and is_cur then
		local short_title = M.truncate_cells(opts.title, inner_budget - 3)
		label = short_title ~= "" and string.format("%s · %s", prefix, short_title) or prefix
	elseif inner_budget >= 4 then
		local short_title = M.truncate_cells(opts.title, inner_budget - 1)
		label = short_title ~= "" and string.format("%s·%s", prefix, short_title) or prefix
	elseif pill_budget < prefix_w + 2 then
		label = M.truncate_cells(prefix, math.max(1, pill_budget - 2))
		run_str = ""
	end
	local raw_pill = string.format(" %s%s ", label, run_str)
	if M.cell_width(raw_pill) > pill_budget then
		raw_pill = M.truncate_cells(vim.trim(raw_pill), math.max(2, pill_budget))
	end
	return string.format(
		"%%#%s#%%%d@%s.on_tab_click@%s%%X%%*",
		hl,
		opts.bufnr,
		opts.click_mod,
		raw_pill:gsub("%%", "%%%%")
	)
end

---Assemble final winbar string with progressive right-button shedding so width never exceeds `win_w`.
---@param opts table
---@return string
function M.assemble_winbar_line(opts)
	local win_w, icon_part, left_joined, sep_str = opts.win_w, opts.icon_part, opts.left_joined, opts.sep_str
	local sw_btn, proj_btn, ws_btn = opts.sw_btn, opts.proj_btn, opts.ws_btn
	local function make_bar(rj)
		return rj ~= "" and string.format("%s%s%%=%s", icon_part, left_joined, rj)
			or string.format("%s%s", icon_part, left_joined)
	end
	local bar = make_bar(join_right_buttons(sw_btn, proj_btn, ws_btn, sep_str))
	if M.measure_width(bar) > win_w and sw_btn ~= "" then
		bar = make_bar(join_right_buttons("", proj_btn, ws_btn, sep_str))
	end
	if M.measure_width(bar) > win_w and proj_btn ~= "" then
		bar = make_bar(join_right_buttons("", "", ws_btn, sep_str))
	end
	if M.measure_width(bar) > win_w and ws_btn ~= "" then
		bar = string.format("%s%s", icon_part, left_joined)
	end
	if M.measure_width(bar) > win_w then
		local fb_in = M.truncate_cells(
			string.format("◆ %d/%d %s", opts.cur_idx, opts.total_chats, opts.cur_title),
			math.max(1, win_w - 2)
		)
		local fb_pill = win_w >= 4 and (" " .. fb_in .. " ") or M.truncate_cells(fb_in, math.max(1, win_w))
		bar = string.format(
			"%%#CcWinbarActive#%%%d@%s.on_tab_click@%s%%X%%*",
			opts.cur_bufnr,
			opts.click_mod,
			fb_pill:gsub("%%", "%%%%")
		)
	end
	return bar
end

---Compute off-screen attention rollup and highest-priority target chat for a hidden slice `[from_i .. to_i]`.
---@param chats table[]
---@param statuses table<integer, table>
---@param from_i integer
---@param to_i integer
---@param fallback_idx integer
---@param anim_idx integer
---@return string, integer
local function summarize_overflow_slice(chats, statuses, from_i, to_i, fallback_idx, anim_idx)
	local wait_n, err_n, unread_n, run_n = 0, 0, 0, 0
	local best_idx, best_prio = nil, 99
	for i = from_i, to_i do
		local c = chats[i]
		local sname = (c and statuses[c.bufnr] and statuses[c.bufnr].state) or "idle"
		if sname == "waiting" then
			wait_n = wait_n + 1
			if best_prio > 1 then
				best_prio, best_idx = 1, i
			end
		elseif sname == "error" then
			err_n = err_n + 1
			if best_prio > 2 then
				best_prio, best_idx = 2, i
			end
		elseif sname == "unread" then
			unread_n = unread_n + 1
			if best_prio > 3 then
				best_prio, best_idx = 3, i
			end
		elseif sname == "thinking" or sname == "streaming" then
			run_n = run_n + 1
			if best_prio > 4 then
				best_prio, best_idx = 4, i
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
		table.insert(parts, M.SPINNER_FRAMES[anim_idx or 1] .. tostring(run_n))
	end
	local target_chat = chats[best_idx or fallback_idx] or chats[from_i]
	return table.concat(parts, " "), (target_chat and target_chat.bufnr or 0)
end

---Select visible pill window `[start_i .. end_i]`, overflow badges, and remaining pill budget for `win_w`.
---@param chats table[]
---@param statuses table<integer, table>
---@param cur_idx integer
---@param win_w integer
---@param avail_group integer
---@param anim_idx integer
---@return integer, integer, string, integer, string, integer, integer
function M.select_pill_page(chats, statuses, cur_idx, win_w, avail_group, anim_idx)
	local total_chats = math.max(1, #chats)
	local max_cap = win_w > 160 and 7
		or (win_w >= 115 and 6 or (win_w >= 88 and 4 or (win_w >= 64 and 3 or (win_w >= 44 and 2 or 1))))
	local max_k = math.min(total_chats, max_cap)
	local min_pill_w = win_w >= 72 and 15 or (win_w >= 48 and 12 or 8)

	for k = max_k, 1, -1 do
		local half_left = math.floor((k - 1) / 2)
		local s = cur_idx - half_left
		local e = s + k - 1
		if s < 1 then
			s, e = 1, math.min(total_chats, k)
		end
		if e > total_chats then
			e = total_chats
			s = math.max(1, e - k + 1)
		end
		local l_roll, l_buf, r_roll, r_buf, l_str, r_str = "", 0, "", 0, "", ""
		if s > 1 and #chats > 0 then
			l_roll, l_buf =
				summarize_overflow_slice(chats, statuses, 1, s - 1, math.max(1, s - (k - half_left)), anim_idx)
			l_str = (l_roll ~= "" and win_w >= 88) and string.format(" ‹ +%d (%s) ", s - 1, l_roll)
				or (win_w >= 44 and string.format(" ‹ +%d ", s - 1) or string.format("‹+%d", s - 1))
		end
		if e < #chats then
			r_roll, r_buf =
				summarize_overflow_slice(chats, statuses, e + 1, #chats, math.min(#chats, e + 1 + half_left), anim_idx)
			r_str = (r_roll ~= "" and win_w >= 88) and string.format(" +%d (%s) › ", #chats - e, r_roll)
				or (win_w >= 44 and string.format(" +%d › ", #chats - e) or string.format("+%d›", #chats - e))
		end
		local lw, rw = M.cell_width(l_str), M.cell_width(r_str)
		local seps_w = math.max(0, (lw > 0 and 1 or 0) + k + (rw > 0 and 1 or 0) - 1)
		local rem = avail_group - lw - rw - seps_w
		if rem < k * min_pill_w and (l_roll ~= "" or r_roll ~= "") then
			if s > 1 then
				l_str = win_w >= 44 and string.format(" ‹ +%d ", s - 1) or string.format("‹+%d", s - 1)
				lw = M.cell_width(l_str)
			end
			if e < #chats then
				r_str = win_w >= 44 and string.format(" +%d › ", #chats - e) or string.format("+%d›", #chats - e)
				rw = M.cell_width(r_str)
			end
			rem = avail_group - lw - rw - seps_w
		end
		if rem >= k * min_pill_w or k == 1 then
			return s, e, l_str, l_buf, r_str, r_buf, math.max(4, rem)
		end
	end
	return 1, total_chats, "", 0, "", 0, math.max(4, avail_group)
end

return M
