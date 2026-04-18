function SourceConfig()
	local cwd = vim.fn.getcwd()
	local config = cwd .. "/config.lua"
	if vim.fn.filereadable(config) == 1 then
		vim.cmd("source " .. config)
	end
end

vim.g.clipboard = {
	name = "win32yank",
	copy = { ["+"] = "clip.exe", ["*"] = "clip.exe" },
	paste = {
		["+"] = "powershell.exe -command Get-Clipboard",
		["*"] = "powershell.exe -command Get-Clipboard",
	},
}

require("settings")
require("filetypes")
require("lazycfg")
require("air")
require("keymaps")
require("clipboard").setup()
