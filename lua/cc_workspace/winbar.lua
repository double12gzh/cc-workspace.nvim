local config = require("cc_workspace.config")
local icons = require("cc_workspace.icons")
local wb_hl = require("cc_workspace.winbar_highlights")

local SPINNER_FRAMES = wb_hl.SPINNER_FRAMES
local cell_width = wb_hl.cell_width

local M = {
	setup_highlights = wb_hl.setup_highlights,
	measure_width = wb_hl.measure_width,
	cell_width = wb_hl.cell_width,
	truncate_cells = wb_hl.truncate_cells,
	format_cols = wb_hl.format_cols,
}

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

				local proj_name, proj_path = "", ""
				local branch = nil
				local show_proj = false
				if win_w >= 54 then
					proj_name, proj_path = ws.get_chat_project_name(cur_chat)
					local chat_dir = ws.get_valid_chat_cwd(cur_chat)
						or (proj_path ~= "" and proj_path ~= "Other" and proj_path or nil)
					branch = (wt and type(wt.get_worktree_branch) == "function" and chat_dir)
							and wt.get_worktree_branch(chat_dir)
						or nil
					if type(branch) == "string" and branch == "" then
						branch = nil
					end
					show_proj = proj_name ~= ""
						and (
							in_ws
							or branch ~= nil
							or (proj_path ~= "" and proj_path ~= "Other" and proj_path ~= global_cwd)
						)
				end

				local badges = wb_hl.build_action_badges({
					win_w = win_w,
					in_ws = in_ws,
					click_mod = CLICK_MOD,
					icon_w = icon_w,
					cur_idx = cur_idx,
					chat_count = #chats,
					show_proj = show_proj,
					proj_name = proj_name,
					branch = branch,
				})

				local start_i, end_i, left_txt, left_target, right_txt, right_target, pills_avail =
					wb_hl.select_pill_page(chats, statuses, cur_idx, win_w, badges.avail_group, wb_state.anim_idx)

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
					for idx = start_i, end_i do
						local c = chats[idx]
						local is_cur = (c.bufnr == buf)
						table.insert(
							left_items,
							wb_hl.format_chat_pill({
								bufnr = c.bufnr,
								idx = idx,
								chat_count = #chats,
								is_cur = is_cur,
								st = statuses[c.bufnr] or { state = "idle", icon = "○", elapsed = 0 },
								title = ws.get_chat_title(c),
								pill_budget = is_cur and math.min(34, base_pill_w + active_bonus)
									or math.min(24, base_pill_w),
								anim_idx = wb_state.anim_idx,
								click_mod = CLICK_MOD,
							})
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
				if badges.new_btn ~= "" then
					table.insert(left_items, badges.new_btn)
				end

				local bar = wb_hl.assemble_winbar_line({
					win_w = win_w,
					icon_part = icon_part,
					left_joined = table.concat(left_items, sep_str),
					sep_str = sep_str,
					sw_btn = badges.sw_btn,
					proj_btn = badges.proj_btn,
					ws_btn = badges.ws_btn,
					cur_idx = cur_idx,
					total_chats = math.max(1, #chats),
					cur_title = ws.get_chat_title(cur_chat),
					cur_bufnr = cur_chat.bufnr,
					click_mod = CLICK_MOD,
				})
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
