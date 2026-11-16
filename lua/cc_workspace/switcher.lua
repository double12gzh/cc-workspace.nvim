local icons = require("cc_workspace.icons")

local M = {}

local dropdown_ns = vim.api.nvim_create_namespace("CcWorkspaceSwitcher")
local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local active_float = nil

---Safely load `cc_workspace.worktree` and ensure its autocmd/highlight hooks are initialized.
---@return table|nil
local function load_worktree_mod()
	local ok_wt, wt = pcall(require, "cc_workspace.worktree")
	if not ok_wt or type(wt) ~= "table" then
		return nil
	end
	if type(wt.setup) == "function" then
		pcall(wt.setup)
	elseif type(wt.setup_highlights) == "function" then
		pcall(wt.setup_highlights)
	end
	return wt
end

---Schedule a standalone Winbar refresh when `cc_workspace.winbar` is available.
local function refresh_winbars()
	local ok_wb, wb = pcall(require, "cc_workspace.winbar")
	if ok_wb and type(wb) == "table" and type(wb.schedule_refresh) == "function" then
		wb.schedule_refresh()
	end
end

---Close the currently open switcher float, if any.
function M.close()
	if active_float and type(active_float.close) == "function" then
		active_float.close()
	end
end

---Return the currently open switcher floating window ID and buffer ID, if open.
---@return integer|nil win, integer|nil buf
function M.get_float_win()
	if active_float and active_float.win and vim.api.nvim_win_is_valid(active_float.win) then
		return active_float.win, active_float.buf
	end
	return nil, nil
end

---Jump to the highest-priority unread, waiting, errored, or running AI Agent conversation.
---@param opts? { silent?: boolean }
---@return boolean jumped
function M.jump_to_attention(opts)
	opts = type(opts) == "table" and opts or {}
	pcall(require, "codecompanion")
	local wt = load_worktree_mod()
	if wt and type(wt.jump_to_attention) == "function" then
		local ok_j, jumped = pcall(wt.jump_to_attention, { silent = true })
		if ok_j and jumped then
			refresh_winbars()
			return true
		end
	end

	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	local fallback_bufnr = wt and type(wt.get_last_background_bufnr) == "function" and wt.get_last_background_bufnr()
		or nil
	if not fallback_bufnr and wt and type(wt.get_active_requests) == "function" then
		local ok_r, reqs = pcall(wt.get_active_requests)
		if ok_r and type(reqs) == "table" then
			for _, req in ipairs(reqs) do
				if type(req) == "table" and type(req.bufnr) == "number" then
					fallback_bufnr = req.bufnr
					break
				end
			end
		end
	end

	if fallback_bufnr and chat_mod and type(chat_mod.buf_get_chat) == "function" then
		local chat = chat_mod.buf_get_chat(fallback_bufnr)
		if chat and vim.api.nvim_buf_is_valid(chat.bufnr) then
			if wt and type(wt.clear_last_background_bufnr) == "function" then
				pcall(wt.clear_last_background_bufnr)
			end
			require("cc_workspace").focus_or_open_chat(chat)
			if wt and type(wt.mark_read) == "function" then
				pcall(wt.mark_read, chat.bufnr)
			end
			refresh_winbars()
			return true
		end
	end

	if not opts.silent then
		vim.notify("No unread or active background AI chats", vim.log.levels.INFO, { title = "AI Workspace" })
	end
	return false
end

---Resolve the most relevant Git repository root from the current chat, buffer, or working directory.
---@param ws table
---@param wt table
---@return string|nil
local function resolve_current_repo_root(ws, wt)
	if type(wt.get_repo_root) ~= "function" then
		return nil
	end
	local candidates = {}
	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	if ws.is_current_tab() then
		local main_win = ws.get_main_win()
		if main_win and chat_mod and type(chat_mod.buf_get_chat) == "function" then
			local cur_chat = chat_mod.buf_get_chat(vim.api.nvim_win_get_buf(main_win))
			if cur_chat then
				local chat_cwd = ws.get_valid_chat_cwd(cur_chat)
				if chat_cwd then
					table.insert(candidates, chat_cwd)
				end
				local proj_path = ws.get_chat_project_path(cur_chat)
				if type(proj_path) == "string" and proj_path ~= "" and proj_path ~= "Other" then
					table.insert(candidates, proj_path)
				end
			end
		end
	else
		local cur_buf = vim.api.nvim_get_current_buf()
		if vim.bo[cur_buf].filetype == "codecompanion" and chat_mod and type(chat_mod.buf_get_chat) == "function" then
			local cur_chat = chat_mod.buf_get_chat(cur_buf)
			local chat_cwd = cur_chat and ws.get_valid_chat_cwd(cur_chat) or nil
			if chat_cwd then
				table.insert(candidates, chat_cwd)
			end
		elseif vim.bo[cur_buf].buftype == "" then
			local bname = vim.api.nvim_buf_get_name(cur_buf)
			if bname ~= "" then
				table.insert(candidates, vim.fs.dirname(bname))
			end
		end
	end
	table.insert(candidates, vim.fn.getcwd())
	table.insert(candidates, vim.fn.getcwd(-1, -1))
	for _, dir in ipairs(candidates) do
		if type(dir) == "string" and dir ~= "" then
			local ok_r, root = pcall(wt.get_repo_root, dir)
			if ok_r and type(root) == "string" and root ~= "" then
				return root
			end
		end
	end
	return nil
end

---Interactive Orca/Herdr flow: create a Git Worktree and immediately spawn an Agent Chat inside it.
function M.create_worktree_chat()
	if vim.fn.mode():sub(1, 1) == "i" then
		vim.cmd("stopinsert")
	end
	require("codecompanion")
	local ws = require("cc_workspace")
	local wt = load_worktree_mod()
	if not wt or type(wt.prompt_create_worktree) ~= "function" then
		vim.notify("Git Worktree engine is unavailable", vim.log.levels.WARN, { title = "AI Workspace" })
		return
	end
	local repo_root = resolve_current_repo_root(ws, wt)
	if not repo_root then
		vim.notify("Current directory is not inside a Git repository", vim.log.levels.WARN, { title = "AI Workspace" })
		return
	end
	wt.prompt_create_worktree(repo_root, function(wt_info)
		if type(wt_info) ~= "table" or type(wt_info.path) ~= "string" or wt_info.path == "" then
			return
		end
		if not ws.is_current_tab() then
			ws.enter(false, { skip_auto_chat = true })
		end
		ws.new_chat(true, wt_info.path)
		refresh_winbars()
	end)
end

---Compute pure terminal cell width of `str` (unaffected by window `wrap`/`showbreak`).
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

---Truncate `str` to at most `max_w` display cells using `…`.
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

---Format a two-column line (`left` + padding + `right`) within `total_w` display cells.
---@param left string
---@param right string
---@param total_w integer
---@return string
local function format_cols(left, right, total_w)
	local rw = cell_width(right)
	if rw == 0 then
		return truncate_cells(left, total_w)
	end
	if rw >= total_w - 2 then
		return truncate_cells(right, total_w)
	end
	local max_left = math.max(1, total_w - rw - 2)
	local lfit = truncate_cells(left, max_left)
	local pad = math.max(1, total_w - cell_width(lfit) - rw)
	return lfit .. string.rep(" ", pad) .. right
end

---Open the `<leader>cl` floating Agent Switcher & Quick Actions menu.
function M.open()
	M.close()

	require("codecompanion")
	local ws = require("cc_workspace")
	local wt = load_worktree_mod()
	local chat_mod = require("codecompanion.interactions.chat")
	local aichat_icons = icons.get("aichat", true)
	local branch_glyph = icons.git.Branch ~= "" and icons.git.Branch or ""
	local ws_glyph = icons.ui.Workspace ~= "" and icons.ui.Workspace or "󰕮"
	local hist_glyph = icons.ui.History_alt ~= "" and icons.ui.History_alt or "󰋚"
	local warn_glyph = icons.diagnostics.Warning ~= "" and icons.diagnostics.Warning or ""
	local spin_idx = 1

	local function collect_chats()
		local all = chat_mod.buf_get_chat()
		local list = {}
		if type(all) == "table" then
			for _, entry in ipairs(all) do
				if entry.chat and vim.api.nvim_buf_is_valid(entry.chat.bufnr) then
					table.insert(list, entry.chat)
				end
			end
		end
		table.sort(list, function(a, b)
			return a.bufnr < b.bufnr
		end)
		return list
	end

	local chats = collect_chats()
	local empty_actions = {
		{ key = "n", label = " + New Conversation            [n] ", hl = "Function" },
		{
			key = "t",
			label = string.format(" %s New Git Worktree + Agent    [t] ", branch_glyph),
			hl = "DiagnosticOk",
		},
		{
			key = "w",
			label = string.format(" %s Open AI Workspace           [w] ", ws_glyph),
			hl = "DiagnosticInfo",
		},
		{ key = "a", label = " + Add Project to Workspace    [a] ", hl = "Special" },
		{
			key = "h",
			label = string.format(" %s Browse Saved History        [h] ", hist_glyph),
			hl = "Directory",
		},
	}

	local max_allowed = math.max(38, math.min(vim.o.columns - 4, math.max(54, math.floor(vim.o.columns * 0.72))))

	local function compute_title()
		if #chats == 0 then
			return string.format(" %sAgents ", aichat_icons.Chat)
		end
		if wt and type(wt.get_rollup) == "function" then
			local bufnrs = {}
			for _, c in ipairs(chats) do
				table.insert(bufnrs, c.bufnr)
			end
			local ok_r, rollup = pcall(wt.get_rollup, bufnrs, spin_idx)
			if ok_r and type(rollup) == "table" and type(rollup.badge) == "string" and rollup.badge ~= "" then
				return string.format(" %sAgents (%d) · %s ", aichat_icons.Chat, #chats, rollup.badge)
			end
		end
		return string.format(" %sAgents (%d) ", aichat_icons.Chat, #chats)
	end

	local function compute_footer(w, count)
		if count <= 0 then
			return " CR:select · t:worktree · q:close "
		end
		if w >= 74 then
			return " 1-9/CR:open · u:unread · t:worktree · n:new · a:proj · d:close · w:ws · h:hist "
		elseif w >= 58 then
			return " 1-9/CR:open · u:unread · t:wt · n:new · d:close · w:ws · h:hist "
		elseif w >= 46 then
			return " CR:open · u:unread · t:wt · n:new · d:del · w:ws "
		end
		return " CR:open · u:att · t:wt · n:new "
	end

	local function build_req_map()
		local map = {}
		if wt and type(wt.get_active_requests) == "function" then
			local ok_r, reqs = pcall(wt.get_active_requests)
			if ok_r and type(reqs) == "table" then
				for _, req in ipairs(reqs) do
					if type(req) == "table" and type(req.bufnr) == "number" then
						map[req.bufnr] = req
					end
				end
			end
		end
		return map
	end

	local function format_chat_lines()
		if #chats == 0 then
			local lines, hls = {}, {}
			local target_w = math.min(max_allowed, 38)
			for i, item in ipairs(empty_actions) do
				local fit = truncate_cells(item.label, target_w)
				table.insert(lines, fit)
				table.insert(hls, { row = i - 1, col_start = 0, col_end = #fit, group = item.hl })
			end
			return lines, hls, target_w
		end

		local req_map = build_req_map()
		local now = vim.uv.hrtime()
		local global_cwd = ws.normalize_project_path(vim.fn.getcwd(-1, -1))
		local proj_set = {}
		local proj_count = 0
		for _, c in ipairs(chats) do
			local _, ppath = ws.get_chat_project_name(c)
			if ppath and not proj_set[ppath] then
				proj_set[ppath] = true
				proj_count = proj_count + 1
			end
		end

		local rows_data = {}
		local max_natural_w = 48
		for idx, c in ipairs(chats) do
			local cur_win = vim.fn.bufwinid(c.bufnr)
			local visible_cur = cur_win ~= -1
			local any_wins = not visible_cur and vim.fn.win_findbuf(c.bufnr) or nil
			local visible_other = type(any_wins) == "table" and #any_wins > 0
			local adapter_name = (c.adapter and (c.adapter.name or c.adapter.formatted_name)) or "AI"
			local pname, ppath = ws.get_chat_project_name(c)
			local chat_dir = ws.get_valid_chat_cwd(c) or (ppath ~= "" and ppath ~= "Other" and ppath or nil)
			local branch = (wt and type(wt.get_worktree_branch) == "function" and chat_dir)
					and wt.get_worktree_branch(chat_dir)
				or nil
			if type(branch) == "string" and branch == "" then
				branch = nil
			end

			local st = nil
			if wt and type(wt.get_chat_status) == "function" then
				local ok_s, res = pcall(wt.get_chat_status, c.bufnr, visible_cur, spin_idx)
				if ok_s and type(res) == "table" then
					st = res
				end
			end

			local req = req_map[c.bufnr]
			local marker = visible_cur and "◆" or (visible_other and "◐" or "○")
			local status_str = visible_cur and "Active" or (visible_other and "Open" or "Idle")
			local line_hl = visible_cur and "DiagnosticInfo" or (visible_other and "Special" or "Normal")
			local status_hl = visible_cur and "DiagnosticInfo" or "Comment"

			local state_name = st and st.state or "idle"
			if req and req.started_at and state_name ~= "waiting" and state_name ~= "error" then
				state_name = req.phase == "streaming" and "streaming" or "thinking"
			end

			if state_name == "thinking" then
				local elapsed = (st and type(st.elapsed) == "number" and st.elapsed)
					or (req and req.started_at and math.floor((now - req.started_at) / 1e9))
					or 0
				marker = SPINNER_FRAMES[spin_idx]
				status_str = string.format("%s T%ds", SPINNER_FRAMES[spin_idx], elapsed)
				line_hl = "DiagnosticWarn"
				status_hl = (st and st.badge_hl) or "DiagnosticWarn"
			elseif state_name == "streaming" then
				local elapsed = (st and type(st.elapsed) == "number" and st.elapsed)
					or (req and req.started_at and math.floor((now - req.started_at) / 1e9))
					or 0
				marker = "⚡"
				status_str = string.format("%s S%ds", SPINNER_FRAMES[spin_idx], elapsed)
				line_hl = "DiagnosticOk"
				status_hl = (st and st.badge_hl) or "DiagnosticOk"
			elseif state_name == "waiting" then
				marker = warn_glyph
				status_str = warn_glyph .. " Wait"
				line_hl = "DiagnosticError"
				status_hl = (st and st.badge_hl) or "DiagnosticError"
			elseif state_name == "error" then
				marker = "✗"
				status_str = "✗ Err"
				line_hl = "DiagnosticError"
				status_hl = (st and st.badge_hl) or "DiagnosticError"
			elseif state_name == "unread" then
				marker = "✓"
				status_str = "✓ Done"
				line_hl = (st and st.hl) or "DiagnosticOk"
				status_hl = (st and st.badge_hl) or "DiagnosticOk"
			end

			local capped_title = truncate_cells(ws.get_chat_title(c), 30)
			local prefix = string.format(" %s [%d] ", marker, idx)
			local loc_tag = ""
			if pname ~= "" and branch then
				loc_tag =
					string.format("[%s · %s %s]", truncate_cells(pname, 14), branch_glyph, truncate_cells(branch, 20))
			elseif branch then
				loc_tag = string.format("[%s %s]", branch_glyph, truncate_cells(branch, 20))
			elseif pname ~= "" and (proj_count > 1 or (ppath ~= "" and ppath ~= "Other" and ppath ~= global_cwd)) then
				loc_tag = string.format("[%s]", truncate_cells(pname, 14))
			end

			local tail_status = string.format("%s · %s", adapter_name, status_str)
			local meta = loc_tag ~= "" and string.format("%s  %s", loc_tag, tail_status) or tail_status
			local nat_w = cell_width(prefix) + cell_width(capped_title) + 2 + cell_width(meta) + 1
			max_natural_w = math.max(max_natural_w, nat_w)
			table.insert(rows_data, {
				prefix = prefix,
				title = capped_title,
				loc_tag = loc_tag,
				tail_status = tail_status,
				meta = meta,
				line_hl = line_hl,
				status_hl = status_hl,
			})
		end

		local target_w = math.min(max_allowed, max_natural_w)
		local inner_w = math.max(16, target_w - 1)
		local result = {}
		local hls = {}
		for idx, r in ipairs(rows_data) do
			local meta_fit = r.meta
			local truncated_meta = false
			if cell_width(meta_fit) > inner_w - 8 then
				meta_fit = truncate_cells(meta_fit, math.max(8, inner_w - 10))
				truncated_meta = true
			end
			local line = format_cols(r.prefix .. r.title, meta_fit, inner_w) .. " "
			table.insert(result, line)
			local row0 = idx - 1
			local prefix_end = math.min(#r.prefix, #line)
			table.insert(hls, { row = row0, col_start = 0, col_end = prefix_end, group = r.line_hl })
			local meta_start = math.max(0, #line - #meta_fit - 1)
			if not truncated_meta and r.loc_tag ~= "" then
				local loc_end = math.min(#line, meta_start + #r.loc_tag)
				table.insert(hls, { row = row0, col_start = meta_start, col_end = loc_end, group = "Directory" })
				table.insert(hls, { row = row0, col_start = loc_end, col_end = #line, group = r.status_hl })
			else
				table.insert(hls, { row = row0, col_start = meta_start, col_end = #line, group = r.status_hl })
			end
		end
		return result, hls, target_w
	end

	local visible_win = nil
	local initial_row = 1
	for idx, c in ipairs(chats) do
		local winid = vim.fn.bufwinid(c.bufnr)
		if winid ~= -1 then
			visible_win = winid
			initial_row = idx
			break
		end
	end

	local lines, init_hls, width = format_chat_lines()
	local height = math.min(math.max(1, #lines), 12)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].undolevels = -1

	local function apply_buf_render(new_lines, new_hls)
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
		vim.bo[buf].modifiable = false
		vim.api.nvim_buf_clear_namespace(buf, dropdown_ns, 0, -1)
		for _, h in ipairs(new_hls) do
			pcall(vim.api.nvim_buf_add_highlight, buf, dropdown_ns, h.group, h.row, h.col_start, h.col_end)
		end
	end
	apply_buf_render(lines, init_hls)

	local win_opts = {
		relative = "editor",
		anchor = "NE",
		style = "minimal",
		border = "rounded",
		title = compute_title(),
		title_pos = "center",
		footer = compute_footer(width, #chats),
		footer_pos = "center",
		width = width,
		height = height,
		zindex = 60,
	}
	if visible_win and vim.api.nvim_win_is_valid(visible_win) then
		local pos = vim.api.nvim_win_get_position(visible_win)
		local w = vim.api.nvim_win_get_width(visible_win)
		local has_wb = (vim.wo[visible_win].winbar ~= "") and 1 or 0
		win_opts.row = pos[1] + has_wb
		win_opts.col = math.max(width + 1, math.min(vim.o.columns - 1, pos[2] + w - 1))
	else
		win_opts.row = (vim.o.showtabline > 0 and #vim.api.nvim_list_tabpages() > 1) and 2 or 1
		win_opts.col = math.max(width + 1, vim.o.columns - 2)
	end

	local float_win = vim.api.nvim_open_win(buf, true, win_opts)
	vim.wo[float_win].cursorline = true
	vim.wo[float_win].wrap = false
	pcall(vim.api.nvim_win_set_cursor, float_win, { math.min(initial_row, #lines), 0 })

	local refresh_timer = vim.uv.new_timer()
	local function stop_refresh_timer()
		if refresh_timer then
			refresh_timer:stop()
			if not refresh_timer:is_closing() then
				refresh_timer:close()
			end
			refresh_timer = nil
		end
	end

	local function close_dropdown()
		stop_refresh_timer()
		if active_float and active_float.win == float_win then
			active_float = nil
		end
		if vim.api.nvim_win_is_valid(float_win) then
			vim.api.nvim_win_close(float_win, true)
		end
	end

	local function refresh_dropdown()
		if not vim.api.nvim_win_is_valid(float_win) or not vim.api.nvim_buf_is_valid(buf) then
			stop_refresh_timer()
			if active_float and active_float.win == float_win then
				active_float = nil
			end
			return
		end
		chats = collect_chats()
		local cursor = vim.api.nvim_win_get_cursor(float_win)
		local updated_lines, updated_hls, new_w = format_chat_lines()
		apply_buf_render(updated_lines, updated_hls)
		local new_h = math.min(math.max(1, #updated_lines), 12)
		pcall(vim.api.nvim_win_set_config, float_win, {
			width = new_w,
			height = new_h,
			title = compute_title(),
			title_pos = "center",
			footer = compute_footer(new_w, #chats),
			footer_pos = "center",
		})
		pcall(vim.api.nvim_win_set_cursor, float_win, { math.min(cursor[1], #updated_lines), 0 })
	end

	active_float = {
		win = float_win,
		buf = buf,
		close = close_dropdown,
		refresh = refresh_dropdown,
	}

	if refresh_timer then
		refresh_timer:start(
			200,
			200,
			vim.schedule_wrap(function()
				spin_idx = spin_idx % #SPINNER_FRAMES + 1
				refresh_dropdown()
			end)
		)
	end

	local function run_quick_action(key)
		close_dropdown()
		if key == "n" then
			ws.new_smart_chat()
		elseif key == "t" then
			M.create_worktree_chat()
		elseif key == "u" then
			M.jump_to_attention()
		elseif key == "w" then
			ws.toggle()
		elseif key == "a" then
			ws.enter(false, { skip_auto_chat = true })
			ws.prompt_add_project()
		elseif key == "h" then
			ws.patch_history_ui()
			pcall(vim.cmd, "CodeCompanionHistory")
		end
	end

	local function select_index(idx)
		if #chats == 0 then
			local act = empty_actions[idx]
			if act then
				run_quick_action(act.key)
			end
			return
		end
		local target = chats[idx]
		close_dropdown()
		if target then
			ws.focus_or_open_chat(target)
			if wt and type(wt.mark_read) == "function" then
				pcall(wt.mark_read, target.bufnr)
			end
			refresh_winbars()
		end
	end

	local function delete_selected()
		if #chats == 0 or not vim.api.nvim_win_is_valid(float_win) then
			return
		end
		local idx = vim.api.nvim_win_get_cursor(float_win)[1]
		local target = chats[idx]
		if not target then
			return
		end
		local is_running = (wt and type(wt.has_active_request) == "function" and wt.has_active_request(target.bufnr))
			or false
		if not is_running and wt and type(wt.get_chat_status) == "function" then
			local ok_s, st = pcall(wt.get_chat_status, target.bufnr, false, spin_idx)
			if ok_s and type(st) == "table" and (st.state == "thinking" or st.state == "streaming") then
				is_running = true
			end
		end
		if is_running then
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
		if vim.api.nvim_win_is_valid(float_win) then
			refresh_dropdown()
		end
	end

	local map_opts = { buffer = buf, nowait = true, silent = true }
	vim.keymap.set("n", "q", close_dropdown, map_opts)
	vim.keymap.set("n", "<Esc>", close_dropdown, map_opts)
	vim.keymap.set("n", "<CR>", function()
		local row = vim.api.nvim_win_get_cursor(float_win)[1]
		select_index(row)
	end, map_opts)
	vim.keymap.set("n", "n", function()
		run_quick_action("n")
	end, map_opts)
	vim.keymap.set("n", "t", function()
		run_quick_action("t")
	end, map_opts)
	vim.keymap.set("n", "u", function()
		run_quick_action("u")
	end, map_opts)
	vim.keymap.set("n", "w", function()
		run_quick_action("w")
	end, map_opts)
	vim.keymap.set("n", "a", function()
		run_quick_action("a")
	end, map_opts)
	vim.keymap.set("n", "h", function()
		run_quick_action("h")
	end, map_opts)
	vim.keymap.set("n", "d", delete_selected, map_opts)
	vim.keymap.set("n", "x", delete_selected, map_opts)

	local function handle_mouse_expr()
		local pos = vim.fn.getmousepos()
		local total = #chats > 0 and #chats or #empty_actions
		if pos.winid == float_win and pos.line >= 1 and pos.line <= total then
			local clicked = pos.line
			vim.schedule(function()
				select_index(clicked)
			end)
		else
			vim.schedule(close_dropdown)
		end
		return "<Ignore>"
	end
	local mouse_opts = { buffer = buf, nowait = true, silent = true, expr = true }
	vim.keymap.set("n", "<LeftMouse>", handle_mouse_expr, mouse_opts)
	vim.keymap.set("n", "<2-LeftMouse>", handle_mouse_expr, mouse_opts)
	for i = 1, 9 do
		vim.keymap.set("n", tostring(i), function()
			if i <= #chats then
				select_index(i)
			end
		end, map_opts)
	end
	vim.api.nvim_create_autocmd("BufLeave", {
		buffer = buf,
		once = true,
		callback = close_dropdown,
	})
end

M.pick_open_chat = M.open

---Focus/create a CodeCompanion chat and open the adapter/model picker (`<leader>cs`).
function M.select_adapter_or_model()
	local cc = require("codecompanion")
	local ws = require("cc_workspace")
	local chat = cc.last_chat()
	if not chat or not vim.api.nvim_buf_is_valid(chat.bufnr) then
		chat = ws.new_smart_chat()
	else
		ws.focus_or_open_chat(chat)
	end
	if chat then
		require("codecompanion.interactions.chat.keymaps.change_adapter").callback(chat)
	end
end

---Toggle a named CodeCompanion CLI agent (`omp`, `pi`, etc.).
---@param agent_name string
function M.toggle_cli_agent(agent_name)
	local cc = require("codecompanion")
	local cli = require("codecompanion.interactions.cli")
	local existing = cli.find_by_agent(agent_name)
	if existing then
		if existing.ui:is_visible() then
			existing.ui:hide()
		else
			local visible = cli.get_visible()
			if visible and visible ~= existing then
				visible.ui:hide()
			end
			existing.ui:open()
			existing:focus()
		end
	else
		local visible = cli.get_visible()
		if visible then
			visible.ui:hide()
		end
		cc.cli({ agent = agent_name })
	end
end

return M
