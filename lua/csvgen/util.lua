-- /home/jmeyer/.config/nvim/lua/csvgen/util.lua FINAL
-- csvgen/util.lua — Shared utility functions.

local U = {}

function U.exit_visual()
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
end

function U.get_visual_lines()
	local start_line = vim.fn.line("'<")
	local end_line = vim.fn.line("'>")
	local buf = vim.api.nvim_get_current_buf()
	local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
	return buf, start_line, end_line, lines
end

function U.insert_after(buf, line_nr, lines)
	vim.api.nvim_buf_set_lines(buf, line_nr, line_nr, false, lines)
end

-- /home/jmeyer/.config/nvim/lua/csvgen/util.lua:23 FINAL
function U.trim(s)
	if not s then
		return ""
	end
	return s:gsub("^%s+", ""):gsub("%s+$", "")
end

function U.parse_range(range_str)
	local numbers = {}
	local start_num, end_num, suffix = range_str:match("^(%d+)%-(%d+)([eo]?)$")
	if start_num and end_num then
		for i = tonumber(start_num), tonumber(end_num) do
			if suffix == "" or (suffix == "e" and i % 2 == 0) or (suffix == "o" and i % 2 == 1) then
				table.insert(numbers, i)
			end
		end
	else
		local single = range_str:match("^(%d+)$")
		if single then
			table.insert(numbers, tonumber(single))
		end
	end
	return numbers
end

function U.expand_id_list(str)
	local ids = {}
	for range in str:gmatch("[^,]+") do
		local token = U.trim(range)
		for _, n in ipairs(U.parse_range(token)) do
			table.insert(ids, n)
		end
	end
	return ids
end

function U.parse_cartesian_segment(segment)
	local left_part, right_part = segment:match("^([^%(]+)%(([^%)]+)%)$")
	if not (left_part and right_part) then
		return nil
	end
	return U.expand_id_list(left_part), U.expand_id_list(right_part)
end

function U.parse_splits(splits_str)
	local splits = {}
	splits_str = splits_str:gsub("^%((.*)%)$", "%1")
	local pos = 1
	local len = #splits_str
	while pos <= len + 1 do
		local comma = splits_str:find(",", pos, true)
		local chunk
		if comma then
			chunk = splits_str:sub(pos, comma - 1)
			pos = comma + 1
		else
			chunk = splits_str:sub(pos)
			pos = len + 2
		end
		chunk = chunk:match("^%s*(.-)%s*$")
		table.insert(splits, chunk)
	end
	return splits
end

function U.for_each_segment(lines, callback)
	for _, line in ipairs(lines) do
		local l = U.trim(line)
		if l ~= "" and not l:match("^#") then
			for segment in l:gmatch("%S+") do
				callback(segment)
			end
		end
	end
end

function U.parse_csv_fields(line)
	local fields = {}
	local in_quotes = false
	local current = ""
	for j = 1, #line do
		local char = line:sub(j, j)
		if char == '"' then
			in_quotes = not in_quotes
		elseif char == "," and not in_quotes then
			table.insert(fields, current)
			current = ""
		else
			current = current .. char
		end
	end
	table.insert(fields, current)
	return fields
end

return U
