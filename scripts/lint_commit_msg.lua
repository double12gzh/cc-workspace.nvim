-- Conventional Commits, 3-paragraph `-m` structure, `bat` alias hygiene, and AI `Co-Authored-By` linter.
-- Run standalone:
--   nvim --headless -u NONE -l scripts/lint_commit_msg.lua [--require-coauthor] [--comment-char <char|auto|none>] <commit-msg-file|->

local M = {}

---@type table<string, boolean>
M.ALLOWED_TYPES = {
	build = true,
	chore = true,
	ci = true,
	docs = true,
	feat = true,
	fix = true,
	perf = true,
	refactor = true,
	revert = true,
	style = true,
	test = true,
}

---@type table<string, string>
M.AI_COAUTHORS = {
	Claude = "noreply@anthropic.com",
	Gemini = "218195315+gemini-cli@users.noreply.github.com",
	GPT = "noreply@openai.com",
	DeepSeek = "noreply@deepseek.com",
}

local AI_VENDOR_EMAILS = {
	["noreply@anthropic.com"] = "Claude",
	["218195315+gemini-cli@users.noreply.github.com"] = "Gemini",
	["noreply@google.com"] = "Gemini",
	["noreply@openai.com"] = "GPT",
	["noreply@deepseek.com"] = "DeepSeek",
}

local AI_VENDOR_DOMAINS = {
	["anthropic.com"] = "Claude",
	["openai.com"] = "GPT",
	["deepseek.com"] = "DeepSeek",
}

local FORBIDDEN_EMAIL_DOMAINS = {
	["cursor.com"] = true,
	["roocode.com"] = true,
	["kilocode.ai"] = true,
	["windsurf.com"] = true,
	["codeium.com"] = true,
}

local FORBIDDEN_NAME_PHRASES = {
	"oh-my-pi",
	"claude code",
	"roo code",
	"kilo code",
	"gemini cli",
	"gemini code",
	"github copilot",
	"amazon q",
}

local FORBIDDEN_NAME_TOKENS = {
	claude = true,
	anthropic = true,
	gemini = true,
	gpt = true,
	chatgpt = true,
	openai = true,
	deepseek = true,
	sonnet = true,
	opus = true,
	haiku = true,
	flash = true,
	antigravity = true,
	agy = true,
	omp = true,
	pi = true,
	codex = true,
	cursor = true,
	windsurf = true,
	copilot = true,
	cline = true,
	aider = true,
	codecompanion = true,
	opencode = true,
	roocode = true,
	kilocode = true,
	supermaven = true,
	tabnine = true,
	trae = true,
	devin = true,
	junie = true,
	augment = true,
	kiro = true,
}

local EXTENDED_AI_FAMILIES = {
	qwen = "Qwen",
	glm = "GLM",
	grok = "Grok",
	kimi = "Kimi",
	llama = "Llama",
	mistral = "Mistral",
	minimax = "MiniMax",
}

---@class CcWsCommitLintOpts
---@field strip_comments? boolean Strip Git comment lines and verbose scissors (default: true)
---@field comment_char? string Git comment leader (`#`, `;`, `auto`, or `none`; default: `#`)
---@field require_coauthor? boolean Require a canonical AI `Co-Authored-By` trailer

---@param normalized string
---@return string
local function detect_auto_comment_char(normalized)
	local ch = normalized:match("\n([^\n%w%s])%s*%-%-%-%-+%s*>8%s*%-%-%-%-+")
		or normalized:match("^([^\n%w%s])%s*Please enter the commit message")
		or normalized:match("\n([^\n%w%s])%s*Please enter the commit message")
	return ch or "#"
end

---Resolve `core.commentChar` from Git configuration for `cwd` (defaults to `#`).
---@param cwd? string
---@return string comment_char
function M.resolve_git_comment_char(cwd)
	local ok, proc = pcall(vim.system, { "git", "config", "--get", "core.commentChar" }, {
		cwd = cwd,
		text = true,
		env = { GIT_TERMINAL_PROMPT = "0", GIT_OPTIONAL_LOCKS = "0" },
	})
	if not ok or not proc then
		return "#"
	end
	local res = proc:wait(2000)
	if not res or res.code ~= 0 then
		return "#"
	end
	local val = vim.trim(res.stdout or "")
	if val:lower() == "auto" then
		return "auto"
	end
	if #val == 1 and not val:match("%s") then
		return val
	end
	return "#"
end

---Strip Git comment lines, `git commit -v` scissors (`<cc> ---... >8 ---...`), and outer blank lines.
---@param raw string
---@param opts? CcWsCommitLintOpts
---@return string[] lines
function M.clean_commit_message(raw, opts)
	local normalized = (raw or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
	local cc = (opts and opts.comment_char) or "#"
	local strip_comments = (not opts or opts.strip_comments ~= false) and cc ~= "none" and cc ~= ""
	if strip_comments and cc == "auto" then
		cc = detect_auto_comment_char(normalized)
	end
	local cc_pat = strip_comments and vim.pesc(cc) or nil
	local kept = {}

	for line in (normalized .. "\n"):gmatch("(.-)\n") do
		if strip_comments and cc_pat then
			if line:match("^" .. cc_pat .. "%s*%-%-%-%-+%s*>8%s*%-%-%-%-+") then
				break
			end
			if line:sub(1, #cc) ~= cc then
				table.insert(kept, line)
			end
		else
			table.insert(kept, line)
		end
	end

	local first_nonblank = 1
	while first_nonblank <= #kept and kept[first_nonblank]:match("^%s*$") do
		first_nonblank = first_nonblank + 1
	end
	local last_nonblank = #kept
	while last_nonblank >= first_nonblank and kept[last_nonblank]:match("^%s*$") do
		last_nonblank = last_nonblank - 1
	end

	local out = {}
	for i = first_nonblank, last_nonblank do
		table.insert(out, kept[i])
	end
	return out
end

---@param line string
---@param next_line? string
---@return boolean
local function has_bat_pollution(line, next_line)
	if line:match("^%s*STDIN%s*$") or line:match("^%s*File:%s+%S") or line:match("^%s*%d+%s*│") then
		return true
	end
	if line:find("STDIN", 1, true) and (line:find("─", 1, true) or line:find("│", 1, true)) then
		return true
	end
	if
		line:find("───┬───", 1, true)
		or line:find("───┼───", 1, true)
		or line:find("───┴───", 1, true)
	then
		return true
	end
	if line:match("^   1 [%-%*A-Za-z]") then
		return true
	end
	if
		(line:match("^  +1%s") or line:match("^  +1$"))
		and next_line
		and (next_line:match("^  +2%s") or next_line:match("^  +2$"))
	then
		return true
	end
	return false
end

---@param tok string
---@return boolean
local function is_glued_ai_model_token(tok)
	if tok:match("^o%d$") or tok:match("^o%dmini$") or tok:match("^o%dpro$") then
		return true
	end
	return tok:match("^claude%d") ~= nil
		or tok:match("^gemini%d") ~= nil
		or tok:match("^gpt%d") ~= nil
		or tok:match("^chatgpt") ~= nil
		or tok:match("^deepseek") ~= nil
end

---@param lc_email string
---@return boolean
local function is_ai_bot_email(lc_email)
	if lc_email:find("%[bot%]@", 1, false) then
		return true
	end
	local local_part, domain = lc_email:match("^([^@]+)@(.+)$")
	if not local_part or not domain then
		return false
	end
	if FORBIDDEN_EMAIL_DOMAINS[domain] then
		return true
	end
	local clean_local = local_part:gsub("^%d+%+", "")
	return clean_local:match("^gemini") ~= nil
		or clean_local:match("^claude") ~= nil
		or clean_local:match("^gpt") ~= nil
		or clean_local:match("^chatgpt") ~= nil
		or clean_local:match("^codex") ~= nil
		or clean_local:match("^copilot") ~= nil
		or clean_local:match("^cursor") ~= nil
		or clean_local:match("^antigravity") ~= nil
end

---@param name string
---@param email string
---@return string|nil err, boolean is_ai_coauthor
local function validate_coauthor_identity(name, email)
	local expected_ai_email = M.AI_COAUTHORS[name]
	if expected_ai_email then
		if email ~= expected_ai_email then
			return string.format(
				"Co-Authored-By model '%s' must use official email <%s> (got <%s>)",
				name,
				expected_ai_email,
				email
			),
				false
		end
		return nil, true
	end

	local lc_name = name:lower()
	for _, phrase in ipairs(FORBIDDEN_NAME_PHRASES) do
		if lc_name:find(phrase, 1, true) then
			return string.format(
				"Co-Authored-By name '%s' uses client/harness name; use base model family only (Claude, Gemini, GPT, DeepSeek)",
				name
			),
				false
		end
	end
	if name:match("%d+%.%d+") then
		return string.format(
			"Co-Authored-By name '%s' must not contain model version numbers; use base model family only",
			name
		),
			false
	end
	for tok in lc_name:gmatch("[%w]+") do
		if FORBIDDEN_NAME_TOKENS[tok] or is_glued_ai_model_token(tok) then
			return string.format(
				"Co-Authored-By name '%s' must use base model family only (Claude, Gemini, GPT, DeepSeek) without version numbers, sub-models, or client/harness names",
				name
			),
				false
		end
		for fam_stem, ext_base in pairs(EXTENDED_AI_FAMILIES) do
			if (tok == fam_stem and name ~= ext_base) or tok:match("^" .. fam_stem .. "%d") then
				return string.format(
					"Co-Authored-By name '%s' must use base model family '%s' without version or tier qualifiers",
					name,
					ext_base
				),
					false
			end
		end
	end

	local lc_email = email:lower()
	local email_domain = lc_email:match("@([^@]+)$") or ""
	local vendor_family = AI_VENDOR_EMAILS[lc_email] or AI_VENDOR_DOMAINS[email_domain]
	if vendor_family then
		return string.format(
			"Co-Authored-By <%s> must use exact base model name '%s' and <%s> (got '%s')",
			email,
			vendor_family,
			M.AI_COAUTHORS[vendor_family],
			name
		),
			false
	end
	if is_ai_bot_email(lc_email) then
		return string.format(
			"Co-Authored-By '%s <%s>' uses an AI bot/harness identity; use canonical base model family and official vendor noreply email",
			name,
			email
		),
			false
	end

	return nil, false
end

---@param line string
---@return boolean
local function is_bullet_line(line)
	return line:match("^%s*[%-%*]%s+") ~= nil
end

---@param line string
---@return boolean
local function is_numbered_item_line(line)
	return line:match("^%s*%d+[%.%)]%s+") ~= nil
end

---Validate a commit message against Conventional Commits, 3-part `-m`, `bat` hygiene, and `Co-Authored-By` rules.
---@param raw string
---@param opts? CcWsCommitLintOpts
---@return string[] errors
function M.validate_commit_message(raw, opts)
	opts = opts or {}
	local errs = {}
	local lines = M.clean_commit_message(raw, opts)
	if #lines == 0 then
		return { "commit message is empty" }
	end

	for idx, line in ipairs(lines) do
		if line:find("\027[", 1, true) then
			table.insert(errs, string.format("line %d: ANSI escape sequence detected in commit message", idx))
		end
		if has_bat_pollution(line, lines[idx + 1]) then
			table.insert(
				errs,
				string.format(
					"line %d: 'bat'/'cat' decoration detected; never use bare 'cat' to construct commit messages",
					idx
				)
			)
		end
	end

	---@type { lines: string[] }[]
	local paragraphs = {}
	local cur_para = nil
	for _, line in ipairs(lines) do
		if line:match("^%s*$") then
			cur_para = nil
		else
			if not cur_para then
				cur_para = { lines = {} }
				table.insert(paragraphs, cur_para)
			end
			table.insert(cur_para.lines, line)
		end
	end

	local first_line = lines[1]
	local is_git_special = first_line:match("^Merge ") ~= nil
		or first_line:match('^Revert ".+"$') ~= nil
		or first_line:match("^fixup! ") ~= nil
		or first_line:match("^squash! ") ~= nil
		or first_line:match("^amend! ") ~= nil

	if not is_git_special then
		if #paragraphs[1].lines > 1 then
			table.insert(errs, "subject line must be separated from body/trailers by a blank line")
		end

		local header = paragraphs[1].lines[1]
		if header ~= vim.trim(header) then
			table.insert(errs, "commit subject line must not have leading or trailing whitespace")
		end
		local trimmed_header = vim.trim(header)
		local colon_pos = trimmed_header:find(":", 1, true)
		if not colon_pos then
			table.insert(
				errs,
				"subject must follow Conventional Commits format '<type>(<scope>): <subject>' or '<type>: <subject>'"
			)
		else
			local head_prefix = trimmed_header:sub(1, colon_pos - 1)
			local after_colon = trimmed_header:sub(colon_pos + 1)
			if head_prefix:sub(-1) == "!" then
				head_prefix = head_prefix:sub(1, -2)
			end

			local ctype, scope = nil, nil
			if head_prefix:find("[()]") then
				ctype, scope = head_prefix:match("^([A-Za-z0-9_%-]+)%((.*)%)$")
			else
				ctype = head_prefix:match("^([A-Za-z0-9_%-]+)$")
			end

			if not ctype then
				table.insert(
					errs,
					"subject must follow Conventional Commits format '<type>(<scope>): <subject>' or '<type>: <subject>'"
				)
			else
				if not M.ALLOWED_TYPES[ctype] then
					table.insert(
						errs,
						string.format(
							"invalid commit type '%s' (allowed: build, chore, ci, docs, feat, fix, perf, refactor, revert, style, test)",
							ctype
						)
					)
				end
				if scope ~= nil then
					if scope == "" then
						table.insert(errs, "commit scope '()' must not be empty; omit '()' for unscoped commits")
					else
						local valid_scope = true
						for _, seg in ipairs(vim.split(scope, ",", { plain = true })) do
							if not seg:match("^[a-z0-9][a-z0-9_%-/]*$") then
								valid_scope = false
								break
							end
						end
						if not valid_scope then
							table.insert(
								errs,
								string.format(
									"invalid commit scope '(%s)'; expected lowercase module/topic identifier",
									scope
								)
							)
						end
					end
				end
				if after_colon:sub(1, 1) ~= " " or after_colon:sub(2, 2) == " " or vim.trim(after_colon) == "" then
					table.insert(
						errs,
						"colon in '<type>(<scope>): <subject>' must be followed by a single space and non-empty subject"
					)
				end
			end
		end
	end

	for p_idx = 2, #paragraphs - 1 do
		local cur_lines = paragraphs[p_idx].lines
		local p_cur_first, p_cur_last = cur_lines[1], cur_lines[#cur_lines]
		local p_nxt_first = paragraphs[p_idx + 1].lines[1]
		local split_bullets = (is_bullet_line(p_cur_first) or is_bullet_line(p_cur_last))
			and is_bullet_line(p_nxt_first)
		local split_numbered = (is_numbered_item_line(p_cur_first) or is_numbered_item_line(p_cur_last))
			and is_numbered_item_line(p_nxt_first)
		if split_bullets or split_numbered then
			table.insert(
				errs,
				"separate list/bullet paragraphs detected; merge all list items inside a single '-m' body argument"
			)
			break
		end
	end

	local has_any_coauthor = false
	local has_ai_coauthor = false
	for p_idx, para in ipairs(paragraphs) do
		for _, line in ipairs(para.lines) do
			if line:lower():match("^%s*co%-?author[a-z%-]*%s*:") then
				has_any_coauthor = true
				if p_idx ~= #paragraphs then
					table.insert(errs, "Co-Authored-By trailer must appear in the final paragraph")
				end
				if not line:match("^Co%-Authored%-By: ") then
					table.insert(
						errs,
						string.format(
							"malformed trailer '%s'; use exact casing 'Co-Authored-By: <Model> <email>'",
							vim.trim(line)
						)
					)
				else
					local trimmed_trailer = line:gsub("%s+$", "")
					local raw_name, email = trimmed_trailer:match("^Co%-Authored%-By: (.-)%s+<([^<>%s]+@[^<>%s]+)>$")
					local name = raw_name and vim.trim(raw_name) or ""
					if name == "" or not email then
						table.insert(
							errs,
							string.format(
								"malformed Co-Authored-By trailer '%s'; expected 'Co-Authored-By: <Model> <email>'",
								vim.trim(line)
							)
						)
					else
						local id_err, is_ai = validate_coauthor_identity(name, email)
						if id_err then
							table.insert(errs, id_err)
						end
						if is_ai then
							has_ai_coauthor = true
						end
					end
				end
			end
		end
	end

	if has_any_coauthor then
		if not is_git_special and #paragraphs ~= 3 then
			table.insert(
				errs,
				string.format(
					"co-authored commits must use the standard 3-paragraph '-m' structure (1: subject, 2: body, 3: trailers); got %d paragraph(s)",
					#paragraphs
				)
			)
		elseif is_git_special and #paragraphs < 2 then
			table.insert(errs, "Co-Authored-By trailer must be separated from subject by a blank line")
		end
		for _, tline in ipairs(paragraphs[#paragraphs].lines) do
			if not tline:match("^[A-Za-z][A-Za-z0-9%-]*:%s+.+$") then
				table.insert(
					errs,
					"final trailer paragraph must contain only 'Key: Value' trailers (separate body bullets from Co-Authored-By with a blank line)"
				)
				break
			end
		end
	end

	if opts.require_coauthor and not has_ai_coauthor then
		table.insert(
			errs,
			"missing required AI Co-Authored-By trailer (Claude, Gemini, GPT, or DeepSeek with official vendor noreply email)"
		)
	end

	return errs
end

---Strip `#` comments outside single/double quotes from a TOML source string.
---@param src string
---@return string
local function strip_toml_comments(src)
	local out = {}
	for line in ((src or "") .. "\n"):gmatch("(.-)\n") do
		local in_dq, in_sq, escaped = false, false, false
		local cut = nil
		for i = 1, #line do
			local c = line:sub(i, i)
			if in_dq then
				if escaped then
					escaped = false
				elseif c == "\\" then
					escaped = true
				elseif c == '"' then
					in_dq = false
				end
			elseif in_sq then
				if c == "'" then
					in_sq = false
				end
			else
				if c == '"' then
					in_dq = true
				elseif c == "'" then
					in_sq = true
				elseif c == "#" then
					cut = i - 1
					break
				end
			end
		end
		table.insert(out, cut and line:sub(1, cut) or line)
	end
	return table.concat(out, "\n")
end

---Extract `{ message = "^<type>" }` parser types from `cliff.toml` source text (ignoring `#` comments).
---@param cliff_src string
---@return table<string, boolean> types
function M.parse_cliff_types(cliff_src)
	local stripped = strip_toml_comments(cliff_src or "")
	local found = {}
	for _, pat in ipairs({ 'message%s*=%s*"%^([a-z0-9_%-]+)', "message%s*=%s*'%^([a-z0-9_%-]+)" }) do
		for msg_pat in stripped:gmatch(pat) do
			found[msg_pat] = true
		end
	end
	return found
end

---Verify `<repo_root>/cliff.toml` exists and its Conventional Commit types match `M.ALLOWED_TYPES`.
---@param repo_root string
---@return string[] errors
function M.check_cliff_toml_sync(repo_root)
	local errs = {}
	local cliff_path = repo_root .. "/cliff.toml"
	local st = vim.uv.fs_stat(cliff_path)
	if not st or st.type ~= "file" then
		return { "cliff.toml: missing Conventional Commits changelog configuration" }
	end
	local fd = vim.uv.fs_open(cliff_path, "r", 438)
	if not fd then
		return { "cliff.toml: unable to open file" }
	end
	local src = st.size > 0 and vim.uv.fs_read(fd, st.size, 0) or ""
	vim.uv.fs_close(fd)

	local stripped = strip_toml_comments(src or "")
	if not stripped:match("conventional_commits%s*=%s*true") then
		table.insert(errs, "cliff.toml: missing 'conventional_commits = true' under [git]")
	end

	local cliff_types = M.parse_cliff_types(src or "")
	for t in pairs(M.ALLOWED_TYPES) do
		if not cliff_types[t] then
			table.insert(errs, string.format("cliff.toml: missing commit_parsers entry for '^%s'", t))
		end
	end
	for t in pairs(cliff_types) do
		if not M.ALLOWED_TYPES[t] then
			table.insert(
				errs,
				string.format("cliff.toml: commit_parsers type '^%s' missing from scripts/lint_commit_msg.lua", t)
			)
		end
	end
	table.sort(errs)
	return errs
end

local is_main_cli = not vim.g.cc_ws_lint_as_lib
	and type(arg) == "table"
	and type(arg[0]) == "string"
	and vim.fs.basename(arg[0]) == "lint_commit_msg.lua"

if is_main_cli then
	local require_coauthor = false
	local comment_char = nil ---@type string|nil
	local end_of_opts = false
	local msg_file = nil
	local idx = 1
	while idx <= #arg do
		local a = arg[idx]
		if not end_of_opts and a == "--" then
			end_of_opts = true
		elseif not end_of_opts and a == "--require-coauthor" then
			require_coauthor = true
		elseif not end_of_opts and a == "--comment-char" then
			idx = idx + 1
			comment_char = arg[idx]
			if not comment_char or comment_char == "" then
				io.stderr:write("COMMIT-MSG ERROR: --comment-char requires a value\n")
				os.exit(2)
			end
		elseif not end_of_opts and a:sub(1, 15) == "--comment-char=" then
			comment_char = a:sub(16)
		elseif not end_of_opts and a:sub(1, 2) == "--" then
			io.stderr:write("COMMIT-MSG ERROR: unknown option: " .. a .. "\n")
			os.exit(2)
		elseif not msg_file then
			msg_file = a
		else
			io.stderr:write("COMMIT-MSG ERROR: unexpected argument: " .. a .. "\n")
			os.exit(2)
		end
		idx = idx + 1
	end
	if not msg_file or msg_file == "" then
		io.stderr:write("Usage: lint_commit_msg.lua [--require-coauthor] [--comment-char <char|auto|none>] <file|->\n")
		os.exit(2)
	end

	local raw = nil
	if msg_file == "-" then
		raw = io.stdin:read("*a") or ""
	else
		local st = vim.uv.fs_stat(msg_file)
		if st and st.type == "directory" then
			io.stderr:write("COMMIT-MSG ERROR: path is a directory: " .. tostring(msg_file) .. "\n")
			os.exit(1)
		end
		local fh = io.open(msg_file, "rb")
		if not fh then
			io.stderr:write("COMMIT-MSG ERROR: cannot read file: " .. tostring(msg_file) .. "\n")
			os.exit(1)
		end
		raw = fh:read("*a") or ""
		fh:close()
	end

	if not comment_char then
		local git_dir_hint = (msg_file ~= "-") and vim.fs.dirname(vim.fn.fnamemodify(msg_file, ":p")) or vim.uv.cwd()
		comment_char = M.resolve_git_comment_char(git_dir_hint)
	end

	local errs = M.validate_commit_message(raw, {
		require_coauthor = require_coauthor,
		comment_char = comment_char,
	})
	if #errs > 0 then
		for _, e in ipairs(errs) do
			io.stderr:write("COMMIT-MSG ERROR: " .. e .. "\n")
		end
		io.stderr:write(string.format("commit-msg check failed with %d error(s)\n", #errs))
		os.exit(1)
	end
	io.stdout:write("commit-msg: OK\n")
	os.exit(0)
end

return M
