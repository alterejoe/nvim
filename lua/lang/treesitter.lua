-- /home/jmeyer/.config/nvim/lua/lang/treesitter.lua FINAL
local M = {}

function M.setup(languages)
	vim.api.nvim_create_autocmd("FileType", {
		callback = function()
			pcall(vim.treesitter.start)
		end,
	})
end

function M.collect_grammars(languages)
	local grammars = {}
	for _, config in pairs(languages) do
		if config.treesitter then
			if type(config.treesitter) == "table" then
				vim.list_extend(grammars, config.treesitter)
			else
				table.insert(grammars, config.treesitter)
			end
		end
	end
	return grammars
end

return M
