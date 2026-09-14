-- /home/altjoe/.config/nvim/lua/opencode-manage/json.lua FINAL
-- opencode-manage.json — the shared pretty JSON writer.
-- The registry consolidation's extraction target: pretty_json was duplicated
-- in registry.lua and skills.lua; folders.lua consumes this single helper,
-- and the other two migrate when that registry entry merges (their local
-- copies stay until then). Hand-reviewed artifacts are rewritten 2-space
-- with sorted keys; callers write with
--   vim.fn.writefile(vim.split(json.pretty(data), "\n", { plain = true }), file)

local M = {}

--- Pretty JSON, 2-space indent, sorted object keys.
--- @param val any
--- @param indent number|nil
--- @return string
function M.pretty(val, indent)
	indent = indent or 0
	local pad = string.rep("  ", indent)
	if type(val) == "table" then
		if vim.islist(val) then
			local parts = {}
			for _, v in ipairs(val) do
				parts[#parts + 1] = pad .. "  " .. M.pretty(v, indent + 1)
			end
			if #parts == 0 then
				return "[]"
			end
			return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
		end
		local keys = {}
		for k in pairs(val) do
			keys[#keys + 1] = k
		end
		table.sort(keys)
		local parts = {}
		for _, k in ipairs(keys) do
			parts[#parts + 1] = string.format("%s  %q: %s", pad, k, M.pretty(val[k], indent + 1))
		end
		if #parts == 0 then
			return "{}"
		end
		return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
	end
	if type(val) == "string" then
		return string.format("%q", val)
	end
	return tostring(val)
end

return M
