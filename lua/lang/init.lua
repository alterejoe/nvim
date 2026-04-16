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

-- Check neovim version
local function check_nvim_version(major, minor, patch)
	local v = vim.version()
	if v.major > major then
		return true
	end
	if v.major < major then
		return false
	end
	if v.minor > minor then
		return true
	end
	if v.minor < minor then
		return false
	end
	return v.patch >= patch
end

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

function M.setup()
	-- vim.notify("DEBUG: M.setup() called", vim.log.levels.INFO)
	local langs = languages()
	-- vim.notify("DEBUG: languages() returned type=" .. type(langs) .. ", value=" .. vim.inspect(langs), vim.log.levels.INFO)
	if not langs then
		vim.notify("DEBUG: langs is nil, returning early", vim.log.levels.WARN)
		return
	end

	local has_0_12 = check_nvim_version(0, 12, 0)

	-- order matters: filetypes must be registered before LSP attaches
	require("lang.filetypes").setup(langs)
	require("lang.lsp").setup(langs)

	-- if has_0_12 then
	require("lang.treesitter").setup(langs)
	-- else
	-- 	vim.notify("lang: nvim < 0.12, treesitter setup skipped", vim.log.levels.WARN)
	-- end

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
