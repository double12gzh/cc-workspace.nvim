-- Standalone headless E2E test suite for `cc-workspace.nvim`.
-- Run via:
--   nvim --headless -u NONE -i NONE --noplugin --cmd 'set rtp+=/Users/jeffreyguan/Documents/code/cc-workspace.nvim' "+luafile /Users/jeffreyguan/Documents/code/cc-workspace.nvim/tests/run_headless.lua"

local passed, failed, failures = 0, 0, {}

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

local function history_tree_digest(root_dir)
	if not vim.uv.fs_lstat(root_dir) then
		return "MISSING"
	end
	local entries = {}
	local function walk(dir, prefix)
		local scan = vim.uv.fs_scandir(dir)
		if not scan then
			return
		end
		while true do
			---@type string?, string?
			local name, etype = vim.uv.fs_scandir_next(scan)
			if not name then
				break
			end
			local full = dir .. "/" .. name
			local rel = prefix ~= "" and (prefix .. "/" .. name) or name
			etype = etype or ((vim.uv.fs_lstat(full) or {}).type or "unknown")
			if etype == "directory" then
				table.insert(entries, "D:" .. rel)
				walk(full, rel)
			else
				table.insert(entries, "F:" .. rel .. "=" .. file_sha256(full))
			end
		end
	end
	walk(root_dir, "")
	table.sort(entries)
	return vim.fn.sha256(table.concat(entries, "\n"))
end

local function worktrees_tree_digest(root_dir)
	if not vim.uv.fs_lstat(root_dir) then
		return "MISSING"
	end
	local entries = {}
	local scan = vim.uv.fs_scandir(root_dir)
	while scan do
		---@type string?, string?
		local rname, rtype = vim.uv.fs_scandir_next(scan)
		if not rname then
			break
		end
		local rfull = root_dir .. "/" .. rname
		rtype = rtype or ((vim.uv.fs_lstat(rfull) or {}).type or "unknown")
		table.insert(entries, rtype .. ":" .. rname)
		if rtype == "directory" then
			local sub = vim.uv.fs_scandir(rfull)
			while sub do
				---@type string?, string?
				local bname, btype = vim.uv.fs_scandir_next(sub)
				if not bname then
					break
				end
				btype = btype or ((vim.uv.fs_lstat(rfull .. "/" .. bname) or {}).type or "unknown")
				table.insert(entries, btype .. ":" .. rname .. "/" .. bname)
			end
		end
	end
	table.sort(entries)
	return vim.fn.sha256(table.concat(entries, "\n"))
end

local function run_cmd_sync(cmd, cwd)
	local res = vim.system(cmd, { cwd = cwd, text = true }):wait(10000)
	assert(
		res and res.code == 0,
		string.format("command failed (%s): %s", table.concat(cmd, " "), (res and res.stderr) or "")
	)
	return res.stdout or ""
end

local user_data_dir = vim.fn.stdpath("data")
local user_projects_json = user_data_dir .. "/cc-workspace-projects.json"
local user_history_dir = user_data_dir .. "/codecompanion-history"
local user_history_index = user_history_dir .. "/index.json"
local user_worktrees_dir = user_data_dir .. "/cc-worktrees"
local before_projects_sha = file_sha256(user_projects_json)
local before_history_sha = file_sha256(user_history_index)
local before_history_tree = history_tree_digest(user_history_dir)
local before_worktrees_tree = worktrees_tree_digest(user_worktrees_dir)

local tmp_root = vim.fn.tempname()
vim.fn.mkdir(tmp_root, "p")

for _, gvar in ipairs({
	"GIT_DIR",
	"GIT_WORK_TREE",
	"GIT_IMPLICIT_WORK_TREE",
	"GIT_INDEX_FILE",
	"GIT_OBJECT_DIRECTORY",
	"GIT_ALTERNATE_OBJECT_DIRECTORIES",
	"GIT_COMMON_DIR",
	"GIT_PREFIX",
}) do
	vim.env[gvar] = nil
end

-- ============================================================================
-- Deterministic standalone CodeCompanion test harness (zero external processes)
-- ============================================================================
local mock_chats, mock_saved_history, mock_notifications = {}, {}, {}
local mock_last_chat, mock_adapter_picker_buf = nil, nil
local mock_lualine_refreshes = 0

local orig_notify = vim.notify
---@diagnostic disable-next-line: duplicate-set-field
vim.notify = function(msg, level, opts)
	table.insert(mock_notifications, { msg = tostring(msg), level = level, opts = opts })
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
		opts = { cwd = args.cwd, save_id = args.save_id, title = args.title },
		adapter = {
			name = "omp",
			formatted_name = "oh-my-pi",
			type = "acp",
			schema = { model = { default = "anthropic/claude-sonnet-4" } },
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
	local fd = assert(vim.uv.fs_open(dir .. "/README.md", "w", 420))
	vim.uv.fs_write(fd, "# " .. vim.fs.basename(dir) .. "\n", 0)
	vim.uv.fs_close(fd)
	run_cmd_sync({ "git", "add", "README.md" }, dir)
	run_cmd_sync({ "git", "commit", "-m", "initial commit" }, dir)
	run_cmd_sync({ "git", "branch", "existing-branch" }, dir)
end

local ok_suite, suite_err = xpcall(function()
	vim.o.columns, vim.o.lines, vim.o.laststatus, vim.o.showtabline = 180, 48, 3, 2

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

	-- 1. Core Setup, Icons & CodeCompanion Extension Contract
	local ext = require("codecompanion._extensions.workspace")
	check(type(ext) == "table" and type(ext.setup) == "function", "extension exports setup()")
	check(type(ext.exports) == "table", "extension exports table")

	local ws = require("cc_workspace")
	local icons = require("cc_workspace.icons")
	local wt = require("cc_workspace.worktree")
	local winbar = require("cc_workspace.winbar")
	local statusline = require("cc_workspace.statusline")
	local switcher = require("cc_workspace.switcher")

	ws.setup({ projects_file = tmp_projects_file, worktrees_base_dir = tmp_worktrees_dir, notifications = true })
	ws.set_projects_file(tmp_projects_file)
	wt.set_worktrees_base_dir(tmp_worktrees_dir)

	check(
		ws.get_projects_file() == wt.normalize_path(tmp_projects_file) or ws.get_projects_file() == tmp_projects_file,
		"isolated projects_file configured"
	)
	check(icons.get("aichat", true).Chat == "󱜸 ", "icons.get('aichat', true).Chat default")
	check(icons.ui.Folder == "" and icons.git.Branch == "", "default Folder & Branch icons")
	for _, cmd_name in ipairs({
		"CodeCompanionWorkspace",
		"CodeCompanionWorkspaceAddProject",
		"CodeCompanionWorkspaceWorktree",
		"CodeCompanionWorkspaceKeys",
		"CodeCompanionNotificationsToggle",
	}) do
		check(vim.fn.exists(":" .. cmd_name) == 2, ":" .. cmd_name .. " command registered")
	end
	check(
		ws.worktree == wt and ws.winbar == winbar and ws.statusline == statusline and ws.switcher == switcher,
		"ws lazy sub-module accessors"
	)

	-- 2. Git Worktree Discovery, Creation & Removal Safety
	local norm_alpha = wt.normalize_path(repo_alpha)
	local norm_beta = wt.normalize_path(repo_beta)
	---@cast norm_alpha string
	---@cast norm_beta string
	check(wt.get_repo_root(repo_alpha) == norm_alpha, "get_repo_root resolves main repo")
	check(wt.get_worktree_branch(repo_alpha) == "main", "get_worktree_branch resolves main branch")
	check(wt.is_linked_worktree(repo_alpha) == false, "main repo is not a linked worktree")

	local created_wt, create_err = nil, nil
	wt.create_worktree(repo_alpha, { branch = "feat/ui-extract" }, function(info, err)
		created_wt, create_err = info, err
	end)
	vim.wait(5000, function()
		return created_wt ~= nil or create_err ~= nil
	end, 20)
	check(create_err == nil and type(created_wt) == "table", "create_worktree new branch succeeded", create_err)
	local wt_feat_path = created_wt and created_wt.path or ""
	check(wt.is_linked_worktree(wt_feat_path) == true, "linked worktree detected")
	check(wt.get_repo_root(wt_feat_path) == norm_alpha, "linked worktree resolves back to canonical repo_root")
	check(wt.get_worktree_branch(wt_feat_path) == "feat/ui-extract", "linked worktree branch resolved")

	local existing_wt, existing_err = nil, nil
	wt.create_worktree(repo_alpha, { branch = "existing-branch" }, function(info, err)
		existing_wt, existing_err = info, err
	end)
	vim.wait(5000, function()
		return existing_wt ~= nil or existing_err ~= nil
	end, 20)
	check(
		existing_err == nil and type(existing_wt) == "table",
		"create_worktree existing branch succeeded",
		existing_err
	)

	local rm_main_done, rm_main_ok = false, nil
	wt.remove_worktree(norm_alpha, {}, function(ok)
		rm_main_ok, rm_main_done = ok, true
	end)
	vim.wait(2000, function()
		return rm_main_done
	end, 20)
	check(rm_main_ok == false, "remove_worktree refuses main worktree")

	if existing_wt and existing_wt.path then
		local dfd = assert(vim.uv.fs_open(existing_wt.path .. "/dirty.txt", "w", 420))
		vim.uv.fs_write(dfd, "uncommitted\n", 0)
		vim.uv.fs_close(dfd)

		local rm_dirty_done, rm_dirty_ok = false, nil
		wt.remove_worktree(existing_wt.path, { force = false }, function(ok)
			rm_dirty_ok, rm_dirty_done = ok, true
		end)
		vim.wait(3000, function()
			return rm_dirty_done
		end, 20)
		check(rm_dirty_ok == false, "remove_worktree refuses dirty worktree without force")

		local rm_force_done, rm_force_ok = false, nil
		wt.remove_worktree(existing_wt.path, { force = true }, function(ok)
			rm_force_ok, rm_force_done = ok, true
		end)
		vim.wait(5000, function()
			return rm_force_done
		end, 20)
		check(rm_force_ok == true, "remove_worktree succeeds with force = true")
	end

	-- 3. Workspace Layout, Sidebar Rendering, Disambiguation & Path Yanking
	for _, p in ipairs({ repo_alpha, repo_beta, dup_one, dup_two }) do
		ws.add_project(p, { silent = true })
	end
	check(#ws.list_projects() == 4, "4 projects persisted to isolated store")

	ws.enter(false, { skip_auto_chat = true })
	check(ws.is_current_tab() == true, "entered workspace tab")
	local main_win = ws.get_main_win()
	check(type(main_win) == "number" and vim.api.nvim_win_is_valid(main_win), "workspace main_win valid")

	local state_mod = require("cc_workspace.state")
	local sb_buf = state_mod.state.sidebar_buf
	local sb_win = state_mod.state.sidebar_win
	check(sb_buf and vim.api.nvim_buf_is_valid(sb_buf), "sidebar buffer valid")
	---@cast sb_buf integer
	---@cast sb_win integer

	local sb_text = table.concat(vim.api.nvim_buf_get_lines(sb_buf, 0, -1, false), "\n")
	check(not sb_text:find("+ New conversation", 1, true), "zero '+ New conversation' child rows in sidebar")
	check(sb_text:find("suite_a/…/libboundscheck", 1, true) ~= nil, "tail-aware disambiguation for suite_a")
	check(sb_text:find("suite_b/…/libboundscheck", 1, true) ~= nil, "tail-aware disambiguation for suite_b")

	local chat_alpha = ws.new_chat(true, norm_alpha)
	check(chat_alpha ~= nil and ws.get_valid_chat_cwd(chat_alpha) == norm_alpha, "chat_alpha scoped to repo_alpha")
	---@cast chat_alpha table
	chat_alpha:set_title("Alpha Main Refactor")

	local chat_wt = ws.new_chat(true, wt_feat_path)
	check(chat_wt ~= nil and ws.get_valid_chat_cwd(chat_wt) == wt_feat_path, "chat_wt scoped to linked worktree")
	---@cast chat_wt table
	chat_wt:set_title("Extract UI Modules")

	ws.render()
	sb_text = table.concat(vim.api.nvim_buf_get_lines(sb_buf, 0, -1, false), "\n")
	check(sb_text:find("feat/ui-extract", 1, true) ~= nil, "sidebar renders linked worktree branch")

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

	-- 4. Statusline Component & Extension + Agent Lifecycle States
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

	ws.show_chat(chat_wt, true)
	local idle_str = comp[1]()
	check(
		idle_str:find("omp", 1, true) ~= nil
			and idle_str:find("claude-sonnet-4", 1, true) ~= nil
			and idle_str:find("1.4k tok", 1, true) ~= nil,
		"statusline idle chat metadata",
		idle_str
	)

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

	comp.on_click(1, "l")
	check(vim.api.nvim_get_current_buf() == chat_wt.bufnr, "statusline on_click jumped to unread chat")
	check(wt.get_chat_status(chat_wt.bufnr).state == "idle", "viewing chat cleared unread -> idle")

	-- 5. Winbar 22-Chat Stress Test, Highlights & `%@` Statusline Evaluation
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
		check(next(vim.api.nvim_get_hl(0, { name = hname, link = false })) ~= nil, "highlight group defined: " .. hname)
	end

	while #mock_chats < 22 do
		local idx = #mock_chats + 1
		local c = ws.new_chat(false, (idx % 2 == 0) and wt_feat_path or norm_beta, { skip_show = true })
		---@cast c table
		c:set_title(string.format("Task #%02d Architecture Review", idx))
	end
	check(#mock_chats == 22, "22 simultaneous open chats created")

	wt.set_chat_state(mock_chats[1].bufnr, "waiting", { notify = false })
	wt.set_chat_state(mock_chats[2].bufnr, "error", { notify = false })
	wt.set_chat_state(mock_chats[20].bufnr, "unread", { notify = false })
	wt.set_chat_state(mock_chats[21].bufnr, "streaming", { notify = false })

	-- Run extended Winbar, Keymaps, Switcher, Embed & Linter suites (`tests/test_keymaps_and_lint.lua`)
	local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
	dofile(plugin_root .. "/tests/test_keymaps_and_lint.lua")({
		check = check,
		plugin_root = plugin_root,
		tmp_root = tmp_root,
		tmp_projects_file = tmp_projects_file,
		ws = ws,
		wt = wt,
		winbar = winbar,
		switcher = switcher,
		state_mod = state_mod,
		mock_chats = mock_chats,
		wt_feat_path = wt_feat_path,
		get_adapter_picker_buf = function()
			return mock_adapter_picker_buf
		end,
	})

	statusline.stop()
	wt.reset_states()
end, debug.traceback)

vim.notify = orig_notify
pcall(vim.fn.delete, tmp_root, "rf")

if not ok_suite then
	failed = failed + 1
	io.stderr:write("UNHANDLED ERROR:\n" .. tostring(suite_err) .. "\n")
end

-- Verify live user data files and directories are 100% untouched!
local after_projects_sha = file_sha256(user_projects_json)
local after_history_sha = file_sha256(user_history_index)
local after_history_tree = history_tree_digest(user_history_dir)
local after_worktrees_tree = worktrees_tree_digest(user_worktrees_dir)
check(before_projects_sha == after_projects_sha, "live ~/.local/share/nvim/cc-workspace-projects.json untouched")
check(before_history_sha == after_history_sha, "live ~/.local/share/nvim/codecompanion-history/index.json untouched")
check(before_history_tree == after_history_tree, "live ~/.local/share/nvim/codecompanion-history/ tree untouched")
check(before_worktrees_tree == after_worktrees_tree, "live ~/.local/share/nvim/cc-worktrees/ tree untouched")

io.stdout:write(string.format("cc-workspace.nvim headless suite: %d passed, %d failed\n", passed, failed))
io.stdout:flush()
if failed > 0 then
	vim.cmd("cquit 1")
else
	vim.cmd("qall!")
end
