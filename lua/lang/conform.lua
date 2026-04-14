local M = {}

-- filetypes where LSP formatting should run last (after conform formatters)
local LSP_FORMAT_FTS = {
	go = "last",
}

local function collect_formatters(languages)
	local formatters_by_ft = {}
	for name, config in pairs(languages) do
		if not config.formatter then
			goto continue
		end
		-- derive the primary filetype: prefer lsp.filetypes[1], fall back to lang key
		local ft = (config.lsp and config.lsp.filetypes and config.lsp.filetypes[1]) or name
		if type(config.formatter) == "table" then
			formatters_by_ft[ft] = config.formatter
		else
			formatters_by_ft[ft] = { config.formatter }
		end
		::continue::
	end
	return formatters_by_ft
end

---@param languages table
function M.setup(languages)
	require("conform").setup({
		formatters_by_ft = collect_formatters(languages),
		format_on_save = function(bufnr)
			if vim.b[bufnr].disable_autoformat then
				return
			end
			local ft = vim.bo[bufnr].filetype
			return {
				timeout_ms = 2000,
				lsp_format = LSP_FORMAT_FTS[ft] or "never",
			}
		end,
		log_level = vim.log.levels.ERROR,
		notify_on_error = true,
		notify_no_formatters = true,
	})
end

return M
