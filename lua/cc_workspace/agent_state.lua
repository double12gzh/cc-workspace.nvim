-- Orca/Herdr agent lifecycle state machine (`thinking`/`streaming`/`waiting`/`error`/`unread`/`idle`),
-- spinner timer, status rollups, attention jumper, background toast notifications, and listeners.

local config = require("cc_workspace.config")
local git = require("cc_workspace.git")
local icons = require("cc_workspace.icons")

local M = {}

M.SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local VALID_STATES = { thinking = true, streaming = true, waiting = true, error = true, unread = true, idle = true }
local ATTENTION_PRIORITY = { waiting = 1, error = 2, unread = 3, streaming = 4, thinking = 4 }

---@class CcActiveRequest
---@field bufnr integer|nil
---@field interaction string
---@field adapter string
---@field phase "thinking"|"streaming"
---@field started_at number
---@field elapsed integer

---@class CcAgentChatStatus
---@field state "thinking"|"streaming"|"waiting"|"error"|"unread"|"idle"
---@field phase "thinking"|"streaming"|"waiting"|"error"|"unread"|"idle"
---@field icon string
---@field badge string
---@field short string
---@field hl string
---@field badge_hl string
---@field started_at number|nil
---@field elapsed integer

---@class CcAgentRollup
---@field thinking integer
---@field streaming integer
---@field running integer
---@field waiting integer
---@field unread integer
---@field error integer
---@field idle integer
---@field total integer
---@field badge string

local ag_state = {
	setup_done = false,
	notifications = true,
	last_bg_bufnr = nil, ---@type integer|nil
	anim_idx = 1,
	spinner_timer = nil, ---@type uv.uv_timer_t|nil
	ui_refresh_scheduled = false,
	pending_listener_events = {}, ---@type { bufnr: integer, state_name: string }[]
	chats = {}, ---@type table<integer, table>
	other_requests = {}, ---@type table<string, table>
	tools_running = {}, ---@type table<integer, boolean>
	listeners = {}, ---@type fun(bufnr: integer, state_name: string)[]
}

---Define Orca/Herdr agent lifecycle highlight groups (refreshed on `ColorScheme`).
function M.setup_highlights()
	vim.api.nvim_set_hl(0, "CcAgentThinking", { link = "DiagnosticWarn", default = true })
	vim.api.nvim_set_hl(0, "CcAgentStreaming", { link = "DiagnosticOk", default = true })
	vim.api.nvim_set_hl(0, "CcAgentWaiting", { link = "DiagnosticError", default = true })
	vim.api.nvim_set_hl(0, "CcAgentError", { link = "DiagnosticError", default = true })
	vim.api.nvim_set_hl(0, "CcAgentActive", { link = "DiagnosticInfo", default = true })
	vim.api.nvim_set_hl(0, "CcAgentIdle", { link = "Comment", default = true })
	local ok_ok, diag_ok = pcall(vim.api.nvim_get_hl, 0, { name = "DiagnosticOk", link = false })
	local unread_fg = (ok_ok and type(diag_ok) == "table" and diag_ok.fg) and string.format("#%06x", diag_ok.fg)
		or (vim.o.background == "light" and "#2e7d32" or "#89b482")
	vim.api.nvim_set_hl(0, "CcAgentUnread", { fg = unread_fg, bold = true })
end

---@param cb fun(bufnr: integer, state_name: string)
---@return fun() unsubscribe
function M.on_change(cb)
	if type(cb) ~= "function" then
		return function() end
	end
	table.insert(ag_state.listeners, cb)
	return function()
		for i = #ag_state.listeners, 1, -1 do
			if ag_state.listeners[i] == cb then
				return table.remove(ag_state.listeners, i)
			end
		end
	end
end

---@return integer
function M.get_anim_idx()
	return ag_state.anim_idx
end

---@return integer|nil
function M.get_last_background_bufnr()
	if ag_state.last_bg_bufnr and vim.api.nvim_buf_is_valid(ag_state.last_bg_bufnr) then
		return ag_state.last_bg_bufnr
	end
	ag_state.last_bg_bufnr = nil
	return nil
end

function M.clear_last_background_bufnr()
	ag_state.last_bg_bufnr = nil
end

local function count_running_requests()
	local n = 0
	for bufnr, entry in pairs(ag_state.chats) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			if entry.state == "thinking" or entry.state == "streaming" then
				n = n + 1
			end
		else
			ag_state.chats[bufnr], ag_state.tools_running[bufnr] = nil, nil
		end
	end
	for key, req in pairs(ag_state.other_requests) do
		if req.bufnr and not vim.api.nvim_buf_is_valid(req.bufnr) then
			ag_state.other_requests[key] = nil
		else
			n = n + 1
		end
	end
	return n
end

local function stop_spinner_timer()
	if ag_state.spinner_timer then
		ag_state.spinner_timer:stop()
		if not ag_state.spinner_timer:is_closing() then
			ag_state.spinner_timer:close()
		end
		ag_state.spinner_timer = nil
	end
end

local function on_spinner_tick()
	if count_running_requests() <= 0 then
		return stop_spinner_timer()
	end
	ag_state.anim_idx = (ag_state.anim_idx % #M.SPINNER_FRAMES) + 1
	pcall(function()
		require("cc_workspace.winbar").refresh()
	end)
	pcall(vim.cmd.redrawstatus)
end

local function ensure_spinner_timer()
	if not ag_state.spinner_timer then
		local timer = vim.uv.new_timer()
		if timer then
			ag_state.spinner_timer = timer
			timer:start(140, 140, vim.schedule_wrap(on_spinner_tick))
		end
	end
end

local function notify_ui_changed(bufnr, state_name)
	table.insert(ag_state.pending_listener_events, { bufnr = bufnr, state_name = state_name })
	if ag_state.ui_refresh_scheduled then
		return
	end
	ag_state.ui_refresh_scheduled = true
	vim.schedule(function()
		ag_state.ui_refresh_scheduled = false
		local events = ag_state.pending_listener_events
		ag_state.pending_listener_events = {}
		pcall(function()
			require("cc_workspace.winbar").refresh()
		end)
		local ws = package.loaded["cc_workspace"]
		if type(ws) == "table" and type(ws.is_current_tab) == "function" and ws.is_current_tab() then
			local fn = ws.schedule_render or ws.render
			if type(fn) == "function" then
				pcall(fn)
			end
		end
		pcall(vim.cmd.redrawstatus)
		for _, ev in ipairs(events) do
			for _, fn in ipairs(ag_state.listeners) do
				pcall(fn, ev.bufnr, ev.state_name)
			end
		end
	end)
end

local function extract_adapter_name(raw_adapter)
	if type(raw_adapter) == "table" then
		local name = raw_adapter.name or raw_adapter.formatted_name
		return (type(name) == "string" and name ~= "") and name or nil
	end
	return (type(raw_adapter) == "string" and raw_adapter ~= "") and raw_adapter or nil
end

---Return all currently active (`thinking` or `streaming`) requests sorted by `bufnr`.
---@return CcActiveRequest[]
function M.get_active_requests()
	local now_hr = vim.uv.hrtime()
	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	local list = {}
	local function push_req(bnr, inter, adp, ph, sa)
		local item = { bufnr = bnr, interaction = inter, adapter = adp or "AI", phase = ph, started_at = sa }
		item.elapsed = math.max(0, math.floor((now_hr - sa) / 1e9))
		table.insert(list, item)
	end

	for bufnr, entry in pairs(ag_state.chats) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			if entry.state == "thinking" or entry.state == "streaming" then
				local adp = entry.adapter
				if (not adp or adp == "") and chat_mod and type(chat_mod.buf_get_chat) == "function" then
					local c = chat_mod.buf_get_chat(bufnr)
					adp = c and extract_adapter_name(c.adapter) or nil
				end
				push_req(bufnr, "chat", adp, entry.state, entry.started_at or now_hr)
			end
		else
			ag_state.chats[bufnr], ag_state.tools_running[bufnr] = nil, nil
		end
	end

	for key, req in pairs(ag_state.other_requests) do
		if req.bufnr and not vim.api.nvim_buf_is_valid(req.bufnr) then
			ag_state.other_requests[key] = nil
		else
			local ph = req.phase == "streaming" and "streaming" or "thinking"
			push_req(req.bufnr, req.interaction or "other", req.adapter, ph, req.started_at or now_hr)
		end
	end

	table.sort(list, function(a, b)
		local ab, bb = a.bufnr or math.huge, b.bufnr or math.huge
		return ab ~= bb and (ab < bb) or ((a.started_at or 0) < (b.started_at or 0))
	end)
	return list
end

---Return true when `bufnr` currently has an active (`thinking` or `streaming`) request.
---@param bufnr integer|nil
---@return boolean
function M.has_active_request(bufnr)
	if type(bufnr) ~= "number" or bufnr <= 0 or not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	local entry = ag_state.chats[bufnr]
	if entry and (entry.state == "thinking" or entry.state == "streaming") then
		return true
	end
	for _, req in pairs(ag_state.other_requests) do
		if req.bufnr == bufnr then
			return true
		end
	end
	return false
end

local function emit_transition_notification(bufnr, state_name, entry)
	if not ag_state.notifications or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	local function fire_toast()
		if not ag_state.notifications or not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end
		local chat_mod = package.loaded["codecompanion.interactions.chat"]
		local chat = chat_mod and chat_mod.buf_get_chat(bufnr) or nil
		local ok_ws, ws = pcall(require, "cc_workspace")
		local chat_cwd = chat and ((type(chat.opts) == "table" and chat.opts.cwd) or chat.cwd) or nil
		if (not chat_cwd or chat_cwd == "") and ok_ws and ws and chat then
			chat_cwd = ws.get_valid_chat_cwd(chat)
		end

		local proj_name, proj_path = nil, nil
		if ok_ws and ws and chat and type(ws.get_chat_project_name) == "function" then
			proj_name, proj_path = ws.get_chat_project_name(chat)
		end
		local repo_root = git.get_repo_root(chat_cwd or proj_path)
		if (not proj_name or proj_name == "" or proj_name == "Other") and repo_root then
			proj_name = vim.fs.basename(repo_root)
		end
		proj_name = (proj_name and proj_name ~= "") and proj_name
			or ((chat_cwd and vim.fs.basename(chat_cwd)) or "Workspace")

		local branch = git.get_worktree_branch(chat_cwd or proj_path)
		local scope = (branch and branch ~= "") and string.format("[%s · %s %s]", proj_name, icons.git.Branch, branch)
			or string.format("[%s]", proj_name)

		local title = entry.title
		if (not title or title == "") and ok_ws and ws and chat and type(ws.get_chat_title) == "function" then
			title = ws.truncate_display(ws.get_chat_title(chat), 36)
		elseif not title or title == "" then
			title = (chat and ((chat.opts and chat.opts.title) or chat.title)) or string.format("Chat #%d", bufnr)
			title = #title > 36 and (title:sub(1, 35) .. "…") or title
		end

		local elapsed = math.max(0, tonumber(entry.elapsed) or 0)
		local suffix = state_name == "unread" and string.format("✓ Completed (%ds)", elapsed)
			or (state_name == "waiting" and (icons.diagnostics.Warning .. " Waiting") or "✗ Failed")
		local level = state_name == "unread" and vim.log.levels.INFO
			or (state_name == "waiting" and vim.log.levels.WARN or vim.log.levels.ERROR)
		vim.notify(string.format("%s %s — %s", scope, title, suffix), level, { title = "AI Workspace" })
	end
	if vim.in_fast_event() then
		vim.schedule(fire_toast)
	else
		fire_toast()
	end
end

---@return boolean
function M.notifications_enabled()
	return ag_state.notifications == true
end

---@param enabled boolean
function M.set_notifications(enabled)
	ag_state.notifications = enabled == true
end

---@param silent? boolean
---@return boolean enabled
function M.toggle_notifications(silent)
	ag_state.notifications = not ag_state.notifications
	if not silent then
		local label = ag_state.notifications and "enabled" or "disabled"
		vim.notify("AI Agent notifications " .. label, vim.log.levels.INFO, { title = "AI Workspace" })
	end
	return ag_state.notifications
end

---Update per-`bufnr` agent lifecycle state (`thinking`, `streaming`, `waiting`, `error`, `unread`, `idle`).
---@param bufnr integer
---@param state_name "thinking"|"streaming"|"waiting"|"error"|"unread"|"idle"
---@param extra? { started_at?: number, elapsed?: number, error?: string, tool?: string, title?: string, adapter?: string, notify?: boolean }
function M.set_chat_state(bufnr, state_name, extra)
	if type(bufnr) ~= "number" or bufnr <= 0 or not VALID_STATES[state_name] then
		return
	end
	extra = extra or {}
	local now_hr = vim.uv.hrtime()
	local prev = ag_state.chats[bufnr]
	local prev_state = prev and prev.state or "idle"
	local was_running = (prev_state == "thinking" or prev_state == "streaming" or prev_state == "waiting")

	local started_at = prev and prev.started_at or nil
	if state_name == "thinking" or state_name == "streaming" then
		started_at = extra.started_at or ((was_running and started_at) and started_at or now_hr)
	end

	local elapsed = extra.elapsed
	if elapsed == nil then
		if (state_name == "unread" or state_name == "error" or state_name == "idle") and started_at and was_running then
			elapsed = math.max(0, math.floor((now_hr - started_at) / 1e9))
		elseif prev and type(prev.elapsed) == "number" and state_name == prev_state then
			elapsed = prev.elapsed
		else
			elapsed = 0
		end
	end
	if state_name == "idle" then
		started_at = nil
	end

	local prev_phase = (prev_state == "streaming" or prev_state == "thinking") and prev_state
		or (prev and prev.prev_running_phase)
	local entry = { bufnr = bufnr, state = state_name, started_at = started_at, elapsed = elapsed, updated_at = now_hr }
	entry.adapter = extra.adapter or (prev and prev.adapter or nil)
	entry.prev_running_phase = (state_name == "waiting") and prev_phase or nil
	entry.error = extra.error or (state_name == "error" and prev and prev.error or nil)
	entry.tool = extra.tool or (state_name == "waiting" and prev and prev.tool or nil)
	entry.title = extra.title or (prev and prev.title or nil)
	ag_state.chats[bufnr] = entry

	if state_name == "thinking" or state_name == "streaming" then
		ensure_spinner_timer()
	elseif count_running_requests() <= 0 then
		stop_spinner_timer()
	end

	if prev_state ~= state_name then
		local bg_attn = (state_name == "unread" or state_name == "error" or state_name == "waiting")
		if bg_attn and extra.notify ~= false and vim.api.nvim_get_current_buf() ~= bufnr then
			ag_state.last_bg_bufnr = bufnr
			emit_transition_notification(bufnr, state_name, entry)
		end
		notify_ui_changed(bufnr, state_name)
	end
end

---Clear `"unread"`, `"error"`, or `"waiting"` state back to `"idle"` when the user views `bufnr`.
---@param bufnr integer|nil
function M.mark_read(bufnr)
	local entry = (type(bufnr) == "number" and bufnr > 0) and ag_state.chats[bufnr] or nil
	if entry and (entry.state == "unread" or entry.state == "error" or entry.state == "waiting") then
		entry.state, entry.error, entry.tool, entry.updated_at = "idle", nil, nil, vim.uv.hrtime()
		if ag_state.last_bg_bufnr == bufnr then
			ag_state.last_bg_bufnr = nil
		end
		---@cast bufnr integer
		notify_ui_changed(bufnr, "idle")
	end
end

local function resolve_spinner(anim_idx)
	local idx = type(anim_idx) == "number" and anim_idx or ag_state.anim_idx
	return M.SPINNER_FRAMES[((math.max(1, math.floor(idx)) - 1) % #M.SPINNER_FRAMES) + 1]
end

local function make_chat_status(st, icon, badge, hl, sa, el)
	local res = { state = st, phase = st, icon = icon, badge = badge, short = icon, hl = hl, badge_hl = hl }
	res.started_at, res.elapsed = sa, el
	return res
end

---Return Orca/Herdr status symbols, badges, highlights, and elapsed time for `bufnr`.
---@param bufnr integer
---@param is_cur? boolean
---@param anim_idx? integer
---@return CcAgentChatStatus
function M.get_chat_status(bufnr, is_cur, anim_idx)
	local entry = type(bufnr) == "number" and ag_state.chats[bufnr] or nil
	local st = (entry and entry.state) or "idle"
	local spin = resolve_spinner(anim_idx)
	local sa = entry and entry.started_at or nil
	local live_el = sa and math.max(0, math.floor((vim.uv.hrtime() - sa) / 1e9)) or nil

	if st == "thinking" then
		local el = live_el or 0
		return make_chat_status("thinking", spin, string.format("%s T%ds", spin, el), "CcAgentThinking", sa, el)
	elseif st == "streaming" then
		local el = live_el or 0
		return make_chat_status("streaming", "⚡", string.format("%s S%ds", spin, el), "CcAgentStreaming", sa, el)
	elseif st == "waiting" then
		local warn = icons.diagnostics.Warning
		return make_chat_status(
			"waiting",
			warn,
			warn .. " Wait",
			"CcAgentWaiting",
			sa,
			live_el or (entry and entry.elapsed or 0)
		)
	elseif st == "error" then
		return make_chat_status("error", "✗", "✗ Err", "CcAgentError", nil, (entry and entry.elapsed) or 0)
	elseif st == "unread" then
		return make_chat_status("unread", "✓", "✓ Done", "CcAgentUnread", nil, (entry and entry.elapsed) or 0)
	end
	local cur = is_cur == true
	return make_chat_status(
		"idle",
		cur and "◆" or "○",
		cur and "Active" or "Idle",
		cur and "CcAgentActive" or "CcAgentIdle",
		nil,
		0
	)
end

local function collect_all_chat_bufnrs()
	local seen, result = {}, {}
	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	if chat_mod and type(chat_mod.buf_get_chat) == "function" then
		local all = chat_mod.buf_get_chat()
		for _, item in ipairs(type(all) == "table" and all or {}) do
			local b = item and item.chat and item.chat.bufnr
			if type(b) == "number" and vim.api.nvim_buf_is_valid(b) and not seen[b] then
				seen[b] = true
				table.insert(result, b)
			end
		end
	end
	for b in pairs(ag_state.chats) do
		if type(b) == "number" and vim.api.nvim_buf_is_valid(b) and not seen[b] then
			seen[b] = true
			table.insert(result, b)
		end
	end
	table.sort(result)
	return result
end

---Aggregate status counts and compact Orca/Herdr badge (`"1 ✗1 ✓2 ⠋1"` or `""`) across `bufnrs` (or all chats when nil).
---@param bufnrs? (integer|table)[]
---@param anim_idx? integer
---@return CcAgentRollup
function M.get_rollup(bufnrs, anim_idx)
	local counts = { thinking = 0, streaming = 0, running = 0, waiting = 0, unread = 0, error = 0, idle = 0, total = 0 }
	local seen = {}
	for _, item in ipairs(bufnrs or collect_all_chat_bufnrs()) do
		local b = type(item) == "table" and item.bufnr or item
		if type(b) == "number" and b > 0 and not seen[b] and vim.api.nvim_buf_is_valid(b) then
			seen[b] = true
			counts.total = counts.total + 1
			local st = (ag_state.chats[b] and ag_state.chats[b].state) or "idle"
			local key = VALID_STATES[st] and st or "idle"
			counts[key] = counts[key] + 1
			if key == "thinking" or key == "streaming" then
				counts.running = counts.running + 1
			end
		end
	end

	local parts = {}
	if counts.waiting > 0 then
		table.insert(parts, string.format("%s%d", icons.diagnostics.Warning, counts.waiting))
	end
	if counts.error > 0 then
		table.insert(parts, string.format("✗%d", counts.error))
	end
	if counts.unread > 0 then
		table.insert(parts, string.format("✓%d", counts.unread))
	end
	if counts.running > 0 then
		table.insert(parts, string.format("%s%d", resolve_spinner(anim_idx), counts.running))
	end
	---@type CcAgentRollup
	local res = vim.tbl_extend("force", counts, { badge = table.concat(parts, " ") })
	return res
end

---Return valid chat `bufnr`s requiring user attention or actively running, ordered by urgency.
---@return integer[]
function M.get_attention_chats()
	local items = {}
	for bufnr, entry in pairs(ag_state.chats) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			local prio = ATTENTION_PRIORITY[entry.state]
			if prio then
				table.insert(items, { bufnr = bufnr, prio = prio, updated_at = entry.updated_at or 0 })
			end
		else
			ag_state.chats[bufnr], ag_state.tools_running[bufnr] = nil, nil
		end
	end
	table.sort(items, function(a, b)
		if a.prio ~= b.prio then
			return a.prio < b.prio
		end
		return a.updated_at ~= b.updated_at and (a.updated_at > b.updated_at) or (a.bufnr < b.bufnr)
	end)
	local result = {}
	for _, it in ipairs(items) do
		table.insert(result, it.bufnr)
	end
	return result
end

local function focus_existing_split_win(bufnr)
	local wins = vim.fn.win_findbuf(bufnr)
	for _, w in ipairs(type(wins) == "table" and wins or {}) do
		if vim.api.nvim_win_is_valid(w) then
			local ok_cfg, cfg = pcall(vim.api.nvim_win_get_config, w)
			if ok_cfg and (cfg.relative == nil or cfg.relative == "") then
				local tp = vim.api.nvim_win_get_tabpage(w)
				if vim.api.nvim_tabpage_is_valid(tp) and tp ~= vim.api.nvim_get_current_tabpage() then
					vim.api.nvim_set_current_tabpage(tp)
				end
				vim.api.nvim_set_current_win(w)
				return vim.api.nvim_get_current_buf() == bufnr
			end
		end
	end
	return false
end

---Jump directly to the highest-priority attention/unread/running chat and mark it read.
---@param opts? { silent?: boolean }
---@return boolean jumped
function M.jump_to_attention(opts)
	opts = opts or {}
	local attention = M.get_attention_chats()
	if #attention == 0 then
		local last_bg = M.get_last_background_bufnr()
		attention = last_bg and { last_bg } or {}
	end
	if #attention == 0 then
		if not opts.silent then
			local info_msg = "No unread or active AI chats needing attention"
			vim.notify(info_msg, vim.log.levels.INFO, { title = "AI Workspace" })
		end
		return false
	end

	local cur_buf = vim.api.nvim_get_current_buf()
	local target_bufnr = (attention[1] == cur_buf and #attention > 1) and attention[2] or attention[1]
	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	local target_chat = chat_mod and chat_mod.buf_get_chat(target_bufnr) or nil
	local ok_ws, ws = pcall(require, "cc_workspace")

	local jumped = false
	if ok_ws and ws and target_chat then
		if type(ws.is_current_tab) == "function" and ws.is_current_tab() and type(ws.show_chat) == "function" then
			pcall(ws.show_chat, target_chat, true)
			jumped = (vim.api.nvim_get_current_buf() == target_bufnr)
		else
			jumped = focus_existing_split_win(target_bufnr)
			if not jumped and type(ws.focus_or_open_chat) == "function" then
				pcall(ws.focus_or_open_chat, target_chat)
				if vim.api.nvim_get_current_buf() ~= target_bufnr then
					focus_existing_split_win(target_bufnr)
				end
				jumped = (vim.api.nvim_get_current_buf() == target_bufnr)
			end
		end
	end

	if not jumped and vim.api.nvim_buf_is_valid(target_bufnr) then
		if not focus_existing_split_win(target_bufnr) then
			vim.api.nvim_set_current_buf(target_bufnr)
		end
		jumped = true
	end
	if jumped then
		ag_state.last_bg_bufnr = nil
		M.mark_read(target_bufnr)
	end
	return jumped
end

---Reset all tracked per-buffer agent states (primarily for isolated tests).
function M.reset_states()
	ag_state.chats, ag_state.other_requests, ag_state.tools_running, ag_state.last_bg_bufnr = {}, {}, {}, nil
	stop_spinner_timer()
end

---Check whether `bufnr` currently has tracked agent state.
---@param bufnr integer
---@return table|nil
function M.get_chat_entry(bufnr)
	return ag_state.chats[bufnr]
end

---Get or update mid-turn HTTP tool execution tracking for `bufnr`.
---@param bufnr integer
---@param running? boolean|nil
---@return boolean
function M.tools_running(bufnr, running)
	if running ~= nil then
		ag_state.tools_running[bufnr] = running == true and true or nil
	end
	return ag_state.tools_running[bufnr] == true
end

---Remove tracked state for a closed or wiped buffer, stopping spinner timer when idle.
---@param bufnr integer
---@param emit_closed? boolean
function M.drop_chat_buf(bufnr, emit_closed)
	if ag_state.chats[bufnr] or ag_state.tools_running[bufnr] or emit_closed then
		ag_state.chats[bufnr], ag_state.tools_running[bufnr] = nil, nil
		if ag_state.last_bg_bufnr == bufnr then
			ag_state.last_bg_bufnr = nil
		end
		if count_running_requests() <= 0 then
			stop_spinner_timer()
		end
		if emit_closed then
			notify_ui_changed(bufnr, "closed")
		end
	end
end

---Track or clear non-chat (`inline`/`cmd`/`cli`) CodeCompanion requests.
---@param ev string
---@param data table
---@param raw_adapter any
function M.handle_non_chat_event(ev, data, raw_adapter)
	if ev == "CodeCompanionChatClosed" and type(data.bufnr) == "number" then
		return M.drop_chat_buf(data.bufnr, false)
	end
	local key = (data.id ~= nil and tostring(data.id) ~= "") and ("id:" .. tostring(data.id))
		or string.format("%s:%s", tostring(data.interaction or "other"), tostring(data.bufnr or "0"))
	local bnr = type(data.bufnr) == "number" and data.bufnr or nil

	if ev == "CodeCompanionRequestStarted" or ev == "CodeCompanionRequestStreaming" then
		local phase = ev == "CodeCompanionRequestStreaming" and "streaming" or "thinking"
		local req = ag_state.other_requests[key]
		if req and phase == "streaming" then
			if req.phase ~= "streaming" then
				req.phase = "streaming"
				notify_ui_changed(req.bufnr or 0, "streaming")
			end
		else
			local adp = extract_adapter_name(raw_adapter) or "AI"
			local item =
				{ key = key, bufnr = bnr, interaction = data.interaction or "other", adapter = adp, phase = phase }
			item.started_at = vim.uv.hrtime()
			ag_state.other_requests[key] = item
			notify_ui_changed(bnr or 0, phase)
		end
		ensure_spinner_timer()
	elseif ev == "CodeCompanionRequestFinished" then
		if ag_state.other_requests[key] then
			ag_state.other_requests[key] = nil
		else
			for k, req in pairs(ag_state.other_requests) do
				if (bnr and req.bufnr == bnr) or (data.interaction and req.interaction == data.interaction) then
					ag_state.other_requests[k] = nil
					break
				end
			end
		end
		if count_running_requests() <= 0 then
			stop_spinner_timer()
		end
		notify_ui_changed(bnr or 0, "idle")
	end
end

---Apply initial/override notification options and refresh highlight groups.
---@param opts? { notifications?: boolean }
function M.configure_options(opts)
	opts = opts or {}
	if opts.notifications ~= nil then
		ag_state.notifications = opts.notifications == true
	elseif not ag_state.setup_done and config.options and config.options.notifications ~= nil then
		ag_state.notifications = config.options.notifications == true
	end
	M.setup_highlights()
	ag_state.setup_done = true
end

M.extract_adapter_name = extract_adapter_name

---@param opts? { notifications?: boolean, worktrees_base_dir?: string }
function M.setup(opts)
	local ok_wt, wt = pcall(require, "cc_workspace.worktree")
	if ok_wt and type(wt) == "table" and type(wt.setup) == "function" then
		wt.setup(opts)
	else
		M.configure_options(opts)
	end
end

return M
