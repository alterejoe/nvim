-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
	local lazyrepo = "https://github.com/folke/lazy.nvim.git"
	local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
	if vim.v.shell_error ~= 0 then
		vim.api.nvim_echo({
			{ "Warning: failed to clone lazy.nvim:\n", "WarningMsg" },
			{ out, "WarningMsg" },
			{ "\nContinuing without plugins...\n", "WarningMsg" },
		}, true, {})
		return
	end
end
vim.opt.rtp:prepend(lazypath)

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

local spec = {}
local plugin_dir = vim.fn.stdpath("config") .. "/lua/plugins"

local function is_valid_spec(s)
	-- a lazy plugin spec must have a non-empty string as its first element
	return type(s) == "table" and type(s[1]) == "string" and s[1] ~= ""
end

for _, file in ipairs(vim.fn.glob(plugin_dir .. "/*.lua", false, true)) do
	local name = vim.fn.fnamemodify(file, ":t:r")
	local ok, result = pcall(require, "plugins." .. name)
	if not ok then
		vim.api.nvim_echo({
			{ "Warning: plugins/" .. name .. ".lua failed to load:\n", "WarningMsg" },
			{ tostring(result) .. "\n", "WarningMsg" },
		}, true, {})
	elseif type(result) == "table" then
		local entries = (type(result[1]) == "table") and result or { result }
		for _, s in ipairs(entries) do
			if is_valid_spec(s) then
				table.insert(spec, s)
			else
				vim.api.nvim_echo({
					{ "Warning: plugins/" .. name .. ".lua: invalid spec entry skipped\n", "WarningMsg" },
					{ "  (first element must be a non-empty plugin name string)\n", "WarningMsg" },
				}, true, {})
			end
		end
	end
end
require("lazy").setup({
    spec = spec,
    rocks            = { enabled = false },
    install          = { missing = false, colorscheme = { "default" } },
    checker          = { enabled = false },
    change_detection = { enabled = false },
})
