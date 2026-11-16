-- Standalone headless E2E test suite for `cc-workspace.nvim`.
-- Run via:
--   nvim --headless --cmd 'set rtp+=/Users/jeffreyguan/Documents/code/cc-workspace.nvim' -l /Users/jeffreyguan/Documents/code/cc-workspace.nvim/tests/run_headless.lua

local passed = 0
local failed = 0
local failures = {}

local function check(cond, label, detail)
	if cond then
		passed = passed + 1
	else
		failed = failed + 1
		local msg = detail and string.format("%s (%s)", label, tostring(detail)) or label
		table.insert(failures, msg)
		io.stderr:write("FAIL: " .. msg .. "\n")
	end
end

local function file_sha256(path)
	local st = vim.uv.fs_stat(path)
	if not st then
		return "MISSING"
	end
	local fd = vim.uv.fs_open(path, "r", 438)
	if not fd then
		return "UNREADABLE"
	end
	local data = vim.uv.fs_read(fd, st.size, 0) or ""
	vim.uv.fs_close(fd)
	return vim.fn.sha256(data)
end

local function run_cmd_sync(cmd, cwd)
	local res = vim.system(cmd, { cwd = cwd, text = true }):wait(10000)
	assert(
		res and res.code == 0,
		string.format("command failed (%s): %s", table.concat(cmd, " "), (res and res.stderr) or "")
	)
	return res.stdout or ""
end

local user_projects_json = vim.fn.stdpath("data") .. "/cc-workspace-projects.json"
local user_history_index = vim.fn.stdpath("data") .. "/codecompanion-history/index.json"
local before_projects_sha = file_sha256(user_projects_json)
local before_history_sha = file_sha256(user_history_index)

local tmp_root = vim.fn.tempname()
vim.fn.mkdir(tmp_root, "p")

-- ============================================================================
-- Deterministic standalone CodeCompanion test harness (zero external processes)
-- ============================================================================
local mock_chats = {}
local mock_last_chat = nil
local mock_saved_history = {}
local mock_adapter_picker_buf = nil
local mock_notifications = {}
local mock_lualine_refreshes = 0

local orig_notify = vim.notify
vim.notify = function(msg, level, opts)
	table.insert(mock_notifications, {
		msg = tostring(msg),
		level = level,
		opts = opts,
	})
end

package.loaded["lualine"] = {
	refresh = function(opts)
		if type(opts) == "table" and type(opts.place) == "table" and opts.place[1] == "statusline" then
			mock_lualine_refreshes = mock_lualine_refreshes + 1
		end
	end,
}

local chat_mod = {}

function chat_mod.new(args)
	args = type(args) == "table" and args or {}
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].filetype = "codecompanion"
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].swapfile = false
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "## Me", "", tostring(args.title or "") })

	local chat = {
		bufnr = buf,
		hidden = args.hidden == true,
		tokens = args.tokens or 1420,
		cycle = 1,
		messages = args.messages or {},
		buffer_context = args.buffer_context or {},
		opts = {
			cwd = args.cwd,
			save_id = args.save_id,
			title = args.title,
		},
		adapter = {
			name = "omp",
			formatted_name = "oh-my-pi",
			type = "acp",
			schema = {
				model = { default = "anthropic/claude-sonnet-4" },
			},
		},
		acp_connection = {
			get_config_options = function()
				return {
					{ category = "model", currentValue = "anthropic/claude-sonnet-4" },
					{ category = "mode", currentValue = "agent" },
				}
			end,
		},
	}

	chat.ui = {
		winnr = nil,
		show_in_win = function(self, spec)
			local w = spec and spec.winnr
			if w and vim.api.nvim_win_is_valid(w) then
				vim.api.nvim_win_set_buf(w, chat.bufnr)
				self.winnr = w
				vim.api.nvim_exec_autocmds("User", {
					pattern = "CodeCompanionChatOpened",
					data = { bufnr = chat.bufnr, interaction = "chat" },
				})
			end
		end,
		open = function(self)
			for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
				if vim.api.nvim_win_get_buf(w) == chat.bufnr then
					self.winnr = w
					vim.api.nvim_set_current_win(w)
					return
				end
			end
			vim.cmd("botright vsplit")
			local w = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(w, chat.bufnr)
			self.winnr = w
			vim.api.nvim_exec_autocmds("User", {
				pattern = "CodeCompanionChatOpened",
				data = { bufnr = chat.bufnr, interaction = "chat" },
			})
		end,
		hide = function(self)
			local w = self.winnr or vim.fn.bufwinid(chat.bufnr)
			if w and w ~= -1 and vim.api.nvim_win_is_valid(w) and #vim.api.nvim_tabpage_list_wins(0) > 1 then
				pcall(vim.api.nvim_win_hide, w)
			end
			self.winnr = nil
		end,
		is_visible = function()
			return vim.fn.bufwinid(chat.bufnr) ~= -1
		end,
		is_visible_non_curtab = function()
			local cur_tp = vim.api.nvim_get_current_tabpage()
			for _, w in ipairs(vim.fn.win_findbuf(chat.bufnr) or {}) do
				if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_tabpage(w) ~= cur_tp then
					return true
				end
			end
			return false
		end,
		lock_buf = function()
			if vim.api.nvim_buf_is_valid(chat.bufnr) then
				vim.bo[chat.bufnr].modifiable = false
			end
		end,
		unlock_buf = function()
			if vim.api.nvim_buf_is_valid(chat.bufnr) then
				vim.bo[chat.bufnr].modifiable = true
			end
		end,
	}

	function chat:set_title(title)
		self.opts.title = title
		self.title = title
		vim.api.nvim_exec_autocmds("User", {
			pattern = "CodeCompanionChatTitle",
			data = { bufnr = self.bufnr, title = title },
		})
	end

	function chat:close()
		for i = #mock_chats, 1, -1 do
			if mock_chats[i].bufnr == self.bufnr then
				table.remove(mock_chats, i)
			end
		end
		if mock_last_chat and mock_last_chat.bufnr == self.bufnr then
			mock_last_chat = mock_chats[#mock_chats]
		end
		vim.api.nvim_exec_autocmds("User", {
			pattern = "CodeCompanionChatClosed",
			data = { bufnr = self.bufnr, interaction = "chat" },
		})
		if vim.api.nvim_buf_is_valid(self.bufnr) then
			pcall(vim.api.nvim_buf_delete, self.bufnr, { force = true })
		end
	end

	table.insert(mock_chats, chat)
	mock_last_chat = chat

	vim.api.nvim_exec_autocmds("User", {
		pattern = "CodeCompanionChatCreated",
		data = { bufnr = buf, interaction = "chat" },
	})

	if not chat.hidden then
		chat.ui:open()
	end
	return chat
end

function chat_mod.buf_get_chat(bufnr)
	if bufnr == nil then
		local out = {}
		for _, c in ipairs(mock_chats) do
			if vim.api.nvim_buf_is_valid(c.bufnr) then
				table.insert(out, { bufnr = c.bufnr, chat = c })
			end
		end
		return out
	end
	local target = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
	for _, c in ipairs(mock_chats) do
		if c.bufnr == target and vim.api.nvim_buf_is_valid(c.bufnr) then
			return c
		end
	end
	return nil
end

function chat_mod.last_chat()
	if mock_last_chat and vim.api.nvim_buf_is_valid(mock_last_chat.bufnr) then
		return mock_last_chat
	end
	for i = #mock_chats, 1, -1 do
		if vim.api.nvim_buf_is_valid(mock_chats[i].bufnr) then
			mock_last_chat = mock_chats[i]
			return mock_last_chat
		end
	end
	return nil
end

package.preload["codecompanion.interactions.chat"] = function()
	return chat_mod
end

package.preload["codecompanion.utils.context"] = function()
	return {
		get = function(bufnr)
			local b = (type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)) and bufnr
				or vim.api.nvim_get_current_buf()
			local name = vim.api.nvim_buf_get_name(b)
			return {
				bufnr = b,
				buftype = vim.bo[b].buftype,
				filetype = vim.bo[b].filetype,
				filename = name,
				path = name,
				relative_path = name ~= "" and vim.fn.fnamemodify(name, ":.") or "",
				lines = {},
				line_count = 0,
				is_normal = true,
				is_visual = false,
				code = false,
			}
		end,
	}
end

package.preload["codecompanion.utils.markdown"] = function()
	return {
		form_codeblock = function(text, opts)
			return string.format("```%s\n%s\n```", (opts and opts.ft) or "", text or "")
		end,
	}
end

package.preload["codecompanion.interactions.chat.keymaps.change_adapter"] = function()
	return {
		callback = function(chat)
			mock_adapter_picker_buf = chat and chat.bufnr or nil
		end,
	}
end

package.preload["codecompanion.interactions.cli"] = function()
	return {
		find_by_agent = function()
			return nil
		end,
		get_visible = function()
			return nil
		end,
	}
end

package.preload["codecompanion"] = function()
	return {
		last_chat = chat_mod.last_chat,
		chat = function(args)
			return chat_mod.new(args)
		end,
		cli = function() end,
		extensions = {
			history = {
				get_location = function()
					return tmp_root .. "/history"
				end,
				get_chats = function()
					return mock_saved_history
				end,
				load_chat = function(save_id)
					return mock_saved_history[save_id]
				end,
			},
		},
	}
end

local function create_git_repo(dir, branch_name)
	vim.fn.mkdir(dir, "p")
	run_cmd_sync({ "git", "init", "-b", branch_name or "main" }, dir)
	run_cmd_sync({ "git", "config", "user.email", "test@example.com" }, dir)
	run_cmd_sync({ "git", "config", "user.name", "Test Runner" }, dir)
	local readme = dir .. "/README.md"
	local fd = assert(vim.uv.fs_open(readme, "w", 420))
	vim.uv.fs_write(fd, "# " .. vim.fs.basename(dir) .. "\n", 0)
	vim.uv.fs_close(fd)
	run_cmd_sync({ "git", "add", "README.md" }, dir)
	run_cmd_sync({ "git", "commit", "-m", "initial commit" }, dir)
	run_cmd_sync({ "git", "branch", "existing-branch" }, dir)
end

local ok_suite, suite_err = xpcall(function()
	vim.o.columns = 180
	vim.o.lines = 48
	vim.o.laststatus = 3
	vim.o.showtabline = 2

	local tmp_projects_file = tmp_root .. "/cc-workspace-projects.json"
	local tmp_worktrees_dir = tmp_root .. "/cc-worktrees"
	vim.fn.mkdir(tmp_worktrees_dir, "p")
	vim.fn.mkdir(tmp_root .. "/history", "p")

	local repo_alpha = tmp_root .. "/repos/alpha-service"
	local repo_beta = tmp_root .. "/repos/beta-engine"
	local dup_one = tmp_root .. "/suite_a/open_source/libboundscheck"
	local dup_two = tmp_root .. "/suite_b/open_source/libboundscheck"
	create_git_repo(repo_alpha, "main")
	create_git_repo(repo_beta, "main")
	vim.fn.mkdir(dup_one, "p")
	vim.fn.mkdir(dup_two, "p")

	-- ========================================================================
	-- 1. Core Setup, Icons & CodeCompanion Extension Contract
	-- ========================================================================
	local ext = require("codecompanion._extensions.workspace")
	check(type(ext) == "table" and type(ext.setup) == "function", "extension exports setup()")
	check(type(ext.exports) == "table", "extension exports table")

	local ws = require("cc_workspace")
	local icons = require("cc_workspace.icons")
	local wt = require("cc_workspace.worktree")
	local winbar = require("cc_workspace.winbar")
	local statusline = require("cc_workspace.statusline")
	local switcher = require("cc_workspace.switcher")

	ws.setup({
		projects_file = tmp_projects_file,
		worktrees_base_dir = tmp_worktrees_dir,
		notifications = true,
	})
	ws.set_projects_file(tmp_projects_file)
	wt.set_worktrees_base_dir(tmp_worktrees_dir)

	check(
		ws.get_projects_file() == wt.normalize_path(tmp_projects_file) or ws.get_projects_file() == tmp_projects_file,
		"isolated projects_file configured"
	)
	check(icons.get("aichat", true).Chat == "󱜸 ", "icons.get('aichat', true).Chat default")
	check(icons.ui.Folder == "", "icons.ui.Folder default")
	check(icons.git.Branch == "", "icons.git.Branch default")
	check(vim.fn.exists(":CodeCompanionWorkspace") == 2, ":CodeCompanionWorkspace command registered")
	check(
		vim.fn.exists(":CodeCompanionWorkspaceAddProject") == 2,
		":CodeCompanionWorkspaceAddProject command registered"
	)
	check(vim.fn.exists(":CodeCompanionWorkspaceWorktree") == 2, ":CodeCompanionWorkspaceWorktree command registered")
	check(
		vim.fn.exists(":CodeCompanionNotificationsToggle") == 2,
		":CodeCompanionNotificationsToggle command registered"
	)
	check(
		ws.worktree == wt and ws.winbar == winbar and ws.statusline == statusline and ws.switcher == switcher,
		"ws lazy sub-module accessors"
	)

	-- ========================================================================
	-- 2. Git Worktree Discovery, Creation & Removal Safety
	-- ========================================================================
	local norm_alpha = wt.normalize_path(repo_alpha)
	local norm_beta = wt.normalize_path(repo_beta)
	check(wt.get_repo_root(repo_alpha) == norm_alpha, "get_repo_root resolves main repo")
	check(wt.get_worktree_branch(repo_alpha) == "main", "get_worktree_branch resolves main branch")
	check(wt.is_linked_worktree(repo_alpha) == false, "main repo is not a linked worktree")

	local created_wt = nil
	local create_err = nil
	wt.create_worktree(repo_alpha, { branch = "feat/ui-extract" }, function(info, err)
		created_wt = info
		create_err = err
	end)
	vim.wait(5000, function()
		return created_wt ~= nil or create_err ~= nil
	end, 20)
	check(create_err == nil and type(created_wt) == "table", "create_worktree new branch succeeded", create_err)
	local wt_feat_path = created_wt and created_wt.path or ""
	check(wt.is_linked_worktree(wt_feat_path) == true, "linked worktree detected")
	check(wt.get_repo_root(wt_feat_path) == norm_alpha, "linked worktree resolves back to canonical repo_root")
	check(wt.get_worktree_branch(wt_feat_path) == "feat/ui-extract", "linked worktree branch resolved")

	local existing_wt = nil
	local existing_err = nil
	wt.create_worktree(repo_alpha, { branch = "existing-branch" }, function(info, err)
		existing_wt = info
		existing_err = err
	end)
	vim.wait(5000, function()
		return existing_wt ~= nil or existing_err ~= nil
	end, 20)
	check(
		existing_err == nil and type(existing_wt) == "table",
		"create_worktree existing branch succeeded",
		existing_err
	)

	-- Refuse removing main worktree
	local rm_main_done, rm_main_ok = false, nil
	wt.remove_worktree(norm_alpha, {}, function(ok)
		rm_main_ok = ok
		rm_main_done = true
	end)
	vim.wait(2000, function()
		return rm_main_done
	end, 20)
	check(rm_main_ok == false, "remove_worktree refuses main worktree")

	-- Dirty check + force removal on `existing_wt`
	if existing_wt and existing_wt.path then
		local dirty_file = existing_wt.path .. "/dirty.txt"
		local dfd = assert(vim.uv.fs_open(dirty_file, "w", 420))
		vim.uv.fs_write(dfd, "uncommitted\n", 0)
		vim.uv.fs_close(dfd)

		local rm_dirty_done, rm_dirty_ok = false, nil
		wt.remove_worktree(existing_wt.path, { force = false }, function(ok)
			rm_dirty_ok = ok
			rm_dirty_done = true
		end)
		vim.wait(3000, function()
			return rm_dirty_done
		end, 20)
		check(rm_dirty_ok == false, "remove_worktree refuses dirty worktree without force")

		local rm_force_done, rm_force_ok = false, nil
		wt.remove_worktree(existing_wt.path, { force = true }, function(ok)
			rm_force_ok = ok
			rm_force_done = true
		end)
		vim.wait(5000, function()
			return rm_force_done
		end, 20)
		check(rm_force_ok == true, "remove_worktree succeeds with force = true")
	end

	-- ========================================================================
	-- 3. Workspace Layout, Sidebar Rendering, Disambiguation & Path Yanking
	-- ========================================================================
	ws.add_project(repo_alpha, { silent = true })
	ws.add_project(repo_beta, { silent = true })
	ws.add_project(dup_one, { silent = true })
	ws.add_project(dup_two, { silent = true })
	check(#ws.list_projects() == 4, "4 projects persisted to isolated store")

	ws.enter(false, { skip_auto_chat = true })
	check(ws.is_current_tab() == true, "entered workspace tab")
	local main_win = ws.get_main_win()
	check(type(main_win) == "number" and vim.api.nvim_win_is_valid(main_win), "workspace main_win valid")

	local state_mod = require("cc_workspace.state")
	local sb_buf = state_mod.state.sidebar_buf
	local sb_win = state_mod.state.sidebar_win
	check(sb_buf and vim.api.nvim_buf_is_valid(sb_buf), "sidebar buffer valid")

	local sb_lines = vim.api.nvim_buf_get_lines(sb_buf, 0, -1, false)
	local sb_text = table.concat(sb_lines, "\n")
	check(not sb_text:find("+ New conversation", 1, true), "zero '+ New conversation' child rows in sidebar")
	check(sb_text:find("suite_a/…/libboundscheck", 1, true) ~= nil, "tail-aware disambiguation for suite_a")
	check(sb_text:find("suite_b/…/libboundscheck", 1, true) ~= nil, "tail-aware disambiguation for suite_b")

	-- Spawn chats in repo_alpha and linked worktree
	local chat_alpha = ws.new_chat(true, norm_alpha)
	check(chat_alpha ~= nil and ws.get_valid_chat_cwd(chat_alpha) == norm_alpha, "chat_alpha scoped to repo_alpha")
	chat_alpha:set_title("Alpha Main Refactor")

	local chat_wt = ws.new_chat(true, wt_feat_path)
	check(chat_wt ~= nil and ws.get_valid_chat_cwd(chat_wt) == wt_feat_path, "chat_wt scoped to linked worktree")
	chat_wt:set_title("Extract UI Modules")

	ws.render()
	sb_lines = vim.api.nvim_buf_get_lines(sb_buf, 0, -1, false)
	sb_text = table.concat(sb_lines, "\n")
	check(sb_text:find("feat/ui-extract", 1, true) ~= nil, "sidebar renders linked worktree branch")

	-- Test Path Yanking (`y` single path + `Y` all repo/worktree paths)
	vim.api.nvim_set_current_win(sb_win)
	local wt_row, alpha_proj_row, header_row = nil, nil, nil
	for r, act in pairs(state_mod.state.row_actions) do
		if act.kind == "worktree" and act.path == wt_feat_path then
			wt_row = r
		elseif act.kind == "project" and act.path == norm_alpha then
			alpha_proj_row = r
		elseif act.kind == "projects_header" then
			header_row = r
		end
	end

	check(wt_row ~= nil, "found linked worktree row in sidebar")
	if wt_row then
		vim.api.nvim_win_set_cursor(sb_win, { wt_row, 0 })
		local yanked_single = ws.yank_row_path(false)
		check(
			type(yanked_single) == "table" and #yanked_single == 1 and yanked_single[1] == wt_feat_path,
			"yank_row_path(false) copies worktree path"
		)
		check(vim.fn.getreg('"') == wt_feat_path, "unnamed register holds worktree path")
	end

	check(alpha_proj_row ~= nil, "found repo_alpha project row in sidebar")
	if alpha_proj_row then
		vim.api.nvim_win_set_cursor(sb_win, { alpha_proj_row, 0 })
		local yanked_repo = ws.yank_row_path(true)
		check(
			type(yanked_repo) == "table"
				and vim.tbl_contains(yanked_repo, norm_alpha)
				and vim.tbl_contains(yanked_repo, wt_feat_path),
			"yank_row_path(true) copies main repo + linked worktree paths"
		)
	end

	if header_row then
		vim.api.nvim_win_set_cursor(sb_win, { header_row, 0 })
		local yanked_all = ws.yank_row_path(true)
		check(type(yanked_all) == "table" and #yanked_all >= 5, "PROJECTS header Y copies all repo & worktree paths")
	end

	-- ========================================================================
	-- 4. Statusline Component & Extension + Agent Lifecycle States
	-- ========================================================================
	local comp = statusline.component()
	local sl_ext = statusline.extension(comp)
	local sl_ext_default = statusline.extension()
	check(
		type(comp[1]) == "function" and type(comp.color) == "function" and type(comp.on_click) == "function",
		"statusline.component() structure"
	)
	check(
		sl_ext.filetypes[1] == "cc-workspace" and sl_ext.sections.lualine_x[1] == comp,
		"statusline.extension(comp) preserves component"
	)
	check(
		sl_ext_default.filetypes[1] == "cc-workspace" and type(sl_ext_default.sections.lualine_x[1][1]) == "function",
		"statusline.extension() builds component"
	)

	-- Focus chat_wt in workspace and verify idle metadata rendering
	ws.show_chat(chat_wt, true)
	local idle_str = comp[1]()
	check(
		idle_str:find("omp", 1, true) ~= nil
			and idle_str:find("claude-sonnet-4", 1, true) ~= nil
			and idle_str:find("1.4k tok", 1, true) ~= nil,
		"statusline idle chat metadata",
		idle_str
	)

	-- Start request on chat_wt, leave workspace -> verify background streaming + unread toast + jump
	vim.api.nvim_exec_autocmds("User", {
		pattern = "CodeCompanionRequestStarted",
		data = { bufnr = chat_wt.bufnr, interaction = "chat", adapter = chat_wt.adapter },
	})
	local think_str = comp[1]()
	check(think_str:find("Thinking", 1, true) ~= nil, "statusline shows Thinking on RequestStarted", think_str)

	vim.api.nvim_exec_autocmds("User", {
		pattern = "CodeCompanionRequestStreaming",
		data = { bufnr = chat_wt.bufnr, interaction = "chat", adapter = chat_wt.adapter },
	})
	ws.leave()
	check(ws.is_current_tab() == false, "ws.leave() switched back to code tab without stopping chat")
	check(wt.get_chat_status(chat_wt.bufnr).state == "streaming", "chat_wt remains streaming in background")

	local bg_stream_str = comp[1]()
	check(
		bg_stream_str:find("Streaming", 1, true) ~= nil and bg_stream_str:find("[bg]", 1, true) ~= nil,
		"statusline shows Streaming [bg] in code tab",
		bg_stream_str
	)

	vim.wait(220, function()
		return mock_lualine_refreshes > 0
	end, 20)
	check(mock_lualine_refreshes > 0, "statusline spinner timer refreshed lualine")

	local notif_before = #mock_notifications
	vim.api.nvim_exec_autocmds("User", {
		pattern = "CodeCompanionRequestFinished",
		data = { bufnr = chat_wt.bufnr, interaction = "chat", adapter = chat_wt.adapter },
	})
	vim.wait(100, function()
		return #mock_notifications > notif_before
	end, 10)
	check(wt.get_chat_status(chat_wt.bufnr).state == "unread", "background finish transitions chat to unread")
	check(
		#mock_notifications > notif_before
			and mock_notifications[#mock_notifications].msg:find("Completed", 1, true) ~= nil,
		"completion toast emitted"
	)

	local unread_sl = comp[1]()
	check(unread_sl:find("✓1 unread", 1, true) ~= nil, "statusline displays ✓1 unread rollup", unread_sl)

	-- Click statusline component -> jumps straight to unread chat and marks it read!
	comp.on_click(1, "l")
	check(vim.api.nvim_get_current_buf() == chat_wt.bufnr, "statusline on_click jumped to unread chat")
	check(wt.get_chat_status(chat_wt.bufnr).state == "idle", "viewing chat cleared unread -> idle")

	-- ========================================================================
	-- 5. Winbar 22-Chat Stress Test, Highlights & `%@` Statusline Evaluation
	-- ========================================================================
	ws.enter(true, { skip_auto_chat = true })
	winbar.setup()

	local hl_active = vim.api.nvim_get_hl(0, { name = "CcWinbarActive", link = false })
	check(
		hl_active.bold == true
			and string.format("#%06x", hl_active.fg or 0) == "#1d2021"
			and string.format("#%06x", hl_active.bg or 0) == "#d8a657",
		"CcWinbarActive is bold #1d2021 on #d8a657"
	)
	for _, hname in ipairs({
		"CcWinbarSep",
		"CcWinbarActive",
		"CcWinbarRunning",
		"CcWinbarUnread",
		"CcWinbarError",
		"CcWinbarWaiting",
		"CcWinbarInactive",
		"CcWinbarOverflow",
		"CcWinbarAction",
	}) do
		local h = vim.api.nvim_get_hl(0, { name = hname, link = false })
		check(next(h) ~= nil, "highlight group defined: " .. hname)
	end

	-- Spawn up to 22 total open chats
	while #mock_chats < 22 do
		local idx = #mock_chats + 1
		local target_dir = (idx % 2 == 0) and wt_feat_path or norm_beta
		local c = ws.new_chat(false, target_dir, { skip_show = true })
		c:set_title(string.format("Task #%02d Architecture Review", idx))
	end
	check(#mock_chats == 22, "22 simultaneous open chats created")

	-- Assign rich off-screen & visible states
	wt.set_chat_state(mock_chats[1].bufnr, "waiting", { notify = false })
	wt.set_chat_state(mock_chats[2].bufnr, "error", { notify = false })
	wt.set_chat_state(mock_chats[20].bufnr, "unread", { notify = false })
	wt.set_chat_state(mock_chats[21].bufnr, "streaming", { notify = false })

	for _, cols in ipairs({ 180, 120, 90, 62 }) do
		vim.o.columns = cols
		ws.sync_sidebar_width()
		local cur_main = ws.get_main_win()
		local win_w = vim.api.nvim_win_get_width(cur_main)
		local width_ok = true
		local pills_ok = true
		local eval_ok = true
		local no_global_cb = true

		for idx = 1, 22 do
			ws.show_chat(mock_chats[idx], true)
			winbar.refresh()
			local bar = vim.wo[cur_main].winbar
			if bar:find("_user_cc_", 1, true) or not bar:find("v:lua.require'cc_workspace.winbar'.", 1, true) then
				no_global_cb = false
			end
			local pill_count = 0
			for _ in bar:gmatch("on_tab_click@") do
				pill_count = pill_count + 1
			end
			if pill_count < 1 or pill_count > 7 then
				pills_ok = false
			end
			vim.v.errmsg = ""
			local ev = vim.api.nvim_eval_statusline(bar, {
				winid = cur_main,
				use_winbar = true,
				maxwidth = 9999,
				highlights = true,
			})
			if vim.v.errmsg ~= "" or ev.width > win_w or winbar.measure_width(bar) > win_w then
				width_ok = false
				eval_ok = false
			end
		end

		check(no_global_cb, string.format("cols=%d winbar uses module-scoped v:lua.require callbacks", cols))
		check(pills_ok, string.format("cols=%d winbar renders 1..7 pills across all 22 chats", cols))
		check(
			width_ok and eval_ok,
			string.format("cols=%d nvim_eval_statusline width <= win_w (%d) across all 22 chats", cols, win_w)
		)
	end

	-- Verify wide winbar badges at cols=180 on middle chat #10
	vim.o.columns = 180
	ws.sync_sidebar_width()
	ws.show_chat(mock_chats[10], true)
	-- Restore states that viewing during loop marked read
	wt.set_chat_state(mock_chats[1].bufnr, "waiting", { notify = false })
	wt.set_chat_state(mock_chats[2].bufnr, "error", { notify = false })
	wt.set_chat_state(mock_chats[20].bufnr, "unread", { notify = false })
	winbar.refresh()

	local wide_bar = vim.wo[ws.get_main_win()].winbar
	local wide_ev = vim.api.nvim_eval_statusline(wide_bar, {
		winid = ws.get_main_win(),
		use_winbar = true,
		maxwidth = 9999,
	})
	check(
		wide_ev.str:find("‹ +", 1, true) ~= nil and wide_ev.str:find("›", 1, true) ~= nil,
		"wide winbar shows ‹ +N and +M › overflow badges",
		wide_ev.str
	)
	check(wide_ev.str:find("[10/22 ▾]", 1, true) ~= nil, "wide winbar shows [10/22 ▾] switcher button", wide_ev.str)
	check(
		wide_ev.str:find("feat/ui-extract", 1, true) ~= nil,
		"wide winbar shows linked worktree branch badge",
		wide_ev.str
	)
	check(wide_ev.str:find("Code", 1, true) ~= nil, "wide winbar shows Code toggle in workspace", wide_ev.str)

	-- Overflow click jumps to highest-priority off-screen attention chat (#1 waiting)
	local left_target = tonumber(wide_bar:match("%%(%d+)@v:lua%.require'cc_workspace%.winbar'%.on_overflow_click@"))
	check(left_target == mock_chats[1].bufnr, "left overflow targets highest-priority waiting chat #1")
	winbar.on_overflow_click(left_target, 1, "l")
	check(vim.api.nvim_win_get_buf(ws.get_main_win()) == mock_chats[1].bufnr, "on_overflow_click focused chat #1")

	-- Middle-click closes idle chat #22 safely
	local count_before_mid = #mock_chats
	winbar.on_tab_click(mock_chats[22].bufnr, 1, "m")
	check(#mock_chats == count_before_mid - 1, "middle-click on pill closes chat safely")

	-- ========================================================================
	-- 6. Floating Agent Switcher (`<leader>cl`) & Quick Actions
	-- ========================================================================
	wt.set_chat_state(mock_chats[5].bufnr, "unread", { notify = false })
	switcher.open()
	local fl_win, fl_buf = switcher.get_float_win()
	check(fl_win ~= nil and vim.api.nvim_win_is_valid(fl_win), "switcher.open() creates floating window")
	local fl_lines = vim.api.nvim_buf_get_lines(fl_buf, 0, -1, false)
	check(#fl_lines == #mock_chats, "switcher renders all open chats")
	local fl_text = table.concat(fl_lines, "\n")
	check(
		fl_text:find("✓ Done", 1, true) ~= nil and fl_text:find("feat/ui-extract", 1, true) ~= nil,
		"switcher shows status & worktree branch"
	)
	switcher.close()
	check(switcher.get_float_win() == nil, "switcher.close() closes float cleanly")

	-- `switcher.jump_to_attention()` jumps to unread chat #5 (or highest priority)
	local jumped = switcher.jump_to_attention({ silent = true })
	check(jumped == true, "switcher.jump_to_attention() jumped to attention chat")

	-- `switcher.select_adapter_or_model()` invokes adapter picker on active chat
	switcher.select_adapter_or_model()
	check(mock_adapter_picker_buf ~= nil, "switcher.select_adapter_or_model() invoked change_adapter")

	-- ========================================================================
	-- 6b. Real `nvim --embed` C-Level Winbar `%@v:lua.require...@` Mouse Click
	-- ========================================================================
	do
		local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
		local stdin = vim.uv.new_pipe(false)
		local stdout = vim.uv.new_pipe(false)
		local session = vim.mpack.Session({ unpack = vim.mpack.Unpacker() })
		local replies = {}
		local handle = vim.uv.spawn("nvim", {
			args = { "--embed", "-u", "NONE", "--cmd", "set rtp+=" .. plugin_root },
			stdio = { stdin, stdout, nil },
		}, function() end)

		stdout:read_start(function(_, chunk)
			if not chunk then
				return
			end
			local pos = 1
			while pos <= #chunk do
				local typ, id_or_m, err_or_p, res, next_pos = session:receive(chunk, pos)
				if not typ then
					break
				end
				pos = next_pos
				if typ == "response" then
					replies[id_or_m] = { err = err_or_p, res = res }
				end
			end
		end)

		local rpc_seq = 0
		local function rpc_call(method, args)
			rpc_seq = rpc_seq + 1
			local req_id = rpc_seq
			stdin:write(session:request(req_id) .. vim.mpack.encode(method) .. vim.mpack.encode(args))
			vim.wait(2000, function()
				return replies[req_id] ~= nil
			end, 5)
			return replies[req_id]
		end

		rpc_call("nvim_ui_attach", { 120, 30, { ext_linegrid = true } })
		rpc_call("nvim_exec_lua", {
			[[
				vim.o.mouse = "a"
				local target_p = ...
				local chats = {}
				package.preload["codecompanion.interactions.chat"] = function()
					return {
						buf_get_chat = function(b)
							if b == nil then
								local out = {}
								for _, c in ipairs(chats) do
									table.insert(out, { bufnr = c.bufnr, chat = c })
								end
								return out
							end
							for _, c in ipairs(chats) do
								if c.bufnr == b then return c end
							end
							return nil
						end,
						last_chat = function() return chats[#chats] end,
					}
				end
				package.preload["codecompanion"] = function()
					return { last_chat = function() return chats[#chats] end, extensions = {} }
				end
				require("codecompanion")
				require("codecompanion.interactions.chat")
				local ws = require("cc_workspace")
				ws.set_projects_file(target_p)
				local wb = require("cc_workspace.winbar")
				wb.setup()
				for i = 1, 2 do
					local b = vim.api.nvim_create_buf(false, true)
					vim.bo[b].filetype = "codecompanion"
					table.insert(chats, {
						bufnr = b,
						opts = { title = "Tab" .. i, save_id = "s" .. i },
						ui = {
							show_in_win = function(self, spec)
								vim.api.nvim_win_set_buf(spec.winnr, b)
							end,
							is_visible_non_curtab = function() return false end,
						},
					})
				end
				vim.api.nvim_win_set_buf(0, chats[1].bufnr)
				wb.refresh()
				vim.cmd("redraw!")
				_G._embed_chat2_buf = chats[2].bufnr
				local ev = vim.api.nvim_eval_statusline(vim.wo[0].winbar, { use_winbar = true, maxwidth = 9999 })
				local s = ev.str:find("Tab2", 1, true)
				_G._embed_tab2_col = s and (vim.api.nvim_strwidth(ev.str:sub(1, s - 1)) + 1) or 18
			]],
			{ tmp_projects_file },
		})

		local col_res = rpc_call("nvim_exec_lua", { "return _G._embed_tab2_col", {} })
		local click_col = (col_res and type(col_res.res) == "number") and col_res.res or 18
		rpc_call("nvim_input_mouse", { "left", "press", "", 0, 0, click_col })
		rpc_call("nvim_input_mouse", { "left", "release", "", 0, 0, click_col })
		local after_click = rpc_call("nvim_exec_lua", {
			"return { cur = vim.api.nvim_get_current_buf(), expected = _G._embed_chat2_buf, err = vim.v.errmsg }",
			{},
		})
		if handle then
			pcall(handle.kill, handle, "sigterm")
		end
		stdin:close()
		stdout:close()

		local clicked_ok = after_click
			and type(after_click.res) == "table"
			and after_click.res.cur == after_click.res.expected
			and after_click.res.err == ""
		check(clicked_ok, "nvim --embed mouse click on winbar pill switches chat buffer with 0 errors")
	end

	-- ========================================================================
	-- 7. Global Hygiene Check (zero `_G._user_cc_*` leaks)
	-- ========================================================================
	local leaked_globals = {}
	for k in pairs(_G) do
		if type(k) == "string" and k:match("^_user_cc_") then
			table.insert(leaked_globals, k)
		end
	end
	check(#leaked_globals == 0, "zero _G._user_cc_* globals leaked", table.concat(leaked_globals, ", "))

	statusline.stop()
	wt.reset_states()
end, debug.traceback)

vim.notify = orig_notify
pcall(vim.fn.delete, tmp_root, "rf")

if not ok_suite then
	failed = failed + 1
	io.stderr:write("UNHANDLED ERROR:\n" .. tostring(suite_err) .. "\n")
end

-- Verify live user data files are 100% untouched!
local after_projects_sha = file_sha256(user_projects_json)
local after_history_sha = file_sha256(user_history_index)
check(before_projects_sha == after_projects_sha, "live ~/.local/share/nvim/cc-workspace-projects.json untouched")
check(before_history_sha == after_history_sha, "live ~/.local/share/nvim/codecompanion-history/index.json untouched")

print(string.format("cc-workspace.nvim headless suite: %d passed, %d failed", passed, failed))
if failed > 0 then
	os.exit(1)
end
os.exit(0)
