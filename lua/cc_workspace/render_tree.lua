-- `PROJECTS` tree builder, Git Worktree sub-tree grouping, conversation child rows,
-- UTF-8-safe byte-indexed highlight emitters, and dynamic footer legend rendering.

local icons = require("cc_workspace.icons")
local projects = require("cc_workspace.projects")
local state_mod = require("cc_workspace.state")

local state = state_mod.state
local format_columns = state_mod.format_columns
local truncate_display = state_mod.truncate_display
local matches_filter = state_mod.matches_filter

local M = {}

local function on_wt_async_update(_list, changed, ui_changed)
	if ui_changed == false or (ui_changed == nil and changed == false) then
		return
	end
	if state_mod.is_workspace_valid() and state_mod.is_current_tab() and state.actions.schedule_render then
		state.actions.schedule_render()
	end
end

---Resolve title highlight group for a chat row based on agent lifecycle state.
---@param st_state string
---@param is_cur boolean
---@return string
function M.resolve_chat_title_hl(st_state, is_cur)
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

local function make_wt_group_node(np, branch, head, is_main, dirty, locked, prunable)
	return {
		norm_path = np,
		branch = branch or "",
		head = head or "",
		is_main = is_main == true,
		dirty = dirty == true,
		locked = locked == true,
		prunable = prunable == true,
		active_items = {},
		history_items = {},
		shown_active = {},
		shown_history = {},
	}
end

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
				table.insert(
					proj_worktrees,
					make_wt_group_node(
						np,
						w.branch,
						w.head,
						w.is_main == true or np == proj.path,
						w.dirty,
						w.locked,
						w.prunable
					)
				)
			end
		end
		for _, aitem in ipairs(proj.active_items) do
			local wp = aitem.wt_root or aitem.chat_cwd
			if wp and not seen_wt[wp] and vim.fn.isdirectory(wp) == 1 then
				local ar = type(wt.get_repo_root) == "function" and wt.get_repo_root(wp) or nil
				if ar and projects.normalize_project_path(ar) == proj.path then
					seen_wt[wp] = true
					local br = (type(wt.get_worktree_branch) == "function" and wt.get_worktree_branch(wp))
						or projects.project_basename(wp)
					table.insert(proj_worktrees, make_wt_group_node(wp, br, "", wp == proj.path, false, false, false))
				end
			end
		end
	end
	proj.worktrees = proj_worktrees
	proj.repo_root = proj_repo_root and projects.normalize_project_path(proj_repo_root) or nil
	return proj_worktrees
end

local function bucket_project_items_into_worktrees(proj, proj_worktrees)
	if #proj_worktrees < 2 then
		return
	end
	local function find_wt_bucket(raw_cwd)
		local ncwd = projects.normalize_project_path(raw_cwd)
		if ncwd then
			local best = nil
			for _, w in ipairs(proj_worktrees) do
				if
					(ncwd == w.norm_path or ncwd:sub(1, #w.norm_path + 1) == w.norm_path .. "/")
					and (not best or #w.norm_path > #best.norm_path)
				then
					best = w
				end
			end
			if best then
				return best
			end
		end
		return proj_worktrees[1]
	end
	for _, aitem in ipairs(proj.active_items) do
		table.insert(find_wt_bucket(aitem.wt_root or aitem.chat_cwd).active_items, aitem)
	end
	for _, hitem in ipairs(proj.history_items) do
		table.insert(find_wt_bucket(hitem.cwd).history_items, hitem)
	end
end

local function filter_chat_item_lists(active_items, history_items, filter_lc)
	local act_matched, hist_matched = {}, {}
	for _, a in ipairs(active_items) do
		if matches_filter(filter_lc, a.title, a.adapter_name, a.wt_branch) then
			table.insert(act_matched, a)
		end
	end
	for _, h in ipairs(history_items) do
		if matches_filter(filter_lc, h.title or h.save_id or "Untitled", h.adapter, h.model) then
			table.insert(hist_matched, h)
		end
	end
	return act_matched, hist_matched
end

local function filter_project_for_sidebar(proj, proj_worktrees, filter_lc)
	if filter_lc == "" then
		proj.shown_active, proj.shown_history = proj.active_items, proj.history_items
		if #proj_worktrees >= 2 then
			for _, w in ipairs(proj_worktrees) do
				w.shown_active, w.shown_history = w.active_items, w.history_items
			end
			proj.shown_worktrees = proj_worktrees
		end
		return true
	end

	local proj_matched = matches_filter(filter_lc, proj.display_name, proj.base_name, proj.path)
	if #proj_worktrees >= 2 then
		local wt_shown, any_child_match = {}, false
		for _, w in ipairs(proj_worktrees) do
			local wt_matched = matches_filter(filter_lc, w.branch, w.norm_path)
			local w_act, w_hist = filter_chat_item_lists(w.active_items, w.history_items, filter_lc)
			if wt_matched or #w_act > 0 or #w_hist > 0 then
				any_child_match = true
				local keep_all = wt_matched and #w_act == 0 and #w_hist == 0
				w.shown_active = keep_all and w.active_items or w_act
				w.shown_history = keep_all and w.history_items or w_hist
				table.insert(wt_shown, w)
			end
		end
		if any_child_match then
			proj.shown_worktrees = wt_shown
			return true
		elseif proj_matched then
			for _, w in ipairs(proj_worktrees) do
				w.shown_active, w.shown_history = w.active_items, w.history_items
			end
			proj.shown_worktrees = proj_worktrees
			return true
		end
		return false
	end

	if #proj_worktrees == 1 and proj_worktrees[1].branch and matches_filter(filter_lc, proj_worktrees[1].branch) then
		proj_matched = true
	end
	local act_matched, hist_matched = filter_chat_item_lists(proj.active_items, proj.history_items, filter_lc)
	if proj_matched then
		local none = #act_matched == 0 and #hist_matched == 0
		proj.shown_active = none and proj.active_items or act_matched
		proj.shown_history = none and proj.history_items or hist_matched
		return true
	elseif #act_matched > 0 or #hist_matched > 0 then
		proj.shown_active, proj.shown_history = act_matched, hist_matched
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
function M.prepare_visible_projects(all_projects, current_cwd, current_cwd_proj, filter_lc, wt)
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
		elseif a.pinned ~= b.pinned then
			return a.pinned
		end
		return (a.display_name or "") < (b.display_name or "")
	end)
	return visible_projects
end

---Render active and saved conversation child rows beneath a Project or Worktree group.
---@param buf table
---@param opts { main_buf: integer, filter_lc: string, indent: string, active: table[], history: table[], expand_map: table<string, boolean>, scope_key: string, ctx: table }
function M.render_chat_children(buf, opts)
	local shown_active, shown_history = opts.active, opts.history
	if #shown_active + #shown_history == 0 then
		return
	end
	local content_width = buf.content_width
	local indent_str = opts.indent
	local max_hist = state_mod.get_max_history_per_project()

	for _, aitem in ipairs(shown_active) do
		local c = aitem.chat
		local is_cur = (c.bufnr == opts.main_buf)
		local st = state_mod.get_chat_status_info(c.bufnr, is_cur)
		local badge = st.state == "idle" and (is_cur and "Active" or "now") or st.badge
		local badge_hl = st.state == "idle" and (is_cur and "CcWsActive" or "CcWsMuted") or st.badge_hl
		local title_hl = M.resolve_chat_title_hl(st.state, is_cur)

		local text = format_columns(string.format("%s%s %s", indent_str, st.icon, aitem.title), badge, content_width)
		local action = vim.tbl_extend("force", opts.ctx, { kind = "active_chat", chat = c, title = aitem.title })
		local row = buf.add_line(text, nil, action)
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

	local show_all = (opts.filter_lc ~= "") or (opts.expand_map[opts.scope_key] == true)
	local limit = show_all and #shown_history or math.min(#shown_history, max_hist)
	for i = 1, limit do
		local item = shown_history[i]
		local age = state_mod.format_age(item.updated_at)
		local raw_title = item.title or item.save_id or "Untitled"
		local text = format_columns(indent_str .. raw_title, age, content_width)
		local action =
			vim.tbl_extend("force", opts.ctx, { kind = "history_chat", save_id = item.save_id, title = raw_title })
		local row = buf.add_line(text, nil, action)
		local age_start = #text - #age
		buf.add_hl(row, 0, age_start, "CcWsIdle")
		if age ~= "" then
			buf.add_hl(row, age_start, #text, "CcWsMuted")
		end
	end

	if #shown_history > max_hist and opts.filter_lc == "" then
		local more_label = show_all and (indent_str .. "▴ Show less")
			or string.format("%s… See all (%d)", indent_str, #shown_history)
		local action = vim.tbl_extend("force", opts.ctx, { kind = opts.ctx.toggle_kind, path = opts.scope_key })
		buf.add_line(truncate_display(more_label, content_width), "CcWsMuted", action)
	end
end

local function compute_single_worktree_tag(wt1, base_left, proj_right, cur_tag, missing_tag, content_width)
	local right_w = vim.fn.strdisplaywidth(proj_right)
	local suffix_w = vim.fn.strdisplaywidth(cur_tag .. missing_tag)
	local left_budget = math.max(4, content_width - right_w - 2)
	local wt1_avail = left_budget - vim.fn.strdisplaywidth(base_left) - suffix_w
	local wt1_dirty = wt1.dirty and "*" or ""
	local dirty_w = vim.fn.strdisplaywidth(wt1_dirty)
	if wt1_avail >= 5 + dirty_w then
		local br1 = (wt1.branch and wt1.branch ~= "") and wt1.branch or (wt1.head ~= "" and wt1.head or "HEAD")
		return string.format(
			" %s %s%s",
			icons.git.Branch,
			truncate_display(br1, math.min(12, wt1_avail - 3 - dirty_w)),
			wt1_dirty
		),
			wt1_dirty
	end
	return "", ""
end

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
	local wt_cur = (current_cwd == wt_path or current_cwd:sub(1, #wt_path + 1) == wt_path .. "/") and " •" or ""
	local br_icon = icons.git.Branch

	local wt_base_left, wt_badge, wt_badge_hl, wt_right = "", "", "CcWsMuted", "[+]"
	if is_empty_wt_leaf then
		wt_base_left = string.format("      %s %s", br_icon, wt_branch)
	else
		wt_base_left = string.format("    %s %s %s", wt_collapsed and "▸" or "▾", br_icon, wt_branch)
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

	local wt_line = format_columns(wt_base_left .. wt_dirty .. wt_cur, wt_right, content_width)
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
		M.render_chat_children(buf, {
			main_buf = main_buf,
			filter_lc = filter_lc,
			indent = "      ",
			active = w.shown_active or {},
			history = w.shown_history or {},
			expand_map = state.expanded_all_worktrees,
			scope_key = wt_path,
			ctx = {
				worktree_path = wt_path,
				worktree_row = wt_row,
				repo_root = proj.path,
				project_path = proj.path,
				project_row = proj_row,
				toggle_kind = "toggle_worktree_all",
			},
		})
	end
	return (state.focus_worktree_path and state.focus_worktree_path == wt_path) and wt_row or nil
end

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
		collapsed = explicit_col ~= nil and (explicit_col == true)
			or (multi_wt and total_count == 0 and not is_proj_cur)
	end

	local cur_tag = ((not multi_wt or collapsed) and is_proj_cur) and " •" or ""
	local missing_tag = (proj.path ~= "Other" and vim.fn.isdirectory(proj.path) ~= 1) and " !" or ""

	local base_left, proj_badge, proj_badge_hl, proj_right = "", "", "CcWsMuted", "[+]"
	if is_empty_proj_leaf then
		base_left = string.format("    %s %s", ui_icons.EmptyFolder, proj.display_name)
	else
		base_left = string.format(
			"  %s %s %s",
			collapsed and "▸" or "▾",
			collapsed and ui_icons.Folder or ui_icons.FolderOpen,
			proj.display_name
		)
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

	local proj_line = format_columns(base_left .. wt1_tag .. cur_tag .. missing_tag, proj_right, content_width)
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

	local focus_project_row = (state.focus_project_path and state.focus_project_path == proj.path) and proj_row or nil
	local focus_worktree_row = nil

	if not is_empty_proj_leaf and not collapsed then
		if multi_wt then
			for _, w in ipairs(proj.shown_worktrees or proj_wts) do
				local matched_wt_row = render_worktree_group(buf, main_buf, filter_lc, current_cwd, proj, proj_row, w)
				focus_worktree_row = matched_wt_row or focus_worktree_row
			end
		else
			M.render_chat_children(buf, {
				main_buf = main_buf,
				filter_lc = filter_lc,
				indent = "    ",
				active = proj.shown_active or {},
				history = proj.shown_history or {},
				expand_map = state.expanded_all_projects,
				scope_key = proj.path,
				ctx = {
					repo_root = proj.repo_root,
					project_path = proj.path,
					project_row = proj_row,
					toggle_kind = "toggle_project_all",
				},
			})
		end
	end
	return focus_project_row, focus_worktree_row
end

---Render the `PROJECTS` section header, project groups, and dynamic footer shortcut legend.
---@param buf table
---@param data table
---@param visible_projects table[]
---@param filter_lc string
---@return integer|nil focus_project_row, integer|nil focus_worktree_row
function M.render_projects_section(buf, data, visible_projects, filter_lc)
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

	local focus_project_row, focus_worktree_row = nil, nil
	state.rendered_project_paths, state.rendered_worktree_paths = {}, {}

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
			focus_project_row = p_row or focus_project_row
			focus_worktree_row = wt_row or focus_worktree_row
		end
	end

	buf.add_line(" " .. string.rep("─", content_width - 1), "CcWsMuted")
	local footer = (
		type(state.actions.format_sidebar_footer) == "function" and state.actions.format_sidebar_footer(content_width)
	) or { "  Enter:open  a:proj  w:wt  n:new", "  y/Y:copy  d:del  o:code  q:back" }
	for _, fl in ipairs(footer) do
		buf.add_line(truncate_display(fl, content_width), "CcWsMuted")
	end
	return focus_project_row, focus_worktree_row
end

return M
