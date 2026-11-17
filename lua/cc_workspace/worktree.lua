-- Backwards-compatible facade re-exporting Git inspection (`git.lua`),
-- async worktree operations (`worktree_ops.lua`), agent lifecycle state (`agent_state.lua`),
-- and idempotent CodeCompanion lifecycle autocmd registration (`setup`).

local agent_state = require("cc_workspace.agent_state")
local git = require("cc_workspace.git")
local worktree_ops = require("cc_workspace.worktree_ops")

local M = {
	-- Constants
	SPINNER_FRAMES = agent_state.SPINNER_FRAMES,

	-- Pure-Lua `.git` / `HEAD` inspection, path normalization & cache management (`git.lua`)
	normalize_path = git.normalize_path,
	invalidate_git_cache = git.invalidate_git_cache,
	get_repo_root = git.get_repo_root,
	get_worktree_root = git.get_worktree_root,
	is_linked_worktree = git.is_linked_worktree,
	get_worktree_branch = git.get_worktree_branch,
	run_git_async = git.run_git_async,

	-- Bounded async Git worktree discovery, creation & removal (`worktree_ops.lua`)
	list_worktrees = worktree_ops.list_worktrees,
	set_worktrees_base_dir = worktree_ops.set_worktrees_base_dir,
	get_worktrees_base_dir = worktree_ops.get_worktrees_base_dir,
	sanitize_branch_dir = worktree_ops.sanitize_branch_dir,
	default_worktree_dir = worktree_ops.default_worktree_dir,
	create_worktree = worktree_ops.create_worktree,
	prompt_create_worktree = worktree_ops.prompt_create_worktree,
	remove_worktree = worktree_ops.remove_worktree,

	-- Orca / Herdr agent lifecycle status, rollups, notifications & listeners (`agent_state.lua`)
	setup_highlights = agent_state.setup_highlights,
	on_change = agent_state.on_change,
	get_anim_idx = agent_state.get_anim_idx,
	get_last_background_bufnr = agent_state.get_last_background_bufnr,
	clear_last_background_bufnr = agent_state.clear_last_background_bufnr,
	get_active_requests = agent_state.get_active_requests,
	has_active_request = agent_state.has_active_request,
	notifications_enabled = agent_state.notifications_enabled,
	set_notifications = agent_state.set_notifications,
	toggle_notifications = agent_state.toggle_notifications,
	set_chat_state = agent_state.set_chat_state,
	mark_read = agent_state.mark_read,
	get_chat_status = agent_state.get_chat_status,
	get_rollup = agent_state.get_rollup,
	get_attention_chats = agent_state.get_attention_chats,
	jump_to_attention = agent_state.jump_to_attention,
	reset_states = agent_state.reset_states,
}

---Check whether a `CodeCompanionRequestFinished` event payload represents a failed turn.
---@param data table
---@return boolean, string|nil
local function is_error_finish(data)
	if type(data) ~= "table" then
		return false, nil
	elseif data.error ~= nil and data.error ~= false and data.error ~= "" then
		local msg = type(data.error) == "string" and data.error
			or (type(data.error) == "table" and data.error.message)
			or "Request error"
		return true, msg
	end
	local st = type(data.status) == "string" and data.status:lower() or ""
	local err_st = st == "error" or st == "failed" or st == "refusal" or st == "max_tokens" or st == "max_turn_requests"
	return err_st, err_st and st or nil
end

---Dispatch chat-buffer CodeCompanion `User` lifecycle events into `agent_state`.
---@param ev string
---@param bufnr integer
---@param data table
---@param adapter_name string|nil
local function handle_chat_user_event(ev, bufnr, data, adapter_name)
	local nopts = { adapter = adapter_name, notify = false }
	if ev == "CodeCompanionChatCreated" then
		if not agent_state.get_chat_entry(bufnr) then
			agent_state.set_chat_state(bufnr, "idle", nopts)
		end
	elseif ev == "CodeCompanionChatOpened" and vim.api.nvim_get_current_buf() == bufnr then
		agent_state.mark_read(bufnr)
	elseif ev == "CodeCompanionChatSubmitted" then
		agent_state.tools_running(bufnr, false)
		agent_state.set_chat_state(bufnr, "thinking", nopts)
	elseif ev == "CodeCompanionRequestStarted" then
		agent_state.set_chat_state(bufnr, "thinking", nopts)
	elseif ev == "CodeCompanionRequestStreaming" then
		agent_state.set_chat_state(bufnr, "streaming", nopts)
	elseif ev == "CodeCompanionRequestFinished" then
		local is_err, err_msg = is_error_finish(data)
		local st = type(data.status) == "string" and data.status:lower() or ""
		if is_err then
			agent_state.tools_running(bufnr, false)
			agent_state.set_chat_state(bufnr, "error", { adapter = adapter_name, error = err_msg })
		elseif st == "cancelled" or st == "canceled" then
			agent_state.tools_running(bufnr, false)
			agent_state.set_chat_state(bufnr, "idle", nopts)
		elseif agent_state.tools_running(bufnr) then
			local cur = agent_state.get_chat_entry(bufnr)
			if not cur or cur.state ~= "waiting" then
				agent_state.set_chat_state(bufnr, "thinking", nopts)
			end
		elseif vim.api.nvim_get_current_buf() ~= bufnr then
			agent_state.set_chat_state(bufnr, "unread", { adapter = adapter_name })
		else
			agent_state.set_chat_state(bufnr, "idle", nopts)
		end
	elseif ev == "CodeCompanionChatStopped" or ev == "CodeCompanionChatCleared" then
		agent_state.tools_running(bufnr, false)
		local cur = agent_state.get_chat_entry(bufnr)
		if not cur or cur.state ~= "error" then
			agent_state.set_chat_state(bufnr, "idle", nopts)
		end
	elseif ev == "CodeCompanionChatClosed" then
		agent_state.drop_chat_buf(bufnr, true)
	elseif
		ev == "CodeCompanionToolApprovalRequested"
		or ev == "CodeCompanionToolQuestionAsked"
		or ev == "CodeCompanionToolWaiting"
		or ev:match("^CodeCompanionToolConfirm")
	then
		agent_state.set_chat_state(
			bufnr,
			"waiting",
			{ adapter = adapter_name, tool = data.name or data.header or data.tool }
		)
	elseif ev == "CodeCompanionToolApprovalFinished" or ev == "CodeCompanionToolQuestionAnswered" then
		local choice = type(data.choice) == "string" and data.choice:lower() or ""
		if choice == "cancelled" or choice == "cancel" then
			agent_state.tools_running(bufnr, false)
			agent_state.set_chat_state(bufnr, "idle", nopts)
		else
			local prev = agent_state.get_chat_entry(bufnr)
			agent_state.set_chat_state(bufnr, (prev and prev.prev_running_phase) or "thinking", nopts)
		end
	elseif ev == "CodeCompanionToolsStarted" or ev == "CodeCompanionToolStarted" then
		agent_state.tools_running(bufnr, true)
		local cur = agent_state.get_chat_entry(bufnr)
		if not cur or (cur.state ~= "waiting" and cur.state ~= "streaming") then
			agent_state.set_chat_state(bufnr, "thinking", nopts)
		end
	elseif ev == "CodeCompanionToolsFinished" then
		agent_state.tools_running(bufnr, false)
		local is_err, err_msg = is_error_finish(data)
		if is_err then
			agent_state.set_chat_state(bufnr, "error", { adapter = adapter_name, error = err_msg })
		end
	end
end

---Initialize worktree base directory and CodeCompanion agent lifecycle autocmds idempotently.
---@param opts? { notifications?: boolean, worktrees_base_dir?: string }
function M.setup(opts)
	opts = opts or {}
	if type(opts.worktrees_base_dir) == "string" and opts.worktrees_base_dir ~= "" then
		worktree_ops.set_worktrees_base_dir(opts.worktrees_base_dir)
	end
	agent_state.configure_options(opts)

	local group = vim.api.nvim_create_augroup("CcWorkspaceWorktree", { clear = true })
	vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = agent_state.setup_highlights })

	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = {
			"CodeCompanionRequestStarted",
			"CodeCompanionRequestStreaming",
			"CodeCompanionRequestFinished",
			"CodeCompanionChatCreated",
			"CodeCompanionChatOpened",
			"CodeCompanionChatSubmitted",
			"CodeCompanionChatStopped",
			"CodeCompanionChatCleared",
			"CodeCompanionChatClosed",
			"CodeCompanionTool*",
		},
		callback = function(args)
			local ev = args.match or ""
			local data = type(args.data) == "table" and args.data or {}
			local bnr = type(data.bufnr) == "number" and data.bufnr or nil
			if
				bnr
				and bnr > 0
				and vim.api.nvim_buf_is_valid(bnr)
				and (data.interaction == nil or data.interaction == "chat")
			then
				handle_chat_user_event(ev, bnr, data, agent_state.extract_adapter_name(data.adapter))
			else
				agent_state.handle_non_chat_event(ev, data, data.adapter)
			end
		end,
	})

	vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "TabEnter" }, {
		group = group,
		callback = function()
			local buf = vim.api.nvim_get_current_buf()
			if
				vim.api.nvim_buf_is_valid(buf)
				and (vim.bo[buf].filetype == "codecompanion" or agent_state.get_chat_entry(buf) ~= nil)
				and vim.fn.bufwinid(buf) ~= -1
			then
				agent_state.mark_read(buf)
			end
		end,
	})

	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		callback = function(args)
			agent_state.drop_chat_buf(args.buf, false)
		end,
	})
end

return M
