local M = {}

---@class CcWorkspaceChatKeymapsConfig
---@field stop? boolean|string
---@field close? boolean|table<string, string>
---@field next_chat? boolean|string
---@field previous_chat? boolean|string

---@class CcWorkspaceConfig
---@field sidebar_width? integer
---@field max_history_per_project? integer
---@field projects_file? string|nil
---@field worktrees_base_dir? string|nil
---@field notifications? boolean
---@field commands? boolean
---@field winbar? boolean|table
---@field chat_keymaps? boolean|CcWorkspaceChatKeymapsConfig
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

---Merge user configuration options into `M.options`.
---@param opts? CcWorkspaceConfig
---@return CcWorkspaceConfig
function M.setup(opts)
	if type(opts) == "table" then
		M.options = vim.tbl_deep_extend("force", M.options, opts)
	end
	return M.options
end

return M
