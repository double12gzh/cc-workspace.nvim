-- Markdown frontmatter, agent customization (.agents/{rules,skills}), link, and Mermaid linter.
-- Loaded by `scripts/lint_repo.lua`.

local M = {}

local MAX_RULE_BYTES = 24000
local MAX_MERMAID_LABEL_WIDTH = 48
local MAX_MERMAID_FANOUT = 3

---Parse simple YAML frontmatter (`---\n...\n---\n`) at the top of a Markdown string.
---@param md string
---@return table<string, string>|nil fields, string body, boolean has_frontmatter, string|nil parse_err
function M.parse_frontmatter(md)
	if md:sub(1, 4) ~= "---\n" then
		return nil, md, false, nil
	end
	local close_start, close_end = md:find("\n---\n", 4, true)
	if not close_start then
		return nil, md, true, "unclosed YAML frontmatter (missing closing '---')"
	end
	local raw_yaml = md:sub(5, close_start - 1)
	local body = md:sub(close_end + 1)
	local fields = {}
	local current_folded_key = nil
	local current_folded_sep = " "
	local folded_parts = {}

	local function flush_folded()
		if current_folded_key then
			fields[current_folded_key] = vim.trim(table.concat(folded_parts, current_folded_sep))
			current_folded_key = nil
			folded_parts = {}
		end
	end

	local lnum = 1
	for line in (raw_yaml .. "\n"):gmatch("(.-)\n") do
		lnum = lnum + 1
		if current_folded_key then
			if line:match("^%s*$") then
				if current_folded_sep == "\n" then
					table.insert(folded_parts, "")
				end
			elseif line:match("^%s+%S") then
				table.insert(folded_parts, vim.trim(line))
			else
				flush_folded()
			end
		end
		if not current_folded_key then
			local trimmed = vim.trim(line)
			if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
				if line:match("^%s") then
					return nil, body, true, string.format("line %d: unexpected indentation or YAML list item", lnum)
				end
				local k, v = line:match("^([%w_%-]+)%s*:%s*(.*)$")
				if not k then
					return nil, body, true, string.format("line %d: malformed YAML entry '%s'", lnum, trimmed)
				end
				local val = vim.trim(v)
				if val == ">-" or val == ">" then
					current_folded_key = k
					current_folded_sep = " "
					folded_parts = {}
				elseif val == "|" or val == "|-" then
					current_folded_key = k
					current_folded_sep = "\n"
					folded_parts = {}
				else
					if #val >= 2 then
						local q1, q2 = val:sub(1, 1), val:sub(-1)
						if q1 == '"' and q2 == '"' and not val:sub(2, -2):find('"', 1, true) then
							val = val:sub(2, -2)
						elseif q1 == "'" and q2 == "'" and not val:sub(2, -2):find("'", 1, true) then
							val = val:sub(2, -2)
						end
					end
					fields[k] = val
				end
			end
		end
	end
	flush_folded()
	return fields, body, true, nil
end

---Validate standalone `AGENTS.md` / `GEMINI.md` content (no frontmatter, non-empty, `<= 24000` bytes).
---@param content string
---@param rel_path string
---@return string[] errors
function M.validate_agents_md(content, rel_path)
	local errs = {}
	if #content == 0 then
		table.insert(errs, rel_path .. ": file is empty")
	end
	if #content > MAX_RULE_BYTES then
		table.insert(errs, string.format("%s: size %d exceeds %d byte rule cap", rel_path, #content, MAX_RULE_BYTES))
	end
	if content:sub(1, 4) == "---\n" then
		table.insert(errs, rel_path .. ": standalone AGENTS.md must not start with YAML frontmatter")
	end
	return errs
end

---Validate `.agents/rules/<name>.md` content (valid YAML frontmatter, `trigger`, `globs`, byte cap).
---@param content string
---@param rel_path string
---@return string[] errors
function M.validate_rule_markdown(content, rel_path)
	local errs = {}
	if #content > MAX_RULE_BYTES then
		table.insert(errs, string.format("%s: size %d exceeds %d byte rule cap", rel_path, #content, MAX_RULE_BYTES))
	end
	local fm, body, has_fm, fm_err = M.parse_frontmatter(content)
	if not has_fm or not fm then
		table.insert(
			errs,
			rel_path .. ": missing or invalid YAML frontmatter" .. (fm_err and (" (" .. fm_err .. ")") or "")
		)
		return errs
	end
	local trigger = fm.trigger
	local valid_triggers = { always_on = true, glob = true, model_decision = true, manual = true }
	if not trigger or not valid_triggers[trigger] then
		table.insert(
			errs,
			string.format("%s: invalid or missing frontmatter 'trigger' (got %s)", rel_path, tostring(trigger))
		)
	elseif trigger == "glob" then
		local globs = fm.globs or ""
		if globs == "" then
			table.insert(errs, rel_path .. ": trigger 'glob' requires non-empty 'globs' string")
		elseif globs:find("[{}]") then
			table.insert(errs, rel_path .. ": 'globs' must expand braces instead of using '{...}'")
		elseif globs:find("[\"']") then
			table.insert(errs, rel_path .. ": 'globs' must be a single comma-separated string without embedded quotes")
		else
			for part in globs:gmatch("[^,]+") do
				local pat = vim.trim(part)
				if pat == "" then
					table.insert(errs, rel_path .. ": empty pattern in comma-separated 'globs'")
				elseif pat:find("/", 1, true) and pat:sub(1, 3) ~= "**/" then
					table.insert(
						errs,
						string.format("%s: workspace-relative glob '%s' must start with '**/'", rel_path, pat)
					)
				end
			end
		end
	elseif trigger == "model_decision" and (not fm.description or fm.description == "") then
		table.insert(errs, rel_path .. ": trigger 'model_decision' requires non-empty 'description'")
	end
	if vim.trim(body) == "" then
		table.insert(errs, rel_path .. ": rule Markdown body is empty")
	end
	return errs
end

---Validate `.agents/skills/<skill_dir>/SKILL.md` frontmatter and naming contract.
---@param content string
---@param skill_dir_name string
---@param rel_path string
---@return string[] errors
function M.validate_skill_markdown(content, skill_dir_name, rel_path)
	local errs = {}
	local valid_kebab = skill_dir_name:match("^[a-z0-9][a-z0-9%-]*$") ~= nil
		and not skill_dir_name:find("%-%-")
		and skill_dir_name:sub(-1) ~= "-"
	if not valid_kebab then
		table.insert(
			errs,
			string.format("%s: skill folder '%s' must be lowercase hyphenated", rel_path, skill_dir_name)
		)
	end
	local fm, body, has_fm, fm_err = M.parse_frontmatter(content)
	if not has_fm or not fm then
		table.insert(
			errs,
			rel_path .. ": SKILL.md missing or invalid YAML frontmatter" .. (fm_err and (" (" .. fm_err .. ")") or "")
		)
		return errs
	end
	if fm.name ~= skill_dir_name then
		table.insert(
			errs,
			string.format(
				"%s: frontmatter name '%s' must match skill folder '%s'",
				rel_path,
				tostring(fm.name),
				skill_dir_name
			)
		)
	end
	if not fm.description or vim.trim(fm.description) == "" then
		table.insert(errs, rel_path .. ": SKILL.md requires non-empty 'description'")
	end
	if vim.trim(body) == "" then
		table.insert(errs, rel_path .. ": SKILL.md body is empty")
	end
	return errs
end

---Strip CommonMark inline code spans (supporting single, double, or N-backtick delimiters).
---@param line string
---@return string
local function strip_inline_code_spans(line)
	local out = {}
	local i = 1
	local len = #line
	while i <= len do
		local s, e = line:find("`+", i)
		if not s or not e then
			table.insert(out, line:sub(i))
			break
		end
		if s > i then
			table.insert(out, line:sub(i, s - 1))
		end
		local tick_len = e - s + 1
		local pos = e + 1
		local matched_close = nil
		while pos <= len do
			local cs, ce = line:find("`+", pos)
			if not cs or not ce then
				break
			end
			if (ce - cs + 1) == tick_len then
				matched_close = ce
				break
			end
			pos = ce + 1
		end
		if matched_close then
			i = matched_close + 1
		else
			table.insert(out, line:sub(s, e))
			i = e + 1
		end
	end
	return table.concat(out)
end

---Extract node ID and optional label text from a Mermaid flowchart endpoint token.
---@param token string
---@return string|nil id, string|nil label
local function parse_mermaid_node_token(token)
	local t = vim.trim(token):gsub(":::[%w_%-]+$", "")
	if t == "" then
		return nil, nil
	end
	local id, rest = t:match("^([%w_%-]+)%s*(.*)$")
	if not id then
		return nil, nil
	end
	local label = nil
	if rest and rest ~= "" then
		label = rest:match('^%[%"(.-)%"%]$')
			or rest:match('^%(%["(.-)"%]%)$')
			or rest:match("^%[(.-)%]$")
			or rest:match("^%((.-)%)$")
			or rest:match("^%{(.-)%}$")
	end
	return id, label
end

---Audit a single Mermaid code block against terminal-width & vertical layout rules.
---@param block_lines { lnum: integer, text: string }[]
---@param rel_path string
---@return string[] errors
local function validate_mermaid_block(block_lines, rel_path)
	local errs = {}
	local is_flowchart = false
	local all_nodes = {} ---@type table<string, integer>
	local node_order = {} ---@type string[]
	local degree = {} ---@type table<string, integer>
	local edges = {} ---@type { u: string, v: string, invisible: boolean }[]
	local fanout_sets = {} ---@type table<string, table<string, boolean>>
	local subgraphs = {} ---@type { id: string, lnum: integer, members: table<string, boolean> }[]
	local sg_stack = {} ---@type { id: string, lnum: integer, members: table<string, boolean> }[]

	local function register_node(id, label, lnum)
		if not all_nodes[id] then
			all_nodes[id] = lnum
			table.insert(node_order, id)
		end
		degree[id] = degree[id] or 0
		for _, sg in ipairs(sg_stack) do
			sg.members[id] = true
		end
		if label and label ~= "" then
			for seg in (label:gsub("<br%s*/?>", "\n") .. "\n"):gmatch("(.-)\n") do
				local w = vim.fn.strdisplaywidth(vim.trim(seg))
				if w > MAX_MERMAID_LABEL_WIDTH then
					table.insert(
						errs,
						string.format(
							"%s:%d: Mermaid node '%s' single-line label width (%d) exceeds %d cols",
							rel_path,
							lnum,
							id,
							w,
							MAX_MERMAID_LABEL_WIDTH
						)
					)
				end
			end
		end
	end

	for _, item in ipairs(block_lines) do
		local lnum = item.lnum
		local trimmed = vim.trim(item.text)
		if trimmed ~= "" and trimmed:sub(1, 2) ~= "%%" then
			local kw, dir = trimmed:match("^(flowchart)%s+([%a]+)%f[%W]")
			if not kw then
				kw, dir = trimmed:match("^(graph)%s+([%a]+)%f[%W]")
			end
			if kw then
				local up_dir = (dir or ""):upper()
				if up_dir == "LR" or up_dir == "RL" then
					table.insert(
						errs,
						string.format(
							"%s:%d: horizontal Mermaid layout (%s) is forbidden; use TD or TB",
							rel_path,
							lnum,
							up_dir
						)
					)
				end
				is_flowchart = true
			elseif is_flowchart then
				local sg_rest = trimmed:match("^subgraph%s+(.+)$")
				if sg_rest then
					local sg_id = sg_rest:match("^([%w_%-]+)") or ("subgraph_" .. tostring(lnum))
					local sg_obj = { id = sg_id, lnum = lnum, members = {} }
					for _, parent_sg in ipairs(sg_stack) do
						parent_sg.members[sg_id] = true
					end
					table.insert(subgraphs, sg_obj)
					table.insert(sg_stack, sg_obj)
				elseif trimmed == "end" then
					if #sg_stack > 0 then
						table.remove(sg_stack)
					end
				elseif
					not trimmed:match("^direction%s+")
					and not trimmed:match("^classDef%s+")
					and not trimmed:match("^class%s+")
					and not trimmed:match("^style%s+")
					and not trimmed:match("^linkStyle%s+")
					and not trimmed:match("^click%s+")
				then
					local norm = trimmed
						:gsub("%-%-+[^%-~>|]*%-%->", " --> ")
						:gsub("==+[^=]*==>", " ==> ")
						:gsub("%-%.[^%.]*%.%->", " -.-> ")
					local link_ops = { "<-->", "-.->", "~~~", "==>", "===", "-->", "---", "-.-" }
					local has_edge = false
					for _, op in ipairs(link_ops) do
						if norm:find(op, 1, true) then
							has_edge = true
							break
						end
					end

					if has_edge then
						local parts, ops, cursor = {}, {}, 1
						while cursor <= #norm do
							local best_s, best_e, best_op = nil, nil, nil
							for _, op in ipairs(link_ops) do
								local s, e = norm:find(op, cursor, true)
								if s and (not best_s or s < best_s) then
									best_s, best_e, best_op = s, e, op
								end
							end
							if not best_s then
								table.insert(parts, norm:sub(cursor))
								break
							end
							table.insert(parts, norm:sub(cursor, best_s - 1))
							table.insert(ops, best_op)
							cursor = best_e + 1
						end

						local group_ids = {}
						for idx, raw_part in ipairs(parts) do
							local cleaned = vim.trim(raw_part):gsub("^|[^|]*|%s*", "")
							local ids_here = {}
							for sub_tok in cleaned:gmatch("[^&]+") do
								local nid, nlabel = parse_mermaid_node_token(sub_tok)
								if nid then
									register_node(nid, nlabel, lnum)
									table.insert(ids_here, nid)
								end
							end
							group_ids[idx] = ids_here
						end

						for idx = 1, #ops do
							local invis = (ops[idx] == "~~~")
							for _, u in ipairs(group_ids[idx] or {}) do
								for _, v in ipairs(group_ids[idx + 1] or {}) do
									degree[u] = (degree[u] or 0) + 1
									degree[v] = (degree[v] or 0) + 1
									table.insert(edges, { u = u, v = v, invisible = invis })
									if not invis and u ~= v then
										fanout_sets[u] = fanout_sets[u] or {}
										fanout_sets[u][v] = true
									end
								end
							end
						end
					else
						local nid, nlabel = parse_mermaid_node_token(trimmed)
						if nid then
							register_node(nid, nlabel, lnum)
						end
					end
				end
			end
		end
	end

	if is_flowchart then
		local sg_ids = {}
		for _, sg in ipairs(subgraphs) do
			sg_ids[sg.id] = true
		end
		if #node_order >= 2 then
			for _, nid in ipairs(node_order) do
				if not sg_ids[nid] and (degree[nid] or 0) == 0 then
					table.insert(
						errs,
						string.format(
							"%s:%d: unconnected Mermaid node '%s' renders horizontally; connect via edges or '~~~'",
							rel_path,
							all_nodes[nid] or 1,
							nid
						)
					)
				end
			end
		end

		for _, u in ipairs(node_order) do
			local targets = fanout_sets[u]
			if targets then
				local cnt = 0
				for _ in pairs(targets) do
					cnt = cnt + 1
				end
				if cnt > MAX_MERMAID_FANOUT then
					table.insert(
						errs,
						string.format(
							"%s:%d: Mermaid node '%s' has %d horizontal branches (max %d)",
							rel_path,
							all_nodes[u] or 1,
							u,
							cnt,
							MAX_MERMAID_FANOUT
						)
					)
				end
			end
		end

		for _, sg in ipairs(subgraphs) do
			local has_outside_nodes = (#subgraphs > 1)
			if not has_outside_nodes then
				for _, nid in ipairs(node_order) do
					if nid ~= sg.id and not sg.members[nid] then
						has_outside_nodes = true
						break
					end
				end
			end
			if has_outside_nodes then
				local connected = (degree[sg.id] or 0) > 0
				if not connected then
					for _, e in ipairs(edges) do
						local u_in = (e.u == sg.id) or sg.members[e.u] == true
						local v_in = (e.v == sg.id) or sg.members[e.v] == true
						if u_in ~= v_in then
							connected = true
							break
						end
					end
				end
				if not connected then
					table.insert(
						errs,
						string.format(
							"%s:%d: floating Mermaid subgraph '%s' is disconnected from main flow (renders side-by-side)",
							rel_path,
							sg.lnum,
							sg.id
						)
					)
				end
			end
		end
	end

	return errs
end

---Extract relative Markdown links and audit Mermaid blocks outside outer fenced code blocks.
---@param content string
---@param rel_path string
---@return { line: integer, target: string }[] links, string[] mermaid_errors
function M.extract_markdown_links_and_mermaid(content, rel_path)
	local links, mermaid_errs, mermaid_lines = {}, {}, {}
	local in_fence, fence_char, fence_len, fence_is_mermaid = false, "", 0, false
	local lnum = 0

	for line in (content .. "\n"):gmatch("(.-)\n") do
		lnum = lnum + 1
		if not in_fence then
			local ticks, rest = line:match("^%s*(`+)%s*(.*)$")
			local tildes, trest = line:match("^%s*(~+)%s*(.*)$")
			if ticks and #ticks >= 3 and not rest:find("`", 1, true) then
				in_fence, fence_char, fence_len = true, "`", #ticks
				fence_is_mermaid = ((rest:match("^([%w_%-]+)") or ""):lower() == "mermaid")
				mermaid_lines = {}
			elseif tildes and #tildes >= 3 then
				in_fence, fence_char, fence_len = true, "~", #tildes
				fence_is_mermaid = ((trest:match("^([%w_%-]+)") or ""):lower() == "mermaid")
				mermaid_lines = {}
			else
				local stripped = strip_inline_code_spans(line)
				for target in stripped:gmatch("%]%(([^)%s]+)[^)]*%)") do
					if
						not target:match("^https?://")
						and not target:match("^mailto:")
						and not target:match("^file://")
						and not target:match("^customization://")
						and not target:match("^#")
					then
						local clean_target = target:gsub("#.*$", "")
						if clean_target ~= "" then
							table.insert(links, { line = lnum, target = clean_target })
						end
					end
				end
			end
		else
			local close_delim = (fence_char == "`") and line:match("^%s*(`+)%s*$") or line:match("^%s*(~+)%s*$")
			if close_delim and #close_delim >= fence_len then
				if fence_is_mermaid then
					vim.list_extend(mermaid_errs, validate_mermaid_block(mermaid_lines, rel_path))
				end
				in_fence, fence_char, fence_len, fence_is_mermaid, mermaid_lines = false, "", 0, false, {}
			elseif fence_is_mermaid then
				table.insert(mermaid_lines, { lnum = lnum, text = line })
			end
		end
	end

	return links, mermaid_errs
end

---Validate `AGENTS.md`, `.agents/{rules,skills}`, Markdown links, and Mermaid blocks across `repo_root`.
---@param repo_root string
---@param read_file fun(path: string): string|nil, string|nil
---@param list_files_sorted fun(root_dir: string, pred: fun(rel: string, full: string): boolean): string[]
---@return string[] errors, { rules: integer, skills: integer, md_links_checked: integer } stats
function M.lint_docs_and_customizations(repo_root, read_file, list_files_sorted)
	local all_errors = {}
	local stats = { rules = 0, skills = 0, md_links_checked = 0 }
	local md_seen = {} ---@type table<string, boolean>
	local md_files_to_check = {} ---@type string[]
	local function queue_md(full_path)
		if not md_seen[full_path] then
			md_seen[full_path] = true
			table.insert(md_files_to_check, full_path)
		end
	end

	local agents_path = repo_root .. "/AGENTS.md"
	local agents_src, agents_err = read_file(agents_path)
	if not agents_src then
		table.insert(all_errors, "AGENTS.md: " .. tostring(agents_err))
	else
		vim.list_extend(all_errors, M.validate_agents_md(agents_src, "AGENTS.md"))
		queue_md(agents_path)
	end

	local function list_dir_entries(dir)
		local scan = vim.uv.fs_scandir(dir)
		if not scan then
			return nil
		end
		local items = {}
		while true do
			---@type string?, string?
			local name, etype = vim.uv.fs_scandir_next(scan)
			if not name then
				break
			end
			local full = dir .. "/" .. name
			table.insert(
				items,
				{ name = name, full = full, etype = etype or ((vim.uv.fs_lstat(full) or {}).type or nil) }
			)
		end
		return items
	end

	for _, item in ipairs(list_dir_entries(repo_root) or {}) do
		if item.etype == "file" and item.name:sub(-3) == ".md" then
			if item.name == "GEMINI.md" then
				local gsrc = read_file(item.full)
				if gsrc then
					vim.list_extend(all_errors, M.validate_agents_md(gsrc, item.name))
				end
			end
			queue_md(item.full)
		end
	end

	for _, doc_dir in ipairs({ "docs", "lua" }) do
		local mpaths = list_files_sorted(repo_root .. "/" .. doc_dir, function(rel)
			return rel:sub(-3) == ".md"
		end)
		for _, mpath in ipairs(mpaths) do
			local base = vim.fs.basename(mpath)
			if base == "AGENTS.md" or base == "GEMINI.md" then
				local asrc = read_file(mpath)
				if asrc then
					vim.list_extend(all_errors, M.validate_agents_md(asrc, mpath:sub(#repo_root + 2)))
				end
			end
			queue_md(mpath)
		end
	end

	-- `.agents/rules/*.md`
	local rules_entries = list_dir_entries(repo_root .. "/.agents/rules")
	if not rules_entries then
		table.insert(all_errors, ".agents/rules: missing directory")
	else
		local rule_files = {}
		for _, item in ipairs(rules_entries) do
			if item.etype == "file" and item.name:sub(-3) == ".md" then
				table.insert(rule_files, item.full)
			else
				table.insert(
					all_errors,
					string.format(".agents/rules/%s: unexpected non-rule entry (expected flat *.md files)", item.name)
				)
			end
		end
		table.sort(rule_files)
		if #rule_files == 0 then
			table.insert(all_errors, ".agents/rules: expected at least one .md rule file")
		end
		for _, rfull in ipairs(rule_files) do
			stats.rules = stats.rules + 1
			local rrel = rfull:sub(#repo_root + 2)
			local rsrc, rerr = read_file(rfull)
			if not rsrc then
				table.insert(all_errors, rrel .. ": " .. tostring(rerr))
			else
				vim.list_extend(all_errors, M.validate_rule_markdown(rsrc, rrel))
				queue_md(rfull)
			end
		end
	end

	-- `.agents/skills/<dir>/SKILL.md`
	local skills_root = repo_root .. "/.agents/skills"
	local skill_entries = list_dir_entries(skills_root)
	if not skill_entries then
		table.insert(all_errors, ".agents/skills: missing directory")
	else
		local skill_dirs = {}
		for _, item in ipairs(skill_entries) do
			if item.etype == "directory" then
				table.insert(skill_dirs, item.name)
			else
				table.insert(
					all_errors,
					string.format(
						".agents/skills/%s: unexpected file (each skill must be a <name>/SKILL.md folder)",
						item.name
					)
				)
			end
		end
		table.sort(skill_dirs)
		if #skill_dirs == 0 then
			table.insert(all_errors, ".agents/skills: expected at least one skill folder")
		end
		for _, sdir in ipairs(skill_dirs) do
			stats.skills = stats.skills + 1
			local skill_md = skills_root .. "/" .. sdir .. "/SKILL.md"
			local srel = ".agents/skills/" .. sdir .. "/SKILL.md"
			local ssrc, serr = read_file(skill_md)
			if not ssrc then
				table.insert(all_errors, srel .. ": " .. tostring(serr))
			else
				vim.list_extend(all_errors, M.validate_skill_markdown(ssrc, sdir, srel))
			end
			local all_skill_mds = list_files_sorted(skills_root .. "/" .. sdir, function(rel)
				return rel:sub(-3) == ".md"
			end)
			for _, smd in ipairs(all_skill_mds) do
				queue_md(smd)
			end
		end
	end

	table.sort(md_files_to_check)
	for _, mfull in ipairs(md_files_to_check) do
		local mrel = mfull:sub(#repo_root + 2)
		local msrc = read_file(mfull)
		if msrc then
			local links, m_errs = M.extract_markdown_links_and_mermaid(msrc, mrel)
			vim.list_extend(all_errors, m_errs)
			local base_dir = vim.fs.dirname(mfull)
			for _, lk in ipairs(links) do
				stats.md_links_checked = stats.md_links_checked + 1
				local resolved = vim.fs.normalize(base_dir .. "/" .. lk.target)
				local inside_repo = (resolved == repo_root) or (resolved:sub(1, #repo_root + 1) == repo_root .. "/")
				if not inside_repo then
					table.insert(
						all_errors,
						string.format("%s:%d: relative link '%s' escapes repository root", mrel, lk.line, lk.target)
					)
				elseif not vim.uv.fs_stat(resolved) then
					table.insert(
						all_errors,
						string.format("%s:%d: broken relative link '%s'", mrel, lk.line, lk.target)
					)
				end
			end
		end
	end

	for _, pair in ipairs({
		{ "CLAUDE.md", "AGENTS.md" },
		{ ".claude/rules", ".agents/rules" },
		{ ".claude/skills", ".agents/skills" },
	}) do
		local link_full = repo_root .. "/" .. pair[1]
		local lst = vim.uv.fs_lstat(link_full)
		if not lst or lst.type ~= "link" then
			table.insert(all_errors, string.format("%s: must be a symlink to %s", pair[1], pair[2]))
		elseif vim.uv.fs_realpath(link_full) ~= vim.uv.fs_realpath(repo_root .. "/" .. pair[2]) then
			table.insert(all_errors, string.format("%s: symlink target mismatch (expected %s)", pair[1], pair[2]))
		end
	end

	local ignored_rel_dirs = {
		[".git"] = true,
		[".worktrees"] = true,
		[".claude/worktrees"] = true,
		[".omp"] = true,
		[".pi"] = true,
		[".luals-log"] = true,
	}
	local function scan_dangling_symlinks(dir, rel_prefix)
		local scan = vim.uv.fs_scandir(dir)
		while scan do
			---@type string?, string?
			local name, etype = vim.uv.fs_scandir_next(scan)
			if not name then
				break
			end
			local full = dir .. "/" .. name
			local rel = rel_prefix ~= "" and (rel_prefix .. "/" .. name) or name
			if not ignored_rel_dirs[rel] then
				etype = etype or ((vim.uv.fs_lstat(full) or {}).type or nil)
				if etype == "link" and not vim.uv.fs_stat(full) then
					table.insert(all_errors, rel .. ": dangling symlink")
				elseif etype == "directory" then
					scan_dangling_symlinks(full, rel)
				end
			end
		end
	end
	scan_dangling_symlinks(repo_root, "")

	return all_errors, stats
end

return M
