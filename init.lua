function SourceConfig()
	local cwd = vim.fn.getcwd()
	local config = cwd .. "/config.lua"
	if vim.fn.filereadable(config) == 1 then
		vim.cmd("source " .. config)
	end
end

require("filetypes")
require("lazycfg")
require("settings")
require("keymaps")
