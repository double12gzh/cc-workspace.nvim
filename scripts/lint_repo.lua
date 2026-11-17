-- Architectural, AST, max-line-ceiling, hygiene, and customization linter for `cc-workspace.nvim`.
-- Run standalone:
--   nvim --headless -u NONE -l scripts/lint_repo.lua

local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = vim.fs.normalize(vim.fn.fnamemodify(script_path, ":p:h"))
local md_linter = dofile(script_dir .. "/lint_markdown.lua")
local cm_linter = dofile(script_dir .. "/lint_commit_msg.lua")

local M = {
	MAX_LUA_LINES = 800,
	parse_frontmatter = md_linter.parse_frontmatter,
	validate_agents_md = md_linter.validate_agents_md,
	validate_rule_markdown = md_linter.validate_rule_markdown,
	validate_skill_markdown = md_linter.validate_skill_markdown,
	extract_markdown_links_and_mermaid = md_linter.extract_markdown_links_and_mermaid,
	validate_commit_message = cm_linter.validate_commit_message,
	check_cliff_toml_sync = cm_linter.check_cliff_toml_sync,
}

local LEAF_NO_FACADE_MODULES = {
	["cc_workspace.config"] = true,
	["cc_workspace.icons"] = true,
	["cc_workspace.state"] = true,
	["cc_workspace.git"] = true,
	["cc_workspace.worktree_ops"] = true,
	["cc_workspace.agent_state"] = true,
	["cc_workspace.worktree"] = true,
	["cc_workspace.winbar_highlights"] = true,
	["cc_workspace.winbar"] = true,
	["cc_workspace.statusline"] = true,
	["cc_workspace.switcher"] = true,
	["cc_workspace.keymaps"] = true,
}

local DEPRECATED_DOTTED_CALLS = {
	["vim.api.nvim_buf_add_highlight"] = "use vim.api.nvim_buf_set_extmark instead",
	["vim.api.nvim_buf_get_option"] = "use vim.bo[buf] instead",
	["vim.api.nvim_buf_set_option"] = "use vim.bo[buf] instead",
	["vim.api.nvim_win_get_option"] = "use vim.wo[win] instead",
	["vim.api.nvim_win_set_option"] = "use vim.wo[win] instead",
	["vim.tbl_islist"] = "use vim.islist instead",
	["vim.tbl_flatten"] = "use vim.iter(...):flatten():totable() instead",
}

local FORBIDDEN_BLOCKING_CALLS = {
	["vim.fn.system"] = "blocking subprocess forbidden in lua/; use async vim.system",
	["vim.fn.systemlist"] = "blocking subprocess forbidden in lua/; use async vim.system",
	["io.popen"] = "blocking subprocess forbidden in lua/; use async vim.system",
	["os.execute"] = "blocking subprocess forbidden in lua/; use async vim.system",
}

---Read an entire file from disk as a string.
---@param path string
---@return string|nil content, string|nil err
local function read_file(path)
	local st = vim.uv.fs_stat(path)
	if not st or st.type ~= "file" then
		return nil, "not a regular file: " .. tostring(path)
	end
	local fd = vim.uv.fs_open(path, "r", 438)
	if not fd then
		return nil, "unable to open: " .. tostring(path)
	end
	local data = st.size > 0 and vim.uv.fs_read(fd, st.size, 0) or ""
	vim.uv.fs_close(fd)
	return data or "", nil
end

---Recursively collect files matching `pred` under `root_dir` in deterministic sorted order.
---@param root_dir string
---@param pred fun(rel_path: string, full_path: string): boolean
---@return string[]
local function list_files_sorted(root_dir, pred)
	local out = {}
	local function walk(dir, rel_prefix)
		local scan = vim.uv.fs_scandir(dir)
		if not scan then
			return
		end
		while true do
			---@type string?, string?
			local name, entry_type = vim.uv.fs_scandir_next(scan)
			if not name then
				break
			end
			local full = dir .. "/" .. name
			local rel = rel_prefix ~= "" and (rel_prefix .. "/" .. name) or name
			if not entry_type then
				local st = vim.uv.fs_lstat(full)
				entry_type = st and st.type or nil
			end
			if entry_type == "directory" then
				walk(full, rel)
			elseif entry_type == "file" and pred(rel, full) then
				table.insert(out, full)
			end
		end
	end
	walk(root_dir, "")
	table.sort(out)
	return out
end

---Count physical lines in a source string (matching `wc -l` for trailing-newline files).
---@param src string
---@return integer
function M.count_file_lines(src)
	if src == "" then
		return 0
	end
	local count = 0
	for _ in src:gmatch("\n") do
		count = count + 1
	end
	return src:sub(-1) == "\n" and count or (count + 1)
end

---Verify a `.lua` file does not exceed `max_lines` (`M.MAX_LUA_LINES = 800` by default).
---@param src string
---@param rel_path string
---@param max_lines? integer
---@return string|nil err
function M.check_lua_line_limit(src, rel_path, max_lines)
	local cap = max_lines or M.MAX_LUA_LINES
	local lines = M.count_file_lines(src)
	if lines > cap then
		return string.format("%s: file has %d lines, exceeding max %d lines", rel_path, lines, cap)
	end
	return nil
end

---Convert a `lua/?.lua` or `lua/?/init.lua` relative path to its Lua module name.
---@param rel_from_repo string
---@return string|nil
function M.lua_rel_to_module(rel_from_repo)
	local sub = rel_from_repo:match("^lua/(.+)%.lua$")
	return sub and sub:gsub("/", "."):gsub("%.init$", "") or nil
end

---Check whether `mod_name` belongs to this plugin's internal Lua namespace.
---@param mod_name string
---@return boolean
local function is_internal_module(mod_name)
	return mod_name == "cc_workspace"
		or mod_name:sub(1, 13) == "cc_workspace."
		or mod_name == "codecompanion._extensions.workspace"
		or mod_name:sub(1, 36) == "codecompanion._extensions.workspace."
end

---@param node TSNode
---@param src string
---@return string|nil
local function get_dotted_expr(node, src)
	local ntype = node:type()
	if ntype == "identifier" then
		return vim.treesitter.get_node_text(node, src)
	elseif ntype == "dot_index_expression" then
		local tbl, fld = (node:field("table") or {})[1], (node:field("field") or {})[1]
		local left = tbl and get_dotted_expr(tbl, src) or nil
		return (left and fld) and (left .. "." .. vim.treesitter.get_node_text(fld, src)) or nil
	end
	return nil
end

---@param node TSNode|nil
---@param src string
---@return string|nil
local function get_root_identifier(node, src)
	local cur = node
	while cur do
		local t = cur:type()
		if t == "identifier" then
			return vim.treesitter.get_node_text(cur, src)
		elseif t == "dot_index_expression" or t == "bracket_index_expression" or t == "method_index_expression" then
			cur = (cur:field("table") or {})[1]
		else
			return nil
		end
	end
	return nil
end

---@param node TSNode|nil
---@param src string
---@return string|nil
local function extract_string_literal(node, src)
	if not node or node:type() ~= "string" then
		return nil
	end
	local content_node = (node:field("content") or {})[1]
	return content_node and vim.treesitter.get_node_text(content_node, src) or ""
end

---@param args_node TSNode|nil
---@return TSNode[]
local function collect_arg_nodes(args_node)
	local out = {}
	for i = 0, (args_node and args_node:named_child_count() or 0) - 1 do
		local c = args_node and args_node:named_child(i) or nil
		if c then
			table.insert(out, c)
		end
	end
	return out
end

---@param node TSNode
---@return boolean
local function is_inside_function(node)
	local cur = node:parent()
	while cur do
		local t = cur:type()
		if t == "function_declaration" or t == "function_definition" then
			return true
		end
		cur = cur:parent()
	end
	return false
end

---@param node TSNode
---@param src string
---@param target_name string
---@return boolean
local function has_enclosing_named_function(node, src, target_name)
	local cur = node:parent()
	while cur do
		if cur:type() == "function_declaration" then
			local fn_node = (cur:field("name") or {})[1]
			if fn_node and vim.treesitter.get_node_text(fn_node, src) == target_name then
				return true
			end
		end
		cur = cur:parent()
	end
	return false
end

---@class CcWsLuaAnalysisResult
---@field errors string[]
---@field top_requires string[]
---@field deferred_requires { mod: string, line: integer }[]

---Analyze a Lua source string for syntax, AST hygiene, lexical global writes, and `require` edges.
---@param src string
---@param rel_path string
---@param opts? { is_runtime_lua?: boolean }
---@return CcWsLuaAnalysisResult
function M.analyze_lua_source(src, rel_path, opts)
	opts = opts or {}
	local is_runtime_lua = opts.is_runtime_lua == true
	local errors, top_requires, deferred_requires = {}, {}, {}

	local function add_err(line_1idx, col_1idx, msg)
		table.insert(errors, string.format("%s:%d:%d: %s", rel_path, line_1idx, col_1idx, msg))
	end

	local chunk_fn, load_err = load(src, "@" .. rel_path)
	if not chunk_fn then
		table.insert(errors, string.format("%s: LuaJIT compile error: %s", rel_path, tostring(load_err)))
		return { errors = errors, top_requires = top_requires, deferred_requires = deferred_requires }
	end

	local parser = vim.treesitter.get_string_parser(src, "lua")
	local trees = parser:parse()
	local root = trees and trees[1] and trees[1]:root() or nil
	if not root or root:has_error() then
		add_err(1, 1, "Treesitter Lua parse error")
		return { errors = errors, top_requires = top_requires, deferred_requires = deferred_requires }
	end

	local lnum = 1
	for line in (src .. "\n"):gmatch("(.-)\n") do
		if is_runtime_lua then
			local c_legacy = line:find("_user_cc_", 1, true)
			if c_legacy then
				add_err(lnum, c_legacy, "legacy '_user_cc_' global callback identifier is forbidden in lua/")
			end
		end
		local c_diag = line:find("^%s*%-%-%-@diagnostic%s+disable%f[^%w%-]")
		if c_diag then
			add_err(
				lnum,
				c_diag,
				"blanket '---@diagnostic disable' is forbidden; fix the type or use disable-next-line"
			)
		end
		lnum = lnum + 1
	end

	local function bind_parameters(params_node, scope)
		if not params_node then
			return
		end
		for i = 0, params_node:named_child_count() - 1 do
			local p = params_node:named_child(i)
			if p and p:type() == "identifier" then
				scope[vim.treesitter.get_node_text(p, src)] = true
			end
		end
	end

	local function extract_local_var_names(decl_node)
		local names = {}
		for i = 0, decl_node:named_child_count() - 1 do
			local sub = decl_node:named_child(i)
			local vlist = nil
			if sub and sub:type() == "variable_list" then
				vlist = sub
			elseif sub and sub:type() == "assignment_statement" then
				for j = 0, sub:named_child_count() - 1 do
					local sc = sub:named_child(j)
					if sc and sc:type() == "variable_list" then
						vlist = sc
						break
					end
				end
			end
			if vlist then
				for k = 0, vlist:named_child_count() - 1 do
					local id = vlist:named_child(k)
					if id and id:type() == "identifier" then
						table.insert(names, vim.treesitter.get_node_text(id, src))
					end
				end
			end
		end
		return names
	end

	local function is_local_bound(scopes, name)
		for i = #scopes, 1, -1 do
			if scopes[i][name] then
				return true
			end
		end
		return false
	end

	local function is_safe_tilde_expand_callee(dot_node)
		local parent = dot_node:parent()
		if not parent or parent:type() ~= "function_call" or (parent:field("name") or {})[1] ~= dot_node then
			return false
		end
		local args = collect_arg_nodes((parent:field("arguments") or {})[1])
		return #args == 1 and extract_string_literal(args[1], src) == "~"
	end

	local function check_dot_expression(node)
		local parent = node:parent()
		if parent and parent:type() == "dot_index_expression" and (parent:field("table") or {})[1] == node then
			return
		end
		local dotted = get_dotted_expr(node, src)
		if not dotted then
			return
		end
		local r0, c0 = node:start()
		local line1, col1 = r0 + 1, c0 + 1
		if dotted == "vim.loop" or dotted:sub(1, 9) == "vim.loop." then
			add_err(line1, col1, string.format("deprecated API '%s' (use vim.uv instead)", dotted))
		end
		if DEPRECATED_DOTTED_CALLS[dotted] then
			add_err(line1, col1, string.format("deprecated API '%s' (%s)", dotted, DEPRECATED_DOTTED_CALLS[dotted]))
		end
		if is_runtime_lua then
			if FORBIDDEN_BLOCKING_CALLS[dotted] then
				add_err(line1, col1, FORBIDDEN_BLOCKING_CALLS[dotted])
			end
			if dotted == "vim.fn.expand" and not is_safe_tilde_expand_callee(node) then
				add_err(
					line1,
					col1,
					"vim.fn.expand() on non-'~' path is forbidden in lua/; use projects.expand_raw_dir_path"
				)
			end
		end
	end

	local walk_node

	local function walk_block(block_node, scopes, extra_bindings)
		local scope = {}
		for k, v in pairs(extra_bindings or {}) do
			scope[k] = v
		end
		table.insert(scopes, scope)
		for i = 0, block_node:named_child_count() - 1 do
			local stmt = block_node:named_child(i)
			if stmt then
				walk_node(stmt, scopes)
			end
		end
		table.remove(scopes)
		return scope
	end

	local function check_function_call(node)
		local callee = (node:field("name") or {})[1]
		if not callee then
			return
		end
		local r0, c0 = node:start()
		local line1, col1 = r0 + 1, c0 + 1
		local args = collect_arg_nodes((node:field("arguments") or {})[1])

		if callee:type() == "method_index_expression" then
			local m_node = (callee:field("method") or {})[1]
			local m_name = m_node and vim.treesitter.get_node_text(m_node, src) or nil
			if is_runtime_lua and m_name == "wait" then
				local allowed_zoxide = (
					rel_path == "lua/cc_workspace/projects.lua"
					and has_enclosing_named_function(node, src, "collect_zoxide_candidates")
				)
				if not allowed_zoxide then
					add_err(line1, col1, "synchronous ':wait()' is forbidden in lua/; use async callbacks")
				end
			end
			return
		end

		local dotted = get_dotted_expr(callee, src)
		if not dotted then
			return
		end
		if is_runtime_lua and dotted == "rawset" and #args >= 1 and args[1]:type() == "identifier" then
			if vim.treesitter.get_node_text(args[1], src) == "_G" then
				add_err(line1, col1, "rawset(_G, ...) global mutation is forbidden in lua/")
			end
		end

		local req_mod = nil
		if dotted == "require" and #args >= 1 then
			req_mod = extract_string_literal(args[1], src)
		elseif dotted == "pcall" and #args >= 2 and args[1]:type() == "identifier" then
			if vim.treesitter.get_node_text(args[1], src) == "require" then
				req_mod = extract_string_literal(args[2], src)
			end
		elseif dotted == "xpcall" and #args >= 3 and args[1]:type() == "identifier" then
			if vim.treesitter.get_node_text(args[1], src) == "require" then
				req_mod = extract_string_literal(args[3], src)
			end
		end
		if req_mod and req_mod ~= "" then
			if is_inside_function(node) then
				table.insert(deferred_requires, { mod = req_mod, line = line1 })
			else
				table.insert(top_requires, req_mod)
			end
		end
	end

	walk_node = function(node, scopes)
		local ntype = node:type()
		if ntype == "dot_index_expression" then
			check_dot_expression(node)
		end

		if ntype == "variable_declaration" then
			for i = 0, node:named_child_count() - 1 do
				local sub = node:named_child(i)
				if sub and sub:type() == "assignment_statement" then
					for j = 0, sub:named_child_count() - 1 do
						local sc = sub:named_child(j)
						if sc and sc:type() == "expression_list" then
							walk_node(sc, scopes)
						end
					end
				end
			end
			for _, vname in ipairs(extract_local_var_names(node)) do
				scopes[#scopes][vname] = true
			end
			return
		end

		if ntype == "function_declaration" or ntype == "function_definition" then
			local fn_scope = {}
			if ntype == "function_declaration" then
				local first_tok = node:child(0)
				local is_local_fn = first_tok ~= nil and first_tok:type() == "local"
				local fn_name_node = (node:field("name") or {})[1]
				if is_local_fn then
					if fn_name_node and fn_name_node:type() == "identifier" then
						scopes[#scopes][vim.treesitter.get_node_text(fn_name_node, src)] = true
					end
				elseif fn_name_node then
					local fn_t = fn_name_node:type()
					local r0, c0 = fn_name_node:start()
					if fn_t == "identifier" and is_runtime_lua then
						local fname = vim.treesitter.get_node_text(fn_name_node, src)
						if not is_local_bound(scopes, fname) then
							add_err(r0 + 1, c0 + 1, "accidental global function '" .. fname .. "' (missing 'local')")
						end
					elseif is_runtime_lua and (fn_t == "dot_index_expression" or fn_t == "method_index_expression") then
						local root_id = get_root_identifier(fn_name_node, src)
						if root_id == "_G" then
							add_err(r0 + 1, c0 + 1, "_G global function is forbidden in lua/")
						elseif root_id and root_id ~= "vim" and not is_local_bound(scopes, root_id) then
							add_err(r0 + 1, c0 + 1, "function defined on undeclared global table '" .. root_id .. "'")
						end
						walk_node(fn_name_node, scopes)
					else
						walk_node(fn_name_node, scopes)
					end
				end
				if fn_name_node and fn_name_node:type() == "method_index_expression" then
					fn_scope["self"] = true
				end
			end
			bind_parameters((node:field("parameters") or {})[1], fn_scope)
			local body = (node:field("body") or {})[1]
			if body then
				walk_block(body, scopes, fn_scope)
			end
			return
		end

		if ntype == "for_statement" then
			local clause = (node:field("clause") or {})[1]
			local loop_bindings = {}
			if clause and clause:type() == "for_numeric_clause" then
				for _, fld in ipairs({ "start", "end", "step" }) do
					local fn_expr = (clause:field(fld) or {})[1]
					if fn_expr then
						walk_node(fn_expr, scopes)
					end
				end
				local iname = (clause:field("name") or {})[1]
				if iname then
					loop_bindings[vim.treesitter.get_node_text(iname, src)] = true
				end
			elseif clause and clause:type() == "for_generic_clause" then
				for i = 0, clause:named_child_count() - 1 do
					local sub = clause:named_child(i)
					if sub and sub:type() == "expression_list" then
						walk_node(sub, scopes)
					elseif sub and sub:type() == "variable_list" then
						for k = 0, sub:named_child_count() - 1 do
							local id = sub:named_child(k)
							if id and id:type() == "identifier" then
								loop_bindings[vim.treesitter.get_node_text(id, src)] = true
							end
						end
					end
				end
			end
			local body = (node:field("body") or {})[1]
			if body then
				walk_block(body, scopes, loop_bindings)
			end
			return
		end

		if ntype == "repeat_statement" then
			local body = (node:field("body") or {})[1]
			local cond = (node:field("condition") or {})[1]
			local body_scope = body and walk_block(body, scopes) or {}
			if cond then
				table.insert(scopes, body_scope)
				walk_node(cond, scopes)
				table.remove(scopes)
			end
			return
		end

		if ntype == "block" then
			walk_block(node, scopes)
			return
		end

		if ntype == "assignment_statement" then
			local parent = node:parent()
			if not (parent and parent:type() == "variable_declaration") and is_runtime_lua then
				for i = 0, node:named_child_count() - 1 do
					local sub = node:named_child(i)
					if sub and sub:type() == "variable_list" then
						for k = 0, sub:named_child_count() - 1 do
							local target = sub:named_child(k)
							if target and target:type() == "identifier" then
								local vname = vim.treesitter.get_node_text(target, src)
								if not is_local_bound(scopes, vname) then
									local r0, c0 = target:start()
									add_err(
										r0 + 1,
										c0 + 1,
										string.format("accidental global variable write '%s' (missing 'local')", vname)
									)
								end
							elseif
								target
								and (target:type() == "dot_index_expression" or target:type() == "bracket_index_expression")
								and get_root_identifier(target, src) == "_G"
							then
								local r0, c0 = target:start()
								add_err(r0 + 1, c0 + 1, "_G global table write is forbidden in lua/")
							end
						end
					end
				end
			end
		end

		if ntype == "function_call" then
			check_function_call(node)
		end

		for i = 0, node:named_child_count() - 1 do
			local child = node:named_child(i)
			if child then
				walk_node(child, scopes)
			end
		end
	end

	walk_block(root, {})
	return { errors = errors, top_requires = top_requires, deferred_requires = deferred_requires }
end

---Detect cycles and leaf-boundary violations in a module top-level `require` graph.
---@param adj table<string, string[]>
---@param known_modules table<string, boolean>
---@return string[] errors
function M.detect_dag_violations(adj, known_modules)
	local errs, mod_names = {}, {}
	for m in pairs(adj) do
		table.insert(mod_names, m)
	end
	table.sort(mod_names)

	for _, mod in ipairs(mod_names) do
		for _, dep in ipairs(adj[mod] or {}) do
			if is_internal_module(dep) and not known_modules[dep] then
				table.insert(errs, string.format("module '%s' top-level requires unknown module '%s'", mod, dep))
			end
			if LEAF_NO_FACADE_MODULES[mod] and dep == "cc_workspace" then
				table.insert(
					errs,
					string.format(
						"leaf module '%s' must not top-level require facade 'cc_workspace' (use deferred pcall(require, ...))",
						mod
					)
				)
			end
		end
	end

	local color, stack, stack_pos = {}, {}, {}
	local function dfs(u)
		color[u] = 1
		table.insert(stack, u)
		stack_pos[u] = #stack
		local deps = vim.deepcopy(adj[u] or {})
		table.sort(deps)
		for _, v in ipairs(deps) do
			if adj[v] ~= nil then
				if color[v] == 1 then
					local cycle = {}
					for idx = stack_pos[v], #stack do
						table.insert(cycle, stack[idx])
					end
					table.insert(cycle, v)
					table.insert(errs, "top-level require() cycle detected: " .. table.concat(cycle, " -> "))
				elseif not color[v] then
					dfs(v)
				end
			end
		end
		stack_pos[u] = nil
		table.remove(stack)
		color[u] = 2
	end

	for _, m in ipairs(mod_names) do
		if not color[m] then
			dfs(m)
		end
	end
	return errs
end

---Run all repository lint checks against `repo_root`.
---@param repo_root string
---@return string[] errors, table stats
function M.lint_repository(repo_root)
	local all_errors = {}
	local stats = { lua_files = 0, modules = 0, rules = 0, skills = 0, md_links_checked = 0 }

	local lua_runtime_files = list_files_sorted(repo_root .. "/lua", function(rel)
		return rel:sub(-4) == ".lua"
	end)
	local known_modules, mod_by_file = {}, {}
	for _, full in ipairs(lua_runtime_files) do
		local mod = M.lua_rel_to_module(full:sub(#repo_root + 2))
		if mod then
			known_modules[mod] = true
			mod_by_file[full] = mod
			stats.modules = stats.modules + 1
		end
	end

	local top_adj = {}
	for _, subdir in ipairs({ "lua", "tests", "scripts" }) do
		local files = list_files_sorted(repo_root .. "/" .. subdir, function(rel)
			return rel:sub(-4) == ".lua"
		end)
		for _, full in ipairs(files) do
			stats.lua_files = stats.lua_files + 1
			local rel = full:sub(#repo_root + 2)
			local src, rerr = read_file(full)
			if not src then
				table.insert(all_errors, rel .. ": " .. tostring(rerr))
			else
				local line_err = M.check_lua_line_limit(src, rel, M.MAX_LUA_LINES)
				if line_err then
					table.insert(all_errors, line_err)
				end
				local is_rt = (subdir == "lua")
				local res = M.analyze_lua_source(src, rel, { is_runtime_lua = is_rt })
				vim.list_extend(all_errors, res.errors)
				if is_rt then
					local mod = mod_by_file[full]
					if mod then
						top_adj[mod] = res.top_requires
					end
					for _, dreq in ipairs(res.deferred_requires) do
						if is_internal_module(dreq.mod) and not known_modules[dreq.mod] then
							table.insert(
								all_errors,
								string.format(
									"%s:%d: deferred require('%s') references unknown internal module",
									rel,
									dreq.line,
									dreq.mod
								)
							)
						end
					end
				end
			end
		end
	end

	vim.list_extend(all_errors, M.detect_dag_violations(top_adj, known_modules))

	local test_src = read_file(repo_root .. "/tests/run_headless.lua") or ""
	for _, guard in ipairs({
		{ "before_projects_sha == after_projects_sha", "missing live cc-workspace-projects.json SHA-256 guard" },
		{ "before_history_sha == after_history_sha", "missing live codecompanion-history SHA-256 guard" },
		{ "before_history_tree == after_history_tree", "missing live codecompanion-history tree guard" },
		{ "before_worktrees_tree == after_worktrees_tree", "missing live cc-worktrees tree guard" },
	}) do
		if not test_src:find(guard[1], 1, true) then
			table.insert(all_errors, "tests/run_headless.lua: " .. guard[2])
		end
	end

	local doc_errs, doc_stats = md_linter.lint_docs_and_customizations(repo_root, read_file, list_files_sorted)
	vim.list_extend(all_errors, doc_errs)
	vim.list_extend(all_errors, cm_linter.check_cliff_toml_sync(repo_root))
	stats.rules = doc_stats.rules
	stats.skills = doc_stats.skills
	stats.md_links_checked = doc_stats.md_links_checked

	return all_errors, stats
end

if not vim.g.cc_ws_lint_as_lib then
	local repo_root = vim.fs.normalize(vim.fn.fnamemodify(script_path, ":p:h:h"))
	local errs, stats = M.lint_repository(repo_root)
	if #errs > 0 then
		for _, e in ipairs(errs) do
			io.stderr:write("LINT ERROR: " .. e .. "\n")
		end
		io.stderr:write(string.format("lint_repo.lua failed with %d error(s)\n", #errs))
		os.exit(1)
	end
	io.stdout:write(
		string.format(
			"lint_repo.lua: OK (%d lua files, %d modules, %d rules, %d skills, %d md links verified)\n",
			stats.lua_files,
			stats.modules,
			stats.rules,
			stats.skills,
			stats.md_links_checked
		)
	)
	os.exit(0)
end

return M
