local icons = require("cc_workspace.icons")
local projects = require("cc_workspace.projects")
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

---Shared deduplicated callback for asynchronous Git worktree status updates.
---@param _list table[]|nil
---@param changed? boolean
---@param ui_changed? boolean
local function on_wt_async_update(_list, changed, ui_changed)
	if ui_changed == false or (ui_changed == nil and changed == false) then
		return
	end
	if state_mod.is_workspace_valid() and state_mod.is_current_tab() then
		M.schedule_render()
	end
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

---Resolve title highlight group for a chat row based on agent lifecycle state.
---@param st_state string
---@param is_cur boolean
---@return string
local function resolve_chat_title_hl(st_state, is_cur)
	if st_state == "unread" then
		return "CcAgentUnread"
	elseif is_cur then
		return "CcWsActive"
	elseif st_state == "error" then
		return "CcAgentError"
	elseif st_state == "waiting" then
		return "CcAgentWaiting"
	end
	return "CcWsIdle"
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
		local title_hl = resolve_chat_title_hl(st.state, is_cur)

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

---Discover Git worktrees for a repository project (pure-Lua seeded + async background refresh).
---@param proj table
---@param wt table|nil
---@return table[]
local function discover_project_worktrees(proj, wt)
	local proj_worktrees = {}
	local proj_repo_root = (wt and proj.path ~= "Other" and type(wt.get_repo_root) == "function")
			and wt.get_repo_root(proj.path)
		or nil
	if wt and proj_repo_root and projects.normalize_project_path(proj_repo_root) == proj.path then
		local raw_wts = type(wt.list_worktrees) == "function"
				and wt.list_worktrees(proj.path, { on_update = on_wt_async_update })
			or {}
		local seen_wt = {}
		for _, w in ipairs(raw_wts or {}) do
			local np = projects.normalize_project_path(w.path) or w.path
			if np and not seen_wt[np] then
				seen_wt[np] = true
				table.insert(proj_worktrees, {
					norm_path = np,
					branch = w.branch or "",
					head = w.head or "",
					is_main = w.is_main == true or np == proj.path,
					dirty = w.dirty == true,
					locked = w.locked == true,
					prunable = w.prunable == true,
					active_items = {},
					history_items = {},
					shown_active = {},
					shown_history = {},
				})
			end
		end
		-- Ensure any active chat in a newly created worktree is represented immediately
		for _, aitem in ipairs(proj.active_items) do
			local wp = aitem.wt_root or aitem.chat_cwd
			if wp and not seen_wt[wp] and vim.fn.isdirectory(wp) == 1 then
				local ar = type(wt.get_repo_root) == "function" and wt.get_repo_root(wp) or nil
				if ar and projects.normalize_project_path(ar) == proj.path then
					seen_wt[wp] = true
					table.insert(proj_worktrees, {
						norm_path = wp,
						branch = (type(wt.get_worktree_branch) == "function" and wt.get_worktree_branch(wp))
							or projects.project_basename(wp),
						head = "",
						is_main = (wp == proj.path),
						dirty = false,
						locked = false,
						prunable = false,
						active_items = {},
						history_items = {},
						shown_active = {},
						shown_history = {},
					})
				end
			end
		end
	end
	proj.worktrees = proj_worktrees
	proj.repo_root = proj_repo_root and projects.normalize_project_path(proj_repo_root) or nil
	return proj_worktrees
end

---Bucket a project's active and history items into its discovered worktrees when `#proj_worktrees >= 2`.
---@param proj table
---@param proj_worktrees table[]
local function bucket_project_items_into_worktrees(proj, proj_worktrees)
	if #proj_worktrees < 2 then
		return
	end
	local function find_wt_bucket(raw_cwd)
		local ncwd = projects.normalize_project_path(raw_cwd)
		if ncwd then
			local best = nil
			for _, w in ipairs(proj_worktrees) do
				if ncwd == w.norm_path or ncwd:sub(1, #w.norm_path + 1) == w.norm_path .. "/" then
					if not best or #w.norm_path > #best.norm_path then
						best = w
					end
				end
			end
			if best then
				return best
			end
		end
		return proj_worktrees[1]
	end

	for _, aitem in ipairs(proj.active_items) do
		local bucket = find_wt_bucket(aitem.wt_root or aitem.chat_cwd)
		table.insert(bucket.active_items, aitem)
	end
	for _, hitem in ipairs(proj.history_items) do
		local bucket = find_wt_bucket(hitem.cwd)
		table.insert(bucket.history_items, hitem)
	end
end

---Filter active and history chat items by `filter_lc`.
---@param active_items table[]
---@param history_items table[]
---@param filter_lc string
---@return table[] act_matched, table[] hist_matched
local function filter_chat_item_lists(active_items, history_items, filter_lc)
	local act_matched = {}
	for _, a in ipairs(active_items) do
		if matches_filter(filter_lc, a.title, a.adapter_name, a.wt_branch) then
			table.insert(act_matched, a)
		end
	end
	local hist_matched = {}
	for _, h in ipairs(history_items) do
		local h_title = h.title or h.save_id or "Untitled"
		if matches_filter(filter_lc, h_title, h.adapter, h.model) then
			table.insert(hist_matched, h)
		end
	end
	return act_matched, hist_matched
end

---Apply sidebar keyword filter to a project and its worktrees/chats; return whether the project should be shown.
---@param proj table
---@param proj_worktrees table[]
---@param filter_lc string
---@return boolean
local function filter_project_for_sidebar(proj, proj_worktrees, filter_lc)
	if filter_lc == "" then
		proj.shown_active = proj.active_items
		proj.shown_history = proj.history_items
		if #proj_worktrees >= 2 then
			for _, w in ipairs(proj_worktrees) do
				w.shown_active = w.active_items
				w.shown_history = w.history_items
			end
			proj.shown_worktrees = proj_worktrees
		end
		return true
	end

	local proj_matched = matches_filter(filter_lc, proj.display_name, proj.base_name, proj.path)
	if #proj_worktrees >= 2 then
		local wt_shown = {}
		local any_child_match = false
		for _, w in ipairs(proj_worktrees) do
			local wt_matched = matches_filter(filter_lc, w.branch, w.norm_path)
			local w_act, w_hist = filter_chat_item_lists(w.active_items, w.history_items, filter_lc)
			if wt_matched then
				any_child_match = true
				w.shown_active = (#w_act > 0 or #w_hist > 0) and w_act or w.active_items
				w.shown_history = (#w_act > 0 or #w_hist > 0) and w_hist or w.history_items
				table.insert(wt_shown, w)
			elseif #w_act > 0 or #w_hist > 0 then
				any_child_match = true
				w.shown_active = w_act
				w.shown_history = w_hist
				table.insert(wt_shown, w)
			end
		end
		if any_child_match then
			proj.shown_worktrees = wt_shown
			return true
		elseif proj_matched then
			for _, w in ipairs(proj_worktrees) do
				w.shown_active = w.active_items
				w.shown_history = w.history_items
			end
			proj.shown_worktrees = proj_worktrees
			return true
		end
		return false
	end

	local wt1_branch = (#proj_worktrees == 1) and proj_worktrees[1].branch or nil
	if wt1_branch and matches_filter(filter_lc, wt1_branch) then
		proj_matched = true
	end
	local act_matched, hist_matched = filter_chat_item_lists(proj.active_items, proj.history_items, filter_lc)
	if proj_matched then
		if #act_matched == 0 and #hist_matched == 0 then
			proj.shown_active = proj.active_items
			proj.shown_history = proj.history_items
		else
			proj.shown_active = act_matched
			proj.shown_history = hist_matched
		end
		return true
	elseif #act_matched > 0 or #hist_matched > 0 then
		proj.shown_active = act_matched
		proj.shown_history = hist_matched
		return true
	end
	return false
end

---Prepare, filter, and sort visible projects for the `PROJECTS` tree.
---@param all_projects table[]
---@param current_cwd string
---@param current_cwd_proj string
---@param filter_lc string
---@param wt table|nil
---@return table[]
local function prepare_visible_projects(all_projects, current_cwd, current_cwd_proj, filter_lc, wt)
	local visible_projects = {}
	for _, proj in ipairs(all_projects) do
		table.sort(proj.history_items, function(a, b)
			return (a.updated_at or 0) > (b.updated_at or 0)
		end)
		local proj_worktrees = discover_project_worktrees(proj, wt)
		bucket_project_items_into_worktrees(proj, proj_worktrees)
		if filter_project_for_sidebar(proj, proj_worktrees, filter_lc) then
			table.insert(visible_projects, proj)
		end
	end

	table.sort(visible_projects, function(a, b)
		local a_cur = (a.path == current_cwd or a.path == current_cwd_proj)
		local b_cur = (b.path == current_cwd or b.path == current_cwd_proj)
		if a_cur ~= b_cur then
			return a_cur
		end
		local a_score = math.max(a.latest or 0, a.added_at or 0)
		local b_score = math.max(b.latest or 0, b.added_at or 0)
		if a_score ~= b_score then
			return a_score > b_score
		end
		if a.pinned ~= b.pinned then
			return a.pinned
		end
		return (a.display_name or "") < (b.display_name or "")
	end)
	return visible_projects
end

---Render active and saved conversation child rows beneath a Project or Worktree group.
---@param buf table
---@param main_buf integer
---@param filter_lc string
---@param indent_str string
---@param shown_active table[]
---@param shown_history table[]
---@param expand_map table<string, boolean>
---@param scope_key string
---@param parent_ctx table
local function render_chat_children(
	buf,
	main_buf,
	filter_lc,
	indent_str,
	shown_active,
	shown_history,
	expand_map,
	scope_key,
	parent_ctx
)
	if #shown_active + #shown_history == 0 then
		return
	end
	local content_width = buf.content_width
	local max_hist = state_mod.get_max_history_per_project()

	for _, aitem in ipairs(shown_active) do
		local c = aitem.chat
		local is_cur = (c.bufnr == main_buf)
		local st = state_mod.get_chat_status_info(c.bufnr, is_cur)
		local badge = st.state == "idle" and (is_cur and "Active" or "now") or st.badge
		local badge_hl = st.state == "idle" and (is_cur and "CcWsActive" or "CcWsMuted") or st.badge_hl
		local title_hl = resolve_chat_title_hl(st.state, is_cur)

		local left = string.format("%s%s %s", indent_str, st.icon, aitem.title)
		local text = format_columns(left, badge, content_width)
		local row = buf.add_line(
			text,
			nil,
			vim.tbl_extend("force", parent_ctx, {
				kind = "active_chat",
				chat = c,
				title = aitem.title,
			})
		)
		local badge_start = #text - #badge
		local icon_prefix = indent_str .. st.icon .. " "
		if text:sub(1, #icon_prefix) == icon_prefix then
			buf.add_hl(row, 0, #icon_prefix, st.hl)
			if badge_start > #icon_prefix then
				buf.add_hl(row, #icon_prefix, badge_start, title_hl)
			end
		elseif badge_start > 0 then
			buf.add_hl(row, 0, badge_start, st.hl)
		end
		buf.add_hl(row, badge_start, #text, badge_hl)
	end

	local show_all = (filter_lc ~= "") or (expand_map[scope_key] == true)
	local limit = show_all and #shown_history or math.min(#shown_history, max_hist)
	for i = 1, limit do
		local item = shown_history[i]
		local age = state_mod.format_age(item.updated_at)
		local raw_title = item.title or item.save_id or "Untitled"
		local text = format_columns(indent_str .. raw_title, age, content_width)
		local row = buf.add_line(
			text,
			nil,
			vim.tbl_extend("force", parent_ctx, {
				kind = "history_chat",
				save_id = item.save_id,
				title = raw_title,
			})
		)
		local age_start = #text - #age
		buf.add_hl(row, 0, age_start, "CcWsIdle")
		if age ~= "" then
			buf.add_hl(row, age_start, #text, "CcWsMuted")
		end
	end

	if #shown_history > max_hist and filter_lc == "" then
		local more_label = show_all and (indent_str .. "▴ Show less")
			or string.format("%s… See all (%d)", indent_str, #shown_history)
		buf.add_line(
			truncate_display(more_label, content_width),
			"CcWsMuted",
			vim.tbl_extend("force", parent_ctx, {
				kind = parent_ctx.toggle_kind,
				path = scope_key,
			})
		)
	end
end

---Format inline branch + dirty indicator for a single-worktree project header row.
---@param wt1 table
---@param base_left string
---@param proj_right string
---@param cur_tag string
---@param missing_tag string
---@param content_width integer
---@return string wt1_tag, string wt1_dirty
local function compute_single_worktree_tag(wt1, base_left, proj_right, cur_tag, missing_tag, content_width)
	local right_w = vim.fn.strdisplaywidth(proj_right)
	local suffix_w = vim.fn.strdisplaywidth(cur_tag .. missing_tag)
	local left_budget = math.max(4, content_width - right_w - 2)
	local wt1_avail = left_budget - vim.fn.strdisplaywidth(base_left) - suffix_w
	local wt1_dirty = wt1.dirty and "*" or ""
	local dirty_w = vim.fn.strdisplaywidth(wt1_dirty)
	if wt1_avail >= 5 + dirty_w then
		local br1 = (wt1.branch and wt1.branch ~= "") and wt1.branch or (wt1.head ~= "" and wt1.head or "HEAD")
		local br_max = math.min(12, wt1_avail - 3 - dirty_w)
		return string.format(" %s %s%s", icons.git.Branch, truncate_display(br1, br_max), wt1_dirty), wt1_dirty
	end
	return "", ""
end

---Emit highlight spans for a Project header row.
local function emit_project_row_highlights(
	buf,
	proj_row,
	proj_line,
	base_left,
	wt1_tag,
	wt1_dirty,
	proj_right,
	proj_badge,
	proj_badge_hl
)
	local proj_right_col = #proj_line - #proj_right
	local proj_wt_prefix = base_left .. wt1_tag
	if wt1_tag ~= "" and proj_line:sub(1, #proj_wt_prefix) == proj_wt_prefix then
		local br_end = #proj_wt_prefix - #wt1_dirty
		buf.add_hl(proj_row, 0, #base_left, "CcWsProject")
		buf.add_hl(proj_row, #base_left, br_end, "CcWsWorktree")
		if wt1_dirty ~= "" then
			buf.add_hl(proj_row, br_end, br_end + #wt1_dirty, "CcWsDirty")
		end
		if proj_right_col > #proj_wt_prefix then
			buf.add_hl(proj_row, #proj_wt_prefix, proj_right_col, "CcWsProject")
		end
	else
		buf.add_hl(proj_row, 0, proj_right_col, "CcWsProject")
	end
	if proj_badge_hl == "CcWsMuted" then
		buf.add_hl(proj_row, proj_right_col, #proj_line, "CcWsMuted")
	else
		buf.add_hl(proj_row, proj_right_col, proj_right_col + #proj_badge, proj_badge_hl)
		buf.add_hl(proj_row, proj_right_col + #proj_badge, #proj_line, "CcWsMuted")
	end
end

---Render a single Git worktree subgroup row and its child conversations.
---@param buf table
---@param main_buf integer
---@param filter_lc string
---@param current_cwd string
---@param proj table
---@param proj_row integer
---@param w table
---@return integer|nil focus_wt_row
local function render_worktree_group(buf, main_buf, filter_lc, current_cwd, proj, proj_row, w)
	local content_width = buf.content_width
	local wt_path = w.norm_path
	table.insert(state.rendered_worktree_paths, wt_path)
	local wt_total_count = #w.active_items + #w.history_items
	local is_empty_wt_leaf = (wt_total_count == 0)
	local wt_collapsed = not is_empty_wt_leaf and (filter_lc == "") and (state.collapsed_worktrees[wt_path] == true)
	local wt_branch = (w.branch and w.branch ~= "") and w.branch
		or (w.head ~= "" and w.head or projects.project_basename(wt_path))
	local wt_dirty = w.dirty and "*" or ""
	local is_wt_cur = (current_cwd == wt_path or current_cwd:sub(1, #wt_path + 1) == wt_path .. "/")
	local wt_cur = is_wt_cur and " •" or ""
	local br_icon = icons.git.Branch

	local wt_base_left
	local wt_badge = ""
	local wt_badge_hl = "CcWsMuted"
	local wt_right
	if is_empty_wt_leaf then
		wt_base_left = string.format("      %s %s", br_icon, wt_branch)
		wt_right = "[+]"
	else
		local wt_arrow = wt_collapsed and "▸" or "▾"
		wt_base_left = string.format("    %s %s %s", wt_arrow, br_icon, wt_branch)
		local wt_bufnrs = {}
		for _, aitem in ipairs(w.active_items) do
			table.insert(wt_bufnrs, aitem.chat.bufnr)
		end
		local wt_rollup = state_mod.get_rollup_info(wt_bufnrs)
		local wt_count = tostring(filter_lc ~= "" and (#w.shown_active + #w.shown_history) or wt_total_count)
		wt_badge = wt_rollup.badge ~= "" and wt_rollup.badge or wt_count
		wt_badge_hl = wt_rollup.badge ~= "" and wt_rollup.hl or "CcWsMuted"
		wt_right = wt_badge .. " [+]"
	end

	local wt_left = wt_base_left .. wt_dirty .. wt_cur
	local wt_line = format_columns(wt_left, wt_right, content_width)
	local wt_row = buf.add_line(wt_line, nil, {
		kind = "worktree",
		is_empty_leaf = is_empty_wt_leaf,
		collapsed = wt_collapsed,
		plus_col_1idx = (not is_empty_wt_leaf) and (#wt_line - 2) or nil,
		path = wt_path,
		worktree_path = wt_path,
		repo_root = proj.path,
		project_path = proj.path,
		project_row = proj_row,
		branch = wt_branch,
		is_main = w.is_main == true,
		dirty = w.dirty == true,
		active_count = #w.active_items,
		history_count = #w.history_items,
	})

	local wt_right_col = #wt_line - #wt_right
	if wt_line:sub(1, #wt_base_left) == wt_base_left then
		buf.add_hl(wt_row, 0, #wt_base_left, "CcWsWorktree")
		local wt_dirty_prefix = wt_base_left .. wt_dirty
		if wt_dirty ~= "" and wt_line:sub(1, #wt_dirty_prefix) == wt_dirty_prefix then
			buf.add_hl(wt_row, #wt_base_left, #wt_dirty_prefix, "CcWsDirty")
			if wt_right_col > #wt_dirty_prefix then
				buf.add_hl(wt_row, #wt_dirty_prefix, wt_right_col, "CcWsProject")
			end
		elseif wt_right_col > #wt_base_left then
			buf.add_hl(wt_row, #wt_base_left, wt_right_col, "CcWsProject")
		end
	else
		buf.add_hl(wt_row, 0, wt_right_col, "CcWsWorktree")
	end
	if wt_badge_hl == "CcWsMuted" then
		buf.add_hl(wt_row, wt_right_col, #wt_line, "CcWsMuted")
	else
		buf.add_hl(wt_row, wt_right_col, wt_right_col + #wt_badge, wt_badge_hl)
		buf.add_hl(wt_row, wt_right_col + #wt_badge, #wt_line, "CcWsMuted")
	end

	if not is_empty_wt_leaf and not wt_collapsed then
		render_chat_children(
			buf,
			main_buf,
			filter_lc,
			"      ",
			w.shown_active or {},
			w.shown_history or {},
			state.expanded_all_worktrees,
			wt_path,
			{
				worktree_path = wt_path,
				worktree_row = wt_row,
				repo_root = proj.path,
				project_path = proj.path,
				project_row = proj_row,
				toggle_kind = "toggle_worktree_all",
			}
		)
	end

	if state.focus_worktree_path and state.focus_worktree_path == wt_path then
		return wt_row
	end
	return nil
end

---Render a single Project group header and its nested worktrees or conversations.
---@param buf table
---@param main_buf integer
---@param filter_lc string
---@param current_cwd string
---@param current_cwd_proj string
---@param ui_icons table
---@param proj table
---@return integer|nil focus_project_row, integer|nil focus_worktree_row
local function render_project_group(buf, main_buf, filter_lc, current_cwd, current_cwd_proj, ui_icons, proj)
	local content_width = buf.content_width
	table.insert(state.rendered_project_paths, proj.path)
	local proj_wts = proj.worktrees or {}
	local multi_wt = #proj_wts >= 2
	local total_count = #proj.active_items + #proj.history_items
	local shown_total = 0
	if multi_wt then
		for _, w in ipairs(proj.shown_worktrees or proj_wts) do
			shown_total = shown_total + #w.shown_active + #w.shown_history
		end
	else
		shown_total = #(proj.shown_active or {}) + #(proj.shown_history or {})
	end

	local proj_bufnrs = {}
	for _, aitem in ipairs(proj.active_items) do
		table.insert(proj_bufnrs, aitem.chat.bufnr)
	end
	local proj_rollup = state_mod.get_rollup_info(proj_bufnrs)

	local is_proj_cur = (proj.path == current_cwd or proj.path == current_cwd_proj)
	local is_empty_proj_leaf = (not multi_wt) and (total_count == 0)
	local collapsed = false
	if not is_empty_proj_leaf and filter_lc == "" then
		local explicit_col = state.collapsed_projects[proj.path]
		if explicit_col ~= nil then
			collapsed = (explicit_col == true)
		else
			collapsed = (multi_wt and total_count == 0 and not is_proj_cur)
		end
	end

	local cur_tag = ((not multi_wt or collapsed) and is_proj_cur) and " •" or ""
	local missing_tag = (proj.path ~= "Other" and vim.fn.isdirectory(proj.path) ~= 1) and " !" or ""

	local base_left
	local proj_badge = ""
	local proj_badge_hl = "CcWsMuted"
	local proj_right
	if is_empty_proj_leaf then
		base_left = string.format("    %s %s", ui_icons.EmptyFolder, proj.display_name)
		proj_right = "[+]"
	else
		local arrow = collapsed and "▸" or "▾"
		local folder_icon = collapsed and ui_icons.Folder or ui_icons.FolderOpen
		base_left = string.format("  %s %s %s", arrow, folder_icon, proj.display_name)
		local count_str = tostring(filter_lc ~= "" and shown_total or total_count)
		proj_badge = proj_rollup.badge ~= "" and proj_rollup.badge or count_str
		proj_badge_hl = proj_rollup.badge ~= "" and proj_rollup.hl or "CcWsMuted"
		proj_right = proj_badge .. " [+]"
	end

	local wt1_tag, wt1_dirty = "", ""
	if #proj_wts == 1 then
		wt1_tag, wt1_dirty =
			compute_single_worktree_tag(proj_wts[1], base_left, proj_right, cur_tag, missing_tag, content_width)
	end

	local proj_left = base_left .. wt1_tag .. cur_tag .. missing_tag
	local proj_line = format_columns(proj_left, proj_right, content_width)
	local proj_row = buf.add_line(proj_line, nil, {
		kind = "project",
		is_empty_leaf = is_empty_proj_leaf,
		collapsed = collapsed,
		plus_col_1idx = (not is_empty_proj_leaf and proj.path ~= "Other") and (#proj_line - 2) or nil,
		path = proj.path,
		repo_root = proj.repo_root,
		name = proj.display_name,
		custom_name = proj.custom_name,
		pinned = proj.pinned,
		history_count = #proj.history_items,
		active_count = #proj.active_items,
		worktree_count = #proj_wts,
	})
	emit_project_row_highlights(
		buf,
		proj_row,
		proj_line,
		base_left,
		wt1_tag,
		wt1_dirty,
		proj_right,
		proj_badge,
		proj_badge_hl
	)

	local focus_project_row = (state.focus_project_path and state.focus_project_path == proj.path) and proj_row or nil
	local focus_worktree_row = nil

	if not is_empty_proj_leaf and not collapsed then
		if multi_wt then
			for _, w in ipairs(proj.shown_worktrees or proj_wts) do
				local matched_wt_row = render_worktree_group(buf, main_buf, filter_lc, current_cwd, proj, proj_row, w)
				if matched_wt_row then
					focus_worktree_row = matched_wt_row
				end
			end
		else
			render_chat_children(
				buf,
				main_buf,
				filter_lc,
				"    ",
				proj.shown_active or {},
				proj.shown_history or {},
				state.expanded_all_projects,
				proj.path,
				{
					repo_root = proj.repo_root,
					project_path = proj.path,
					project_row = proj_row,
					toggle_kind = "toggle_project_all",
				}
			)
		end
	end

	return focus_project_row, focus_worktree_row
end

---Render the `PROJECTS` section header, project groups, and footer shortcut legend.
---@param buf table
---@param data table
---@param visible_projects table[]
---@param filter_lc string
---@return integer|nil focus_project_row, integer|nil focus_worktree_row
local function render_projects_section(buf, data, visible_projects, filter_lc)
	local content_width = buf.content_width
	local ui_icons = icons.get("ui", false)

	buf.add_line("", nil)
	local proj_hdr_right = "[+a] [+w] [s]"
	local proj_hdr_line = format_columns(" PROJECTS", proj_hdr_right, content_width)
	local right_start = #proj_hdr_line - #proj_hdr_right
	local proj_hdr_row = buf.add_line(proj_hdr_line, nil, {
		kind = "projects_header",
		worktree_col_1idx = right_start + 6,
		search_col_1idx = right_start + 11,
	}, true)
	buf.add_hl(proj_hdr_row, 0, right_start, "CcWsSection")
	buf.add_hl(proj_hdr_row, right_start, right_start + 4, "CcWsAction")
	buf.add_hl(proj_hdr_row, right_start + 5, right_start + 9, "CcWsWorktree")
	buf.add_hl(proj_hdr_row, right_start + 10, #proj_hdr_line, "CcWsMuted")

	local focus_project_row = nil
	local focus_worktree_row = nil
	state.rendered_project_paths = {}
	state.rendered_worktree_paths = {}

	if #visible_projects == 0 then
		if filter_lc ~= "" then
			buf.add_line("   (no matching projects)", "CcWsMuted")
		else
			local add_proj_line = format_columns("   + Add a Project…", "[a]", content_width)
			local arow = buf.add_line(add_proj_line, nil, { kind = "add_project" })
			buf.add_hl(arow, 0, #add_proj_line - 3, "CcWsAction")
			buf.add_hl(arow, #add_proj_line - 3, #add_proj_line, "CcWsMuted")
		end
	else
		for _, proj in ipairs(visible_projects) do
			local p_row, wt_row = render_project_group(
				buf,
				data.main_buf,
				filter_lc,
				data.current_cwd,
				data.current_cwd_proj,
				ui_icons,
				proj
			)
			if p_row then
				focus_project_row = p_row
			end
			if wt_row then
				focus_worktree_row = wt_row
			end
		end
	end

	buf.add_line(" " .. string.rep("─", content_width - 1), "CcWsMuted")
	buf.add_line(truncate_display("  Enter:open  a:proj  w:wt  n:new", content_width), "CcWsMuted")
	buf.add_line(truncate_display("  y/Y:copy  d:del  o:code  q:back", content_width), "CcWsMuted")

	return focus_project_row, focus_worktree_row
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
		prepare_visible_projects(data.all_projects, data.current_cwd, data.current_cwd_proj, filter_lc, wt)
	local focus_project_row, focus_worktree_row = render_projects_section(buf, data, visible_projects, filter_lc)

	commit_render_output(buf, new_row, preferred_row, focus_project_row, focus_worktree_row)
	sync_animation_timer(has_running)
end

state.actions.render = M.render
state.actions.schedule_render = M.schedule_render

return M
