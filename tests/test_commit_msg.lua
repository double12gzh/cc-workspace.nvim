-- Commit message linter (`scripts/lint_commit_msg.lua`), `cliff.toml` sync, and real `commit-msg` Git hook E2E tests.

---@param ctx table
return function(ctx)
	local check = ctx.check
	local plugin_root = ctx.plugin_root
	local tmp_root = ctx.tmp_root

	vim.g.cc_ws_lint_as_lib = true
	local cm = dofile(plugin_root .. "/scripts/lint_commit_msg.lua")
	local repo_linter = dofile(plugin_root .. "/scripts/lint_repo.lua")
	vim.g.cc_ws_lint_as_lib = nil

	-- 1. Valid 3-paragraph AI commits across all canonical model families
	local valid_ai_commits = {
		{
			label = "Claude scoped 3-paragraph commit",
			msg = table.concat({
				"feat(winbar): support middle-click tab close",
				"",
				"- Close targeted chat buffer safely on middle click",
				"- Add headless statusline click regression coverage",
				"",
				"Co-Authored-By: Claude <noreply@anthropic.com>",
			}, "\n"),
		},
		{
			label = "Gemini unscoped CJK + English bullet commit",
			msg = table.concat({
				"docs: sync commit conventions and pre-commit hooks",
				"",
				"- 对齐 Conventional Commits 类型与 cliff.toml 解析配置",
				"- Enforce 3-paragraph -m structure and Co-Authored-By rules",
				"",
				"Co-Authored-By: Gemini <218195315+gemini-cli@users.noreply.github.com>",
			}, "\n"),
		},
		{
			label = "GPT breaking-change commit with multi-scope and Signed-off-by + Co-Authored-By",
			msg = table.concat({
				"refactor(worktree_ops,sidebar)!: bound concurrent async git refreshes",
				"",
				"- Enforce MAX_CONCURRENT_GIT_REFRESH queue cap with SIGKILL watchdog",
				"",
				"Signed-off-by: Test Runner <test@example.com>",
				"Co-Authored-By: GPT <noreply@openai.com>",
			}, "\n"),
		},
		{
			label = "DeepSeek chore(agent) commit",
			msg = table.concat({
				"chore(agent): add commit-msg hook to pre-commit config",
				"",
				"- Wire ./scripts/check.sh commit-msg into .pre-commit-config.yaml",
				"",
				"Co-Authored-By: DeepSeek <noreply@deepseek.com>",
			}, "\n"),
		},
		{
			label = "Git Revert commit with canonical AI Co-Authored-By passes require_coauthor",
			msg = table.concat({
				'Revert "feat(winbar): support middle-click tab close"',
				"",
				"This reverts commit 2083db9.",
				"",
				"Co-Authored-By: Claude <noreply@anthropic.com>",
			}, "\n"),
		},
	}
	for _, tc in ipairs(valid_ai_commits) do
		local errs = cm.validate_commit_message(tc.msg, { require_coauthor = true })
		check(#errs == 0, tc.label, table.concat(errs, "; "))
	end

	-- 2. Valid human solo commits, word-boundary human co-authors, Git special subjects & verbose scissors
	local valid_general_commits = {
		{
			label = "1-paragraph human solo commit",
			msg = "feat: initial standalone cc-workspace.nvim plugin\n",
		},
		{
			label = "2-paragraph human solo commit with numbered list in single -m",
			msg = "fix(sidebar): guard invalid window before cursor jump\n\n1. Check nvim_win_is_valid\n2. Add test\n",
		},
		{
			label = "human co-authors with Nagy/Pierre/Thompson/Claudel/google.com (false-positive safe)",
			msg = table.concat({
				"test(lint): verify word boundaries on human co-author names",
				"",
				"- Ensure Nagy, Pierre, Thompson, Claudel, and human @google.com pass",
				"",
				"Co-Authored-By: Attila Nagy <12345+anagy@users.noreply.github.com>",
				"Co-Authored-By: Pierre Thompson <pierre@example.com>",
				"Co-Authored-By: Camille Claudel <camille@example.org>",
				"Co-Authored-By: Jane Smith <jsmith@google.com>",
				"Co-Authored-By: double12gzh <double12gzh@example.com>   ",
			}, "\n"),
		},
		{
			label = "extended base AI family name without version or tier allowed",
			msg = "feat: x\n\n- y\n\nCo-Authored-By: Qwen <noreply@alibabacloud.com>\n",
		},
		{
			label = "Git auto-generated Merge commit",
			msg = "Merge branch 'feat/ui-extract' into main\n",
		},
		{
			label = "Git default Revert commit",
			msg = 'Revert "feat(winbar): support middle-click tab close"\n\nThis reverts commit 2083db9.\n',
		},
		{
			label = "Git autosquash fixup! and squash! commits",
			msg = "fixup! feat(winbar): support middle-click tab close\n",
		},
		{
			label = "git commit -v verbose diff scissors strips raw diff containing STDIN and bad strings",
			msg = table.concat({
				"docs(agent): document bat STDIN hazard",
				"",
				"- Explain why bare cat is banned in interactive shells",
				"",
				"Co-Authored-By: Claude <noreply@anthropic.com>",
				"# Please enter the commit message for your changes.",
				"# ------------------------ >8 ------------------------",
				"# Do not modify or remove the line above.",
				"diff --git a/AGENTS.md b/AGENTS.md",
				"+     STDIN",
				"+STDIN ─────────",
				"+Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>",
			}, "\n"),
		},
	}
	for _, tc in ipairs(valid_general_commits) do
		local errs = cm.validate_commit_message(tc.msg)
		check(#errs == 0, tc.label, table.concat(errs, "; "))
	end

	-- Custom `comment_char = "auto"` and `comment_char = "none"` unit checks
	local auto_cc_errs = cm.validate_commit_message(
		table.concat({
			"feat(git): support core.commentChar auto",
			"",
			"- Strip # code samples safely when git selects ';' as comment leader",
			"  # literal hash inside body",
			"",
			"Co-Authored-By: Claude <noreply@anthropic.com>",
			"; Please enter the commit message for your changes.",
			"; ------------------------ >8 ------------------------",
			"+STDIN ─────────",
		}, "\n"),
		{ comment_char = "auto", require_coauthor = true }
	)
	check(#auto_cc_errs == 0, "comment_char=auto detects ';' comment leader and preserves '#' body lines")

	-- 3. Negative controls: every forbidden format, bat artifact & AI attribution mistake rejected
	local invalid_commits = {
		{ label = "empty commit message rejected", msg = "" },
		{ label = "comment-only commit message rejected", msg = "# only git comments\n# nothing else\n" },
		{
			label = "bat standalone STDIN header + line numbers rejected",
			msg = "     STDIN\n   1 feat: polluted commit\n",
		},
		{
			label = "bat non-grid File: header + line numbers (bat --style=numbers,header) rejected",
			msg = "feat: x\n\n     File: /tmp/body.txt\n   1 - item 1\n   2 - item 2\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n",
		},
		{
			label = "bat numbers-only gutter (bat --style=numbers) rejected",
			msg = "feat: x\n\n   1 - item 1\n   2 - item 2\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n",
		},
		{
			label = "bat STDIN box border rejected even on Merge commit",
			msg = "Merge branch 'main'\n\nSTDIN ─────────\n",
		},
		{
			label = "bat grid border rejected",
			msg = "feat: polluted\n\n───────┼───────\n",
		},
		{
			label = "bat numbered gutter line with box bar rejected",
			msg = "feat: polluted\n\n   1   │ - item\n",
		},
		{
			label = "ANSI escape sequence rejected",
			msg = "\027[32mfeat: colored subject\027[0m\n",
		},
		{ label = "non-conventional header rejected", msg = "Update README with new instructions\n" },
		{ label = "unknown commit type 'feature' rejected", msg = "feature(winbar): add tab click\n" },
		{ label = "uppercase commit type 'Feat' rejected", msg = "Feat(winbar): add tab click\n" },
		{ label = "empty scope 'feat():' rejected", msg = "feat(): add tab click\n" },
		{ label = "trailing comma scope 'feat(winbar,):' rejected", msg = "feat(winbar,): add tab click\n" },
		{ label = "uppercase/spaced scope rejected", msg = "feat(Win Bar): add tab click\n" },
		{ label = "missing space after colon rejected", msg = "feat(winbar):add tab click\n" },
		{ label = "double space after colon rejected", msg = "feat(winbar):  add tab click\n" },
		{ label = "empty subject after colon rejected", msg = "feat(winbar): \n" },
		{
			label = "missing blank line after subject rejected",
			msg = "feat(winbar): add tab click\n- missing blank separator\n",
		},
		{
			label = "separate -m per bullet (4 paragraphs with Co-Authored-By) rejected",
			msg = table.concat({
				"feat(winbar): add tab click",
				"",
				"- bullet one in first -m",
				"",
				"- bullet two in separate -m",
				"",
				"Co-Authored-By: Claude <noreply@anthropic.com>",
			}, "\n"),
		},
		{
			label = "separate -m per bullet without Co-Authored-By rejected",
			msg = "feat(winbar): add tab click\n\n- bullet one\n\n- bullet two\n",
		},
		{
			label = "intro prose + bullet followed by separate bullet paragraph rejected",
			msg = "feat(winbar): add tab click\n\nSummary:\n- bullet one\n\n- bullet two\n",
		},
		{
			label = "separate -m per numbered list item rejected",
			msg = "feat(winbar): add tab click\n\n1. first item\n\n2. second item\n",
		},
		{
			label = "2-paragraph co-authored commit missing body rejected",
			msg = "feat(winbar): add tab click\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n",
		},
		{
			label = "body bullet glued onto Co-Authored-By without blank line rejected",
			msg = "feat(winbar): add tab click\n\n- bullet one\n\n- bullet two\nCo-Authored-By: Claude <noreply@anthropic.com>\n",
		},
		{
			label = "Co-Authored-By in middle paragraph rejected",
			msg = "feat(winbar): add tab click\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n\n- trailing notes\n",
		},
		{
			label = "lowercase co-authored-by prefix rejected",
			msg = "feat(winbar): add tab click\n\n- add click\n\nco-authored-by: Claude <noreply@anthropic.com>\n",
		},
		{
			label = "typo Co-Author-By trailer key rejected",
			msg = "feat(winbar): add tab click\n\n- add click\n\nCo-Author-By: Claude 3.7 Sonnet <noreply@anthropic.com>\n",
		},
		{
			label = "space before colon 'Co-Authored-By :' rejected",
			msg = "feat(winbar): add tab click\n\n- add click\n\nCo-Authored-By : Claude <noreply@anthropic.com>\n",
		},
		{
			label = "missing hyphen 'Coauthored-By:' rejected",
			msg = "feat(winbar): add tab click\n\n- add click\n\nCoauthored-By: Claude <noreply@anthropic.com>\n",
		},
		{
			label = "malformed Co-Authored-By email rejected",
			msg = "feat(winbar): add tab click\n\n- add click\n\nCo-Authored-By: Claude <not-an-email>\n",
		},
		{
			label = "Git Revert commit with versioned AI Co-Authored-By rejected",
			msg = 'Revert "feat: x"\n\nThis reverts commit abc.\n\nCo-Authored-By: Claude 3.7 Sonnet <noreply@anthropic.com>\n',
		},
		{
			label = "model version 'Claude 3.7 Sonnet' rejected",
			msg = "feat: x\n\n- y\n\nCo-Authored-By: Claude 3.7 Sonnet <noreply@anthropic.com>\n",
		},
		{
			label = "model version 'Claude Opus 4.6' rejected",
			msg = "feat: x\n\n- y\n\nCo-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>\n",
		},
		{
			label = "glued model version 'Claude4' rejected",
			msg = "feat: x\n\n- y\n\nCo-Authored-By: Claude4 <bot@users.noreply.github.com>\n",
		},
		{
			label = "model version 'Gemini 3.8 Flash' rejected",
			msg = "feat: x\n\n- y\n\nCo-Authored-By: Gemini 3.8 Flash <218195315+gemini-cli@users.noreply.github.com>\n",
		},
		{
			label = "glued model version 'Gemini3' rejected",
			msg = "feat: x\n\n- y\n\nCo-Authored-By: Gemini3 <bot@users.noreply.github.com>\n",
		},
		{
			label = "model version 'GPT-4o' rejected",
			msg = "feat: x\n\n- y\n\nCo-Authored-By: GPT-4o <noreply@openai.com>\n",
		},
		{
			label = "glued model version 'GPT4o' and 'GPT5' rejected",
			msg = "feat: x\n\n- y\n\nCo-Authored-By: GPT4o <bot@users.noreply.github.com>\n",
		},
		{
			label = "reasoning model 'o5' rejected",
			msg = "feat: x\n\n- y\n\nCo-Authored-By: o5 <bot@users.noreply.github.com>\n",
		},
		{
			label = "model version 'DeepSeek R1' and glued 'DeepSeekV3' rejected",
			msg = "feat: x\n\n- y\n\nCo-Authored-By: DeepSeekV3 <bot@users.noreply.github.com>\n",
		},
		{
			label = "outer harness 'Antigravity' rejected",
			msg = "feat: x\n\n- y\n\nCo-Authored-By: Antigravity <218195315+gemini-cli@users.noreply.github.com>\n",
		},
		{
			label = "outer harness 'agy' rejected",
			msg = "feat: x\n\n- y\n\nCo-Authored-By: agy <user@example.com>\n",
		},
		{
			label = "outer harness 'Oh-My-Pi' rejected",
			msg = "feat: x\n\n- y\n\nCo-Authored-By: Oh-My-Pi <user@example.com>\n",
		},
		{
			label = "outer harness 'omp' rejected",
			msg = "feat: x\n\n- y\n\nCo-Authored-By: omp <user@example.com>\n",
		},
		{
			label = "outer harness 'Claude Code' rejected",
			msg = "feat: x\n\n- y\n\nCo-Authored-By: Claude Code <noreply@anthropic.com>\n",
		},
		{
			label = "outer harness 'Codex' rejected",
			msg = "feat: x\n\n- y\n\nCo-Authored-By: Codex <noreply@openai.com>\n",
		},
		{
			label = "outer harness 'Cursor' rejected",
			msg = "feat: x\n\n- y\n\nCo-Authored-By: Cursor <user@example.com>\n",
		},
		{
			label = "outer harness 'OpenCode', 'Roo Code', and 'Kilo Code' rejected",
			msg = "feat: x\n\n- y\n\nCo-Authored-By: Roo Code <noreply@roocode.com>\n",
		},
		{
			label = "extended AI family with glued version 'Qwen3' or 'Grok3' rejected",
			msg = "feat: x\n\n- y\n\nCo-Authored-By: Qwen3 <user@example.com>\n",
		},
		{
			label = "wrong Gemini email <noreply@google.com> rejected",
			msg = "feat: x\n\n- y\n\nCo-Authored-By: Gemini <noreply@google.com>\n",
		},
		{
			label = "AI vendor domain <claude@anthropic.com> paired with non-canonical name rejected",
			msg = "feat: x\n\n- y\n\nCo-Authored-By: Assistant <claude@anthropic.com>\n",
		},
		{
			label = "AI bot email <gemini-code-assist@google.com> rejected",
			msg = "feat: x\n\n- y\n\nCo-Authored-By: Helper <gemini-code-assist@google.com>\n",
		},
		{
			label = "GitHub [bot] email rejected",
			msg = "feat: x\n\n- y\n\nCo-Authored-By: Helper <12345+helper[bot]@users.noreply.github.com>\n",
		},
	}
	for _, tc in ipairs(invalid_commits) do
		local errs = cm.validate_commit_message(tc.msg)
		check(#errs >= 1, tc.label)
	end

	check(
		#cm.validate_commit_message("feat: solo commit without trailer\n", { require_coauthor = true }) >= 1,
		"require_coauthor=true rejects commit missing canonical AI Co-Authored-By"
	)

	-- 4. `cliff.toml` parser synchronization checks (positive + commented-out parser negative control)
	local cliff_errs = cm.check_cliff_toml_sync(plugin_root)
	check(#cliff_errs == 0, "cliff.toml commit_parsers synced with lint_commit_msg.lua", table.concat(cliff_errs, "; "))

	local drift_dir = tmp_root .. "/cliff-drift-repo"
	vim.fn.mkdir(drift_dir, "p")
	check(#cm.check_cliff_toml_sync(drift_dir) >= 1, "missing cliff.toml rejected by check_cliff_toml_sync")

	local cliff_fd = assert(vim.uv.fs_open(plugin_root .. "/cliff.toml", "r", 438))
	local cliff_stat = assert(vim.uv.fs_fstat(cliff_fd))
	local real_cliff_src = vim.uv.fs_read(cliff_fd, cliff_stat.size, 0) or ""
	vim.uv.fs_close(cliff_fd)
	local commented_cliff = real_cliff_src:gsub('{ message = "%^revert"', '# { message = "^revert"')
	local dfd = assert(vim.uv.fs_open(drift_dir .. "/cliff.toml", "w", 420))
	vim.uv.fs_write(dfd, commented_cliff, 0)
	vim.uv.fs_close(dfd)
	check(
		#cm.check_cliff_toml_sync(drift_dir) >= 1,
		"commented-out parser rule in cliff.toml rejected by check_cliff_toml_sync"
	)

	-- 5. `.claude/worktrees` isolation: dangling symlinks inside ignored worktrees do not break repo lint
	local fake_repo_check = cm.parse_cliff_types("# { message = \"^feat\" }\n{ message = '^fix', group = 'Fixes' }\n")
	check(
		fake_repo_check.fix == true and not fake_repo_check.feat,
		"parse_cliff_types ignores # comments and handles ''"
	)
	check(type(repo_linter.validate_commit_message) == "function", "lint_repo re-exports validate_commit_message")

	local md_linter = dofile(plugin_root .. "/scripts/lint_markdown.lua")
	local wt_iso = tmp_root .. "/wt-iso-repo"
	vim.fn.mkdir(wt_iso .. "/.agents/rules", "p")
	vim.fn.mkdir(wt_iso .. "/.agents/skills/demo-skill", "p")
	vim.fn.mkdir(wt_iso .. "/.claude/worktrees/agent2", "p")
	local function write_str(p, s)
		local f = assert(vim.uv.fs_open(p, "w", 420))
		vim.uv.fs_write(f, s, 0)
		vim.uv.fs_close(f)
	end
	write_str(wt_iso .. "/AGENTS.md", "# AGENTS\n")
	write_str(wt_iso .. "/.agents/rules/r.md", "---\ntrigger: always_on\n---\nBody\n")
	write_str(wt_iso .. "/.agents/skills/demo-skill/SKILL.md", "---\nname: demo-skill\ndescription: d\n---\nBody\n")
	assert(vim.uv.fs_symlink("AGENTS.md", wt_iso .. "/CLAUDE.md"))
	assert(vim.uv.fs_symlink("../.agents/rules", wt_iso .. "/.claude/rules"))
	assert(vim.uv.fs_symlink("../.agents/skills", wt_iso .. "/.claude/skills"))
	assert(vim.uv.fs_symlink("/nonexistent/target", wt_iso .. "/.claude/worktrees/agent2/dangling_wip"))
	local function rf(p)
		local st = vim.uv.fs_stat(p)
		if not st or st.type ~= "file" then
			return nil, "missing"
		end
		local f = assert(vim.uv.fs_open(p, "r", 438))
		local d = st.size > 0 and vim.uv.fs_read(f, st.size, 0) or ""
		vim.uv.fs_close(f)
		return d, nil
	end
	local wt_errs = md_linter.lint_docs_and_customizations(wt_iso, rf, function()
		return {}
	end)
	check(
		#wt_errs == 0,
		"dangling symlinks inside .claude/worktrees are ignored by lint_docs_and_customizations",
		table.concat(wt_errs, "; ")
	)

	-- 6. Real hermetic `git commit` E2E test wired to `./scripts/check.sh commit-msg` (incl. stdin & custom commentChar)
	local hook_repo = tmp_root .. "/commit-hook-e2e"
	vim.fn.mkdir(hook_repo .. "/.git/hooks", "p")
	for _, avar in ipairs({ "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL" }) do
		vim.env[avar] = nil
	end
	local function git_exec(args, extra_env)
		local env = vim.tbl_extend("force", { GIT_TERMINAL_PROMPT = "0" }, extra_env or {})
		return vim.system(args, { cwd = hook_repo, text = true, env = env }):wait(10000)
	end
	assert(git_exec({ "git", "init", "-b", "main" }).code == 0, "git init commit-hook-e2e")
	assert(git_exec({ "git", "config", "user.name", "Jeffrey Test" }).code == 0)
	assert(git_exec({ "git", "config", "user.email", "jeffrey@example.com" }).code == 0)
	assert(git_exec({ "git", "config", "commit.gpgsign", "false" }).code == 0)
	assert(git_exec({ "git", "config", "core.hooksPath", ".git/hooks" }).code == 0)

	local hook_path = hook_repo .. "/.git/hooks/commit-msg"
	local hfd = assert(vim.uv.fs_open(hook_path, "w", 493)) -- 0755
	vim.uv.fs_write(
		hfd,
		string.format('#!/usr/bin/env bash\nexec %q commit-msg "$1"\n', plugin_root .. "/scripts/check.sh"),
		0
	)
	vim.uv.fs_close(hfd)
	vim.uv.fs_chmod(hook_path, 493)

	local stdin_res = vim.system({ plugin_root .. "/scripts/check.sh", "commit-msg", "-" }, {
		cwd = hook_repo,
		text = true,
		stdin = "feat(lint): support stdin commit-msg check\n",
	}):wait(10000)
	check(stdin_res.code == 0, "check.sh commit-msg '-' validates message from stdin", stdin_res.stderr)

	local tfd = assert(vim.uv.fs_open(hook_repo .. "/hello.txt", "w", 420))
	vim.uv.fs_write(tfd, "v1\n", 0)
	vim.uv.fs_close(tfd)
	assert(git_exec({ "git", "add", "hello.txt" }).code == 0)

	local bad_hook_1 = git_exec({
		"git",
		"commit",
		"-m",
		"feat(hooks): test hook",
		"-m",
		"- bullet 1",
		"-m",
		"- bullet 2",
		"-m",
		"Co-Authored-By: Gemini <218195315+gemini-cli@users.noreply.github.com>",
	})
	check(bad_hook_1.code ~= 0, "real git commit-msg hook blocks 4-paragraph sparse -m commit")

	local bad_hook_2 = git_exec({
		"git",
		"commit",
		"-m",
		"feat(hooks): test hook",
		"-m",
		"- bullet 1",
		"-m",
		"Co-Authored-By: Gemini 3.8 Flash <218195315+gemini-cli@users.noreply.github.com>",
	})
	check(bad_hook_2.code ~= 0, "real git commit-msg hook blocks versioned AI model name")

	local good_hook = git_exec({
		"git",
		"commit",
		"-m",
		"feat(hooks): enforce commit message standards",
		"-m",
		"- Reject bat STDIN artifacts and sparse bullet -m paragraphs\n- Validate base AI model family names and vendor emails",
		"-m",
		"Co-Authored-By: Gemini <218195315+gemini-cli@users.noreply.github.com>",
	})
	check(good_hook.code == 0, "real git commit-msg hook accepts canonical 3-part -m commit", good_hook.stderr)

	local log_out = git_exec({ "git", "log", "-1", "--format=%an <%ae>%n%B" })
	check(
		log_out.code == 0
			and (log_out.stdout or ""):find("Jeffrey Test <jeffrey@example.com>", 1, true) ~= nil
			and (log_out.stdout or ""):find(
					"Co-Authored-By: Gemini <218195315+gemini-cli@users.noreply.github.com>",
					1,
					true
				)
				~= nil,
		"git log preserves human Author and 3rd-paragraph AI Co-Authored-By trailer"
	)

	-- Interactive editor commit (`git commit -F <file> -e`) with custom `core.commentChar = ";"`
	assert(git_exec({ "git", "config", "core.commentChar", ";" }).code == 0)
	local tfd2 = assert(vim.uv.fs_open(hook_repo .. "/hello.txt", "w", 420))
	vim.uv.fs_write(tfd2, "v2\n", 0)
	vim.uv.fs_close(tfd2)
	assert(git_exec({ "git", "add", "hello.txt" }).code == 0)
	local tmpl_path = tmp_root .. "/commit-tmpl.txt"
	local mfd = assert(vim.uv.fs_open(tmpl_path, "w", 420))
	vim.uv.fs_write(
		mfd,
		"fix(hooks): honor git core.commentChar semicolon\n\n- Strip ';' editor comments in commit-msg hook\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n",
		0
	)
	vim.uv.fs_close(mfd)
	local custom_cc_commit = git_exec({ "git", "commit", "-F", tmpl_path, "-e" }, { GIT_EDITOR = "true" })
	check(
		custom_cc_commit.code == 0,
		"interactive git commit with custom core.commentChar=';' passes commit-msg hook",
		custom_cc_commit.stderr
	)
end
