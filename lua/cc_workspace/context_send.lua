-- Visual selection capture, fenced codeblock forwarding, code-tab side-chat split
-- management (`toggle_side_chat`, `focus_or_open_chat`, `new_smart_chat`, `cycle_chat`).

local history_restore = require("cc_workspace.history_restore")
local patches = require("cc_workspace.patches")
local paths = require("cc_workspace.paths")
local projects = require("cc_workspace.projects")
local state_mod = require("cc_workspace.state")

local state = state_mod.state

local M = {}

local function get_layout()
	local ok, mod = pcall(require, "cc_workspace.layout")
	return (ok and type(mod) == "table") and mod or nil
end

---Find the first tiled `codecompanion` split window (and its buffer) in the given tabpage.
---@param tabpage? integer
---@return integer|nil win, integer|nil buf
function M.find_tab_chat_split(tabpage)
	for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tabpage or 0)) do
		if state_mod.is_split_win(w) then
			local b = vim.api.nvim_win_get_buf(w)
			if vim.bo[b].filetype == "codecompanion" then
				return w, b
			end
		end
	end
	return nil, nil
end

---Find the active or first tiled normal code buffer in the current tabpage.
---@return integer|nil
function M.find_tab_code_buf()
	local cur_buf = vim.api.nvim_get_current_buf()
	if vim.bo[cur_buf].buftype == "" and vim.bo[cur_buf].filetype ~= "codecompanion" then
		return cur_buf
	end
	for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if state_mod.is_split_win(w) then
			local b = vim.api.nvim_win_get_buf(w)
			if vim.bo[b].buftype == "" and vim.bo[b].filetype ~= "codecompanion" then
				return b
			end
		end
	end
	return nil
end

---Show `target` inside an existing split window `win` (or open a new code-tab split), sync `lcd`, and mark read.
---@param target table
---@param preferred_win? integer
---@param open_opts? table
function M.open_in_code_tab_split(target, preferred_win, open_opts)
	local wt = state_mod.get_wt()
	local target_cwd = paths.get_valid_chat_cwd(target)

	local function mount_existing(win)
		target.hidden = false
		target.ui:show_in_win({ winnr = win, window_opts = { default = true } })
		vim.t.cc_last_side_chat_buf = target.bufnr
		paths.sync_win_lcd(win, target_cwd)
		vim.api.nvim_set_current_win(win)
		if wt and type(wt.mark_read) == "function" then
			pcall(wt.mark_read, target.bufnr)
		end
		state_mod.refresh_winbars()
	end

	if
		preferred_win
		and state_mod.is_split_win(preferred_win)
		and vim.api.nvim_win_get_tabpage(preferred_win) == vim.api.nvim_get_current_tabpage()
		and vim.bo[vim.api.nvim_win_get_buf(preferred_win)].filetype == "codecompanion"
	then
		return mount_existing(preferred_win)
	end

	local existing_win = M.find_tab_chat_split(0)
	if existing_win then
		return mount_existing(existing_win)
	end

	if target.ui then
		if target.ui:is_visible_non_curtab() then
			target.ui.winnr = nil
		end
		target.ui:open(vim.tbl_extend("force", { window_opts = { default = true } }, open_opts or {}))
		vim.t.cc_last_side_chat_buf = target.bufnr
		if target.ui.winnr and vim.api.nvim_win_is_valid(target.ui.winnr) then
			paths.sync_win_lcd(target.ui.winnr, target_cwd)
		end
		if wt and type(wt.mark_read) == "function" then
			pcall(wt.mark_read, target.bufnr)
		end
		state_mod.refresh_winbars()
	end
end

---Display an existing chat in the current tab's chat pane (or workspace `main_win`), or open a vertical split.
---@param target table
---@param preferred_win? integer
function M.focus_or_open_chat(target, preferred_win)
	if not target or not vim.api.nvim_buf_is_valid(target.bufnr) then
		return
	end
	if state_mod.is_current_tab() then
		local lay = get_layout()
		if lay and type(lay.show_chat) == "function" then
			lay.show_chat(target, true)
		end
		return
	end
	M.open_in_code_tab_split(target, preferred_win)
end

---Create a new chat in-place (reusing the current tab's chat pane or workspace `main_win` without killing background tabs).
---@return table|nil
function M.new_smart_chat()
	if state_mod.is_current_tab() then
		local lay = get_layout()
		return (lay and type(lay.new_chat) == "function") and lay.new_chat(true) or nil
	end
	require("codecompanion")
	patches.patch_codecompanion_cwd()
	local code_buf = M.find_tab_code_buf()
	local target_cwd = projects.resolve_context_project_dir(code_buf)

	-- Always create with `hidden = true` first so `Chat.close_last_chat()` never destroys `state.main_win` in `ws_tab`
	local chat = history_restore.create_scoped_chat(target_cwd, code_buf, true)
	if chat then
		chat.opts = chat.opts or {}
		chat.opts.cwd = target_cwd
		M.focus_or_open_chat(chat)
	end
	return chat
end

---Cycle to the next or previous chat buffer (`}` / `{`) without leaking into CLI terminal buffers.
---@param chat table
---@param delta integer
function M.cycle_chat(chat, delta)
	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	if not chat or not chat_mod then
		return
	end
	local all = chat_mod.buf_get_chat()
	local chats = {}
	local cur_tab = vim.api.nvim_get_current_tabpage()
	local in_ws = state_mod.is_current_tab()
	for _, entry in ipairs(type(all) == "table" and all or {}) do
		local c = entry.chat
		if c and vim.api.nvim_buf_is_valid(c.bufnr) then
			if in_ws or c.bufnr == chat.bufnr or not state_mod.is_buf_visible_in_other_tab(c.bufnr, cur_tab) then
				table.insert(chats, c)
			end
		end
	end
	table.sort(chats, function(a, b)
		return a.bufnr < b.bufnr
	end)
	if #chats <= 1 then
		return
	end
	local cur_idx = nil
	for i, c in ipairs(chats) do
		if c.bufnr == chat.bufnr then
			cur_idx = i
			break
		end
	end
	if cur_idx then
		local next_idx = delta > 0 and ((cur_idx % #chats) + 1) or (((cur_idx - 2 + #chats) % #chats) + 1)
		if chats[next_idx] then
			M.focus_or_open_chat(chats[next_idx])
		end
	end
end

---Capture the active visual selection (or last `'<,'>` marks) and exit visual mode.
---@return string[] lines, string filetype, integer src_buf
function M.capture_visual_selection()
	local src_buf = vim.api.nvim_get_current_buf()
	local ft = vim.bo[src_buf].filetype or ""
	local cur_mode = vim.fn.mode()
	local sel_lines = {}
	if cur_mode:match("^[vV\22]") then
		local ok_r, res = pcall(vim.fn.getregion, vim.fn.getpos("v"), vim.fn.getpos("."), { type = cur_mode })
		sel_lines = (ok_r and type(res) == "table") and res or {}
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
	else
		local pos_start, pos_end = vim.fn.getpos("'<"), vim.fn.getpos("'>")
		if pos_start[2] > 0 and pos_end[2] > 0 then
			local vmode = vim.fn.visualmode()
			local ok_r, res = pcall(vim.fn.getregion, pos_start, pos_end, { type = vmode ~= "" and vmode or "V" })
			sel_lines = (ok_r and type(res) == "table") and res or {}
		end
	end
	return sel_lines, ft, src_buf
end

---Append captured code lines as a fenced markdown block into `chat` safely (even if buffer is locked).
---@param chat table|nil
---@param sel_lines string[]
---@param ft string
---@param rel_path string
---@param target_win? integer
function M.append_selection_to_chat(chat, sel_lines, ft, rel_path, target_win)
	if not chat or not vim.api.nvim_buf_is_valid(chat.bufnr) or #sel_lines == 0 then
		return
	end
	local header = rel_path ~= ""
			and (ft ~= "" and string.format("%s {%s}", ft, rel_path) or string.format("{%s}", rel_path))
		or ft
	local block = require("codecompanion.utils.markdown").form_codeblock(table.concat(sel_lines, "\n"), { ft = header })
	pcall(
		vim.api.nvim_buf_clear_namespace,
		chat.bufnr,
		vim.api.nvim_create_namespace("CodeCompanion-virtual_text"),
		0,
		-1
	)
	if chat.prompt and type(chat.prompt.add) == "function" then
		chat.prompt:add({ content = block .. "\n\n" })
	else
		local was_locked = not vim.bo[chat.bufnr].modifiable
		if was_locked and chat.ui and chat.ui.unlock_buf then
			chat.ui:unlock_buf()
		end
		local lc = vim.api.nvim_buf_line_count(chat.bufnr)
		pcall(
			vim.api.nvim_buf_set_lines,
			chat.bufnr,
			lc,
			lc,
			false,
			vim.split("\n" .. block .. "\n", "\n", { plain = true })
		)
		if was_locked and chat.ui and chat.ui.lock_buf then
			chat.ui:lock_buf()
		end
	end
	local win = target_win or vim.fn.bufwinid(chat.bufnr)
	if win and win ~= -1 and vim.api.nvim_win_is_valid(win) then
		pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(chat.bufnr), 0 })
	end
end

---Send the current visual selection into the AI Workspace's matching Project chat and focus the chat pane.
function M.send_visual_selection()
	local sel_lines, ft, src_buf = M.capture_visual_selection()
	local lay = #sel_lines > 0 and get_layout() or nil
	if not lay then
		return
	end
	local src_proj = not state_mod.is_current_tab() and projects.resolve_context_project_dir(src_buf) or nil
	lay.enter(true, { target_project = src_proj })

	local chat_mod = require("codecompanion.interactions.chat")
	local mbuf = state.main_win
		and vim.api.nvim_win_is_valid(state.main_win)
		and vim.api.nvim_win_get_buf(state.main_win)
	local chat = (mbuf and chat_mod.buf_get_chat(mbuf)) or lay.new_chat(true, src_proj)
	local rel_path = paths.compute_buf_rel_path(src_buf, paths.get_valid_chat_cwd(chat) or src_proj)
	M.append_selection_to_chat(chat, sel_lines, ft, rel_path, state.main_win)
end

---Add the current visual selection into the current tab's side chat (scoped to the current buffer's Project).
function M.add_visual_to_chat()
	if state_mod.is_current_tab() then
		return M.send_visual_selection()
	end
	local sel_lines, ft, src_buf = M.capture_visual_selection()
	if #sel_lines == 0 then
		return
	end
	require("codecompanion")
	patches.patch_codecompanion_cwd()
	local chat_mod = require("codecompanion.interactions.chat")
	local _, split_buf = M.find_tab_chat_split(0)
	local src_proj = projects.resolve_context_project_dir(src_buf)
	local chat = (split_buf and chat_mod.buf_get_chat(split_buf))
		or projects.find_active_chat_for_project(src_proj)
		or M.new_smart_chat()
	if not chat then
		return
	end
	M.focus_or_open_chat(chat)
	local rel_path = paths.compute_buf_rel_path(src_buf, paths.get_valid_chat_cwd(chat) or src_proj)
	M.append_selection_to_chat(chat, sel_lines, ft, rel_path, vim.api.nvim_get_current_win())
end

---Toggle a side-panel chat in normal code tabs without disturbing the AI Workspace tab.
function M.toggle_side_chat()
	if state_mod.is_current_tab() then
		local lay = get_layout()
		if lay and type(lay.leave) == "function" then
			lay.leave()
		end
		return
	end
	require("codecompanion")
	patches.patch_codecompanion_cwd()
	local chat_mod = require("codecompanion.interactions.chat")

	local split_win, split_buf = M.find_tab_chat_split(0)
	if split_win and split_buf then
		vim.t.cc_last_side_chat_buf = split_buf
		local c = chat_mod.buf_get_chat(split_buf)
		if c and c.ui then
			c.ui.winnr, c.ui.window_opts = split_win, nil
			c.ui:hide()
		else
			pcall(vim.api.nvim_win_hide, split_win)
		end
		return
	end

	local code_buf = vim.api.nvim_get_current_buf()
	local cur_tab = vim.api.nvim_get_current_tabpage()
	local target = nil
	local prev_side_buf = vim.t.cc_last_side_chat_buf
	if type(prev_side_buf) == "number" and vim.api.nvim_buf_is_valid(prev_side_buf) then
		local prev_chat = chat_mod.buf_get_chat(prev_side_buf)
		if prev_chat and not state_mod.is_buf_visible_in_other_tab(prev_chat.bufnr, cur_tab) then
			target = prev_chat
		end
	end
	if not target then
		target = projects.find_active_chat_for_project(projects.resolve_context_project_dir(code_buf))
	end
	if not target and vim.api.nvim_buf_get_name(code_buf) == "" then
		local last = chat_mod.last_chat()
		if
			last
			and vim.api.nvim_buf_is_valid(last.bufnr)
			and not state_mod.is_buf_visible_in_other_tab(last.bufnr, cur_tab)
		then
			target = last
		end
	end

	if target and vim.api.nvim_buf_is_valid(target.bufnr) then
		local target_cwd = paths.get_valid_chat_cwd(target)
		if vim.bo[code_buf].buftype == "" and vim.bo[code_buf].filetype ~= "codecompanion" then
			if not target_cwd or paths.buf_within_dir(code_buf, target_cwd) then
				target.buffer_context = paths.with_temp_cwd(target_cwd, function()
					return require("codecompanion.utils.context").get(code_buf)
				end) or target.buffer_context
			end
		end
		M.open_in_code_tab_split(target, nil, { toggled = true })
		return
	end
	M.new_smart_chat()
end

return M
