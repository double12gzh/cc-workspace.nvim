-- Secondary headless E2E suite for `cc-workspace.nvim`:
-- Winbar overflow/clicks, Switcher, `nvim --embed` mouse routing, Dynamic Keymaps (`opts.keymaps`,
-- `false` disabling, live `set_keymaps()`, `:CodeCompanionWorkspaceKeys`), and Repo/AST/800L Linter.

---@param ctx table
return function(ctx)
	local check = ctx.check
	local plugin_root = ctx.plugin_root
	local tmp_root = ctx.tmp_root
	local tmp_projects_file = ctx.tmp_projects_file
	local ws = ctx.ws
	local wt = ctx.wt
	local winbar = ctx.winbar
	local switcher = ctx.switcher
	local state_mod = ctx.state_mod
	local mock_chats = ctx.mock_chats
	local wt_feat_path = ctx.wt_feat_path
	local get_adapter_picker_buf = ctx.get_adapter_picker_buf

	-- ========================================================================
	-- 5b. Multi-Width Winbar Stress Test, Overflow Routing & Middle-Click Close
	-- ========================================================================
	for _, cols in ipairs({ 180, 120, 90, 62 }) do
		vim.o.columns = cols
		ws.sync_sidebar_width()
		local cur_main = ws.get_main_win()
		---@cast cur_main integer
		local win_w = vim.api.nvim_win_get_width(cur_main)
		local width_ok, pills_ok, eval_ok, no_global_cb = true, true, true, true

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
				width_ok, eval_ok = false, false
			end
		end

		check(no_global_cb, string.format("cols=%d winbar uses module-scoped v:lua.require callbacks", cols))
		check(pills_ok, string.format("cols=%d winbar renders 1..7 pills across all 22 chats", cols))
		check(
			width_ok and eval_ok,
			string.format("cols=%d nvim_eval_statusline width <= win_w (%d) across all 22 chats", cols, win_w)
		)
	end

	vim.o.columns = 180
	ws.sync_sidebar_width()
	ws.show_chat(mock_chats[10], true)
	wt.set_chat_state(mock_chats[1].bufnr, "waiting", { notify = false })
	wt.set_chat_state(mock_chats[2].bufnr, "error", { notify = false })
	wt.set_chat_state(mock_chats[20].bufnr, "unread", { notify = false })
	winbar.refresh()

	local cur_main_win = ws.get_main_win()
	---@cast cur_main_win integer
	local wide_bar = vim.wo[cur_main_win].winbar
	local wide_ev = vim.api.nvim_eval_statusline(wide_bar, {
		winid = cur_main_win,
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

	local left_target = tonumber(wide_bar:match("%%(%d+)@v:lua%.require'cc_workspace%.winbar'%.on_overflow_click@"))
	check(left_target == mock_chats[1].bufnr, "left overflow targets highest-priority waiting chat #1")
	---@cast left_target integer
	winbar.on_overflow_click(left_target, 1, "l")
	local wide_main = ws.get_main_win()
	---@cast wide_main integer
	check(vim.api.nvim_win_get_buf(wide_main) == mock_chats[1].bufnr, "on_overflow_click focused chat #1")

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
	---@cast fl_buf integer
	local fl_lines = vim.api.nvim_buf_get_lines(fl_buf, 0, -1, false)
	check(#fl_lines == #mock_chats, "switcher renders all open chats")
	local fl_text = table.concat(fl_lines, "\n")
	check(
		fl_text:find("✓ Done", 1, true) ~= nil and fl_text:find("feat/ui-extract", 1, true) ~= nil,
		"switcher shows status & worktree branch"
	)
	local fl_extmarks = vim.api.nvim_buf_get_extmarks(fl_buf, -1, 0, -1, {})
	check(#fl_extmarks >= #mock_chats, "switcher applies extmark highlights on rendered rows")
	switcher.close()
	check(switcher.get_float_win() == nil, "switcher.close() closes float cleanly")

	local jumped = switcher.jump_to_attention({ silent = true })
	check(jumped == true, "switcher.jump_to_attention() jumped to attention chat")

	switcher.select_adapter_or_model()
	check(get_adapter_picker_buf() ~= nil, "switcher.select_adapter_or_model() invoked change_adapter")

	-- ========================================================================
	-- 6b. Real `nvim --embed` C-Level Winbar `%@v:lua.require...@` Mouse Click
	-- ========================================================================
	do
		local stdin = vim.uv.new_pipe(false)
		local stdout = vim.uv.new_pipe(false)
		---@cast stdin uv.uv_pipe_t
		---@cast stdout uv.uv_pipe_t
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
		pcall(stdout.read_stop, stdout)
		if handle then
			pcall(handle.kill, handle, "sigterm")
			if not handle:is_closing() then
				handle:close()
			end
		end
		if not stdin:is_closing() then
			stdin:close()
		end
		if not stdout:is_closing() then
			stdout:close()
		end

		local clicked_ok = after_click
			and type(after_click.res) == "table"
			and after_click.res.cur == after_click.res.expected
			and after_click.res.err == ""
		check(clicked_ok, "nvim --embed mouse click on winbar pill switches chat buffer with 0 errors")
	end

	-- ========================================================================
	-- 7. Dynamic Keymaps (`opts.keymaps`, `false`, `set_keymaps`, `show_keys`)
	-- ========================================================================
	do
		local config = require("cc_workspace.config")
		local keymaps = require("cc_workspace.keymaps")
		local default_km_snapshot = vim.deepcopy(config.defaults.keymaps)

		local function buf_map_entry(buf, mode, lhs)
			for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
				if m.lhs == lhs then
					return m
				end
			end
			return nil
		end

		local function global_map_entry(mode, lhs)
			for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
				if m.lhs == lhs then
					return m
				end
			end
			return nil
		end

		check(vim.fn.exists(":CodeCompanionWorkspaceKeys") == 2, ":CodeCompanionWorkspaceKeys command registered")
		check(
			type(ws.set_keymaps) == "function"
				and type(ws.get_keymaps) == "function"
				and type(ws.show_keys) == "function",
			"ws exports set_keymaps, get_keymaps, show_keys"
		)

		ws.enter(true, { skip_auto_chat = true })
		local sb_buf = state_mod.state.sidebar_buf
		local sb_win = state_mod.state.sidebar_win
		check(sb_buf ~= nil and vim.api.nvim_buf_is_valid(sb_buf), "live sidebar_buf valid before keymap override")
		---@cast sb_buf integer
		---@cast sb_win integer

		-- 7a. Declarative `ws.setup({ keymaps = ... })` overrides + `false` disabling
		ws.setup({
			projects_file = tmp_projects_file,
			worktrees_base_dir = tmp_root .. "/cc-worktrees",
			keymaps = {
				global = { show_keys = "<F9>" },
				sidebar = { yank_path = "gy", filter = false },
				chat = { next_chat = "]a", previous_chat = false },
			},
		})

		local cfg_km = ws.get_keymaps()
		check(
			cfg_km.sidebar.yank_path == "gy" and cfg_km.sidebar.filter == false,
			"opts.keymaps overrides sidebar.yank_path & disables sidebar.filter"
		)
		check(global_map_entry("n", "<F9>") ~= nil, "opts.keymaps.global binds <F9> in normal mode")
		check(buf_map_entry(sb_buf, "n", "y") == nil, "overridden default 'y' removed from live sidebar_buf")
		check(buf_map_entry(sb_buf, "n", "f") == nil, "disabled 'f' (filter=false) removed from live sidebar_buf")
		local gy_map = buf_map_entry(sb_buf, "n", "gy")
		check(gy_map ~= nil and type(gy_map.callback) == "function", "rebound 'gy' bound on live sidebar_buf")

		local open_chat_buf = mock_chats[1].bufnr
		check(buf_map_entry(open_chat_buf, "n", "]a") ~= nil, "rebound chat.next_chat ']a' applied to open chat buffer")
		check(buf_map_entry(open_chat_buf, "n", "}") == nil, "old chat.next_chat '}' removed from open chat buffer")
		check(
			buf_map_entry(open_chat_buf, "n", "{") == nil,
			"disabled chat.previous_chat '{' removed from open chat buffer"
		)

		-- Execute rebound `gy` callback on the worktree row to confirm functional wiring
		vim.api.nvim_set_current_win(sb_win)
		for r, act in pairs(state_mod.state.row_actions) do
			if act.kind == "worktree" and act.path == wt_feat_path then
				vim.api.nvim_win_set_cursor(sb_win, { r, 0 })
				break
			end
		end
		vim.fn.setreg('"', "")
		if gy_map and gy_map.callback then
			gy_map.callback()
		end
		check(vim.fn.getreg('"') == wt_feat_path, "executing rebound 'gy' callback yanks worktree path")

		-- 7b. Floating Cheatsheet (`:CodeCompanionWorkspaceKeys float` / `show_keys({ mode = "float" })`)
		--     + live hot-rebinding via `ws.set_keymaps(...)` while both sidebar & cheatsheet float are open!
		vim.cmd("CodeCompanionWorkspaceKeys float")
		local help_win, help_buf = keymaps.get_help_float_win()
		check(
			help_win ~= nil and vim.api.nvim_win_is_valid(help_win) and help_buf ~= nil,
			":CodeCompanionWorkspaceKeys float opens cheatsheet window"
		)
		---@cast help_buf integer
		local help_text_1 = table.concat(vim.api.nvim_buf_get_lines(help_buf, 0, -1, false), "\n")
		check(
			help_text_1:find("gy", 1, true) ~= nil and help_text_1:find("<F9>", 1, true) ~= nil,
			"floating cheatsheet renders live rebound keys ('gy', '<F9>')",
			help_text_1
		)
		check(
			not help_text_1:find("Filter by keyword", 1, true),
			"floating cheatsheet omits disabled action (filter=false)"
		)

		ws.set_keymaps({
			global = { show_keys = false },
			sidebar = { yank_path = { "zy", "gy" }, rename = false },
		})
		check(global_map_entry("n", "<F9>") == nil, "set_keymaps(global.show_keys=false) deletes global <F9>")
		check(buf_map_entry(sb_buf, "n", "r") == nil, "set_keymaps(sidebar.rename=false) deletes 'r' on live sidebar")
		check(
			buf_map_entry(sb_buf, "n", "zy") ~= nil and buf_map_entry(sb_buf, "n", "gy") ~= nil,
			"set_keymaps binds alias array { 'zy', 'gy' } on live sidebar_buf"
		)

		local sb_after_lines = vim.api.nvim_buf_get_lines(sb_buf, 0, -1, false)
		local sb_footer = (sb_after_lines[#sb_after_lines - 1] or "") .. "\n" .. (sb_after_lines[#sb_after_lines] or "")
		check(sb_footer:find("zy/Y:copy", 1, true) ~= nil, "sidebar footer hot-updates to 'zy/Y:copy'", sb_footer)

		local help_text_2 = table.concat(vim.api.nvim_buf_get_lines(help_buf, 0, -1, false), "\n")
		check(
			help_text_2:find("zy / gy", 1, true) ~= nil and not help_text_2:find("Rename chat", 1, true),
			"open cheatsheet float hot-refreshes on set_keymaps()",
			help_text_2
		)
		keymaps.close_help_float()
		check(keymaps.get_help_float_win() == nil, "keymaps.close_help_float() closes float cleanly")

		-- 7c. Telescope Keymaps Explorer (`ws.show_keys({ mode = "picker" })`) with deterministic Telescope stub
		local picker_captured = nil
		package.preload["telescope.pickers"] = function()
			return {
				new = function(_, spec)
					local mapped = {}
					if spec.attach_mappings then
						spec.attach_mappings(0, function(m, lhs, fn)
							mapped[m .. ":" .. lhs] = fn
						end)
					end
					picker_captured = { spec = spec, mapped = mapped }
					return {
						prompt_bufnr = 0,
						prompt_win = 0,
						find = function() end,
					}
				end,
			}
		end
		package.preload["telescope.finders"] = function()
			return {
				new_table = function(t)
					return t
				end,
			}
		end
		package.preload["telescope.config"] = function()
			return { values = {
				generic_sorter = function()
					return {}
				end,
			} }
		end
		package.preload["telescope.actions"] = function()
			return {
				select_default = { replace = function() end },
				close = function() end,
			}
		end
		package.preload["telescope.actions.state"] = function()
			return {
				get_selected_entry = function()
					return nil
				end,
			}
		end
		package.preload["telescope.pickers.entry_display"] = function()
			return {
				create = function()
					return function(cols)
						return cols
					end
				end,
			}
		end

		local pk_res = ws.show_keys({ mode = "picker" })
		check(
			pk_res.mode == "picker" and type(pk_res.entries) == "table" and #pk_res.entries >= 45,
			"show_keys({ mode = 'picker' }) builds full multi-scope catalog"
		)
		check(
			picker_captured ~= nil
				and type(picker_captured.mapped["i:<C-r>"]) == "function"
				and type(picker_captured.mapped["n:<C-r>"]) == "function",
			"Telescope keymap explorer attaches <C-r> live-rebind mappings"
		)
		local found_zy_entry = false
		for _, e in ipairs(pk_res.entries) do
			if e.scope == "sidebar" and e.action == "yank_path" and e.key_label == "zy / gy" then
				found_zy_entry = true
				break
			end
		end
		check(found_zy_entry, "Telescope keymap explorer displays live rebound 'zy / gy' entry")

		for _, tmod in ipairs({
			"telescope.pickers",
			"telescope.finders",
			"telescope.config",
			"telescope.actions",
			"telescope.actions.state",
			"telescope.pickers.entry_display",
		}) do
			package.loaded[tmod] = nil
			package.preload[tmod] = nil
		end

		-- Restore defaults cleanly
		ws.set_keymaps(default_km_snapshot)
	end

	-- ========================================================================
	-- 8. Global Hygiene Check (zero `_G._user_cc_*` leaks)
	-- ========================================================================
	local leaked_globals = {}
	for k in pairs(_G) do
		if type(k) == "string" and k:match("^_user_cc_") then
			table.insert(leaked_globals, k)
		end
	end
	check(#leaked_globals == 0, "zero _G._user_cc_* globals leaked", table.concat(leaked_globals, ", "))

	-- ========================================================================
	-- 9. Repository Lint, <=800-Line Ceiling, AST & Customization Self-Tests
	-- ========================================================================
	do
		vim.g.cc_ws_lint_as_lib = true
		local linter = dofile(plugin_root .. "/scripts/lint_repo.lua")
		vim.g.cc_ws_lint_as_lib = nil

		local repo_errs, repo_stats = linter.lint_repository(plugin_root)
		check(#repo_errs == 0, "lint_repository passes on clean repo", table.concat(repo_errs, "; "))
		check(
			repo_stats.modules >= 25 and repo_stats.rules >= 4 and repo_stats.skills >= 3,
			"lint_repository inventory (>=25 modules, >=4 rules, >=3 skills)"
		)

		-- Max 800-line file ceiling checks (boundary 800 allowed, 805 rejected)
		local exact_800 = string.rep("-- line\n", 800)
		local over_805 = string.rep("local _ = 1\n", 805)
		check(
			linter.check_lua_line_limit(exact_800, "lua/cc_workspace/ok.lua") == nil,
			"800-line Lua file passes limit"
		)
		local over_err = linter.check_lua_line_limit(over_805, "lua/cc_workspace/big.lua")
		check(
			type(over_err) == "string" and over_err:find("805 lines", 1, true) ~= nil,
			"805-line Lua file rejected by check_lua_line_limit",
			over_err
		)

		-- Verify `lint_repository` rejects a synthetic 805-line `.lua` file inside an isolated temp repo
		local fake_repo = tmp_root .. "/synthetic-lint-repo"
		vim.fn.mkdir(fake_repo .. "/lua/cc_workspace", "p")
		vim.fn.mkdir(fake_repo .. "/scripts", "p")
		vim.fn.mkdir(fake_repo .. "/tests", "p")
		local f805 = assert(vim.uv.fs_open(fake_repo .. "/lua/cc_workspace/huge.lua", "w", 420))
		vim.uv.fs_write(f805, over_805, 0)
		vim.uv.fs_close(f805)
		local syn_errs = linter.lint_repository(fake_repo)
		local caught_805 = false
		for _, e in ipairs(syn_errs) do
			if e:find("lua/cc_workspace/huge.lua", 1, true) and e:find("exceeding max 800 lines", 1, true) then
				caught_805 = true
				break
			end
		end
		check(caught_805, "lint_repository rejects synthetic 805-line .lua file")

		check(
			#linter.analyze_lua_source("", "lua/cc_workspace/empty.lua", { is_runtime_lua = true }).errors == 0,
			"empty Lua source passes AST lint"
		)
		check(
			#linter.analyze_lua_source(
					"-- comment only\n",
					"lua/cc_workspace/comment.lua",
					{ is_runtime_lua = true }
				).errors == 0,
			"comment-only Lua source passes AST lint"
		)

		local valid_lua = [[
local M = {}
local up = 1
local function helper(a, b)
	for i = 1, 3 do
		up = up + i + a + (b or 0)
	end
	for k, v in pairs({ x = 1 }) do
		local _ = k .. tostring(v)
	end
	repeat
		local inner_done = true
	until inner_done
	return vim.fn.expand("~")
end
function M:run(arg1)
	local ok, ws = pcall(require, "cc_workspace")
	return helper(arg1, self.val), ok, ws
end
return M
]]
		local valid_res = linter.analyze_lua_source(valid_lua, "lua/cc_workspace/sample.lua", { is_runtime_lua = true })
		check(#valid_res.errors == 0, "valid lexical scopes pass AST lint", table.concat(valid_res.errors, "; "))
		check(
			#valid_res.top_requires == 0 and #valid_res.deferred_requires == 1,
			"deferred pcall(require) classified accurately"
		)

		local bad_cases = {
			{ code = "leaked_global = 42\n", label = "bare global variable write rejected" },
			{ code = "do local x = 1 end\nx = 2\n", label = "escaped block-local write rejected" },
			{ code = "function leaked_fn() end\n", label = "non-local global function rejected" },
			{ code = "function UndeclaredTbl.fn() end\n", label = "method on undeclared global table rejected" },
			{ code = "_G.polluted = true\n", label = "_G field write rejected" },
			{ code = "_G.nested.field = 1\n", label = "nested _G field write rejected" },
			{ code = "function _G:method() end\n", label = "_G method declaration rejected" },
			{ code = 'rawset(_G, "polluted", 1)\n', label = "rawset(_G) rejected" },
			{ code = 'vim.fn.system("git status")\n', label = "blocking vim.fn.system rejected" },
			{ code = 'pcall(vim.fn.system, "git status")\n', label = "pcall(vim.fn.system) value ref rejected" },
			{ code = "local sys = vim.fn.system\nreturn sys\n", label = "local alias to vim.fn.system rejected" },
			{ code = 'vim.system({ "git" }):wait()\n', label = "synchronous :wait() rejected" },
			{ code = "local p = 'foo'\nlocal _ = vim.fn.expand(p)\n", label = "unsafe vim.fn.expand(var) rejected" },
			{ code = "local p = 'foo'\npcall(vim.fn.expand, p)\n", label = "pcall(vim.fn.expand, var) rejected" },
			{ code = "local _ = vim.loop.hrtime()\n", label = "deprecated vim.loop rejected" },
			{
				code = "vim.api.nvim_buf_add_highlight(0, -1, 'Error', 0, 0, 1)\n",
				label = "deprecated nvim_buf_add_highlight rejected",
			},
			{
				code = "pcall(vim.api.nvim_buf_add_highlight, 0, -1, 'Error', 0, 0, 1)\n",
				label = "pcall(nvim_buf_add_highlight) value ref rejected",
			},
			{ code = "local cb = '_user_cc_click'\nreturn cb\n", label = "legacy _user_cc_ callback rejected" },
			{
				code = "---" .. "@diagnostic disable\nlocal x = 1\nreturn x\n",
				label = "blanket diagnostic disable rejected",
			},
		}
		for _, tc in ipairs(bad_cases) do
			local res = linter.analyze_lua_source(tc.code, "lua/cc_workspace/render.lua", { is_runtime_lua = true })
			check(#res.errors >= 1, tc.label)
		end

		local proj_bad_wait = linter.analyze_lua_source(
			'local M = {}\nfunction M.bad()\n\treturn vim.system({ "git" }):wait()\nend\nreturn M\n',
			"lua/cc_workspace/projects.lua",
			{ is_runtime_lua = true }
		)
		check(#proj_bad_wait.errors >= 1, ":wait() outside collect_zoxide_candidates in projects.lua rejected")
		local proj_good_wait = linter.analyze_lua_source(
			'local function collect_zoxide_candidates()\n\treturn pcall(function()\n\t\treturn vim.system({ "zoxide" }):wait()\n\tend)\nend\nreturn collect_zoxide_candidates\n',
			"lua/cc_workspace/projects.lua",
			{ is_runtime_lua = true }
		)
		check(#proj_good_wait.errors == 0, ":wait() inside collect_zoxide_candidates in projects.lua allowed")

		local xp_res = linter.analyze_lua_source(
			'local ok, mod = xpcall(require, debug.traceback, "cc_workspace.nonexistent")\nreturn ok, mod\n',
			"lua/cc_workspace/sample.lua",
			{ is_runtime_lua = true }
		)
		check(
			#xp_res.top_requires == 1 and xp_res.top_requires[1] == "cc_workspace.nonexistent",
			"xpcall(require) tracked"
		)

		local known = {
			["cc_workspace"] = true,
			["cc_workspace.a"] = true,
			["cc_workspace.b"] = true,
			["cc_workspace.winbar"] = true,
			["cc_workspace.keymaps"] = true,
		}
		check(#linter.detect_dag_violations({
			["cc_workspace.a"] = { "cc_workspace.b" },
			["cc_workspace.b"] = { "cc_workspace.a" },
		}, known) >= 1, "top-level require() cycle rejected")
		check(#linter.detect_dag_violations({
			["cc_workspace.keymaps"] = { "cc_workspace" },
			["cc_workspace"] = {},
		}, known) >= 1, "leaf module keymaps top-level requiring cc_workspace facade rejected")
		check(#linter.detect_dag_violations({
			["cc_workspace.a"] = { "cc_workspace.nonexistent" },
		}, known) >= 1, "unknown internal module require rejected")

		check(
			#linter.validate_agents_md("---\ntrigger: always_on\n---\n# Bad\n", "AGENTS.md") >= 1,
			"AGENTS.md frontmatter rejected"
		)
		check(
			#linter.validate_agents_md(string.rep("x", 24001), "AGENTS.md") >= 1,
			"oversized AGENTS.md (>24KB) rejected"
		)
		check(
			#linter.validate_rule_markdown("# Missing frontmatter\n", ".agents/rules/bad.md") >= 1,
			"rule without frontmatter rejected"
		)
		check(
			#linter.validate_rule_markdown(
					"---\ntrigger: always_on\nmalformed yaml without colon\n---\nBody\n",
					".agents/rules/bad.md"
				) >= 1,
			"rule with malformed YAML line rejected"
		)
		check(
			#linter.validate_rule_markdown(
					'---\ntrigger: glob\nglobs:\n  - "**/lua/**/*.lua"\n---\nBody\n',
					".agents/rules/bad.md"
				) >= 1,
			"rule with YAML list globs instead of flat string rejected"
		)
		check(
			#linter.validate_rule_markdown(
					'---\ntrigger: glob\nglobs: "**/*.{lua,vim}"\n---\nBody\n',
					".agents/rules/bad.md"
				) >= 1,
			"rule with unexpanded brace globs rejected"
		)
		check(
			#linter.validate_rule_markdown(
					'---\ntrigger: glob\nglobs: "lua/*.lua"\n---\nBody\n',
					".agents/rules/bad.md"
				) >= 1,
			"rule glob without **/ prefix rejected"
		)
		check(
			#linter.validate_skill_markdown(
					"---\nname: wrong-name\ndescription: desc\n---\nBody\n",
					"actual-name",
					".agents/skills/actual-name/SKILL.md"
				) >= 1,
			"skill name mismatch rejected"
		)
		check(
			#linter.validate_skill_markdown(
					"---\nname: Bad_Name\ndescription: desc\n---\nBody\n",
					"Bad_Name",
					".agents/skills/Bad_Name/SKILL.md"
				) >= 1,
			"non-kebab skill folder rejected"
		)

		local md_sample = table.concat({
			"# Doc",
			"Inline `[ignored](./does-not-exist.md)`, double ``[also-ignored](./missing2.md)``, and real [target](./real.md#sec).",
			"````markdown",
			"```sh",
			"[nested-fenced-ignored](./also-missing.md)",
			"```",
			"````",
			"```mermaid",
			"flowchart LR",
			"  A --> B",
			"```",
		}, "\n")
		local links, m_errs = linter.extract_markdown_links_and_mermaid(md_sample, "doc.md")
		check(
			#links == 1 and links[1].target == "./real.md",
			"markdown link extractor handles multi-backtick inline/nested fences and strips anchors"
		)
		check(#m_errs == 1, "horizontal Mermaid flowchart LR rejected")
		local _, merr_unconnected = linter.extract_markdown_links_and_mermaid(
			'```mermaid\nflowchart TD\n  A["One"]\n  B["Two"]\n```\n',
			"doc.md"
		)
		check(#merr_unconnected >= 1, "unconnected horizontal Mermaid nodes rejected")
		local _, merr_floating_sg = linter.extract_markdown_links_and_mermaid(
			"```mermaid\nflowchart TD\n  A --> B\n  subgraph sg1\n    C --> D\n  end\n```\n",
			"doc.md"
		)
		check(#merr_floating_sg >= 1, "floating disconnected Mermaid subgraph rejected")
	end

	dofile(plugin_root .. "/tests/test_commit_msg.lua")(ctx)
end
