local M = {}

---@alias CcWorkspaceKeySpec boolean|string|string[]|table<string, string|string[]>

---@class CcWorkspaceGlobalKeymaps
---@field toggle_workspace? CcWorkspaceKeySpec
---@field send_selection? CcWorkspaceKeySpec
---@field new_chat? CcWorkspaceKeySpec
---@field new_project_chat? CcWorkspaceKeySpec
---@field add_project? CcWorkspaceKeySpec
---@field switcher? CcWorkspaceKeySpec
---@field jump_attention? CcWorkspaceKeySpec
---@field new_worktree_chat? CcWorkspaceKeySpec
---@field toggle_side_chat? CcWorkspaceKeySpec
---@field add_visual_to_chat? CcWorkspaceKeySpec
---@field history? CcWorkspaceKeySpec
---@field select_model? CcWorkspaceKeySpec
---@field show_keys? CcWorkspaceKeySpec

---@class CcWorkspaceSidebarKeymaps
---@field open? CcWorkspaceKeySpec
---@field expand_or_open? CcWorkspaceKeySpec
---@field collapse? CcWorkspaceKeySpec
---@field toggle_fold? CcWorkspaceKeySpec
---@field collapse_all? CcWorkspaceKeySpec
---@field expand_all? CcWorkspaceKeySpec
---@field peek? CcWorkspaceKeySpec
---@field next_item? CcWorkspaceKeySpec
---@field prev_item? CcWorkspaceKeySpec
---@field jump_1_9? CcWorkspaceKeySpec
---@field new_chat? CcWorkspaceKeySpec
---@field new_project_chat? CcWorkspaceKeySpec
---@field new_worktree_chat? CcWorkspaceKeySpec
---@field jump_attention? CcWorkspaceKeySpec
---@field add_project? CcWorkspaceKeySpec
---@field add_project_input? CcWorkspaceKeySpec
---@field open_code_tab? CcWorkspaceKeySpec
---@field rename? CcWorkspaceKeySpec
---@field delete? CcWorkspaceKeySpec
---@field inspect? CcWorkspaceKeySpec
---@field yank_path? CcWorkspaceKeySpec
---@field yank_all_paths? CcWorkspaceKeySpec
---@field filter? CcWorkspaceKeySpec
---@field clear_filter? CcWorkspaceKeySpec
---@field history? CcWorkspaceKeySpec
---@field refresh? CcWorkspaceKeySpec
---@field help? CcWorkspaceKeySpec
---@field leave? CcWorkspaceKeySpec
---@field close_workspace? CcWorkspaceKeySpec

---@class CcWorkspaceChatKeymapsConfig
---@field stop? CcWorkspaceKeySpec
---@field close? CcWorkspaceKeySpec
---@field next_chat? CcWorkspaceKeySpec
---@field previous_chat? CcWorkspaceKeySpec
---@field show_keys? CcWorkspaceKeySpec

---@class CcWorkspaceSwitcherKeymaps
---@field select? CcWorkspaceKeySpec
---@field close? CcWorkspaceKeySpec
---@field new_chat? CcWorkspaceKeySpec
---@field new_worktree_chat? CcWorkspaceKeySpec
---@field jump_attention? CcWorkspaceKeySpec
---@field toggle_workspace? CcWorkspaceKeySpec
---@field add_project? CcWorkspaceKeySpec
---@field history? CcWorkspaceKeySpec
---@field delete_chat? CcWorkspaceKeySpec
---@field select_1_9? CcWorkspaceKeySpec
---@field help? CcWorkspaceKeySpec

---@class CcWorkspaceKeymapsConfig
---@field global? CcWorkspaceGlobalKeymaps|table<string, CcWorkspaceKeySpec>
---@field sidebar? CcWorkspaceSidebarKeymaps|table<string, CcWorkspaceKeySpec>
---@field chat? CcWorkspaceChatKeymapsConfig|table<string, CcWorkspaceKeySpec>
---@field switcher? CcWorkspaceSwitcherKeymaps|table<string, CcWorkspaceKeySpec>

---@class CcWorkspaceConfig
---@field sidebar_width? integer
---@field max_history_per_project? integer
---@field projects_file? string|nil
---@field worktrees_base_dir? string|nil
---@field notifications? boolean
---@field commands? boolean
---@field winbar? boolean|table
---@field chat_keymaps? boolean|CcWorkspaceChatKeymapsConfig
---@field keymaps? CcWorkspaceKeymapsConfig
---@field icons? table<string, any>
M.defaults = {
	sidebar_width = 38,
	max_history_per_project = 10,
	projects_file = nil,
	worktrees_base_dir = nil,
	notifications = true,
	commands = true,
	winbar = true,
	chat_keymaps = true,
	keymaps = {
		global = {},
		sidebar = {
			open = "<CR>",
			expand_or_open = { "l", "<Right>" },
			collapse = { "h", "<Left>" },
			toggle_fold = "za",
			collapse_all = "zM",
			expand_all = "zR",
			peek = { "p", "<Space>" },
			next_item = { "<Tab>", "]c" },
			prev_item = { "<S-Tab>", "[c" },
			jump_1_9 = { "1", "2", "3", "4", "5", "6", "7", "8", "9" },
			new_chat = "n",
			new_project_chat = "N",
			new_worktree_chat = "w",
			jump_attention = "u",
			add_project = { "a", "+" },
			add_project_input = "A",
			open_code_tab = "o",
			rename = "r",
			delete = { "d", "x" },
			inspect = "K",
			yank_path = { "y", "gy" },
			yank_all_paths = "Y",
			filter = "f",
			clear_filter = "F",
			history = { "s", "gh" },
			refresh = "R",
			help = { "?", "g?" },
			leave = "q",
			close_workspace = "Q",
		},
		chat = {
			stop = "q",
			close = "<C-c>",
			next_chat = "}",
			previous_chat = "{",
			show_keys = false,
		},
		switcher = {
			select = "<CR>",
			close = { "q", "<Esc>" },
			new_chat = "n",
			new_worktree_chat = "t",
			jump_attention = "u",
			toggle_workspace = "w",
			add_project = "a",
			history = "h",
			delete_chat = { "d", "x" },
			select_1_9 = { "1", "2", "3", "4", "5", "6", "7", "8", "9" },
			help = { "?", "g?" },
		},
	},
	icons = {
		aichat = {
			Chat = "󱜸",
			Copilot = "",
			Me = "",
		},
		ui = {
			Accepted = "",
			ArrowClosed = "",
			ArrowOpen = "",
			Check = "󰄳",
			ChevronRight = "",
			Circle = "",
			Close = "󰅖",
			Close_alt = "",
			Code = "󰌍",
			EmptyFolder = "",
			EmptyFolderOpen = "",
			Folder = "",
			FolderOpen = "",
			History = "󰄉",
			History_alt = "󰋚",
			Lock = "󰍁",
			Modified = "✥",
			Pencil = "󰏫",
			Project = "",
			Search = "",
			Tab = "",
			Window = "",
			Workspace = "󰕮",
		},
		git = {
			Add = "",
			Branch = "",
			Branch_alt = "",
			Git = "󰊢",
			Mod = "M",
			Remove = "",
			Repo = "",
		},
		diagnostics = {
			Error = "",
			Warning = "",
			Information = "",
			Question = "",
			Hint = "󰌵",
		},
		misc = {
			Add = "+",
			Added = "",
			Code = "",
			Vbar = "│",
		},
	},
}

---@type CcWorkspaceConfig
M.options = vim.deepcopy(M.defaults)

---Atomically merge per-scope keymap overrides without concatenating/partially overwriting `string[]` alias arrays.
---@param dst? CcWorkspaceKeymapsConfig
---@param overrides? CcWorkspaceKeymapsConfig
---@return CcWorkspaceKeymapsConfig
function M.merge_keymaps(dst, overrides)
	---@type table<string, table<string, any>>
	local out = type(dst) == "table" and dst or vim.deepcopy(M.defaults.keymaps or {})
	for _, scope in ipairs({ "global", "sidebar", "chat", "switcher" }) do
		local cur_scope = type(out[scope]) == "table" and out[scope] or {}
		out[scope] = cur_scope
		local src_scope = type(overrides) == "table" and overrides[scope] or nil
		if src_scope == false then
			for k in pairs(cur_scope) do
				cur_scope[k] = false
			end
		elseif type(src_scope) == "table" then
			for act, spec in pairs(src_scope) do
				cur_scope[act] = vim.deepcopy(spec)
			end
		end
	end
	return out
end

---Merge user configuration options into `M.options`.
---@param opts? CcWorkspaceConfig
---@return CcWorkspaceConfig
function M.setup(opts)
	if type(opts) == "table" then
		local prev_km = vim.deepcopy(M.options.keymaps or M.defaults.keymaps or {})
		local plain = vim.deepcopy(opts)
		local user_km = plain.keymaps
		plain.keymaps = nil
		M.options = vim.tbl_deep_extend("force", M.options, plain)
		M.options.keymaps = prev_km

		local chat_km = opts.chat_keymaps
		if chat_km == false then
			M.merge_keymaps(M.options.keymaps, {
				chat = { stop = false, close = false, next_chat = false, previous_chat = false },
			})
		elseif type(chat_km) == "table" then
			M.merge_keymaps(M.options.keymaps, { chat = chat_km })
		end

		if type(user_km) == "table" then
			M.merge_keymaps(M.options.keymaps, user_km)
		end
	end
	return M.options
end

M.KEYMAP_SCHEMA = {
	global = {
		{ "toggle_workspace", "n", "Toggle AI Workspace tab" },
		{ "send_selection", "v", "Send visual selection to AI Workspace" },
		{ "new_chat", "n", "New AI conversation" },
		{ "new_project_chat", "n", "Pick Project & start conversation" },
		{ "add_project", "n", "Add Project to AI Workspace" },
		{ "switcher", "n", "List & switch open Chats" },
		{ "jump_attention", "n", "Jump to unread / attention Chat" },
		{ "new_worktree_chat", "n", "New Git Worktree & Agent Chat" },
		{ "toggle_side_chat", "n", "Toggle side AI Chat split" },
		{ "add_visual_to_chat", "v", "Add visual selection to Chat" },
		{ "history", "n", "Browse saved Chat history" },
		{ "select_model", "n", "Select AI adapter / model" },
		{ "show_keys", "n", "Inspect & rebind AI Workspace keymaps" },
	},
	sidebar = {
		{ "open", "Open chat / toggle tree group" },
		{ "expand_or_open", "Expand group or open item" },
		{ "collapse", "Collapse group / parent row" },
		{ "toggle_fold", "Toggle Project / Worktree fold" },
		{ "collapse_all", "Collapse all groups" },
		{ "expand_all", "Expand all groups" },
		{ "peek", "Peek chat (keep sidebar focus)" },
		{ "next_item", "Next actionable item" },
		{ "prev_item", "Previous actionable item" },
		{ "jump_1_9", "Jump to active chat 1–9" },
		{ "new_chat", "New chat in Worktree / Project" },
		{ "new_project_chat", "Pick Project(s) & start chat" },
		{ "new_worktree_chat", "New Git Worktree + Agent Chat" },
		{ "jump_attention", "Jump to unread / attention Agent" },
		{ "add_project", "Add Project (multi-pick)" },
		{ "add_project_input", "Add Project (path input)" },
		{ "open_code_tab", "Open Worktree / Project code tab" },
		{ "rename", "Rename chat or Project alias" },
		{ "delete", "Close chat / rm Worktree / Proj" },
		{ "inspect", "Inspect Project / Worktree / chat" },
		{ "yank_path", "Copy item path to clipboard" },
		{ "yank_all_paths", "Copy all repo & worktree paths" },
		{ "filter", "Filter by keyword" },
		{ "clear_filter", "Clear keyword filter" },
		{ "history", "Full-text saved history picker" },
		{ "refresh", "Refresh worktrees & sidebar" },
		{ "help", "Show shortcuts cheatsheet" },
		{ "leave", "Back to code tab (keep Workspace)" },
		{ "close_workspace", "Close AI Workspace tab" },
	},
	chat = {
		{ "stop", "Stop request, or focus sidebar / hide" },
		{ "close", "Close chat buffer safely" },
		{ "next_chat", "Cycle to next open chat" },
		{ "previous_chat", "Cycle to previous open chat" },
		{ "show_keys", "Open AI Workspace keymaps inspector" },
	},
	switcher = {
		{ "select", "Focus selected Agent conversation" },
		{ "close", "Close floating Agent Switcher" },
		{ "new_chat", "Start new AI conversation" },
		{ "new_worktree_chat", "Create Git Worktree & start Agent" },
		{ "jump_attention", "Jump to unread / attention Agent" },
		{ "toggle_workspace", "Toggle AI Workspace tab" },
		{ "add_project", "Add Project to AI Workspace" },
		{ "history", "Browse saved Chat history" },
		{ "delete_chat", "Stop & close selected conversation" },
		{ "select_1_9", "Direct jump to open Agent 1–9" },
		{ "help", "Show shortcuts cheatsheet" },
	},
	winbar_mouse = {
		{ "LeftClick Pill", "Switch to clicked Agent chat & mark read", "focus_chat" },
		{ "MiddleClick Pill", "Safely close clicked Agent conversation", "focus_chat" },
		{ "RightClick Pill", "Open floating Agent Switcher menu", "switcher" },
		{ "LeftClick ‹+N / +M›", "Jump to highest-priority off-screen chat", "jump_attention" },
		{ "LeftClick [+]", "Start smart new conversation", "new_chat" },
		{ "Click [Folder·Branch]", "Left: chat in Project · Right: add Project", "new_project_chat" },
		{ "LeftClick [WS / Code]", "Toggle AI Workspace tab / code tab", "toggle_workspace" },
		{ "LeftClick [i/N ▾]", "Open floating Agent Switcher menu", "switcher" },
	},
	commands = {
		{ "CodeCompanionWorkspace", "Toggle AI Workspace tab (or add [dir])" },
		{ "CodeCompanionWorkspaceAddProject", "Add a Project directory to AI Workspace" },
		{ "CodeCompanionWorkspaceWorktree", "Create Git Worktree & start Agent chat" },
		{ "CodeCompanionWorkspaceKeys", "Search, run & live-rebind Workspace keymaps" },
		{ "CodeCompanionNotificationsToggle", "Toggle background AI completion toasts" },
	},
	sig_patterns = {
		{ "show_keys", "show_keys" },
		{ "CodeCompanionWorkspaceKeys", "show_keys" },
		{ "send_visual_selection", "send_selection" },
		{ "add_visual_to_chat", "add_visual_to_chat" },
		{ "prompt_new_project_chat", "new_project_chat" },
		{ "prompt_add_project", "add_project" },
		{ "CodeCompanionWorkspaceAddProject", "add_project" },
		{ "jump_to_attention", "jump_attention" },
		{ "create_worktree_chat", "new_worktree_chat" },
		{ "prompt_create_worktree_chat", "new_worktree_chat" },
		{ "CodeCompanionWorkspaceWorktree", "new_worktree_chat" },
		{ "select_adapter_or_model", "select_model" },
		{ "patch_history_ui", "history" },
		{ "new_smart_chat", "new_chat" },
	},
}

return M
