-- Scoped `buffer_context` resolution, rule-callback chat creation, target `cwd`
-- selection, and `codecompanion-history` conversation restoration.

local patches = require("cc_workspace.patches")
local projects = require("cc_workspace.projects")
local state_mod = require("cc_workspace.state")

local state = state_mod.state

local M = {}

local function get_layout()
	local ok, mod = pcall(require, "cc_workspace.layout")
	return (ok and type(mod) == "table") and mod or nil
end

---Resolve target working directory for a new workspace conversation.
---@param explicit_project_path? string
---@return string
function M.resolve_new_chat_cwd(explicit_project_path)
	if type(explicit_project_path) == "string" and explicit_project_path ~= "" then
		local norm = projects.normalize_project_path(explicit_project_path)
		if norm then
			if vim.fn.isdirectory(norm) == 1 then
				return norm
			end
			vim.notify(
				string.format("Project directory missing on disk (%s); using current directory", norm),
				vim.log.levels.WARN,
				{ title = "AI Workspace" }
			)
			return projects.get_global_cwd()
		end
	end

	local chat_mod = package.loaded["codecompanion.interactions.chat"]
	if chat_mod and state.main_win and vim.api.nvim_win_is_valid(state.main_win) then
		local cur_cwd = projects.get_valid_chat_cwd(chat_mod.buf_get_chat(vim.api.nvim_win_get_buf(state.main_win)))
		if cur_cwd then
			return cur_cwd
		end
	end

	if
		type(state.last_selected_project) == "string"
		and state.last_selected_project ~= ""
		and vim.fn.isdirectory(state.last_selected_project) == 1
	then
		return state.last_selected_project
	end
	return projects.get_global_cwd()
end

---Build `buffer_context` scoped to `target_cwd` without leaking files from unrelated projects.
---@param target_cwd? string
---@return table
function M.resolve_buffer_context(target_cwd)
	local ctx_mod = require("codecompanion.utils.context")
	return projects.with_temp_cwd(target_cwd, function()
		if
			state.prev_code_buf
			and vim.api.nvim_buf_is_valid(state.prev_code_buf)
			and projects.buf_within_dir(state.prev_code_buf, target_cwd)
		then
			return ctx_mod.get(state.prev_code_buf)
		end
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			if
				vim.api.nvim_buf_is_loaded(buf)
				and vim.bo[buf].buftype == ""
				and vim.bo[buf].filetype ~= ""
				and projects.buf_within_dir(buf, target_cwd)
			then
				return ctx_mod.get(buf)
			end
		end
		local base =
			ctx_mod.get(state.sidebar_buf and vim.api.nvim_buf_is_valid(state.sidebar_buf) and state.sidebar_buf or 0)
		if target_cwd and target_cwd ~= "" then
			base.buftype = ""
			base.code = false
			base.filetype = ""
			base.filename = ""
			base.is_visual = false
			base.is_normal = true
			base.lines = {}
			base.line_count = 0
			base.path = ""
			base.relative_path = ""
		end
		return base
	end)
end

---Instantiate a hidden CodeCompanion chat under `target_cwd` with scoped `buffer_context` and rules callbacks.
---@param target_cwd string
---@param explicit_code_buf? integer|nil
---@param use_explicit_buf_ctx? boolean
---@return table|nil
function M.create_scoped_chat(target_cwd, explicit_code_buf, use_explicit_buf_ctx)
	local chat_mod = require("codecompanion.interactions.chat")
	return projects.with_temp_cwd(target_cwd, function()
		local ctx = use_explicit_buf_ctx and require("codecompanion.utils.context").get(explicit_code_buf)
			or M.resolve_buffer_context(target_cwd)
		local rules_cb = nil
		pcall(function()
			rules_cb =
				require("codecompanion.interactions.shared.rules.helpers").add_callbacks({ buffer_context = ctx })
		end)
		return chat_mod.new({ hidden = true, cwd = target_cwd, buffer_context = ctx, callbacks = rules_cb })
	end)
end

local function resolve_saved_adapter_and_settings(data)
	local adapter = data.adapter
	local settings = type(data.settings) == "table" and vim.deepcopy(data.settings) or nil
	if not adapter then
		return nil, nil
	end
	local ok_res, resolved = pcall(require("codecompanion.adapters").resolve, adapter)
	if not ok_res or not resolved then
		vim.notify(
			string.format("Saved adapter '%s' unavailable; using default adapter", tostring(adapter)),
			vim.log.levels.WARN,
			{ title = "AI Workspace" }
		)
		return nil, nil
	end
	if resolved.type == "acp" then
		return adapter, nil
	end
	if settings and settings.model and resolved.schema and resolved.schema.model then
		local choices = resolved.schema.model.choices
		if type(choices) == "table" then
			local valid_models = {}
			for k, v in pairs(choices) do
				table.insert(valid_models, type(k) == "string" and k or v)
			end
			if #valid_models > 0 and not vim.tbl_contains(valid_models, settings.model) then
				vim.notify(
					string.format(
						"Saved model '%s' unavailable in '%s'; using default",
						tostring(settings.model),
						tostring(adapter)
					),
					vim.log.levels.WARN,
					{ title = "AI Workspace" }
				)
				settings = nil
			end
		end
	end
	return adapter, settings
end

local function restore_saved_chat_context(chat, data, effective_cwd)
	local stored_ctx = data.context_items or data.refs or {}
	if not chat.context or type(stored_ctx) ~= "table" or #stored_ctx == 0 then
		return
	end
	projects.with_temp_cwd(effective_cwd, function()
		local existing_items = chat.context_items or {}
		for _, item in ipairs(stored_ctx) do
			local dup = vim.tbl_contains(existing_items, function(ci)
				return ci.id == item.id
			end, { predicate = true })
			if not dup then
				pcall(function()
					chat.context:add(item)
				end)
			end
		end
	end)
end

local function present_restored_chat(chat, in_ws, focus_main)
	local lay = get_layout()
	if in_ws and lay and type(lay.show_chat) == "function" then
		lay.show_chat(chat, focus_main)
	elseif not in_ws and lay and type(lay.focus_or_open_chat) == "function" then
		lay.focus_or_open_chat(chat)
	end
end

---Restore a saved history entry by `save_id` into the workspace `main_win` or current tab's chat split.
---@param save_id string
---@param focus_main? boolean
---@return table|nil
function M.open_history_chat(save_id, focus_main)
	if focus_main == nil then
		focus_main = true
	end
	local in_ws = state_mod.is_current_tab()
	if in_ws then
		if not state_mod.is_workspace_valid() and state.actions.ensure_workspace_layout then
			state.actions.ensure_workspace_layout()
		end
		if not state_mod.is_workspace_valid() then
			return nil
		end
	end

	---@type any
	local cc = require("codecompanion")
	patches.patch_codecompanion_cwd()
	local chat_mod = require("codecompanion.interactions.chat")
	local all = chat_mod.buf_get_chat()
	for _, entry in ipairs(type(all) == "table" and all or {}) do
		if entry.chat and entry.chat.opts and entry.chat.opts.save_id == save_id then
			present_restored_chat(entry.chat, in_ws, focus_main)
			return entry.chat
		end
	end

	local history = cc.extensions and cc.extensions.history
	if not history or not history.load_chat then
		vim.notify("codecompanion-history extension not loaded", vim.log.levels.WARN, { title = "AI Workspace" })
		return nil
	end

	local data = history.load_chat(save_id)
	if not data then
		vim.notify("Failed to load chat: " .. save_id, vim.log.levels.ERROR, { title = "AI Workspace" })
		return nil
	end

	local messages = data.messages or {}
	local last_msg = messages[#messages]
	if last_msg and (last_msg.role ~= "user" or (last_msg.opts or {}).visible == false) then
		table.insert(messages, { role = "user", content = "", opts = { visible = true } })
	end

	local adapter, settings = resolve_saved_adapter_and_settings(data)
	local raw_saved_cwd = projects.normalize_project_path(data.cwd)
		or projects.normalize_project_path(data.project_root)
	local effective_cwd = projects.get_global_cwd()
	if raw_saved_cwd then
		if vim.fn.isdirectory(raw_saved_cwd) == 1 then
			effective_cwd = raw_saved_cwd
		else
			vim.notify(
				string.format("Saved project directory missing on disk (%s); using current directory", raw_saved_cwd),
				vim.log.levels.WARN,
				{ title = "AI Workspace" }
			)
		end
	end
	local saved_cwd_field = raw_saved_cwd or data.cwd or effective_cwd

	local chat = projects.with_temp_cwd(effective_cwd, function()
		return chat_mod.new({
			hidden = true,
			save_id = data.save_id,
			cwd = saved_cwd_field,
			messages = messages,
			buffer_context = M.resolve_buffer_context(effective_cwd),
			settings = settings,
			adapter = adapter,
			title = data.title,
		})
	end)
	if chat then
		restore_saved_chat_context(chat, data, effective_cwd)
		if type(chat.tool_registry) == "table" then
			chat.tool_registry.schemas = type(data.schemas) == "table" and data.schemas or chat.tool_registry.schemas
			chat.tool_registry.in_use = type(data.in_use) == "table" and data.in_use or chat.tool_registry.in_use
		end
		chat.cycle = data.cycle or 1
		chat.opts = chat.opts or {}
		chat.opts.title_refresh_count = data.title_refresh_count or 0
		chat.opts.cwd = saved_cwd_field
		present_restored_chat(chat, in_ws, focus_main)
	end
	return chat
end

return M
