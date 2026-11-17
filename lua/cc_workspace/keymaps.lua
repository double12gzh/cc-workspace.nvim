local config = require("cc_workspace.config")
local icons = require("cc_workspace.icons")

local M = {}

local _bound_global_keys = {}

local SCHEMA = config.KEYMAP_SCHEMA

---Normalize a keymap config entry (`false | string | string[] | table`) into `keys: string[]`, `disabled: boolean`.
---@param spec any
---@return string[], boolean
function M.normalize_keys(spec)
	if spec == false or spec == nil then
		return {}, spec == false
	end
	if spec == true then
		return {}, false
	end
	if type(spec) == "string" then
		local t = spec ~= " " and vim.trim(spec) or spec
		return (t == "" and {} or { spec }), t == ""
	end
	if type(spec) ~= "table" then
		return {}, true
	end
	local out, seen = {}, {}
	local function add_k(k)
		if type(k) == "string" and k ~= "" and not seen[k] then
			seen[k] = true
			table.insert(out, k)
		end
	end
	if vim.islist(spec) then
		for _, k in ipairs(spec) do
			add_k(k)
		end
	else
		for _, m in ipairs({ "n", "v", "i", "x" }) do
			local mk = spec[m]
			if type(mk) == "string" then
				add_k(mk)
			elseif type(mk) == "table" and vim.islist(mk) then
				for _, k in ipairs(mk) do
					add_k(k)
				end
			end
		end
	end
	return out, #out == 0
end

---Format a normalized key list into a compact display label.
---@param keys string[]
---@param fallback? string
---@return string
function M.format_keys(keys, fallback)
	if type(keys) ~= "table" or #keys == 0 then
		return fallback or "(disabled)"
	end
	if #keys == 9 and table.concat(keys, "") == "123456789" then
		return "1 - 9"
	end
	return table.concat(keys, " / ")
end

---Format raw Neovim `lhs` (converting leading `<Space>` / `mapleader` to `<leader>`).
---@param lhs string
---@return string
local function format_lhs_display(lhs)
	if type(lhs) ~= "string" or lhs == "" then
		return ""
	end
	local leader = vim.g.mapleader
	if (leader == nil or leader == " ") and lhs:sub(1, 1) == " " and #lhs > 1 then
		return "<leader>" .. lhs:sub(2)
	end
	if type(leader) == "string" and leader ~= "" and #lhs > #leader and lhs:sub(1, #leader) == leader then
		return "<leader>" .. lhs:sub(#leader + 1)
	end
	return lhs
end

---Classify a global Neovim keymap signature back to a canonical `global` action id, if recognizable.
---@param mode string
---@param sig string
---@return string|nil
local function classify_global_sig(mode, sig)
	for _, pair in ipairs(SCHEMA.sig_patterns) do
		if sig:find(pair[1], 1, true) then
			return pair[2]
		end
	end
	if sig:find("toggle_side_chat", 1, true) then
		return mode == "n" and "toggle_side_chat" or nil
	end
	if sig:find("switcher", 1, true) and (sig:find("open", 1, true) or sig:find("pick_open_chat", 1, true)) then
		return "switcher"
	end
	if
		mode == "n"
		and (
			sig:find("CodeCompanionWorkspace", 1, true)
			or (sig:find("cc_workspace", 1, true) and sig:find("toggle", 1, true))
		)
	then
		return "toggle_workspace"
	end
	return nil
end

---Inspect active editor global mappings (`n`, `v`) to discover external `cc_workspace` shortcuts (e.g. `<leader>cw`, `<leader>cl`, `<leader>ck`).
---@return table<string, string[]>, table[]
function M.detect_external_global_keymaps()
	local by_action, extras, bound_lookup, seen_act, seen_ex = {}, {}, {}, {}, {}
	for _, b in ipairs(_bound_global_keys) do
		bound_lookup[b.mode .. "\0" .. b.lhs] = true
	end
	for _, mode in ipairs({ "n", "v" }) do
		local ok_m, maps = pcall(vim.api.nvim_get_keymap, mode)
		for _, m in ipairs((ok_m and type(maps) == "table") and maps or {}) do
			local raw_lhs = m.lhs or ""
			local disp_lhs = format_lhs_display(raw_lhs)
			if
				raw_lhs ~= ""
				and not raw_lhs:find("Mouse", 1, true)
				and not raw_lhs:find("<Plug>", 1, true)
				and not bound_lookup[mode .. "\0" .. disp_lhs]
				and not bound_lookup[mode .. "\0" .. raw_lhs]
			then
				local rhs, desc = m.rhs or "", m.desc or ""
				local ok_d, d = false, ""
				if type(m.callback) == "function" then
					ok_d, d = pcall(string.dump, m.callback)
				end
				local sig = rhs .. "\n" .. (ok_d and type(d) == "string" and d or "") .. "\n" .. desc
				if
					sig:find("cc_workspace", 1, true)
					or sig:find("CodeCompanionWorkspace", 1, true)
					or sig:find("CodeCompanionNotificationsToggle", 1, true)
				then
					local act_id = classify_global_sig(mode, sig)
					local tag_lhs = mode ~= "n" and (mode .. ":" .. disp_lhs) or disp_lhs
					if act_id then
						by_action[act_id] = by_action[act_id] or {}
						if not seen_act[act_id .. "\0" .. tag_lhs] then
							seen_act[act_id .. "\0" .. tag_lhs] = true
							table.insert(by_action[act_id], tag_lhs)
						end
					elseif not seen_ex[mode .. "\0" .. disp_lhs] then
						seen_ex[mode .. "\0" .. disp_lhs] = true
						table.insert(extras, {
							lhs = tag_lhs,
							mode = mode,
							desc = desc ~= "" and desc or "AI Workspace shortcut",
							callback = m.callback,
							rhs = rhs,
						})
					end
				end
			end
		end
	end
	return by_action, extras
end

---Execute a named global/quick action safely via deferred `require`.
---@param act_id string
function M.run_global_action(act_id)
	local ok_ws, ws = pcall(require, "cc_workspace")
	local ok_sw, sw = pcall(require, "cc_workspace.switcher")
	local ws_fns = ok_ws
			and {
				toggle_workspace = ws.toggle,
				send_selection = ws.send_visual_selection,
				new_chat = ws.new_smart_chat,
				new_project_chat = ws.prompt_new_project_chat,
				toggle_side_chat = ws.toggle_side_chat,
				add_visual_to_chat = ws.add_visual_to_chat,
			}
		or {}
	local sw_fns = ok_sw
			and {
				switcher = sw.open,
				jump_attention = sw.jump_to_attention,
				new_worktree_chat = sw.create_worktree_chat,
				select_model = sw.select_adapter_or_model,
			}
		or {}
	if ws_fns[act_id] then
		ws_fns[act_id]()
	elseif sw_fns[act_id] then
		sw_fns[act_id]()
	elseif act_id == "add_project" and ok_ws then
		ws.enter(false, { skip_auto_chat = true })
		ws.prompt_add_project()
	elseif act_id == "history" and ok_ws then
		pcall(require, "codecompanion")
		ws.patch_history_ui()
		pcall(vim.api.nvim_cmd, { cmd = "CodeCompanionHistory" }, {})
	elseif act_id == "show_keys" then
		M.show_keys({ mode = "picker" })
	elseif act_id == "focus_chat" and ok_ws then
		local ok_cc, cc = pcall(require, "codecompanion")
		local last = ok_cc and type(cc.last_chat) == "function" and cc.last_chat() or nil
		if last and vim.api.nvim_buf_is_valid(last.bufnr) then
			ws.focus_or_open_chat(last)
		else
			ws.new_smart_chat()
		end
	end
end

---Return a deep copy of configured `opts.keymaps` (`{ global, sidebar, chat, switcher }`).
---@return CcWorkspaceKeymapsConfig
function M.get_keymaps()
	local km = (config.options and config.options.keymaps) or config.defaults.keymaps or {}
	return vim.deepcopy(km)
end

---Build full live catalog of effective keymaps across `[Global]`, `[Sidebar]`, `[Chat]`, `[Switcher]`, `[Winbar Mouse]`, and `[Commands]`.
---@return { entries: table[], by_scope: table<string, table[]> }
function M.get_effective_keymaps()
	---@type table<string, table<string, any>>
	local km = (config.options and config.options.keymaps) or config.defaults.keymaps or {}
	local ext_global, ext_extras = M.detect_external_global_keymaps()
	local entries = {}
	local by_scope = { global = {}, sidebar = {}, chat = {}, switcher = {}, winbar = {}, commands = {} }

	local function push(cat, scope, act, mode, keys, cfg_keys, disabled, label, desc, rebindable, exec_fn)
		local e = {
			category = cat,
			scope = scope,
			action = act,
			mode = mode,
			keys = keys,
			configured_keys = cfg_keys,
			disabled = disabled,
			key_label = label,
			desc = desc,
			rebindable = rebindable,
			execute = exec_fn,
		}
		table.insert(entries, e)
		if by_scope[scope] then
			table.insert(by_scope[scope], e)
		end
	end

	for _, meta in ipairs(SCHEMA.global) do
		local id, mode, desc = meta[1], meta[2], meta[3]
		local cfg_keys, dis = M.normalize_keys(km.global and km.global[id])
		local keys = vim.deepcopy(cfg_keys)
		for _, ek in ipairs((not dis and ext_global[id]) or {}) do
			if not vim.tbl_contains(keys, ek) then
				table.insert(keys, ek)
			end
		end
		local lbl = dis and "(disabled)" or M.format_keys(keys, "(opt-in)")
		push("Global", "global", id, mode, keys, cfg_keys, dis, lbl, desc, true, function()
			M.run_global_action(id)
		end)
	end
	for _, ex in ipairs(ext_extras) do
		push("Global", "global", ex.lhs, ex.mode, { ex.lhs }, {}, false, ex.lhs, ex.desc, false, function()
			if type(ex.callback) == "function" then
				ex.callback()
			elseif ex.rhs ~= "" then
				vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(ex.rhs, true, false, true), "m", false)
			end
		end)
	end

	local function push_scope(cat, scope, list, exec_fn)
		local tbl = km[scope] or {}
		for _, meta in ipairs(list) do
			local id, desc = meta[1], meta[2]
			local raw = tbl[id]
			local keys, dis = M.normalize_keys(raw)
			local fb = (scope == "chat" and id == "show_keys" and raw == false) and "(opt-in)" or "(disabled)"
			push(cat, scope, id, "n", keys, keys, dis, M.format_keys(keys, fb), desc, true, exec_fn)
		end
	end

	push_scope("Sidebar", "sidebar", SCHEMA.sidebar, function()
		local ok_ws, ws = pcall(require, "cc_workspace")
		if ok_ws then
			ws.enter(false, { skip_auto_chat = true })
			ws.focus_sidebar()
		end
	end)
	push_scope("Chat", "chat", SCHEMA.chat, function()
		M.run_global_action("focus_chat")
	end)
	push_scope("Switcher", "switcher", SCHEMA.switcher, function()
		M.run_global_action("switcher")
	end)

	for _, item in ipairs(SCHEMA.winbar_mouse) do
		push("Winbar Mouse", "winbar", item[1], "mouse", { item[1] }, {}, false, item[1], item[2], false, function()
			M.run_global_action(item[3])
		end)
	end
	for _, item in ipairs(SCHEMA.commands) do
		local k = ":" .. item[1]
		push("Commands", "commands", item[1], "cmd", { k }, {}, false, k, item[2], false, function()
			pcall(vim.api.nvim_cmd, { cmd = item[1] }, {})
		end)
	end
	return { entries = entries, by_scope = by_scope }
end

---Remove all buffer-local keymaps previously applied by `cc-workspace` on `buf`.
---@param buf integer
function M.clear_buffer_keymaps(buf)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	for _, item in ipairs(type(vim.b[buf]._cc_ws_bound_keys) == "table" and vim.b[buf]._cc_ws_bound_keys or {}) do
		if type(item) == "table" and type(item.mode) == "string" and type(item.lhs) == "string" then
			pcall(vim.api.nvim_buf_del_keymap, buf, item.mode, item.lhs)
		end
	end
	vim.b[buf]._cc_ws_bound_keys = {}
end

---Apply `{ spec, modes?, callback, desc }` bindings on `buf`, tracking them in `vim.b[buf]._cc_ws_bound_keys`.
---@param buf integer
---@param bindings { spec: any, modes?: string|string[], callback: fun(lhs: string), desc: string }[]
function M.bind_buffer_keymaps(buf, bindings)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	M.clear_buffer_keymaps(buf)
	local bound = {}
	local function set_one(m, lhs, cb, desc)
		vim.keymap.set(m, lhs, function()
			cb(lhs)
		end, { buffer = buf, nowait = true, silent = true, desc = "cc-workspace: " .. desc })
		table.insert(bound, { mode = m, lhs = lhs })
	end
	for _, b in ipairs(bindings) do
		if type(b.spec) == "table" and not vim.islist(b.spec) then
			for m, rhs_keys in pairs(b.spec) do
				for _, lhs in ipairs(M.normalize_keys(rhs_keys)) do
					set_one(m, lhs, b.callback, b.desc)
				end
			end
		else
			local modes = b.modes
			local mlist = type(modes) == "table" and modes or { type(modes) == "string" and modes or "n" }
			for _, lhs in ipairs(M.normalize_keys(b.spec)) do
				for _, m in ipairs(mlist) do
					set_one(m, lhs, b.callback, b.desc)
				end
			end
		end
	end
	vim.b[buf]._cc_ws_bound_keys = bound
end

---Apply (or hot-update) global opt-in `opts.keymaps.global` bindings cleanly.
function M.apply_global_keymaps()
	for _, item in ipairs(_bound_global_keys) do
		pcall(vim.keymap.del, item.mode, item.lhs)
	end
	_bound_global_keys = {}
	local gcfg = config.options and config.options.keymaps and config.options.keymaps.global
	if type(gcfg) ~= "table" then
		return
	end
	for _, meta in ipairs(SCHEMA.global) do
		local id, mode, desc = meta[1], meta[2], meta[3]
		for _, lhs in ipairs(M.normalize_keys(gcfg[id])) do
			vim.keymap.set(mode, lhs, function()
				M.run_global_action(id)
			end, { noremap = true, silent = true, desc = "cc-workspace: " .. desc })
			table.insert(_bound_global_keys, { mode = mode, lhs = lhs })
		end
	end
end

---Apply (or hot-update) workspace chat buffer keymaps (`stop`, `close`, `next_chat`, `previous_chat`, `show_keys`) on `buf`.
---@param buf integer
function M.apply_chat_buf_keymaps(buf)
	if not buf or not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= "codecompanion" then
		return
	end
	if config.options and config.options.chat_keymaps == false then
		M.clear_buffer_keymaps(buf)
		return
	end
	if vim.b[buf]._cc_ws_bound_keys == nil then
		for _, def in ipairs({ { "n", "q" }, { "n", "<C-c>" }, { "i", "<C-c>" }, { "n", "}" }, { "n", "{" } }) do
			pcall(vim.api.nvim_buf_del_keymap, buf, def[1], def[2])
		end
	end
	local ckm = (config.options and config.options.keymaps and config.options.keymaps.chat) or {}
	local function get_chat()
		local cm = package.loaded["codecompanion.interactions.chat"]
		return cm and type(cm.buf_get_chat) == "function" and cm.buf_get_chat(buf) or nil
	end
	local function on_stop()
		local chat = get_chat()
		if not chat then
			return
		end
		if chat.current_request or chat.tool_orchestrator then
			chat:stop()
			return
		end
		local ok_ws, ws = pcall(require, "cc_workspace")
		if ok_ws and ws.is_current_tab() then
			ws.focus_sidebar()
		elseif chat.ui and chat.ui:is_visible() then
			chat.ui:hide()
		end
	end
	local function on_close()
		vim.cmd("stopinsert")
		local chat = get_chat()
		local ok_ws, ws = pcall(require, "cc_workspace")
		if chat and ok_ws then
			ws.close_chat_safely(chat, false)
		end
	end
	local function make_cycle(dir)
		return function()
			local chat = get_chat()
			local ok_ws, ws = pcall(require, "cc_workspace")
			if chat and ok_ws then
				ws.cycle_chat(chat, dir)
			end
		end
	end

	M.bind_buffer_keymaps(buf, {
		{ spec = ckm.stop, modes = "n", desc = "Stop request, or focus sidebar / hide chat", callback = on_stop },
		{ spec = ckm.close, modes = { "n", "i" }, desc = "Close chat buffer safely", callback = on_close },
		{ spec = ckm.next_chat, modes = "n", desc = "Open next chat", callback = make_cycle(1) },
		{ spec = ckm.previous_chat, modes = "n", desc = "Open previous chat", callback = make_cycle(-1) },
		{
			spec = ckm.show_keys,
			modes = "n",
			desc = "Inspect AI Workspace keymaps",
			callback = function()
				M.show_keys({ mode = "picker" })
			end,
		},
	})
end

---Hot-update keymaps across all currently open `codecompanion` chat buffers.
function M.apply_chat_keymaps_to_open_buffers()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "codecompanion" then
			M.apply_chat_buf_keymaps(buf)
		end
	end
end

---Format a single short key token for compact footer display (`"<CR>"` -> `"Enter"`).
---@param spec any
---@return string|nil
local function primary_footer_key(spec)
	local k = M.normalize_keys(spec)[1]
	if not k then
		return nil
	end
	local up = k:upper()
	return (up == "<CR>" or up == "<RETURN>") and "Enter" or (up == "<SPACE>" and "Spc" or k)
end

---Build the 2 live shortcut legend lines for the AI Workspace sidebar footer.
---@param _content_width? integer
---@return string[]
function M.format_sidebar_footer(_content_width)
	---@type table<string, any>
	local sb = (config.options and config.options.keymaps and config.options.keymaps.sidebar)
		or (config.defaults.keymaps and config.defaults.keymaps.sidebar)
		or {}
	local row1, row2 = {}, {}
	for _, p in ipairs({
		{ "open", "open" },
		{ "add_project", "proj" },
		{ "new_worktree_chat", "wt" },
		{ "new_chat", "new" },
	}) do
		local k = primary_footer_key(sb[p[1]])
		if k then
			table.insert(row1, k .. ":" .. p[2])
		end
	end
	local y1, y2 = primary_footer_key(sb.yank_path), primary_footer_key(sb.yank_all_paths)
	if y1 and y2 then
		table.insert(row2, y1 .. "/" .. y2 .. ":copy")
	elseif y1 or y2 then
		table.insert(row2, (y1 or y2) .. ":copy")
	end
	for _, p in ipairs({ { "delete", "del" }, { "open_code_tab", "code" }, { "leave", "back" } }) do
		local k = primary_footer_key(sb[p[1]])
		if k then
			table.insert(row2, k .. ":" .. p[2])
		end
	end
	return { "  " .. table.concat(row1, "  "), "  " .. table.concat(row2, "  ") }
end

---Synchronize rendered sidebar footer lines if `render` left stale footer text.
local function sync_sidebar_footer_lines()
	local ok_st, state_mod = pcall(require, "cc_workspace.state")
	local sbuf = ok_st and state_mod.state.sidebar_buf or nil
	if type(sbuf) ~= "number" or not vim.api.nvim_buf_is_valid(sbuf) then
		return
	end
	local ok_r, render = pcall(require, "cc_workspace.render")
	if ok_r and type(render.render) == "function" then
		render.render()
	end
	local cw = state_mod.get_sidebar_width() - 1
	local footer = M.format_sidebar_footer(cw)
	local cur_lines = vim.api.nvim_buf_get_lines(sbuf, 0, -1, false)
	if #cur_lines >= 3 then
		local l1 = state_mod.truncate_display(footer[1] or "", cw)
		local l2 = state_mod.truncate_display(footer[2] or "", cw)
		if cur_lines[#cur_lines - 1] ~= l1 or cur_lines[#cur_lines] ~= l2 then
			vim.bo[sbuf].modifiable = true
			vim.api.nvim_buf_set_lines(sbuf, #cur_lines - 2, #cur_lines, false, { l1, l2 })
			vim.bo[sbuf].modifiable = false
			local ns = state_mod.state.ns
			pcall(vim.api.nvim_buf_set_extmark, sbuf, ns, #cur_lines - 2, 0, { end_col = #l1, hl_group = "CcWsMuted" })
			pcall(vim.api.nvim_buf_set_extmark, sbuf, ns, #cur_lines - 1, 0, { end_col = #l2, hl_group = "CcWsMuted" })
			state_mod.state.last_rendered_lines = vim.api.nvim_buf_get_lines(sbuf, 0, -1, false)
			state_mod.state.last_rendered_tick = vim.api.nvim_buf_get_changedtick(sbuf)
		end
	end
end

---Dynamically override keymaps at runtime, cleaning old keys and hot-rebinding open buffers & floats.
---@param overrides CcWorkspaceKeymapsConfig
---@return CcWorkspaceKeymapsConfig
function M.set_keymaps(overrides)
	if type(overrides) ~= "table" then
		return M.get_keymaps()
	end
	config.options.keymaps = config.merge_keymaps(config.options.keymaps, overrides)
	M.apply_global_keymaps()

	local ok_p, patches = pcall(require, "cc_workspace.patches")
	if ok_p and type(patches.register_chat_keymaps) == "function" then
		patches.register_chat_keymaps()
	end
	M.apply_chat_keymaps_to_open_buffers()

	local ok_st, state_mod = pcall(require, "cc_workspace.state")
	local ok_sb, sidebar = pcall(require, "cc_workspace.sidebar")
	if ok_st and state_mod.state.sidebar_buf and vim.api.nvim_buf_is_valid(state_mod.state.sidebar_buf) then
		if ok_sb and type(sidebar.apply_sidebar_keymaps) == "function" then
			sidebar.apply_sidebar_keymaps(state_mod.state.sidebar_buf)
		end
		sync_sidebar_footer_lines()
	end
	if ok_sb and type(sidebar.refresh_help_float) == "function" then
		sidebar.refresh_help_float()
	end

	local ok_sw, switcher = pcall(require, "cc_workspace.switcher")
	if ok_sw and type(switcher.refresh_keymaps) == "function" then
		switcher.refresh_keymaps()
	end
	return M.get_keymaps()
end

---Parse user text input from `<C-r>` prompt into a normalized `CcWorkspaceKeySpec`.
---@param raw string
---@return CcWorkspaceKeySpec
local function parse_rebind_input(raw)
	local trimmed = vim.trim(raw)
	local lc = trimmed:lower()
	if trimmed == "" or lc == "false" or lc == "off" or lc == "none" or lc == "disable" then
		return false
	end
	if trimmed == "," then
		return ","
	end
	local parts = {}
	for tok in raw:gmatch("[^,]+") do
		local k = tok == " " and " " or vim.trim(tok)
		if k ~= "" then
			table.insert(parts, k)
		end
	end
	return #parts == 0 and false or (#parts == 1 and parts[1] or parts)
end

---Prompt user via `vim.ui.input` to live-rebind a selected Telescope entry (`<C-r>`).
---@param item table|nil
---@param close_fn fun()
local function prompt_rebind_entry(item, close_fn)
	if not item or not item.rebindable then
		vim.notify("Selected item is read-only and cannot be rebound", vim.log.levels.WARN, {
			title = "AI Workspace Keymaps",
		})
		return
	end
	close_fn()
	local prompt = string.format("Rebind [%s] %s (comma aliases, or 'false' to disable): ", item.category, item.action)
	local cur_default = table.concat(item.configured_keys or {}, ", ")
	vim.schedule(function()
		vim.ui.input({ prompt = prompt, default = cur_default }, function(input)
			if input ~= nil then
				local new_spec = parse_rebind_input(input)
				M.set_keymaps({ [item.scope] = { [item.action] = new_spec } })
				local msg_rhs = new_spec == false and "disabled (false)" or M.format_keys(M.normalize_keys(new_spec))
				vim.notify(
					string.format("Updated %s.%s -> %s", item.scope, item.action, msg_rhs),
					vim.log.levels.INFO,
					{ title = "AI Workspace Keymaps" }
				)
			end
			vim.schedule(function()
				M.show_keys({ mode = "picker" })
			end)
		end)
	end)
end

---Close the active floating shortcuts cheatsheet, if open.
function M.close_help_float()
	local ok_sb, sidebar = pcall(require, "cc_workspace.sidebar")
	if ok_sb and type(sidebar.close_help_float) == "function" then
		sidebar.close_help_float()
	end
end

---Return the currently open floating shortcuts cheatsheet window and buffer IDs, if open.
---@return integer|nil win, integer|nil buf
function M.get_help_float_win()
	local ok_sb, sidebar = pcall(require, "cc_workspace.sidebar")
	if ok_sb and type(sidebar.get_help_float_win) == "function" then
		return sidebar.get_help_float_win()
	end
	return nil, nil
end

---Open the Telescope Keymaps Explorer (`:CodeCompanionWorkspaceKeys` / `<leader>ck`), or Floating Cheatsheet (`mode = "float"`).
---@param opts? string|{ mode?: "picker"|"float" }
---@return table
function M.show_keys(opts)
	local mode = type(opts) == "string" and opts ~= "" and opts
		or (type(opts) == "table" and type(opts.mode) == "string" and opts.mode)
		or "picker"
	if vim.fn.mode():sub(1, 1) == "i" then
		vim.cmd("stopinsert")
	end
	local function open_float_view()
		local ok_sb, sidebar = pcall(require, "cc_workspace.sidebar")
		return (ok_sb and type(sidebar.show_help_float) == "function") and sidebar.show_help_float()
			or { mode = "float" }
	end
	if mode == "float" then
		return open_float_view()
	end

	local ok_tp, tp_pickers = pcall(require, "telescope.pickers")
	local ok_tf, tp_finders = pcall(require, "telescope.finders")
	local ok_tc, tp_conf = pcall(require, "telescope.config")
	local ok_ta, tp_actions = pcall(require, "telescope.actions")
	local ok_ts, tp_state = pcall(require, "telescope.actions.state")
	local ok_td, tp_display = pcall(require, "telescope.pickers.entry_display")
	if not (ok_tp and ok_tf and ok_tc and ok_ta and ok_ts and ok_td) then
		local fl = open_float_view()
		fl.fallback = "float"
		return fl
	end

	local entries = M.get_effective_keymaps().entries
	local cat_hls = {
		["Global"] = "DiagnosticInfo",
		["Sidebar"] = "Function",
		["Chat"] = "DiagnosticOk",
		["Switcher"] = "Special",
		["Winbar Mouse"] = "Constant",
		["Commands"] = "Directory",
	}
	local displayer = tp_display.create({
		separator = "  ",
		items = { { width = 14 }, { width = 22 }, { remaining = true } },
	})
	local title =
		string.format("%sAI Workspace Keymaps (<CR>: Run/Focus · <C-r>: Live Rebind)", icons.get("aichat", true).Chat)

	local picker = tp_pickers.new({
		layout_strategy = "horizontal",
		layout_config = { width = 0.84, height = 0.78, prompt_position = "top" },
		sorting_strategy = "ascending",
	}, {
		prompt_title = title,
		finder = tp_finders.new_table({
			results = entries,
			entry_maker = function(entry)
				local cat_tag = "[" .. entry.category .. "]"
				local key_hl = (entry.disabled or entry.key_label == "(opt-in)") and "Comment" or "Special"
				local rhs_desc = entry.rebindable
						and string.format("%s  (%s.%s)", entry.desc, entry.scope, entry.action)
					or entry.desc
				return {
					value = entry,
					ordinal = table.concat({ cat_tag, entry.key_label, entry.action, entry.desc }, " "),
					display = function()
						return displayer({
							{ cat_tag, cat_hls[entry.category] or "Identifier" },
							{ entry.key_label, key_hl },
							{ rhs_desc, entry.disabled and "Comment" or "Normal" },
						})
					end,
				}
			end,
		}),
		sorter = tp_conf.values.generic_sorter({}),
		attach_mappings = function(prompt_bufnr, map)
			tp_actions.select_default:replace(function()
				local sel = tp_state.get_selected_entry()
				tp_actions.close(prompt_bufnr)
				if sel and sel.value and type(sel.value.execute) == "function" then
					vim.schedule(sel.value.execute)
				end
			end)
			local function on_rebind()
				local sel = tp_state.get_selected_entry()
				prompt_rebind_entry(sel and sel.value or nil, function()
					tp_actions.close(prompt_bufnr)
				end)
			end
			map("i", "<C-r>", on_rebind)
			map("n", "<C-r>", on_rebind)
			return true
		end,
	})
	picker:find()
	return { mode = "picker", buf = picker.prompt_bufnr, win = picker.prompt_win, entries = entries, picker = picker }
end

return M
