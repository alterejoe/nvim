-- Helper: extract the top-level key order from a simple YAML map file.
-- Used to preserve user order across saves of groups.yaml / tags.yaml when
-- the caller didn't supply an explicit order (e.g. groups added by picker).
--
-- Recognizes top-level YAML keys at indent 2 (under "groups:" or "tags:")
-- of the form `  name:`. Returns a list of names in file order.
--
-- This is intentionally narrow: it doesn't parse general YAML, only the
-- specific shape these files use.

local M = {}

function M.read_top_level_order(path, top_key)
	if vim.fn.filereadable(path) == 0 then
		return {}
	end
	local f = io.open(path, "r")
	if not f then
		return {}
	end
	local in_section = false
	local order = {}
	for line in f:lines() do
		if line:match("^" .. top_key .. ":%s*$") then
			in_section = true
		elseif in_section then
			-- A new top-level (no leading space, ends with colon) ends the section.
			if line:match("^[%w_%-]+:%s*$") then
				in_section = false
			else
				-- Match `  name:` (exactly two-space indent, then a key, then colon).
				local name = line:match("^  ([%w_%-%./]+):%s*$")
				if name then
					table.insert(order, name)
				end
			end
		end
	end
	f:close()
	return order
end

-- Merge an "explicit order from buffer" with the existing file's order.
-- Rule: if explicit_order is provided and non-empty, use it as-is (the
-- buffer is the source of truth). Otherwise, take existing file order
-- and append any keys in `data` that aren't in file order, alphabetically.
function M.resolve_order(explicit_order, data, existing_order)
	if explicit_order and #explicit_order > 0 then
		-- Buffer-driven save. Trust the buffer order. Append any keys in
		-- data that aren't in explicit_order (shouldn't normally happen,
		-- but guards against losing data on a parser miss).
		local seen = {}
		local result = {}
		for _, name in ipairs(explicit_order) do
			if data[name] ~= nil and not seen[name] then
				table.insert(result, name)
				seen[name] = true
			end
		end
		local extras = {}
		for name in pairs(data) do
			if not seen[name] then
				table.insert(extras, name)
			end
		end
		table.sort(extras)
		for _, name in ipairs(extras) do
			table.insert(result, name)
		end
		return result
	end

	-- Programmatic save. Use existing file order, append new names alphabetically.
	local seen = {}
	local result = {}
	for _, name in ipairs(existing_order or {}) do
		if data[name] ~= nil and not seen[name] then
			table.insert(result, name)
			seen[name] = true
		end
	end
	local extras = {}
	for name in pairs(data) do
		if not seen[name] then
			table.insert(extras, name)
		end
	end
	table.sort(extras)
	for _, name in ipairs(extras) do
		table.insert(result, name)
	end
	return result
end

return M
