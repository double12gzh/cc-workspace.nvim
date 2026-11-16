local icons = require("cc_workspace.icons")

local M = {}

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local sl_state = {
	anim_idx = 1,
	spinner_timer = nil,
	wt_ready = false,
	wt_unsub = nil,
	augroup_ready = false,
}

---Trigger a targeted statusline refresh via `lualine.nvim` when loaded, falling back to `redrawstatus`.
local function refresh_statusline()
	local lualine = package.loaded["lualine"]
	if type(lualine) == "table" and type(lualine.refresh) == "function" then
		pcall(lualine.refresh, { place = { "statusline" } })
	else
		pcall(vim.cmd.redrawstatus)
	end
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

---Safely load `cc_workspace.worktree`, initialize its hooks once, and subscribe to state transitions.
---@return table|nil
local function get_wt()
	local ok, wt = pcall(require, "cc_workspace.worktree")
	if not ok or type(wt) ~= "table" then
		return nil
	end
	if not sl_state.wt_ready then
		sl_state.wt_ready = true
		if type(wt.setup) == "function" then
			pcall(wt.setup)
		end
	end
	if not sl_state.wt_unsub and type(wt.on_change) == "function" then
		local ok_sub, unsub = pcall(wt.on_change, function()
			M.ensure_spinner()
			refresh_statusline()
		end)
		if ok_sub and type(unsub) == "function" then
			sl_state.wt_unsub = unsub
		end
	end
	return wt
end

---Return sorted active requests from `cc_workspace.worktree`.
---@return table[]
local function get_sorted_requests()
	local wt = get_wt()
	if not wt or type(wt.get_active_requests) ~= "function" then
		return {}
	end
	local ok, list = pcall(wt.get_active_requests)
	if not ok or type(list) ~= "table" then
		return {}
	end
	return list
end

---Stop and close the statusline spinner timer when no requests are active.
local function stop_spinner_timer()
	if sl_state.spinner_timer then
		sl_state.spinner_timer:stop()
		if not sl_state.spinner_timer:is_closing() then
			sl_state.spinner_timer:close()
		end
		sl_state.spinner_timer = nil
	end
end

---Ensure a single clean spinner timer is running while requests are active.
function M.ensure_spinner()
	if sl_state.spinner_timer then
		return
	end
	if #get_sorted_requests() == 0 then
		return
	end
	local timer = vim.uv.new_timer()
	if not timer then
		return
	end
	sl_state.spinner_timer = timer
	timer:start(
		150,
		150,
		vim.schedule_wrap(function()
			if #get_sorted_requests() == 0 then
				stop_spinner_timer()
				refresh_statusline()
				return
			end
			sl_state.anim_idx = (sl_state.anim_idx % #SPINNER_FRAMES) + 1
			refresh_statusline()
		end)
	)
end

---Install lightweight autocmds once so request start/stream/finish events immediately manage the spinner.
local function ensure_autocmds()
	if sl_state.augroup_ready then
		return
	end
	sl_state.augroup_ready = true
	local group = vim.api.nvim_create_augroup("CcWorkspaceStatusline", { clear = true })
	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = {
			"CodeCompanionRequestStarted",
			"CodeCompanionRequestStreaming",
			"CodeCompanionRequestFinished",
		},
		callback = function(args)
			get_wt()
			if args.match == "CodeCompanionRequestFinished" then
				if #get_sorted_requests() == 0 then
					stop_spinner_timer()
				end
			else
				M.ensure_spinner()
			end
			vim.schedule(refresh_statusline)
		end,
	})
end

---Collect valid open CodeCompanion chat buffer numbers sorted ascending.
---@return integer[]
local function collect_open_chat_bufnrs()
	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	local bufnrs = {}
	if not chat_mod or type(chat_mod.buf_get_chat) ~= "function" then
		return bufnrs
	end
	local all_entries = chat_mod.buf_get_chat()
	if type(all_entries) == "table" then
		for _, entry in ipairs(all_entries) do
			if entry.chat and vim.api.nvim_buf_is_valid(entry.chat.bufnr) then
				table.insert(bufnrs, entry.chat.bufnr)
			end
		end
	end
	table.sort(bufnrs)
	return bufnrs
end

---Summarize unread/error/waiting/running attention counts across open chats via `cc_workspace.worktree`.
---@return { waiting: integer, error: integer, unread: integer, running: integer, text: string }
local function get_attention_summary()
	local summary = { waiting = 0, error = 0, unread = 0, running = 0, text = "" }
	local wt = get_wt()
	if not wt or type(wt.get_rollup) ~= "function" then
		return summary
	end
	local bufnrs = collect_open_chat_bufnrs()
	local rollup_arg = #bufnrs > 0 and bufnrs or nil
	local ok_r, rollup = pcall(wt.get_rollup, rollup_arg, sl_state.anim_idx)
	if ok_r and type(rollup) == "table" then
		summary.waiting = tonumber(rollup.waiting) or 0
		summary.error = tonumber(rollup.error) or 0
		summary.unread = tonumber(rollup.unread) or 0
		summary.running = tonumber(rollup.running)
			or ((tonumber(rollup.thinking) or 0) + (tonumber(rollup.streaming) or 0))
	end
	local warn_icon = icons.diagnostics.Warning ~= "" and icons.diagnostics.Warning or ""
	local badges = {}
	if summary.waiting > 0 then
		table.insert(badges, string.format("%s%d wait", warn_icon, summary.waiting))
	end
	if summary.error > 0 then
		table.insert(badges, string.format("✗%d err", summary.error))
	end
	if summary.unread > 0 then
		table.insert(badges, string.format("✓%d unread", summary.unread))
	end
	summary.text = table.concat(badges, " · ")
	return summary
end

---Format a token count compactly (e.g. 850 -> "850 tok", 8710 -> "8.7k tok").
---@param count number
---@return string
local function format_tokens(count)
	if count >= 1000 then
		return string.format("%.1fk tok", count / 1000)
	end
	return string.format("%d tok", count)
end

---Shorten a hierarchical model ID (e.g. "magpie/group/gpt-6-astra" -> "gpt-6-astra").
---@param model string
---@return string
local function short_model_name(model)
	local tail = model:match("([^/]+)$")
	return tail or model
end

---Find the active/visible CodeCompanion chat instance in the current tabpage without forcing lazy-load.
---@return table|nil
local function get_visible_chat()
	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	if not chat_mod or type(chat_mod.buf_get_chat) ~= "function" then
		return nil
	end
	local cur = chat_mod.buf_get_chat(0)
	if cur then
		return cur
	end
	for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		local b = vim.api.nvim_win_get_buf(w)
		if vim.bo[b].filetype == "codecompanion" then
			local c = chat_mod.buf_get_chat(b)
			if c then
				return c
			end
		end
	end
	return nil
end

---Extract adapter, model, mode, and token count from a CodeCompanion chat.
---@param chat table
---@return { adapter: string, model?: string, mode?: string, tokens?: string }
local function get_chat_metadata(chat)
	local meta = {
		adapter = (chat.adapter and (chat.adapter.name or chat.adapter.formatted_name)) or "AI",
	}

	if
		chat.adapter
		and chat.adapter.type == "acp"
		and chat.acp_connection
		and chat.acp_connection.get_config_options
	then
		for _, opt in ipairs(chat.acp_connection:get_config_options()) do
			if opt.category == "model" and type(opt.currentValue) == "string" and opt.currentValue ~= "" then
				meta.model = short_model_name(opt.currentValue)
			elseif
				opt.category == "mode"
				and type(opt.currentValue) == "string"
				and opt.currentValue ~= ""
				and opt.currentValue ~= "default"
			then
				meta.mode = opt.currentValue
			end
		end
	elseif chat.adapter and chat.adapter.schema and chat.adapter.schema.model then
		local m = chat.adapter.schema.model.default
		if type(m) == "function" then
			local ok_m, resolved = pcall(m, chat.adapter)
			m = ok_m and resolved or nil
		end
		if type(m) == "string" and m ~= "" then
			meta.model = short_model_name(m)
		end
	end

	if type(chat.tokens) == "number" and chat.tokens > 0 then
		meta.tokens = format_tokens(chat.tokens)
	end
	return meta
end

---Build idle status text for a visible CodeCompanion Chat or CLI instance.
---@return string
local function get_idle_status()
	local chat_icon = icons.get("aichat", true).Chat
	local chat = get_visible_chat()
	if chat and chat.adapter then
		local meta = get_chat_metadata(chat)
		local parts = { chat_icon .. meta.adapter }
		if meta.model then
			table.insert(parts, meta.model)
		end
		if meta.mode then
			table.insert(parts, meta.mode)
		end
		if meta.tokens then
			table.insert(parts, meta.tokens)
		end
		return table.concat(parts, " · ")
	end

	local cli_mod = package.loaded["codecompanion.interactions.cli"]
	if cli_mod and type(cli_mod.get_visible) == "function" then
		local cli = cli_mod.get_visible()
		if cli then
			return string.format("%s%s (CLI)", chat_icon, cli.agent_name or "cli")
		end
	end

	return ""
end

---Render the CodeCompanion / AI Workspace statusline text segment.
---@return string
function M.render()
	local chat_icon = icons.get("aichat", true).Chat
	local reqs = get_sorted_requests()
	local att = get_attention_summary()

	if #reqs == 0 then
		local idle = get_idle_status()
		if att.text ~= "" then
			if idle ~= "" then
				return idle .. " · " .. att.text
			end
			return chat_icon .. att.text
		end
		return idle
	end

	M.ensure_spinner()

	local cur_buf = vim.api.nvim_get_current_buf()
	local now = vim.uv.hrtime()
	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	local spin = SPINNER_FRAMES[sl_state.anim_idx]

	if #reqs == 1 then
		local req = reqs[1]
		local elapsed = type(req.elapsed) == "number" and req.elapsed
			or math.max(0, math.floor((now - (req.started_at or now)) / 1e9))
		local status_text = req.phase == "streaming" and "Streaming" or "Thinking"
		local chat = (req.bufnr and chat_mod and type(chat_mod.buf_get_chat) == "function")
				and chat_mod.buf_get_chat(req.bufnr)
			or get_visible_chat()
		local is_hidden = req.bufnr ~= nil and vim.fn.bufwinid(req.bufnr) == -1
		local meta = chat and get_chat_metadata(chat) or { adapter = req.adapter or "AI" }
		local parts = { chat_icon .. meta.adapter }
		if meta.model then
			table.insert(parts, meta.model)
		end
		if meta.mode then
			table.insert(parts, meta.mode)
		end
		local bg_tag = is_hidden and " [bg]" or ""
		table.insert(parts, string.format("%s %s %ds%s", spin, status_text, elapsed, bg_tag))
		if meta.tokens then
			table.insert(parts, meta.tokens)
		end
		if att.text ~= "" then
			table.insert(parts, att.text)
		end
		return table.concat(parts, " · ")
	end

	local segs = {}
	for _, req in ipairs(reqs) do
		local elapsed = type(req.elapsed) == "number" and req.elapsed
			or math.max(0, math.floor((now - (req.started_at or now)) / 1e9))
		local status_text = req.phase == "streaming" and "Streaming" or "Thinking"
		local buf_tag = req.bufnr and ("#" .. tostring(req.bufnr)) or "?"
		if req.bufnr and req.bufnr == cur_buf then
			buf_tag = buf_tag .. "*"
		elseif req.bufnr and vim.fn.bufwinid(req.bufnr) == -1 then
			buf_tag = buf_tag .. "[bg]"
		end
		table.insert(segs, string.format("%s %s %s %ds", buf_tag, spin, status_text, elapsed))
	end
	local multi_str = chat_icon .. table.concat(segs, " | ")
	if att.text ~= "" then
		multi_str = multi_str .. " · " .. att.text
	end
	return multi_str
end

---Resolve dynamic high-contrast foreground color table for `lualine`.
---@return { fg: string, gui: string }
function M.color()
	local reqs = get_sorted_requests()
	local att = get_attention_summary()
	if att.error > 0 then
		return { fg = resolve_hl_fg("DiagnosticError", "#ea6962"), gui = "bold" }
	end
	if att.waiting > 0 then
		return { fg = resolve_hl_fg("DiagnosticWarn", "#e78a4e"), gui = "bold" }
	end
	if #reqs == 0 then
		if att.unread > 0 then
			return {
				fg = resolve_hl_fg("CcAgentUnread", resolve_hl_fg("DiagnosticOk", "#a9b665")),
				gui = "bold",
			}
		end
		return { fg = resolve_hl_fg("DiagnosticInfo", "#83a598"), gui = "bold" }
	end
	local cur_buf = vim.api.nvim_get_current_buf()
	local active_req = reqs[1]
	for _, req in ipairs(reqs) do
		if req.bufnr == cur_buf then
			active_req = req
			break
		end
	end
	if active_req and active_req.phase == "streaming" then
		return { fg = resolve_hl_fg("DiagnosticOk", "#b8bb26"), gui = "bold" }
	end
	return { fg = resolve_hl_fg("DiagnosticWarn", "#fabd2f"), gui = "bold" }
end

---Handle left-click on the statusline component: jump to highest-priority attention/active chat, CLI, or toggle side chat.
---@param _clicks? integer
---@param button? string
function M.on_click(_clicks, button)
	if button and button ~= "l" then
		return
	end
	local wt = get_wt()
	if wt and type(wt.jump_to_attention) == "function" then
		local ok_j, jumped = pcall(wt.jump_to_attention, { silent = true })
		if ok_j and jumped then
			vim.schedule(function()
				pcall(function()
					require("cc_workspace.winbar").refresh()
				end)
				refresh_statusline()
			end)
			return
		end
	end

	local reqs = get_sorted_requests()
	local target_bufnr = (reqs[1] and reqs[1].bufnr)
		or (wt and type(wt.get_last_background_bufnr) == "function" and wt.get_last_background_bufnr())
		or nil
	if target_bufnr then
		if wt and type(wt.clear_last_background_bufnr) == "function" then
			pcall(wt.clear_last_background_bufnr)
		end
		local cur_win = vim.fn.bufwinid(target_bufnr)
		if cur_win ~= -1 and vim.api.nvim_win_is_valid(cur_win) then
			vim.api.nvim_set_current_win(cur_win)
			if wt and type(wt.mark_read) == "function" then
				pcall(wt.mark_read, target_bufnr)
			end
			return
		end
		local any_wins = vim.fn.win_findbuf(target_bufnr)
		if type(any_wins) == "table" and any_wins[1] and vim.api.nvim_win_is_valid(any_wins[1]) then
			local tp = vim.api.nvim_win_get_tabpage(any_wins[1])
			if vim.api.nvim_tabpage_is_valid(tp) then
				vim.api.nvim_set_current_tabpage(tp)
			end
			vim.api.nvim_set_current_win(any_wins[1])
			if wt and type(wt.mark_read) == "function" then
				pcall(wt.mark_read, target_bufnr)
			end
			return
		end
		local chat_mod = package.loaded["codecompanion.interactions.chat"]
		local chat = (chat_mod and type(chat_mod.buf_get_chat) == "function") and chat_mod.buf_get_chat(target_bufnr)
			or nil
		if chat then
			require("cc_workspace").focus_or_open_chat(chat)
			if wt and type(wt.mark_read) == "function" then
				pcall(wt.mark_read, target_bufnr)
			end
			return
		end
	end

	if reqs[1] and reqs[1].interaction == "cli" then
		vim.cmd("CodeCompanionCLI")
		return
	end
	require("cc_workspace").toggle_side_chat()
end

---Build a complete `lualine` component table (`[1]`, `on_click`, `color`, `cond`).
---@param opts? { min_columns?: integer, cond?: fun(): boolean, [string]: any }
---@return table
function M.component(opts)
	opts = type(opts) == "table" and opts or {}
	ensure_autocmds()
	get_wt()

	local min_cols = tonumber(opts.min_columns) or 60
	local comp = {
		M.render,
		on_click = M.on_click,
		color = M.color,
		cond = type(opts.cond) == "function" and opts.cond or function()
			return vim.o.columns > min_cols
		end,
	}
	for k, v in pairs(opts) do
		if k ~= "min_columns" and k ~= "cond" and comp[k] == nil then
			comp[k] = v
		end
	end
	return comp
end

---Build the `"cc-workspace"` `lualine` extension table keeping `lualine_x = { M.component() }` visible when the sidebar is focused under `laststatus = 3`.
---@param base_ext? table
---@return table
function M.extension(base_ext)
	local is_component = type(base_ext) == "table" and type(base_ext[1]) == "function"
	local comp = is_component and base_ext
		or (type(base_ext) == "table" and type(base_ext.component) == "table" and base_ext.component)
		or M.component()
	local title = (not is_component and type(base_ext) == "table" and type(base_ext.title) == "string")
			and base_ext.title
		or "AI Workspace"

	local ext = {
		sections = {
			lualine_a = {
				function()
					return icons.get("aichat", true).Chat .. title
				end,
			},
			lualine_b = {},
			lualine_c = {},
			lualine_x = { comp },
			lualine_y = {},
			lualine_z = {},
		},
		filetypes = { "cc-workspace" },
	}

	if not is_component and type(base_ext) == "table" then
		if type(base_ext.sections) == "table" then
			ext.sections = vim.tbl_deep_extend("force", ext.sections, base_ext.sections)
		end
		if type(base_ext.inactive_sections) == "table" then
			ext.inactive_sections = vim.deepcopy(base_ext.inactive_sections)
		end
		if type(base_ext.filetypes) == "table" then
			ext.filetypes = vim.deepcopy(base_ext.filetypes)
		end
	end

	return ext
end

---Stop any running statusline spinner timer (useful for isolated tests).
function M.stop()
	stop_spinner_timer()
end

return M
