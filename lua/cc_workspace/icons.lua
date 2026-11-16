local config = require("cc_workspace.config")

local M = {}

local CATEGORIES = { "aichat", "ui", "git", "diagnostics", "misc" }

---Resolve an icon glyph for `category` and `key`, honoring `config.options.icons` overrides.
---@param category string
---@param key string
---@return string
local function resolve_glyph(category, key)
	local opts_icons = type(config.options) == "table" and config.options.icons or nil
	if type(opts_icons) == "table" then
		local cat_tbl = opts_icons[category]
		if type(cat_tbl) == "table" and type(cat_tbl[key]) == "string" then
			return cat_tbl[key]
		end
		if type(opts_icons[key]) == "string" then
			return opts_icons[key]
		end
	end
	local def_cat = config.defaults.icons[category]
	if type(def_cat) == "table" and type(def_cat[key]) == "string" then
		return def_cat[key]
	end
	return ""
end

local category_proxies = {}
local category_spaced_proxies = {}

for _, cat in ipairs(CATEGORIES) do
	category_proxies[cat] = setmetatable({}, {
		__index = function(_, key)
			return resolve_glyph(cat, key)
		end,
	})
	category_spaced_proxies[cat] = setmetatable({}, {
		__index = function(_, key)
			local g = resolve_glyph(cat, key)
			return g ~= "" and (g .. " ") or ""
		end,
	})
	M[cat] = category_proxies[cat]
end

---Get an icon category table (optionally appending a trailing space to each glyph).
---@param category "aichat"|"ui"|"git"|"diagnostics"|"misc"|string
---@param add_space? boolean
---@return table<string, string>
function M.get(category, add_space)
	if add_space then
		if not category_spaced_proxies[category] then
			category_spaced_proxies[category] = setmetatable({}, {
				__index = function(_, key)
					local g = resolve_glyph(category, key)
					return g ~= "" and (g .. " ") or ""
				end,
			})
		end
		return category_spaced_proxies[category]
	end
	if not category_proxies[category] then
		category_proxies[category] = setmetatable({}, {
			__index = function(_, key)
				return resolve_glyph(category, key)
			end,
		})
	end
	return category_proxies[category]
end

return setmetatable(M, {
	__index = function(_, key)
		local opts_icons = type(config.options) == "table" and config.options.icons or nil
		if type(opts_icons) == "table" and type(opts_icons[key]) == "string" then
			return opts_icons[key]
		end
		for _, cat in ipairs(CATEGORIES) do
			local def_cat = config.defaults.icons[cat]
			if type(def_cat) == "table" and type(def_cat[key]) == "string" then
				return resolve_glyph(cat, key)
			end
		end
		return nil
	end,
})
