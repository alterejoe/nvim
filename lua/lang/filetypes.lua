local M = {}

---@param languages table
function M.setup(languages)
	for _, config in pairs(languages) do
		local fr = config.extras and config.extras.filetype_register
		if fr then
			vim.filetype.add({ extension = { [fr.extension] = fr.name } })
		end
	end
end

return M
