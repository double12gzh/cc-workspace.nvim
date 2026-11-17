-- Coalesced sidebar renderer: top header, `AGENTS` rollup section, diff-checked
-- buffer/extmark writer, spinner timer management, and `render_tree` orchestration.

local icons = require("cc_workspace.icons")
local projects = require("cc_workspace.projects")
local render_tree = require("cc_workspace.render_tree")
local state_mod = require("cc_workspace.state")

local state = state_mod.state
local format_columns = state_mod.format_columns
local truncate_display = state_mod.truncate_display
local matches_filter = state_mod.matches_filter

local M = {}

---Schedule a single coalesced sidebar render on the next event-loop tick.
function M.schedule_render()
	if state.render_scheduled then
		return
	end
	state.render_scheduled = true
	vim.schedule(function()
		state.render_scheduled = false
		if state_mod.is_workspace_valid() and state_mod.is_current_tab() then
			M.render()
		end
	end)
end

---Create an accumulator for sidebar buffer lines, highlight spans, and row action metadata.
---@param content_width integer
---@return table
local function new_render_builder(content_width)
	local buf = {
		content_width = content_width,
		lines = {},
		hls = {},
		actions = {},
		action_rows = {},
	}
	function buf.add_line(text, hl_group, action, skip_tab)
		local row = #buf.lines + 1
		table.insert(buf.lines, text)
		if hl_group then
			table.insert(buf.hls, { row = row - 1, col_start = 0, col_end = #text, group = hl_group })
		end
		if action then
			buf.actions[row] = action
			if not skip_tab then
				table.insert(buf.action_rows, row)
			end
		end
		return row
	end
	function buf.add_hl(row_1idx, col_start, col_end, group)
		table.insert(buf.hls, {
			row = row_1idx - 1,
			col_start = col_start,
			col_end = col_end,
			group = group,
		})
	end
	return buf
end

---Render top sidebar header, `+ New Conversation` button, and active keyword filter bar.
---@param buf table
---@param filter_lc string
---@return integer new_row
local function render_top_chrome(buf, filter_lc)
	local content_width = buf.content_width
	local aichat_icons = icons.get("aichat", true)
	local tabline_visible = vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1)
	if not tabline_visible then
		local header_line = format_columns(string.format(" %sAI Workspace", aichat_icons.Chat), "[?]", content_width)
		local hdr_row = buf.add_line(header_line, nil, { kind = "help" }, true)
		buf.add_hl(hdr_row, 0, #header_line - 3, "CcWsTitle")
		buf.add_hl(hdr_row, #header_line - 3, #header_line, "CcWsMuted")
		buf.add_line(" " .. string.rep("─", content_width - 1), "CcWsMuted")
	end

	local new_right = tabline_visible and "[n] [?]" or "[n]"
	local new_line = format_columns("  + New Conversation", new_right, content_width)
	local new_row = buf.add_line(new_line, nil, {
		kind = "new_chat",
		help_col_1idx = tabline_visible and (#new_line - 2) or nil,
	})
	buf.add_hl(new_row, 0, #new_line - #new_right, "CcWsAction")
	buf.add_hl(new_row, #new_line - #new_right, #new_line, "CcWsMuted")

	if filter_lc ~= "" then
		local fline = format_columns(string.format('  %s "%s"', icons.ui.Search, state.filter), "[F]", content_width)
		local frow = buf.add_line(fline, nil, { kind = "filter" })
		buf.add_hl(frow, 0, #fline - 3, "CcWsFilter")
		buf.add_hl(frow, #fline - 3, #fline, "CcWsMuted")
	end
	buf.add_line("", nil)
	return new_row
end

---Collect active chats, project groups, and saved history items with disambiguated display names.
---@param wt table|nil
---@return table
local function collect_workspace_data(wt)
	local store = projects.load_projects_store()
	local pinned_map = projects.get_pinned_map(store)
	local hidden_map = store.hidden or {}
	local current_cwd = projects.get_global_cwd()
	local current_cwd_proj = current_cwd ~= ""
			and projects.resolve_item_project_path(
				current_cwd,
				projects.detect_safe_project_root(current_cwd),
				pinned_map
			)
		or ""
	if current_cwd_proj == "Other" then
		current_cwd_proj = current_cwd
	end

	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	local all_active = {}
	local active_save_ids = {}
	local main_buf = state.main_win
			and vim.api.nvim_win_is_valid(state.main_win)
			and vim.api.nvim_win_get_buf(state.main_win)
		or -1
	if chat_mod then
		local all = chat_mod.buf_get_chat()
		if type(all) == "table" then
			for _, entry in ipairs(all) do
				if entry.chat and vim.api.nvim_buf_is_valid(entry.chat.bufnr) then
					table.insert(all_active, entry.chat)
					if entry.chat.opts and entry.chat.opts.save_id then
						active_save_ids[entry.chat.opts.save_id] = true
					end
				end
			end
		end
	end
	table.sort(all_active, function(a, b)
		return a.bufnr < b.bufnr
	end)
	state.active_chats = all_active

	local by_project = {}
	local all_projects = {}
	local function ensure_project(proj_path)
		if not by_project[proj_path] then
			local pinned = pinned_map[proj_path]
			by_project[proj_path] = {
				path = proj_path,
				custom_name = pinned and pinned.name or nil,
				pinned = pinned ~= nil,
				added_at = pinned and (pinned.added_at or 0) or 0,
				latest = 0,
				active_items = {},
				history_items = {},
			}
			table.insert(all_projects, by_project[proj_path])
		end
		return by_project[proj_path]
	end

	for _, entry in ipairs(store.projects) do
		ensure_project(entry.path)
	end
	if current_cwd_proj ~= "" and not hidden_map[current_cwd_proj] then
		ensure_project(current_cwd_proj)
	end

	local active_meta = {}
	local active_proj_set = {}
	local active_scope_set = {}
	local all_active_bufnrs = {}
	for idx, c in ipairs(all_active) do
		local title = state_mod.get_chat_title(c)
		local adapter_name = c.adapter and (c.adapter.name or c.adapter.formatted_name) or ""
		local chat_cwd = projects.get_valid_chat_cwd(c)
		local wt_root = (wt and chat_cwd and type(wt.get_worktree_root) == "function")
				and projects.normalize_project_path(wt.get_worktree_root(chat_cwd))
			or chat_cwd
		local wt_branch = (wt and chat_cwd and type(wt.get_worktree_branch) == "function")
				and wt.get_worktree_branch(chat_cwd)
			or nil
		local is_linked_wt = (wt and chat_cwd and type(wt.is_linked_worktree) == "function")
				and wt.is_linked_worktree(chat_cwd)
			or false
		local proj_path = projects.get_chat_project_path(c, pinned_map)
		active_proj_set[proj_path] = true
		active_scope_set[wt_root or proj_path] = true
		table.insert(all_active_bufnrs, c.bufnr)
		local proj = ensure_project(proj_path)
		proj.latest = math.max(proj.latest, os.time())
		local item = {
			idx = idx,
			chat = c,
			title = title,
			adapter_name = adapter_name,
			project_path = proj_path,
			chat_cwd = chat_cwd,
			wt_root = wt_root,
			wt_branch = wt_branch,
			is_linked_wt = is_linked_wt,
		}
		table.insert(active_meta, item)
		table.insert(proj.active_items, item)
	end

	local cc = package.loaded["codecompanion"]
	local history_ext = cc and cc.extensions and cc.extensions.history
	if not history_ext and cc then
		pcall(require, "codecompanion._extensions.history")
		history_ext = cc.extensions and cc.extensions.history
	end

	local t_hist_now = state_mod.now_ms()
	local saved_map = state_mod.get_cached_history_chats(history_ext)
	for save_id, item in pairs(saved_map) do
		if type(item) == "table" and not active_save_ids[save_id] then
			local hkey = tostring(item.cwd or "") .. "\0" .. tostring(item.project_root or "")
			local cached_hp = state.history_proj_cache[hkey]
			local proj_path
			if cached_hp and (t_hist_now - cached_hp.ts) < state_mod.PROJECT_ROOT_TTL_MS then
				proj_path = cached_hp.path
			else
				proj_path = projects.resolve_item_project_path(item.cwd, item.project_root, pinned_map)
				state.history_proj_cache[hkey] = { path = proj_path, ts = t_hist_now }
			end
			local is_unpinned_tmp_ghost = not pinned_map[proj_path]
				and (state_mod.is_ephemeral_tmp_path(item.cwd) or state_mod.is_ephemeral_tmp_path(item.project_root) or state_mod.is_ephemeral_tmp_path(
					proj_path
				))
				and (proj_path == "Other" or vim.fn.isdirectory(proj_path) ~= 1)
			if not is_unpinned_tmp_ghost and (not hidden_map[proj_path] or pinned_map[proj_path]) then
				local proj = ensure_project(proj_path)
				if (item.updated_at or 0) > proj.latest then
					proj.latest = item.updated_at or 0
				end
				table.insert(proj.history_items, item)
			end
		end
	end

	projects.assign_project_display_names(all_projects)

	return {
		current_cwd = current_cwd,
		current_cwd_proj = current_cwd_proj,
		main_buf = main_buf,
		all_active = all_active,
		active_meta = active_meta,
		active_proj_set = active_proj_set,
		active_scope_set = active_scope_set,
		all_active_bufnrs = all_active_bufnrs,
		by_project = by_project,
		all_projects = all_projects,
	}
end

---Render the top `AGENTS` rollup section and active conversation rows.
---@param buf table
---@param data table
---@param filter_lc string
---@param wt table|nil
---@return integer|nil preferred_row, boolean has_running
local function render_agents_section(buf, data, filter_lc, wt)
	local content_width = buf.content_width
	local multi_active_scopes = (vim.tbl_count(data.active_scope_set) > 1) or (vim.tbl_count(data.active_proj_set) > 1)
	local filtered_active = {}
	for _, item in ipairs(data.active_meta) do
		local proj = data.by_project[item.project_path]
		local p_disp = proj and proj.display_name or projects.project_basename(item.project_path)
		item.project_display = p_disp
		if
			matches_filter(
				filter_lc,
				item.title,
				item.adapter_name,
				p_disp,
				item.project_path,
				item.wt_branch,
				item.chat_cwd
			)
		then
			table.insert(filtered_active, item)
		end
	end

	local global_rollup = state_mod.get_rollup_info(data.all_active_bufnrs)
	local act_hdr_right = global_rollup.badge ~= "" and global_rollup.badge:gsub(" ", " · ")
		or tostring(#data.all_active)
	local act_hdr_right_hl = global_rollup.badge ~= "" and global_rollup.hl or "CcWsMuted"
	local act_hdr_line = format_columns(" AGENTS", act_hdr_right, content_width)
	local act_hdr_row = buf.add_line(act_hdr_line, nil)
	buf.add_hl(act_hdr_row, 0, #act_hdr_line - #act_hdr_right, "CcWsSection")
	buf.add_hl(act_hdr_row, #act_hdr_line - #act_hdr_right, #act_hdr_line, act_hdr_right_hl)

	local has_running = global_rollup.running > 0
	if not has_running and wt and type(wt.has_active_request) == "function" then
		for _, c in ipairs(data.all_active) do
			if wt.has_active_request(c.bufnr) then
				has_running = true
				break
			end
		end
	end

	if #filtered_active == 0 then
		buf.add_line(filter_lc ~= "" and "   (no matching agents)" or "   (none)", "CcWsMuted")
		return nil, has_running
	end

	local preferred_row = nil
	for _, item in ipairs(filtered_active) do
		local c = item.chat
		local is_cur = (c.bufnr == data.main_buf)
		local st = state_mod.get_chat_status_info(c.bufnr, is_cur)
		if st.state == "thinking" or st.state == "streaming" then
			has_running = true
		end
		local badge = st.badge ~= "" and st.badge or (is_cur and "Active" or "Idle")
		local badge_hl = st.state == "idle" and (is_cur and "CcWsActive" or "CcWsMuted") or st.badge_hl
		local title_hl = render_tree.resolve_chat_title_hl(st.state, is_cur)

		local proj_prefix = ""
		local show_scope_prefix = multi_active_scopes
			or item.is_linked_wt
			or item.project_path ~= data.current_cwd_proj
			or (item.wt_root and item.wt_root ~= data.current_cwd)
		if show_scope_prefix then
			local repo_max = content_width >= 36 and 9 or 6
			local br_max = content_width >= 36 and 9 or 6
			if item.wt_branch and item.wt_branch ~= "" then
				proj_prefix = string.format(
					"[%s:%s] ",
					truncate_display(item.project_display, repo_max),
					truncate_display(item.wt_branch, br_max)
				)
			else
				proj_prefix = string.format("[%s] ", truncate_display(item.project_display, repo_max + 2))
			end
		end

		local indent_part = "  "
		local icon_part = st.icon .. " "
		local idx_part = tostring(item.idx) .. " "
		local left = indent_part .. icon_part .. idx_part .. proj_prefix .. item.title
		local text = format_columns(left, badge, content_width)
		local row = buf.add_line(text, nil, {
			kind = "active_chat",
			chat = c,
			title = item.title,
			project_path = item.project_path,
			worktree_path = item.wt_root,
			repo_root = (wt and item.chat_cwd and type(wt.get_repo_root) == "function") and wt.get_repo_root(
				item.chat_cwd
			) or nil,
		})
		if is_cur then
			preferred_row = row
		end

		local badge_start = #text - #badge
		local p_icon = indent_part .. icon_part
		local p_idx = p_icon .. idx_part
		local idx_hl = is_cur and "CcWsActive" or "CcWsMuted"
		if text:sub(1, #p_icon) ~= p_icon then
			buf.add_hl(row, 0, badge_start, st.hl)
		else
			buf.add_hl(row, 0, #p_icon, st.hl)
			if text:sub(1, #p_idx) ~= p_idx then
				if badge_start > #p_icon then
					buf.add_hl(row, #p_icon, badge_start, idx_hl)
				end
			else
				buf.add_hl(row, #p_icon, #p_idx, idx_hl)
				if proj_prefix ~= "" then
					local p_scope = p_idx .. proj_prefix
					if text:sub(1, #p_scope) == p_scope then
						buf.add_hl(row, #p_idx, #p_scope, "CcWsWorktree")
						if badge_start > #p_scope then
							buf.add_hl(row, #p_scope, badge_start, title_hl)
						end
					elseif badge_start > #p_idx then
						buf.add_hl(row, #p_idx, badge_start, "CcWsWorktree")
					end
				elseif badge_start > #p_idx then
					buf.add_hl(row, #p_idx, badge_start, title_hl)
				end
			end
		end
		buf.add_hl(row, badge_start, #text, badge_hl)
	end
	return preferred_row, has_running
end

---Apply diff-checked lines/highlights to `state.sidebar_buf` and synchronize cursor position.
---@param buf table
---@param new_row integer
---@param preferred_row integer|nil
---@param focus_project_row integer|nil
---@param focus_worktree_row integer|nil
local function commit_render_output(buf, new_row, preferred_row, focus_project_row, focus_worktree_row)
	local lines = buf.lines
	local hls = buf.hls
	state.row_actions = buf.actions
	state.action_rows = buf.action_rows
	state.last_render_ms = state_mod.now_ms()

	local cursor = (state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win))
			and vim.api.nvim_win_get_cursor(state.sidebar_win)
		or { new_row, 0 }
	local cur_tick = vim.api.nvim_buf_get_changedtick(state.sidebar_buf)
	local same_buf = (state.last_rendered_buf == state.sidebar_buf) and (state.last_rendered_tick == cur_tick)
	local lines_unchanged = same_buf and state_mod.string_lists_equal(state.last_rendered_lines, lines)
	if not lines_unchanged then
		vim.bo[state.sidebar_buf].modifiable = true
		vim.api.nvim_buf_set_lines(state.sidebar_buf, 0, -1, false, lines)
		vim.bo[state.sidebar_buf].modifiable = false
		state.last_rendered_buf = state.sidebar_buf
		state.last_rendered_tick = vim.api.nvim_buf_get_changedtick(state.sidebar_buf)
		state.last_rendered_lines = lines
	end

	local hls_unchanged = lines_unchanged and state_mod.hl_lists_equal(state.last_rendered_hls, hls)
	if not hls_unchanged then
		vim.api.nvim_buf_clear_namespace(state.sidebar_buf, state.ns, 0, -1)
		for _, h in ipairs(hls) do
			pcall(vim.api.nvim_buf_set_extmark, state.sidebar_buf, state.ns, h.row, h.col_start, {
				end_col = h.col_end,
				hl_group = h.group,
			})
		end
		state.last_rendered_hls = hls
	end

	if focus_worktree_row then
		state.focus_worktree_path = nil
	end
	if focus_project_row then
		state.focus_project_path = nil
	end
	if state.sidebar_win and vim.api.nvim_win_is_valid(state.sidebar_win) then
		local target_row = cursor[1]
		if focus_worktree_row then
			state.needs_focus_sync = false
			target_row = focus_worktree_row
		elseif focus_project_row then
			state.needs_focus_sync = false
			target_row = focus_project_row
		elseif state.needs_focus_sync then
			state.needs_focus_sync = false
			target_row = preferred_row or new_row
		end
		local clamped_row = math.min(math.max(1, target_row), #lines)
		if cursor[1] ~= clamped_row or cursor[2] ~= 0 then
			pcall(vim.api.nvim_win_set_cursor, state.sidebar_win, { clamped_row, 0 })
		end
	end
end

---Advance spinner animation frame and re-render while workspace is active.
local function on_animation_tick()
	if not state_mod.is_workspace_valid() or not state_mod.is_current_tab() then
		state_mod.stop_timer()
		return
	end
	state.anim_idx = (state.anim_idx or 1) % #state_mod.animate_chars + 1
	M.render()
end

---Start or stop the 250ms spinner timer depending on whether agents are running in the active workspace tab.
---@param has_running boolean
local function sync_animation_timer(has_running)
	if has_running and state_mod.is_current_tab() then
		if not state.timer then
			state.timer = vim.uv.new_timer()
			if state.timer then
				state.timer:start(250, 250, vim.schedule_wrap(on_animation_tick))
			end
		end
	else
		state_mod.stop_timer()
	end
end

---Build and render sidebar buffer contents and highlights.
function M.render()
	if not state.sidebar_buf or not vim.api.nvim_buf_is_valid(state.sidebar_buf) then
		return
	end

	local content_width = state_mod.get_sidebar_width() - 1
	local filter_lc = (state.filter or ""):lower()
	local wt = state_mod.get_wt()

	local buf = new_render_builder(content_width)
	local new_row = render_top_chrome(buf, filter_lc)
	local data = collect_workspace_data(wt)
	local preferred_row, has_running = render_agents_section(buf, data, filter_lc, wt)
	local visible_projects =
		render_tree.prepare_visible_projects(data.all_projects, data.current_cwd, data.current_cwd_proj, filter_lc, wt)
	local focus_project_row, focus_worktree_row =
		render_tree.render_projects_section(buf, data, visible_projects, filter_lc)

	commit_render_output(buf, new_row, preferred_row, focus_project_row, focus_worktree_row)
	sync_animation_timer(has_running)
end

state.actions.render = M.render
state.actions.schedule_render = M.schedule_render

return M
