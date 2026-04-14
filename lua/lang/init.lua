--- lua/lang/init.lua
--- Entry point for the language configuration system.
--- Driven entirely by languages.yaml at the root of the nvim config.
---
--- Usage (after/plugin/lang.lua):
---   require("lang").setup()
---
--- Usage from plugin specs (e.g. blink.cmp, mason):
---   require("lang").blink_per_filetype()   → table<string, string[]>
---   require("lang").mason_packages()       → string[]
---   require("lang").grammars()             → string[]

local M = {}

-- Cached parsed data so YAML is only read once per session.
local _languages = nil

local function languages()
	if _languages then
		return _languages
	end
	local path = vim.fn.stdpath("config") .. "/languages.yaml"
	local data = require("lang.parser").parse(path)
	if not data then
		return nil
	end
	_languages = data.languages
	return _languages
end

--- Run all sub-system setup functions. Call this from after/plugin/lang.lua.
function M.setup()
	local langs = languages()
	if not langs then
		return
	end

	-- order matters: filetypes must be registered before LSP attaches
	require("lang.filetypes").setup(langs)
	require("lang.lsp").setup(langs)
	require("lang.treesitter").setup(langs)
	require("lang.conform").setup(langs)
end

--- Return the blink.cmp `sources.per_filetype` table.
--- Safe to call from a lazy.nvim plugin spec opts function.
---@return table<string, string[]>
function M.blink_per_filetype()
	local langs = languages()
	if not langs then
		return {}
	end
	return require("lang.blink").collect_per_filetype(langs)
end

--- Return the flat list of mason package names across all languages (deduped).
---@return string[]
function M.mason_packages()
	local langs = languages()
	if not langs then
		return {}
	end
	return require("lang.mason").collect(langs)
end

--- Return the flat list of treesitter grammar names across all languages.
---@return string[]
function M.grammars()
	local langs = languages()
	if not langs then
		return {}
	end
	return require("lang.treesitter").collect_grammars(langs)
end

return M
