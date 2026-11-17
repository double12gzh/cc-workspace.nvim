local config = require("cc_workspace.config")
local icons = require("cc_workspace.icons")
local keymaps = require("cc_workspace.keymaps")
local wb_hl = require("cc_workspace.winbar_highlights")

local SPINNER_FRAMES = wb_hl.SPINNER_FRAMES
local cell_width = wb_hl.cell_width
local truncate_cells = wb_hl.truncate_cells
local format_cols = wb_hl.format_cols

local M = {}

local dropdown_ns = vim.api.nvim_create_namespace("CcWorkspaceSwitcher")
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

---Hot-rebind and refresh the currently open switcher float when `set_keymaps` is called.
function M.refresh_keymaps()
	if active_float and type(active_float.rebind) == "function" then
		active_float.rebind()
		if type(active_float.refresh) == "function" then
			active_float.refresh()
		end
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
	local function add_chat_dirs(cur_chat)
		if not cur_chat then
			return
		end
		table.insert(candidates, ws.get_valid_chat_cwd(cur_chat) or "")
		local proj_path = ws.get_chat_project_path(cur_chat)
		if type(proj_path) == "string" and proj_path ~= "Other" then
			table.insert(candidates, proj_path)
		end
	end
	if ws.is_current_tab() then
		local main_win = ws.get_main_win()
		if main_win and chat_mod and type(chat_mod.buf_get_chat) == "function" then
			add_chat_dirs(chat_mod.buf_get_chat(vim.api.nvim_win_get_buf(main_win)))
		end
	else
		local cur_buf = vim.api.nvim_get_current_buf()
		if vim.bo[cur_buf].filetype == "codecompanion" and chat_mod and type(chat_mod.buf_get_chat) == "function" then
			add_chat_dirs(chat_mod.buf_get_chat(cur_buf))
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

---Extract compact primary key token for switcher footer hints.
---@param spec any
---@return string|nil
local function short_sw_key(spec)
	local k = keymaps.normalize_keys(spec)[1]
	if not k then
		return nil
	end
	local up = k:upper()
	return (up == "<CR>" or up == "<RETURN>") and "CR" or k
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

	local function get_sw_cfg()
		return (config.options and config.options.keymaps and config.options.keymaps.switcher)
			or config.defaults.keymaps.switcher
	end

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

	local function build_empty_actions()
		local sw = get_sw_cfg()
		local out = {}
		for _, item in ipairs({
			{ "n", "new_chat", " + New Conversation", "Function" },
			{ "t", "new_worktree_chat", " " .. branch_glyph .. " New Git Worktree + Agent", "DiagnosticOk" },
			{ "w", "toggle_workspace", " " .. ws_glyph .. " Open AI Workspace", "DiagnosticInfo" },
			{ "a", "add_project", " + Add Project to Workspace", "Special" },
			{ "h", "history", " " .. hist_glyph .. " Browse Saved History", "Directory" },
		}) do
			local k = short_sw_key(sw[item[2]])
			local tag = (k and ("[" .. k .. "]") or "") .. " "
			table.insert(out, { act = item[1], label = format_cols(item[3], tag, 36), hl = item[4] })
		end
		return out
	end

	local chats = collect_chats()
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
		local sw = get_sw_cfg()
		local items = {}
		local function add_hint(spec, label)
			local k = short_sw_key(spec)
			if k then
				table.insert(items, k .. ":" .. label)
			end
		end
		if count <= 0 then
			add_hint(sw.select, "select")
			add_hint(sw.new_worktree_chat, "worktree")
			add_hint(sw.help, "keys")
			add_hint(sw.close, "close")
			return " " .. table.concat(items, " · ") .. " "
		end
		local sel_k = short_sw_key(sw.select)
		local has_1_9 = #keymaps.normalize_keys(sw.select_1_9) == 9
		if sel_k then
			table.insert(items, (has_1_9 and w >= 58 and ("1-9/" .. sel_k) or sel_k) .. ":open")
		end
		add_hint(sw.jump_attention, w >= 58 and "unread" or "att")
		add_hint(sw.new_worktree_chat, w >= 74 and "worktree" or "wt")
		add_hint(sw.new_chat, "new")
		if w >= 46 then
			add_hint(sw.delete_chat, w >= 58 and "close" or "del")
			add_hint(sw.toggle_workspace, "ws")
		end
		if w >= 64 then
			add_hint(sw.help, "keys")
		end
		return " " .. truncate_cells(table.concat(items, " · "), math.max(16, w - 4)) .. " "
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
			local empty_actions = build_empty_actions()
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
		local proj_set, proj_count = {}, 0
		for _, c in ipairs(chats) do
			local _, ppath = ws.get_chat_project_name(c)
			if ppath and not proj_set[ppath] then
				proj_set[ppath] = true
				proj_count = proj_count + 1
			end
		end

		local rows_data, max_natural_w = {}, 48
		for idx, c in ipairs(chats) do
			local visible_cur = vim.fn.bufwinid(c.bufnr) ~= -1
			local any_wins = not visible_cur and vim.fn.win_findbuf(c.bufnr) or nil
			local visible_other = type(any_wins) == "table" and #any_wins > 0
			local adapter_name = (c.adapter and (c.adapter.name or c.adapter.formatted_name)) or "AI"
			local pname, ppath = ws.get_chat_project_name(c)
			local chat_dir = ws.get_valid_chat_cwd(c) or (ppath ~= "" and ppath ~= "Other" and ppath or nil)
			local branch = (wt and type(wt.get_worktree_branch) == "function" and chat_dir)
					and wt.get_worktree_branch(chat_dir)
				or nil
			branch = branch ~= "" and branch or nil

			local ok_s, res = false, nil
			if wt and type(wt.get_chat_status) == "function" then
				ok_s, res = pcall(wt.get_chat_status, c.bufnr, visible_cur, spin_idx)
			end
			local st = (ok_s and type(res) == "table") and res or nil

			local req = req_map[c.bufnr]
			local marker = visible_cur and "◆" or (visible_other and "◐" or "○")
			local status_str = visible_cur and "Active" or (visible_other and "Open" or "Idle")
			local line_hl = visible_cur and "DiagnosticInfo" or (visible_other and "Special" or "Normal")
			local status_hl = visible_cur and "DiagnosticInfo" or "Comment"
			local state_name = st and st.state or "idle"
			if req and req.started_at and state_name ~= "waiting" and state_name ~= "error" then
				state_name = req.phase == "streaming" and "streaming" or "thinking"
			end

			if state_name == "thinking" or state_name == "streaming" then
				local elapsed = (st and type(st.elapsed) == "number" and st.elapsed)
					or (req and req.started_at and math.floor((now - req.started_at) / 1e9))
					or 0
				local is_stream = (state_name == "streaming")
				marker = is_stream and "⚡" or SPINNER_FRAMES[spin_idx]
				status_str = string.format("%s %s%ds", SPINNER_FRAMES[spin_idx], is_stream and "S" or "T", elapsed)
				line_hl = is_stream and "DiagnosticOk" or "DiagnosticWarn"
				status_hl = (st and st.badge_hl) or line_hl
			elseif state_name == "waiting" then
				marker, status_str = warn_glyph, warn_glyph .. " Wait"
				line_hl, status_hl = "DiagnosticError", (st and st.badge_hl) or "DiagnosticError"
			elseif state_name == "error" then
				marker, status_str = "✗", "✗ Err"
				line_hl, status_hl = "DiagnosticError", (st and st.badge_hl) or "DiagnosticError"
			elseif state_name == "unread" then
				marker, status_str = "✓", "✓ Done"
				line_hl, status_hl = (st and st.hl) or "DiagnosticOk", (st and st.badge_hl) or "DiagnosticOk"
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
			max_natural_w =
				math.max(max_natural_w, cell_width(prefix) + cell_width(capped_title) + 2 + cell_width(meta) + 1)
			table.insert(rows_data, { prefix, capped_title, loc_tag, meta, line_hl, status_hl })
		end

		local target_w = math.min(max_allowed, max_natural_w)
		local inner_w = math.max(16, target_w - 1)
		local result, hls = {}, {}
		for idx, r in ipairs(rows_data) do
			local prefix, title, loc_tag, meta_fit, line_hl, status_hl = r[1], r[2], r[3], r[4], r[5], r[6]
			local truncated_meta = false
			if cell_width(meta_fit) > inner_w - 8 then
				meta_fit = truncate_cells(meta_fit, math.max(8, inner_w - 10))
				truncated_meta = true
			end
			local line = format_cols(prefix .. title, meta_fit, inner_w) .. " "
			table.insert(result, line)
			local row0 = idx - 1
			table.insert(hls, { row = row0, col_start = 0, col_end = math.min(#prefix, #line), group = line_hl })
			local meta_start = math.max(0, #line - #meta_fit - 1)
			if not truncated_meta and loc_tag ~= "" then
				local loc_end = math.min(#line, meta_start + #loc_tag)
				table.insert(hls, { row = row0, col_start = meta_start, col_end = loc_end, group = "Directory" })
				table.insert(hls, { row = row0, col_start = loc_end, col_end = #line, group = status_hl })
			else
				table.insert(hls, { row = row0, col_start = meta_start, col_end = #line, group = status_hl })
			end
		end
		return result, hls, target_w
	end

	local visible_win, initial_row = nil, 1
	for idx, c in ipairs(chats) do
		local winid = vim.fn.bufwinid(c.bufnr)
		if winid ~= -1 then
			visible_win, initial_row = winid, idx
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
			pcall(vim.api.nvim_buf_set_extmark, buf, dropdown_ns, h.row, h.col_start, {
				end_col = h.col_end,
				hl_group = h.group,
			})
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
		win_opts.row = pos[1] + ((vim.wo[visible_win].winbar ~= "") and 1 or 0)
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
		pcall(vim.api.nvim_win_set_config, float_win, {
			width = new_w,
			height = math.min(math.max(1, #updated_lines), 12),
			title = compute_title(),
			title_pos = "center",
			footer = compute_footer(new_w, #chats),
			footer_pos = "center",
		})
		pcall(vim.api.nvim_win_set_cursor, float_win, { math.min(cursor[1], #updated_lines), 0 })
	end

	local quick_fns = {
		n = ws.new_smart_chat,
		t = M.create_worktree_chat,
		u = M.jump_to_attention,
		w = ws.toggle,
		a = function()
			ws.enter(false, { skip_auto_chat = true })
			ws.prompt_add_project()
		end,
		h = function()
			ws.patch_history_ui()
			pcall(vim.api.nvim_cmd, { cmd = "CodeCompanionHistory" }, {})
		end,
		["?"] = function()
			keymaps.show_keys({ mode = "float" })
		end,
	}
	local function run_quick_action(act)
		close_dropdown()
		if quick_fns[act] then
			quick_fns[act]()
		end
	end

	local function select_index(idx)
		if #chats == 0 then
			local empty_actions = build_empty_actions()
			if empty_actions[idx] then
				run_quick_action(empty_actions[idx].act)
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
		local target = chats[vim.api.nvim_win_get_cursor(float_win)[1]]
		if not target then
			return
		end
		local is_running = (wt and type(wt.has_active_request) == "function" and wt.has_active_request(target.bufnr))
			or false
		if not is_running and wt and type(wt.get_chat_status) == "function" then
			local ok_s, st = pcall(wt.get_chat_status, target.bufnr, false, spin_idx)
			is_running = (ok_s and type(st) == "table" and (st.state == "thinking" or st.state == "streaming"))
		end
		if
			is_running
			and vim.fn.confirm(
					"Conversation is running. Stop and close '" .. ws.get_chat_title(target) .. "'?",
					"&Yes\n&No",
					2
				)
				~= 1
		then
			return
		end
		ws.close_chat_safely(target, false)
		if vim.api.nvim_win_is_valid(float_win) then
			refresh_dropdown()
		end
	end

	local function bind_switcher_buf()
		local sw = get_sw_cfg()
		local jump_keys = keymaps.normalize_keys(sw.select_1_9)
		local bindings = {
			{ spec = sw.close, desc = "Close floating Agent Switcher", callback = close_dropdown },
			{
				spec = sw.select,
				desc = "Focus selected Agent conversation",
				callback = function()
					select_index(vim.api.nvim_win_get_cursor(float_win)[1])
				end,
			},
			{ spec = sw.delete_chat, desc = "Stop & close selected conversation", callback = delete_selected },
			{
				spec = jump_keys,
				desc = "Direct jump to open Agent 1–9",
				callback = function(lhs)
					local idx = tonumber(lhs)
					for i = 1, (idx and 0 or #jump_keys) do
						if jump_keys[i] == lhs then
							idx = i
							break
						end
					end
					if idx and idx <= #chats then
						select_index(idx)
					end
				end,
			},
		}
		for _, q in ipairs({
			{ "new_chat", "Start new AI conversation", "n" },
			{ "new_worktree_chat", "Create Git Worktree & start Agent", "t" },
			{ "jump_attention", "Jump to unread / attention Agent", "u" },
			{ "toggle_workspace", "Toggle AI Workspace tab", "w" },
			{ "add_project", "Add Project to AI Workspace", "a" },
			{ "history", "Browse saved Chat history", "h" },
			{ "help", "Show shortcuts cheatsheet", "?" },
		}) do
			local code = q[3]
			table.insert(bindings, {
				spec = sw[q[1]],
				desc = q[2],
				callback = function()
					run_quick_action(code)
				end,
			})
		end
		keymaps.bind_buffer_keymaps(buf, bindings)
		local function handle_mouse_expr()
			local pos = vim.fn.getmousepos()
			local total = #chats > 0 and #chats or 5
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
	end

	bind_switcher_buf()
	active_float = {
		win = float_win,
		buf = buf,
		close = close_dropdown,
		refresh = refresh_dropdown,
		rebind = bind_switcher_buf,
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
	vim.api.nvim_create_autocmd("BufLeave", { buffer = buf, once = true, callback = close_dropdown })
end

M.pick_open_chat = M.open

---Focus/create a CodeCompanion chat and open the adapter/model picker (`<leader>cs`).
function M.select_adapter_or_model()
	local cc, ws = require("codecompanion"), require("cc_workspace")
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
	local cc, cli = require("codecompanion"), require("codecompanion.interactions.cli")
	local existing, visible = cli.find_by_agent(agent_name), cli.get_visible()
	if existing and existing.ui:is_visible() then
		existing.ui:hide()
		return
	end
	if visible and visible ~= existing then
		visible.ui:hide()
	end
	if existing then
		existing.ui:open()
		existing:focus()
	else
		cc.cli({ agent = agent_name })
	end
end

return M
