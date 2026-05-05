-- browser/dashboard/httpops/parse.lua
--
-- Splits the http panel buffer into per-context sections.
-- Used by save.lua (to apply edits) and curl.lua (to fire a preview
-- request from the first section).
--
-- Each section: { ctx, path, htmx, params = { {key, val}, ... } }
-- params keeps insertion order so re-render is stable per save.
--
-- This module is the natural seam where future expansion (headers,
-- body, form data) would land. Add a new label like "headers:" to the
-- recognized labels and extend the section table; save.lua and curl.lua
-- can then read the new field without rewriting the parser.

local M = {}

function M.parse_buffer(all_lines)
	local sections, cur = {}, nil
	local in_params = false
	for _, l in ipairs(all_lines) do
		local ctx_name = l:match("^%-%-%- context: (.+) %-%-%-%s*$")
		if ctx_name then
			if cur then
				table.insert(sections, cur)
			end
			cur = { ctx = ctx_name, path = nil, htmx = nil, params = {} }
			in_params = false
		elseif cur then
			-- Indented "key: value" under params:
			local indent_key, indent_val = l:match("^%s%s+([%w%.%-_]+):%s*(.*)$")
			if in_params and indent_key then
				table.insert(cur.params, { key = indent_key, val = vim.trim(indent_val) })
			else
				local label, val = l:match("^([%w%.%-_]+):%s*(.*)")
				if label then
					local low = label:lower()
					if low == "path" then
						cur.path = vim.trim(val)
						in_params = false
					elseif low == "htmx" then
						cur.htmx = vim.trim(val) == "true"
						in_params = false
					elseif low == "params" then
						in_params = true
					else
						-- Unknown labels exit any open block. When you add
						-- new labels (headers, body, form), branch them here.
						in_params = false
					end
				end
			end
		end
	end
	if cur then
		table.insert(sections, cur)
	end
	return sections
end

return M
