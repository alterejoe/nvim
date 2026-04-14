local M = {}

local DEFAULT_SOURCES = { "lsp", "path", "snippets", "buffer" }

--- Build the blink `sources.per_filetype` table from languages.yaml.
---
--- Each language can declare:
---
---   blink:
---     sources: [lsp, path, buffer]          # fully override defaults for this ft
---     extra_sources: [dadbod]               # prepend to defaults
---
--- If neither is set the filetype inherits the global `sources.default` list.
---
---@param languages table
---@return table<string, string[]>
function M.collect_per_filetype(languages)
	local per_ft = {}

	for name, config in pairs(languages) do
		local blink = config.blink
		if not blink then
			goto continue
		end

		-- derive the authoritative filetype for this language entry
		local ft = (config.lsp and config.lsp.filetypes and config.lsp.filetypes[1]) or name

		if blink.sources then
			-- explicit override
			per_ft[ft] = blink.sources
		elseif blink.extra_sources then
			-- prepend extras in front of defaults so they appear first in the menu
			local merged = vim.deepcopy(blink.extra_sources)
			vim.list_extend(merged, DEFAULT_SOURCES)
			per_ft[ft] = merged
		end

		::continue::
	end

	return per_ft
end

return M
