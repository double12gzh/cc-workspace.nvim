local ws = require("cc_workspace")

---@type CodeCompanion.Extension
local Extension = {
	---@param opts? CcWorkspaceConfig
	setup = function(opts)
		ws.setup(opts)
	end,
	exports = ws,
}

return Extension
