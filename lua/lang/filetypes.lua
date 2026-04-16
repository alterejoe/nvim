local M = {}

---@param languages table
function M.setup(languages)
	if not languages or type(languages) ~= "table" then
		vim.notify("filetypes.setup: invalid languages argument, got " .. type(languages), vim.log.levels.ERROR)
		return
	end

	for lang_name, config in pairs(languages) do
		if type(config) ~= "table" then
			goto continue
		end

		local fr = config.extras and config.extras.filetype_register
		if fr then
			vim.filetype.add({ extension = { [fr.extension] = fr.name } })
		end

		::continue::
	end
end

return M
