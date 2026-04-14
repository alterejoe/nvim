local M = {}

---@param languages table
function M.setup(languages)
	-- collect grammar names declared in yaml
	local grammars = {}
	for _, config in pairs(languages) do
		if config.treesitter then
			-- treesitter can be a single string or a list
			if type(config.treesitter) == "table" then
				vim.list_extend(grammars, config.treesitter)
			else
				table.insert(grammars, config.treesitter)
			end
		end
	end

	require("nvim-treesitter").setup({
		install_dir = vim.fn.stdpath("data") .. "/site",
	})

	-- auto-start treesitter on every FileType event
	vim.api.nvim_create_autocmd("FileType", {
		callback = function()
			pcall(vim.treesitter.start)
		end,
	})
end

--- Return the flat list of grammar names for external use (e.g. TSInstall checks).
---@param languages table
---@return string[]
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
