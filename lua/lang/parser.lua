local M = {}

--- Parse a YAML file via yq and return decoded Lua table.
--- Returns nil and emits a notification on failure.
---@param path string absolute path to yaml file
---@return table|nil
function M.parse(path)
	local raw = vim.fn.system({ "yq", "-o=json", ".", path })
	if vim.v.shell_error ~= 0 then
		vim.notify("lang/parser: failed to parse " .. path, vim.log.levels.ERROR)
		return nil
	end
	local ok, result = pcall(vim.fn.json_decode, raw)
	if not ok then
		vim.notify("lang/parser: failed to decode json: " .. tostring(result), vim.log.levels.ERROR)
		return nil
	end
	return result
end

return M
