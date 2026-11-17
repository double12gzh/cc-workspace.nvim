-- Public facade for `cc-workspace.nvim` (module `cc_workspace`).
-- Core submodules form a strict 0-cycle DAG:
--   config -> icons -> {winbar_highlights, keymaps, worktree}
--   config -> state -> projects -> render -> patches -> layout -> pickers -> sidebar_actions -> sidebar -> cc_workspace
local config = require("cc_workspace.config")
local keymaps = require("cc_workspace.keymaps")
local layout = require("cc_workspace.layout")
local patches = require("cc_workspace.patches")
local pickers = require("cc_workspace.pickers")
local projects = require("cc_workspace.projects")
local render = require("cc_workspace.render")
local sidebar = require("cc_workspace.sidebar")
local state_mod = require("cc_workspace.state")
local worktree = require("cc_workspace.worktree")

local M = {
	-- State, status & text formatting utilities
	truncate_display = state_mod.truncate_display,
	format_columns = state_mod.format_columns,
	get_chat_title = state_mod.get_chat_title,
	is_current_tab = state_mod.is_current_tab,
	get_main_win = state_mod.get_main_win,

	-- Project store, path normalization & candidate discovery
	normalize_project_path = projects.normalize_project_path,
	get_projects_file = projects.get_projects_file,
	set_projects_file = projects.set_projects_file,
	list_projects = projects.list_projects,
	get_valid_chat_cwd = projects.get_valid_chat_cwd,
	get_chat_project_path = projects.get_chat_project_path,
	get_chat_project_name = projects.get_chat_project_name,
	get_win_cwd = projects.get_win_cwd,
	add_project = projects.add_project,
	remove_project = projects.remove_project,
	rename_project = projects.rename_project,
	warm_zoxide_cache = projects.warm_zoxide_cache,
	get_candidate_projects = projects.get_candidate_projects,

	-- Sidebar renderer & coalesced scheduling
	schedule_render = render.schedule_render,
	render = render.render,

	-- CodeCompanion, history & persisted.nvim patches
	patch_persisted_session = patches.patch_persisted_session,
	patch_codecompanion_cwd = patches.patch_codecompanion_cwd,
	patch_history_ui = patches.patch_history_ui,

	-- Workspace tab/window layout & chat lifecycle
	sync_sidebar_width = layout.sync_sidebar_width,
	focus_sidebar = layout.focus_sidebar,
	show_chat = layout.show_chat,
	new_chat = layout.new_chat,
	open_history_chat = layout.open_history_chat,
	activate_project = layout.activate_project,
	open_project_in_code_tab = layout.open_project_in_code_tab,
	close_chat = layout.close_chat,
	close_chat_safely = layout.close_chat_safely,
	cycle_chat = layout.cycle_chat,
	leave = layout.leave,
	close = layout.close,
	enter = layout.enter,
	send_visual_selection = layout.send_visual_selection,
	add_visual_to_chat = layout.add_visual_to_chat,
	toggle_side_chat = layout.toggle_side_chat,
	focus_or_open_chat = layout.focus_or_open_chat,
	new_smart_chat = layout.new_smart_chat,
	toggle = layout.toggle,

	-- Interactive Telescope / fallback pickers
	prompt_add_project_input = pickers.prompt_add_project_input,
	prompt_add_project = pickers.prompt_add_project,
	prompt_new_project_chat = pickers.prompt_new_project_chat,
	prompt_create_worktree_chat = pickers.prompt_create_worktree_chat,
	create_worktree_chat = pickers.create_worktree_chat,

	-- Sidebar row actions & help float
	yank_row_path = sidebar.yank_row_path,
	show_help_float = sidebar.show_help_float,

	-- Dynamic keymap customization & unified keymap inspector
	get_keymaps = keymaps.get_keymaps,
	get_effective_keymaps = keymaps.get_effective_keymaps,
	set_keymaps = keymaps.set_keymaps,
	show_keys = keymaps.show_keys,
}

---Register the 5 `:CodeCompanionWorkspace*` / `:CodeCompanionNotificationsToggle` user commands idempotently.
local function register_user_commands()
	vim.api.nvim_create_user_command("CodeCompanionWorkspace", function(cmd_opts)
		local arg = vim.trim(cmd_opts.args or "")
		if arg ~= "" then
			local added = M.add_project(arg)
			if added then
				M.enter(true, { target_project = added.path })
			end
		else
			M.toggle()
		end
	end, {
		nargs = "?",
		complete = "dir",
		desc = "Toggle dedicated AI Workspace tab (or add & open a project directory)",
	})

	vim.api.nvim_create_user_command("CodeCompanionWorkspaceAddProject", function(cmd_opts)
		local arg = vim.trim(cmd_opts.args or "")
		if arg ~= "" then
			local added = M.add_project(arg)
			if added then
				M.activate_project(added.path, true)
			end
		else
			M.enter(false, { skip_auto_chat = true })
			M.prompt_add_project()
		end
	end, {
		nargs = "?",
		complete = "dir",
		desc = "Add a Project directory to the AI Workspace sidebar",
	})

	vim.api.nvim_create_user_command("CodeCompanionWorkspaceWorktree", function(cmd_opts)
		local arg = vim.trim(cmd_opts.args or "")
		M.prompt_create_worktree_chat(arg ~= "" and arg or nil)
	end, {
		nargs = "?",
		complete = "dir",
		desc = "Create a Git Worktree and start an AI Workspace conversation in it",
	})

	vim.api.nvim_create_user_command("CodeCompanionWorkspaceKeys", function(cmd_opts)
		local arg = vim.trim(cmd_opts.args or ""):lower()
		M.show_keys({ mode = arg == "float" and "float" or "picker" })
	end, {
		nargs = "?",
		complete = function()
			return { "picker", "float" }
		end,
		desc = "Inspect, search, and dynamically rebind AI Workspace keymaps",
	})

	vim.api.nvim_create_user_command("CodeCompanionNotificationsToggle", function()
		worktree.toggle_notifications()
	end, {
		desc = "Toggle CodeCompanion AI Agent background completion notifications",
	})
end

---Initialize `cc-workspace.nvim` idempotently (config, worktree engine, patches, keymaps, winbar, commands).
---@param opts? CcWorkspaceConfig
---@return table
function M.setup(opts)
	local merged = config.setup(opts)
	state_mod.setup_highlights()

	if type(merged.projects_file) == "string" and merged.projects_file ~= "" and not state_mod.state.projects_file then
		projects.set_projects_file(merged.projects_file)
	end

	worktree.setup({
		notifications = merged.notifications,
		worktrees_base_dir = merged.worktrees_base_dir,
	})

	keymaps.apply_global_keymaps()
	patches.register_chat_keymaps(merged.chat_keymaps)
	keymaps.apply_chat_keymaps_to_open_buffers()
	patches.patch_persisted_session()
	patches.patch_codecompanion_cwd()
	patches.patch_history_ui()
	patches.guard_history_chat_created()

	if state_mod.state.sidebar_buf and vim.api.nvim_buf_is_valid(state_mod.state.sidebar_buf) then
		sidebar.apply_sidebar_keymaps(state_mod.state.sidebar_buf)
		render.schedule_render()
	end

	if merged.winbar ~= false then
		pcall(function()
			local wb_opts = type(merged.winbar) == "table" and merged.winbar or nil
			require("cc_workspace.winbar").setup(wb_opts)
		end)
	end

	if merged.commands ~= false then
		register_user_commands()
	end

	vim.schedule(function()
		patches.register_chat_keymaps(merged.chat_keymaps)
		keymaps.apply_chat_keymaps_to_open_buffers()
		patches.patch_history_ui()
		patches.guard_history_chat_created()
	end)

	state_mod.state.setup_done = true
	return M
end

local LAZY_SUBMODULES = {
	config = "cc_workspace.config",
	icons = "cc_workspace.icons",
	keymaps = "cc_workspace.keymaps",
	sidebar_actions = "cc_workspace.sidebar_actions",
	worktree = "cc_workspace.worktree",
	winbar = "cc_workspace.winbar",
	winbar_highlights = "cc_workspace.winbar_highlights",
	statusline = "cc_workspace.statusline",
	switcher = "cc_workspace.switcher",
}

return setmetatable(M, {
	__index = function(_, key)
		local mod_name = LAZY_SUBMODULES[key]
		if mod_name then
			local ok, mod = pcall(require, mod_name)
			if ok then
				return mod
			end
		end
		return nil
	end,
})
