local config = require("cc_workspace.config")
local icons = require("cc_workspace.icons")
local keymaps = require("cc_workspace.keymaps")
local layout = require("cc_workspace.layout")
local pickers = require("cc_workspace.pickers")
local render = require("cc_workspace.render")
local actions = require("cc_workspace.sidebar_actions")
local state_mod = require("cc_workspace.state")
local wb_hl = require("cc_workspace.winbar_highlights")

local state = state_mod.state
local help_ns = vim.api.nvim_create_namespace("CcWorkspaceHelpFloat")
local active_help_float = nil

local M = {
	yank_row_path = actions.yank_row_path,
	open_full_history = actions.open_full_history,
	prompt_filter = actions.prompt_filter,
	clear_filter = actions.clear_filter,
	rename_current_row = actions.rename_current_row,
	delete_current_row = actions.delete_current_row,
	inspect_current_row = actions.inspect_current_row,
	cursor_target_path = actions.cursor_target_path,
	cursor_project_path = actions.cursor_project_path,
	refresh_sidebar = actions.refresh_sidebar,
}

---Pad or truncate `str` to exact `target_w` terminal display cells.
---@param str string
---@param target_w integer
---@return string
local function fit_cells(str, target_w)
	if target_w <= 0 then
		return ""
	end
	local fit = wb_hl.truncate_cells(str or "", target_w)
	local pad = target_w - wb_hl.cell_width(fit)
	return pad > 0 and (fit .. string.rep(" ", pad)) or fit
end

---Close the active floating shortcuts cheatsheet, if open.
function M.close_help_float()
	if active_help_float and type(active_help_float.close) == "function" then
		active_help_float.close()
	end
end

---Return the currently open floating shortcuts cheatsheet window and buffer IDs, if open.
---@return integer|nil win, integer|nil buf
function M.get_help_float_win()
	if active_help_float and active_help_float.win and vim.api.nvim_win_is_valid(active_help_float.win) then
		return active_help_float.win, active_help_float.buf
	end
	return nil, nil
end

---Refresh the currently open floating cheatsheet in place after live keymap updates.
function M.refresh_help_float()
	if active_help_float and type(active_help_float.refresh) == "function" then
		active_help_float.refresh()
	end
end

---Build categorized lines and extmark highlights for the dynamic Floating Cheatsheet (`?`).
---@param total_w integer
---@return string[], table[]
local function build_cheatsheet_content(total_w)
	local eff = keymaps.get_effective_keymaps().by_scope
	local warn_glyph = icons.diagnostics.Warning ~= "" and icons.diagnostics.Warning or ""
	local two_col = total_w >= 96
	local col_w = two_col and math.floor((total_w - 3) / 2) or (total_w - 2)
	local key_col_w = math.min(15, math.max(11, math.floor(col_w * 0.33)))
	local desc_col_w = math.max(12, col_w - key_col_w - 2)

	local function active_rows(list)
		local out = {}
		for _, e in ipairs(list or {}) do
			if not e.disabled and #e.keys > 0 then
				table.insert(out, { key = e.key_label, desc = e.desc })
			end
		end
		return out
	end

	local function build_col_items(sections)
		local items = {}
		for s_idx, sec in ipairs(sections) do
			if s_idx > 1 then
				table.insert(items, { kind = "blank", text = string.rep(" ", col_w) })
			end
			table.insert(items, { kind = "header", text = fit_cells(" " .. sec.title, col_w) })
			table.insert(items, { kind = "rule", text = " " .. string.rep("─", math.max(4, col_w - 2)) .. " " })
			for _, row in ipairs(sec.rows) do
				local k_fit = fit_cells(" " .. row.key, key_col_w)
				local d_fit = fit_cells(row.desc, desc_col_w)
				local full = fit_cells(k_fit .. " " .. d_fit, col_w)
				table.insert(items, { kind = "row", text = full, key_bytes = #vim.trim(k_fit) + 1 })
			end
		end
		return items
	end

	local left_secs = { { title = "Sidebar Shortcuts", rows = active_rows(eff.sidebar) } }
	local global_rows = active_rows(eff.global)
	if #global_rows == 0 then
		table.insert(global_rows, { key = ":CodeCompanion…", desc = "Opt-in via opts.keymaps.global" })
	end
	local chat_rows = active_rows(eff.chat)
	table.insert(chat_rows, { key = "<CR> / <C-s>", desc = "Send prompt (CodeCompanion)" })
	table.insert(chat_rows, { key = "ga / ?", desc = "Change model / CodeCompanion help" })

	local right_secs = {
		{ title = "Global Shortcuts", rows = global_rows },
		{ title = "Floating Switcher", rows = active_rows(eff.switcher) },
		{ title = "Chat Buffer", rows = chat_rows },
		{
			title = "Agent Status Legend",
			rows = {
				{ key = "⠋ / ⚡ / " .. warn_glyph, desc = "Thinking / Streaming / Waiting" },
				{ key = "✓ / ✗ / ◆ / ○", desc = "Unread / Error / Active / Idle" },
			},
		},
	}

	local lines, hls = {}, {}
	local function add_cell_hls(row0, byte_off, cell)
		if not cell or cell.kind == "blank" then
			return
		end
		if cell.kind == "header" then
			table.insert(hls, { row = row0, col_start = byte_off, col_end = byte_off + #cell.text, group = "Title" })
		elseif cell.kind == "rule" then
			table.insert(hls, { row = row0, col_start = byte_off, col_end = byte_off + #cell.text, group = "Comment" })
		elseif cell.kind == "row" then
			local kb = math.min(#cell.text, cell.key_bytes or 10)
			table.insert(hls, { row = row0, col_start = byte_off, col_end = byte_off + kb, group = "Special" })
		end
	end

	if two_col then
		local l_items = build_col_items(left_secs)
		local r_items = build_col_items(right_secs)
		local max_n = math.max(#l_items, #r_items)
		local blank_col = string.rep(" ", col_w)
		local sep = " │ "
		for i = 1, max_n do
			local lc, rc = l_items[i], r_items[i]
			local lt = lc and lc.text or blank_col
			local rt = rc and rc.text or blank_col
			local line = lt .. sep .. rt
			table.insert(lines, line)
			local r0 = #lines - 1
			add_cell_hls(r0, 0, lc)
			table.insert(hls, { row = r0, col_start = #lt, col_end = #lt + #sep, group = "WinSeparator" })
			add_cell_hls(r0, #lt + #sep, rc)
		end
	else
		local all_secs = { left_secs[1], right_secs[1], right_secs[2], right_secs[3], right_secs[4] }
		for _, item in ipairs(build_col_items(all_secs)) do
			local line = " " .. item.text
			table.insert(lines, line)
			add_cell_hls(#lines - 1, 1, item)
		end
	end
	return lines, hls
end

---Show the dynamic categorized floating shortcuts card (`?` in Sidebar/Switcher or `:CodeCompanionWorkspaceKeys float`).
---@return table
function M.show_help_float()
	M.close_help_float()
	local max_w = math.max(36, vim.o.columns - 6)
	local target_w = vim.o.columns >= 106 and math.min(max_w, 108) or math.min(max_w, 54)
	local lines, hls = build_cheatsheet_content(target_w)
	local h = math.min(#lines, math.max(10, vim.o.lines - 6))
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].undolevels = -1

	local function apply_render(r_lines, r_hls)
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, r_lines)
		vim.bo[buf].modifiable = false
		vim.api.nvim_buf_clear_namespace(buf, help_ns, 0, -1)
		for _, hl in ipairs(r_hls) do
			pcall(vim.api.nvim_buf_set_extmark, buf, help_ns, hl.row, hl.col_start, {
				end_col = hl.col_end,
				hl_group = hl.group,
			})
		end
	end
	apply_render(lines, hls)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		title = string.format(" %sAI Workspace Shortcuts ", icons.get("aichat", true).Chat),
		title_pos = "center",
		footer = " s/<C-f>:Search & Rebind (<C-r>) · q/?/<Esc>:Close ",
		footer_pos = "center",
		width = target_w,
		height = h,
		row = math.max(1, math.floor((vim.o.lines - h) / 2)),
		col = math.max(1, math.floor((vim.o.columns - target_w) / 2)),
		zindex = 80,
	})
	vim.wo[win].wrap = false
	vim.wo[win].cursorline = true

	local function close_help()
		if active_help_float and active_help_float.win == win then
			active_help_float = nil
		end
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	local function refresh_help()
		if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		local nw = vim.o.columns >= 106 and math.min(math.max(36, vim.o.columns - 6), 108)
			or math.min(math.max(36, vim.o.columns - 6), 54)
		local nl, nh = build_cheatsheet_content(nw)
		apply_render(nl, nh)
		local nh_win = math.min(#nl, math.max(10, vim.o.lines - 6))
		pcall(vim.api.nvim_win_set_config, win, {
			width = nw,
			height = nh_win,
			row = math.max(1, math.floor((vim.o.lines - nh_win) / 2)),
			col = math.max(1, math.floor((vim.o.columns - nw) / 2)),
		})
	end

	active_help_float = { win = win, buf = buf, close = close_help, refresh = refresh_help, mode = "float" }
	for _, k in ipairs({ "q", "<Esc>", "?", "<CR>" }) do
		vim.keymap.set("n", k, close_help, {
			buffer = buf,
			nowait = true,
			silent = true,
			desc = "cc-workspace: Close shortcuts float",
		})
	end
	for _, k in ipairs({ "s", "<C-f>", "/" }) do
		vim.keymap.set("n", k, function()
			close_help()
			vim.schedule(function()
				keymaps.show_keys({ mode = "picker" })
			end)
		end, {
			buffer = buf,
			nowait = true,
			silent = true,
			desc = "cc-workspace: Search & live-rebind keymaps",
		})
	end
	vim.api.nvim_create_autocmd("BufLeave", { buffer = buf, once = true, callback = close_help })
	return active_help_float
end

---Activate the action bound to a specific sidebar line.
---@param row number|nil
---@param focus_main boolean
---@param click_col? integer
function M.activate_row(row, focus_main, click_col)
	if not row then
		return
	end
	local act = state.row_actions[row]
	if not act then
		return
	end
	if act.kind == "new_chat" then
		if click_col and act.help_col_1idx and click_col >= act.help_col_1idx then
			M.show_help_float()
		else
			layout.new_chat(focus_main)
		end
	elseif act.kind == "new_project_chat" then
		layout.new_chat(focus_main, act.path)
	elseif act.kind == "add_project" then
		pickers.prompt_add_project()
	elseif act.kind == "projects_header" then
		if click_col and act.search_col_1idx and click_col >= act.search_col_1idx then
			actions.open_full_history()
		elseif click_col and act.worktree_col_1idx and click_col >= act.worktree_col_1idx then
			pickers.prompt_create_worktree_chat()
		else
			pickers.prompt_add_project()
		end
	elseif act.kind == "filter" then
		actions.prompt_filter()
	elseif act.kind == "help" then
		M.show_help_float()
	elseif act.kind == "history_picker" then
		actions.open_full_history()
	elseif act.kind == "active_chat" then
		layout.show_chat(act.chat, focus_main)
	elseif act.kind == "history_chat" then
		layout.open_history_chat(act.save_id, focus_main)
	elseif act.kind == "toggle_project_all" then
		state.expanded_all_projects[act.path] = not state.expanded_all_projects[act.path]
		render.render()
	elseif act.kind == "toggle_worktree_all" then
		state.expanded_all_worktrees[act.path] = not state.expanded_all_worktrees[act.path]
		render.render()
	elseif act.kind == "worktree" then
		state.last_selected_project = act.path or state.last_selected_project
		if act.is_empty_leaf or (click_col and act.plus_col_1idx and click_col >= act.plus_col_1idx) then
			layout.new_chat(focus_main, act.path)
		else
			state.collapsed_worktrees[act.path] = not act.collapsed
			render.render()
		end
	elseif act.kind == "project" then
		state.last_selected_project = act.path ~= "Other" and act.path or state.last_selected_project
		if act.is_empty_leaf or (click_col and act.plus_col_1idx and click_col >= act.plus_col_1idx) then
			layout.new_chat(focus_main, act.path ~= "Other" and act.path or nil)
		else
			state.collapsed_projects[act.path] = not act.collapsed
			render.render()
		end
	end
end

---Jump cursor to the next or previous actionable sidebar row.
---@param delta integer
local function step_action_row(delta)
	if not state_mod.is_workspace_valid() or #state.action_rows == 0 then
		return
	end
	local cur = state_mod.get_sidebar_row()
	if not cur then
		return
	end
	if delta > 0 then
		for _, r in ipairs(state.action_rows) do
			if r > cur then
				vim.api.nvim_win_set_cursor(state.sidebar_win, { r, 0 })
				return
			end
		end
		vim.api.nvim_win_set_cursor(state.sidebar_win, { state.action_rows[1], 0 })
	else
		for i = #state.action_rows, 1, -1 do
			local r = state.action_rows[i]
			if r < cur then
				vim.api.nvim_win_set_cursor(state.sidebar_win, { r, 0 })
				return
			end
		end
		vim.api.nvim_win_set_cursor(state.sidebar_win, { state.action_rows[#state.action_rows], 0 })
	end
end

---Handle `l` / `<Right>` in sidebar: expand collapsed group, step into child, or activate row.
local function handle_key_expand_or_open()
	local row = state_mod.get_sidebar_row()
	local act = row and state.row_actions[row] or nil
	if not act then
		return
	end
	if act.kind == "project" then
		if act.is_empty_leaf then
			layout.new_chat(true, act.path ~= "Other" and act.path or nil)
		elseif act.collapsed then
			state.collapsed_projects[act.path] = false
			render.render()
		elseif state.row_actions[row + 1] and state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
			pcall(vim.api.nvim_win_set_cursor, state.sidebar_win, { row + 1, 0 })
		end
	elseif act.kind == "worktree" then
		if act.is_empty_leaf then
			layout.new_chat(true, act.path)
		elseif act.collapsed then
			state.collapsed_worktrees[act.path] = false
			render.render()
		elseif state.row_actions[row + 1] and state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
			pcall(vim.api.nvim_win_set_cursor, state.sidebar_win, { row + 1, 0 })
		end
	else
		M.activate_row(row, true)
	end
end

---Handle `h` / `<Left>` in sidebar: collapse open group or jump up to parent group row.
local function handle_key_collapse_or_parent()
	local row = state_mod.get_sidebar_row()
	local act = row and state.row_actions[row] or nil
	if not act then
		return
	end
	if act.kind == "project" then
		if not act.is_empty_leaf and not act.collapsed then
			state.collapsed_projects[act.path] = true
			render.render()
		end
	elseif act.kind == "worktree" then
		if not act.is_empty_leaf and not act.collapsed then
			state.collapsed_worktrees[act.path] = true
			render.render()
		elseif act.project_row and state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
			pcall(vim.api.nvim_win_set_cursor, state.sidebar_win, { act.project_row, 0 })
		end
	elseif act.worktree_path and act.worktree_row then
		state.collapsed_worktrees[act.worktree_path] = true
		if state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
			pcall(vim.api.nvim_win_set_cursor, state.sidebar_win, { act.worktree_row, 0 })
		end
		render.render()
	elseif act.project_path and act.project_row then
		state.collapsed_projects[act.project_path] = true
		if state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
			pcall(vim.api.nvim_win_set_cursor, state.sidebar_win, { act.project_row, 0 })
		end
		render.render()
	end
end

---Handle `za` fold toggle on project, worktree, or child rows.
local function handle_key_toggle_fold()
	local row = state_mod.get_sidebar_row()
	local act = row and state.row_actions[row] or nil
	if not act then
		return
	end
	if act.kind == "project" then
		if not act.is_empty_leaf then
			state.collapsed_projects[act.path] = not act.collapsed
			render.render()
		end
	elseif act.kind == "worktree" then
		if not act.is_empty_leaf then
			state.collapsed_worktrees[act.path] = not act.collapsed
			render.render()
		end
	elseif act.worktree_path and act.worktree_row then
		local parent_act = state.row_actions[act.worktree_row]
		local next_collapsed = not (parent_act and parent_act.collapsed == true)
		state.collapsed_worktrees[act.worktree_path] = next_collapsed
		if next_collapsed and state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
			pcall(vim.api.nvim_win_set_cursor, state.sidebar_win, { act.worktree_row, 0 })
		end
		render.render()
	elseif act.project_path and act.project_row then
		local parent_act = state.row_actions[act.project_row]
		local next_collapsed = not (parent_act and parent_act.collapsed == true)
		state.collapsed_projects[act.project_path] = next_collapsed
		if next_collapsed and state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
			pcall(vim.api.nvim_win_set_cursor, state.sidebar_win, { act.project_row, 0 })
		end
		render.render()
	end
end

---Determine whether a mouse click at `(act, clicked_col)` should keep focus in the sidebar rather than jumping to `main_win`.
---@param act table|nil
---@param clicked_col integer
---@return boolean
local function should_mouse_keep_sidebar(act, clicked_col)
	local clicked_plus = act ~= nil and act.plus_col_1idx ~= nil and clicked_col >= act.plus_col_1idx
	local clicked_help = act ~= nil and act.help_col_1idx ~= nil and clicked_col >= act.help_col_1idx
	if clicked_help then
		return true
	end
	if clicked_plus then
		return false
	end
	return act == nil
		or (act.kind == "project" and not act.is_empty_leaf)
		or (act.kind == "worktree" and not act.is_empty_leaf)
		or act.kind == "projects_header"
		or act.kind == "add_project"
		or act.kind == "toggle_project_all"
		or act.kind == "toggle_worktree_all"
		or act.kind == "filter"
		or act.kind == "help"
		or act.kind == "history_picker"
end

---Execute a scheduled mouse click inside the sidebar window.
---@param clicked_line integer
---@param clicked_col integer
local function handle_sidebar_mouse_click(clicked_line, clicked_col)
	if vim.fn.mode():sub(1, 1) == "i" then
		vim.cmd("stopinsert")
	end
	if state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
		pcall(vim.api.nvim_win_set_cursor, state.sidebar_win, { clicked_line, 0 })
	end
	local act = state.row_actions[clicked_line]
	local keep_sidebar = should_mouse_keep_sidebar(act, clicked_col)
	M.activate_row(clicked_line, not keep_sidebar, clicked_col)
end

---Build an expr-keymap handler intercepting clicks targeting `state.sidebar_win`.
---@param fallback_key string
---@return fun(): string
local function make_sidebar_mouse_expr(fallback_key)
	return function()
		if state_mod.is_current_tab() and state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
			local pos = vim.fn.getmousepos()
			if pos.winid == state.sidebar_win and pos.line >= 1 then
				local clicked_line, clicked_col = pos.line, pos.column
				vim.schedule(function()
					handle_sidebar_mouse_click(clicked_line, clicked_col)
				end)
				if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
					return "<C-\\><C-n>"
				end
				return "<Ignore>"
			end
		end
		return fallback_key
	end
end

---Apply (or hot-rebind) all configured `opts.keymaps.sidebar` bindings onto `buf`.
---@param buf integer
function M.apply_sidebar_keymaps(buf)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	---@type table<string, any>
	local sb = (config.options and config.options.keymaps and config.options.keymaps.sidebar)
		or (config.defaults.keymaps and config.defaults.keymaps.sidebar)
		or {}
	local jump_keys = keymaps.normalize_keys(sb.jump_1_9)

	keymaps.bind_buffer_keymaps(buf, {
		{
			spec = sb.open,
			desc = "Open chat / toggle tree group",
			callback = function()
				M.activate_row(state_mod.get_sidebar_row(), true)
			end,
		},
		{ spec = sb.expand_or_open, desc = "Expand group or open item", callback = handle_key_expand_or_open },
		{ spec = sb.collapse, desc = "Collapse group / parent row", callback = handle_key_collapse_or_parent },
		{ spec = sb.toggle_fold, desc = "Toggle Project / Worktree fold", callback = handle_key_toggle_fold },
		{
			spec = sb.collapse_all,
			desc = "Collapse all groups",
			callback = function()
				state.focus_project_path = actions.cursor_project_path() or state.focus_project_path
				for _, p in ipairs(state.rendered_project_paths or {}) do
					state.collapsed_projects[p] = true
				end
				for _, wp in ipairs(state.rendered_worktree_paths or {}) do
					state.collapsed_worktrees[wp] = true
				end
				render.render()
			end,
		},
		{
			spec = sb.expand_all,
			desc = "Expand all groups",
			callback = function()
				state.focus_project_path = actions.cursor_project_path() or state.focus_project_path
				state.collapsed_projects = {}
				for _, p in ipairs(state.rendered_project_paths or {}) do
					state.collapsed_projects[p] = false
				end
				state.collapsed_worktrees = {}
				render.render()
			end,
		},
		{
			spec = sb.peek,
			desc = "Peek conversation (keep sidebar focus)",
			callback = function()
				M.activate_row(state_mod.get_sidebar_row(), false)
			end,
		},
		{
			spec = sb.next_item,
			desc = "Next actionable item",
			callback = function()
				step_action_row(1)
			end,
		},
		{
			spec = sb.prev_item,
			desc = "Previous actionable item",
			callback = function()
				step_action_row(-1)
			end,
		},
		{
			spec = jump_keys,
			desc = "Jump to active conversation 1–9",
			callback = function(lhs)
				local idx = tonumber(lhs)
				if not idx then
					for i, k in ipairs(jump_keys) do
						if k == lhs then
							idx = i
							break
						end
					end
				end
				local target = idx and state.active_chats[idx] or nil
				if target and vim.api.nvim_buf_is_valid(target.bufnr) then
					layout.show_chat(target, true)
				end
			end,
		},
		{
			spec = sb.new_chat,
			desc = "New chat in Worktree / Project",
			callback = function()
				layout.new_chat(true, actions.cursor_target_path())
			end,
		},
		{
			spec = sb.new_project_chat,
			desc = "Pick Project(s) & start chat",
			callback = pickers.prompt_new_project_chat,
		},
		{
			spec = sb.new_worktree_chat,
			desc = "New Git Worktree + Agent Chat",
			callback = pickers.prompt_create_worktree_chat,
		},
		{
			spec = sb.jump_attention,
			desc = "Jump to unread / attention Agent",
			callback = function()
				local wt = state_mod.get_wt()
				if wt and type(wt.jump_to_attention) == "function" then
					wt.jump_to_attention()
				end
			end,
		},
		{ spec = sb.add_project, desc = "Add Project (multi-pick)", callback = pickers.prompt_add_project },
		{ spec = sb.add_project_input, desc = "Add Project (path input)", callback = pickers.prompt_add_project_input },
		{
			spec = sb.open_code_tab,
			desc = "Open Worktree / Project code tab",
			callback = function()
				local p = actions.cursor_target_path()
				if p then
					layout.open_project_in_code_tab(p)
				end
			end,
		},
		{ spec = sb.rename, desc = "Rename chat or Project alias", callback = actions.rename_current_row },
		{ spec = sb.delete, desc = "Close chat / rm Worktree / Project", callback = actions.delete_current_row },
		{ spec = sb.inspect, desc = "Inspect Project / Worktree / chat", callback = actions.inspect_current_row },
		{
			spec = sb.yank_path,
			desc = "Copy item path to clipboard",
			callback = function()
				actions.yank_row_path(false)
			end,
		},
		{
			spec = sb.yank_all_paths,
			desc = "Copy all repo & worktree paths",
			callback = function()
				actions.yank_row_path(true)
			end,
		},
		{ spec = sb.filter, desc = "Filter by keyword", callback = actions.prompt_filter },
		{ spec = sb.clear_filter, desc = "Clear keyword filter", callback = actions.clear_filter },
		{ spec = sb.history, desc = "Full-text saved history picker", callback = actions.open_full_history },
		{ spec = sb.refresh, desc = "Refresh worktrees & sidebar", callback = actions.refresh_sidebar },
		{ spec = sb.help, desc = "Show shortcuts cheatsheet", callback = M.show_help_float },
		{ spec = sb.leave, desc = "Back to code tab (keep Workspace)", callback = layout.leave },
		{ spec = sb.close_workspace, desc = "Close AI Workspace tab", callback = layout.close },
	})

	local mouse_opts = { buffer = buf, nowait = true, silent = true, expr = true }
	vim.keymap.set("n", "<LeftMouse>", make_sidebar_mouse_expr("<LeftMouse>"), mouse_opts)
	vim.keymap.set("n", "<2-LeftMouse>", make_sidebar_mouse_expr("<2-LeftMouse>"), mouse_opts)
	vim.keymap.set({ "n", "i" }, "<LeftMouse>", make_sidebar_mouse_expr("<LeftMouse>"), { silent = true, expr = true })
end

---Configure sidebar buffer options and keymaps.
---@param buf number
function M.setup_sidebar_buf(buf)
	vim.bo[buf].filetype = "cc-workspace"
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].buflisted = false
	vim.bo[buf].undolevels = -1
	vim.bo[buf].modifiable = false
	state.sidebar_buf_ready = buf

	local sb_group = vim.api.nvim_create_augroup("CcWorkspaceSidebarBuf", { clear = true })
	vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
		group = sb_group,
		buffer = buf,
		callback = function()
			vim.cmd("stopinsert")
		end,
	})
	M.apply_sidebar_keymaps(buf)
end

state.actions.setup_sidebar_buf = M.setup_sidebar_buf
state.actions.apply_sidebar_keymaps = M.apply_sidebar_keymaps
state.actions.format_sidebar_footer = keymaps.format_sidebar_footer
if
	state.sidebar_buf
	and vim.api.nvim_buf_is_valid(state.sidebar_buf)
	and state.sidebar_buf_ready ~= state.sidebar_buf
then
	M.setup_sidebar_buf(state.sidebar_buf)
end

return M
