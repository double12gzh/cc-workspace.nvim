local ws = require("cc_workspace")

---@class CodeCompanion.Extension
---@field setup fun(opts?: CcWorkspaceConfig)
---@field exports table

---@type CodeCompanion.Extension
local Extension = {
	---@param opts? CcWorkspaceConfig
	setup = function(opts)
		ws.setup(opts)
	end,
	exports = ws,
}

return Extension
