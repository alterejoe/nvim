local M = {}

--- Collect every mason package declared across all languages (deduped).
---@param languages table
---@return string[]
function M.collect(languages)
	local seen = {}
	local packages = {}
	for _, config in pairs(languages) do
		if config.mason then
			for _, pkg in ipairs(config.mason) do
				if not seen[pkg] then
					seen[pkg] = true
					table.insert(packages, pkg)
				end
			end
		end
	end
	return packages
end

return M
