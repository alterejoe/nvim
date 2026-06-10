-- /home/jmeyer/.config/nvim/lua/csvgen.lua FINAL
-- csvgen.lua — Election Data CSV Generator
--
-- Drop into ~/.config/nvim/lua/csvgen.lua and add to your init.lua:
--
--     require("csvgen").setup()
--
-- All existing keymaps (<leader>sc, sg, sn, sm, sd, sx, sa, sp, sb, sv, se, ec)
-- are registered by setup() with identical behavior.
--
-- To add your own generators, see the "PUBLIC REGISTRATION API" section and the
-- usage examples at the bottom of this file.

local M = {}

M.config = {
	prefix = "<leader>s", -- default prefix for registered keys
}

-- =========================================================================
-- UTILITIES (exposed as M.util so custom generators can reuse them)
-- =========================================================================

local U = {}
M.util = U

--- Exit visual mode so that '< and '> marks are set.
function U.exit_visual()
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
end

--- Get the lines covered by the last visual selection.
--- Must be called AFTER exit_visual().
--- @return buf, start_line, end_line, lines  (start/end are 1-indexed)
function U.get_visual_lines()
	local start_line = vim.fn.line("'<")
	local end_line = vim.fn.line("'>")
	local buf = vim.api.nvim_get_current_buf()
	local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
	return buf, start_line, end_line, lines
end

--- Insert lines after a given 1-indexed line number.
function U.insert_after(buf, line_nr, lines)
	vim.api.nvim_buf_set_lines(buf, line_nr, line_nr, false, lines)
end

--- Trim leading/trailing whitespace.
function U.trim(s)
	return s:gsub("^%s+", ""):gsub("%s+$", "")
end

--- Expand a single range token into a list of numbers.
--- Supports: "5", "5-10", "5-10e" (even only), "5-10o" (odd only).
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

--- Expand a comma-separated list of range tokens: "1-3,7,10-14e" -> {1,2,3,7,10,12,14}
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

--- Parse a cartesian segment "LEFT(RIGHT)" into two id lists.
--- Returns nil if the segment doesn't match.
function U.parse_cartesian_segment(segment)
	local left_part, right_part = segment:match("^([^%(]+)%(([^%)]+)%)$")
	if not (left_part and right_part) then
		return nil
	end
	return U.expand_id_list(left_part), U.expand_id_list(right_part)
end

--- Split a comma-separated splits string, PRESERVING empty fields.
--- "REP,DEM" -> {"REP","DEM"}   "REP,,IND" -> {"REP","","IND"}
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

--- Iterate non-empty, non-comment lines, yielding each whitespace-separated segment.
--- callback(segment) is called for every segment.
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

-- =========================================================================
-- INTERNAL: keymap helper
-- =========================================================================

M.registered = {} -- { [lhs] = { desc = ..., modes = {...} } }  for introspection

local function resolve_lhs(spec)
	-- spec.lhs overrides everything; otherwise prefix .. key
	return spec.lhs or (M.config.prefix .. spec.key)
end

local function map(mode, lhs, fn, desc)
	vim.keymap.set(mode, lhs, fn, {
		desc = desc,
		noremap = true,
		silent = true,
	})
	M.registered[lhs] = M.registered[lhs] or { desc = desc, modes = {} }
	table.insert(M.registered[lhs].modes, mode)
end

--- Build the output formatter from a spec.
--- spec.format may be:
---   - nil               -> "%d,%d"
---   - a string          -> passed to string.format with (left_id, right_id)
---   - a function(a, b)  -> returns the output line
local function make_formatter(spec)
	local fmt = spec.format
	if fmt == nil then
		fmt = "%d,%d"
	end
	if type(fmt) == "string" then
		local f = fmt
		return function(a, b)
			return string.format(f, a, b)
		end
	end
	return fmt
end

-- =========================================================================
-- PUBLIC REGISTRATION API
-- =========================================================================

--- 1) CARTESIAN MAPPING (visual mode, line-based)
--- Select lines of "LEFT(RIGHT)" segments; output is inserted after selection.
--- This is the pattern behind <leader>sm, sd, sx, sa.
---
--- spec = {
---   key    = "m",                       -- becomes <prefix>m  (or set spec.lhs for a full override)
---   desc   = "Generate ...",
---   header = { "", "#FormatVersion 1", "#Left,Right" },  -- emitted verbatim before the rows
---   format = "%d,%d",                   -- or "%d,%d,None", or function(a,b) -> string
--- }
function M.register_mapping(spec)
	local formatter = make_formatter(spec)
	local lhs = resolve_lhs(spec)

	map("v", lhs, function()
		U.exit_visual()
		local buf, _, end_line, lines = U.get_visual_lines()

		local output = {}
		for _, h in ipairs(spec.header or {}) do
			table.insert(output, h)
		end

		U.for_each_segment(lines, function(segment)
			local left_ids, right_ids = U.parse_cartesian_segment(segment)
			if left_ids and right_ids then
				for _, a in ipairs(left_ids) do
					for _, b in ipairs(right_ids) do
						table.insert(output, formatter(a, b))
					end
				end
			end
		end)

		U.insert_after(buf, end_line, output)
	end, spec.desc)
end

--- 2) PATTERN GENERATOR (normal + visual, pattern-string based)
--- Normal mode reads the current line; visual mode yanks the exact selection.
--- Output is appended after the line/selection and a row count is printed.
--- This is the pattern behind <leader>sb and <leader>sv.
---
--- spec = {
---   key    = "b",
---   desc   = "Generate ...",
---   header = { "#FormatVersion 1", "#Left,Right" },
---   format = "%d,%d",                   -- or function(a,b) -> string
---   label  = "ballot/precinct",         -- used in the printed count message
--- }
function M.register_pattern_generator(spec)
	local formatter = make_formatter(spec)
	local lhs = resolve_lhs(spec)
	local label = spec.label or "generated"

	local function generate(pattern)
		local lines = {}
		for _, h in ipairs(spec.header or {}) do
			table.insert(lines, h)
		end
		local count = 0
		for group in pattern:gmatch("%S+") do
			local left_ids, right_ids = U.parse_cartesian_segment(group)
			if left_ids and right_ids then
				for _, a in ipairs(left_ids) do
					for _, b in ipairs(right_ids) do
						table.insert(lines, formatter(a, b))
						count = count + 1
					end
				end
			end
		end
		return lines, count
	end

	map("n", lhs, function()
		local pattern = vim.fn.getline(".")
		local csv_lines, count = generate(pattern)
		vim.fn.append(vim.fn.line("."), csv_lines)
		print("Generated " .. count .. " " .. label .. " rows - Inserted into buffer")
	end, spec.desc .. " from pattern")

	map("v", lhs, function()
		vim.cmd('normal! "vy')
		local pattern = vim.fn.getreg("v")
		local csv_lines, count = generate(pattern)
		local end_line = vim.fn.line("'>")
		vim.fn.append(end_line, csv_lines)
		print("Generated " .. count .. " " .. label .. " rows - Inserted into buffer")
	end, spec.desc .. " from selected pattern")
end

--- 3) LINE TRANSFORM (rewrites lines in place)
--- spec = {
---   key   = "e",          -- or spec.lhs for a full override
---   desc  = "...",
---   mode  = "n" | "v",    -- "n" transforms the whole buffer, "v" the selection
---   fn    = function(lines) -> lines   -- pure transform over a list of lines
--- }
function M.register_transform(spec)
	local lhs = resolve_lhs(spec)

	if spec.mode == "n" then
		map("n", lhs, function()
			local buf = vim.api.nvim_get_current_buf()
			local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			lines = spec.fn(lines)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		end, spec.desc)
	else
		map("v", lhs, function()
			local start_line = vim.fn.line("'<") - 1
			local end_line = vim.fn.line("'>")
			local buf = vim.api.nvim_get_current_buf()
			local lines = vim.api.nvim_buf_get_lines(buf, start_line, end_line, false)
			lines = spec.fn(lines)
			vim.api.nvim_buf_set_lines(buf, start_line, end_line, false, lines)
		end, spec.desc)
	end
end

--- 4) FULLY CUSTOM
--- spec = { key (or lhs), desc, mode = "n"|"v"|{"n","v"}, fn = function() ... }
--- Use M.util helpers inside fn.
function M.register_custom(spec)
	local lhs = resolve_lhs(spec)
	local modes = type(spec.mode) == "table" and spec.mode or { spec.mode }
	for _, mode in ipairs(modes) do
		map(mode, lhs, spec.fn, spec.desc)
	end
end

-- =========================================================================
-- BOOLEAN MATCH EXPRESSION PARSER
-- =========================================================================
--
-- Supports:  word, word|word, word&word, [group]
-- Precedence: & binds tighter than |, [...] overrides.
-- Matching is case-insensitive substring.

--- Parse a bool expression string into a tree.
--- Returns { op = "word"|"or"|"and", ... } or nil.
local function parse_bool_expr(str)
	local pos = 1
	local len = #str

	local function skip_ws()
		while pos <= len and str:sub(pos, pos):match("%s") do
			pos = pos + 1
		end
	end

	local function parse_word()
		local start = pos
		while pos <= len and not str:sub(pos, pos):match("[|&%[%]%s]") do
			pos = pos + 1
		end
		return str:sub(start, pos - 1)
	end

	local function parse_term()
		skip_ws()
		if pos > len then
			return nil
		end
		if str:sub(pos, pos) == "[" then
			pos = pos + 1 -- skip [
			local node = parse_or()
			skip_ws()
			if pos <= len and str:sub(pos, pos) == "]" then
				pos = pos + 1 -- skip ]
			end
			return node
		end
		local word = parse_word()
		if word == "" then
			return nil
		end
		return { op = "word", value = word }
	end

	local function parse_and()
		local left = parse_term()
		if not left then
			return nil
		end
		skip_ws()
		while pos <= len and str:sub(pos, pos) == "&" do
			pos = pos + 1 -- skip &
			local right = parse_term()
			if not right then
				break
			end
			left = { op = "and", children = { left, right } }
			skip_ws()
		end
		return left
	end

	local function parse_or()
		local left = parse_and()
		if not left then
			return nil
		end
		skip_ws()
		while pos <= len and str:sub(pos, pos) == "|" do
			pos = pos + 1 -- skip |
			local right = parse_and()
			if not right then
				break
			end
			left = { op = "or", children = { left, right } }
			skip_ws()
		end
		return left
	end

	return parse_or()
end

--- Evaluate a bool expression tree against a value (case-insensitive substring).
local function eval_bool_expr(node, value)
	if not node then
		return false
	end
	local v = value:lower()
	if node.op == "word" then
		return v:find(node.value:lower(), 1, true) ~= nil
	elseif node.op == "or" then
		for _, child in ipairs(node.children) do
			if eval_bool_expr(child, value) then
				return true
			end
		end
		return false
	elseif node.op == "and" then
		for _, child in ipairs(node.children) do
			if not eval_bool_expr(child, value) then
				return false
			end
		end
		return true
	end
	return false
end

--- Parse CSV fields from a line, respecting quoted values.
local function parse_csv_fields(line)
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

-- =========================================================================
-- ASSOCIATION GENERATOR (name-match based)
-- =========================================================================

--- Register an association generator keybind.
---
--- Normal mode: cursor on pattern line. Pattern is `srcId(matchExpr) ...`
--- Lines below the pattern line are scanned as target data (skipping
--- #-comments and blanks). Output is appended at end-of-buffer.
---
--- spec = {
---   key       = "D",
---   desc      = "...",
---   match_col = 3,     -- 1-indexed column in target rows to match against
---   id_col    = 1,     -- 1-indexed column for the target row's own ID
---   output_header = { "", "#FormatVersion 1", "#SrcExternalId,DstExternalId" },
---   output_format = "%d,%d",
--- }
function M.register_association_generator(spec)
	local lhs = resolve_lhs(spec)

	map("n", lhs, function()
		local buf = vim.api.nvim_get_current_buf()
		local cur_line = vim.fn.line(".")
		local last_line = vim.api.nvim_buf_line_count(buf)

		-- Read pattern from current line (normalize commas to spaces)
		local pattern_text = vim.fn.getline("."):gsub(",", " "):gsub("^%s+", ""):gsub("%s+$", "")
		if pattern_text == "" then
			return
		end

		-- Scan lines below for target data (starting from current line,
		-- since the pattern line may be the last non-comment line before data)
		local targets = {}
		for l = cur_line, last_line do
			local raw = vim.api.nvim_buf_get_lines(buf, l, l + 1, false)[1]
			local trimmed = U.trim(raw)
			if trimmed ~= "" and not trimmed:match("^#") then
				local fields = parse_csv_fields(trimmed)
				local id = tonumber((U.trim(fields[spec.id_col])))
				local match_val = (fields[spec.match_col] or ""):gsub('"', "")
				if id then
					table.insert(targets, { id = id, value = match_val })
				end
			end
		end

		-- Generate output
		local output = {}
		for _, h in ipairs(spec.output_header or {}) do
			table.insert(output, h)
		end

		local count = 0
		for token in pattern_text:gmatch("%S+") do
			local src_id, expr_str = token:match("^(%d+)%((.+)%)$")
			if src_id and expr_str then
				src_id = tonumber(src_id)
				local expr = parse_bool_expr(expr_str)
				if expr then
					for _, t in ipairs(targets) do
						if eval_bool_expr(expr, t.value) then
							table.insert(output, string.format(spec.output_format, src_id, t.id))
							count = count + 1
						end
					end
				end
			end
		end

		U.insert_after(buf, last_line, output)
		print(string.format("Generated %d association rows", count))
	end, spec.desc)
end

--- List all registered keymaps (for a quick :lua require("csvgen").list())
function M.list()
	local keys = {}
	for lhs in pairs(M.registered) do
		table.insert(keys, lhs)
	end
	table.sort(keys)
	for _, lhs in ipairs(keys) do
		local r = M.registered[lhs]
		print(string.format("%-14s [%s]  %s", lhs, table.concat(r.modes, ","), r.desc))
	end
end

-- =========================================================================
-- BUILT-IN GENERATORS (identical behavior to the original keymaps)
-- =========================================================================

local function register_builtins()
	-- ---------------------------------------------------------------
	-- <leader>sc — Generate contest choices from "contestId(numChoices)"
	-- ---------------------------------------------------------------
	M.register_custom({
		key = "c",
		mode = "v",
		desc = "Generate contest choices from pattern",
		fn = function()
			U.exit_visual()
			local buf, _, end_line, lines = U.get_visual_lines()

			local output = {
				"",
				"#FormatVersion 3",
				"#ExternalChoiceId,ExternalContestId,Name,ShortName,IsDisabled,SequenceNumber,SecondName",
			}

			local choice_id = 1

			U.for_each_segment(lines, function(segment)
				local contest_id, num_choices = segment:match("^(%d+)%((%d+)%)$")
				if contest_id and num_choices then
					contest_id = tonumber(contest_id)
					num_choices = tonumber(num_choices)
					for seq = 1, num_choices do
						table.insert(output, string.format('%d,%d,"",,False,%d,', choice_id, contest_id, seq))
						choice_id = choice_id + 1
					end
				end
			end)

			U.insert_after(buf, end_line, output)
		end,
	})

	-- ---------------------------------------------------------------
	-- <leader>sg — Generate contest template "N()" from ranges
	-- ---------------------------------------------------------------
	M.register_custom({
		key = "g",
		mode = "v",
		desc = "Generate contest template from ranges",
		fn = function()
			U.exit_visual()
			local buf, _, end_line, lines = U.get_visual_lines()

			local output = {}

			for _, line in ipairs(lines) do
				local l = U.trim(line)
				if l ~= "" and not l:match("^#") then
					for _, id in ipairs(U.expand_id_list(l)) do
						table.insert(output, string.format("%d()", id))
					end
				end
			end

			U.insert_after(buf, end_line, output)
		end,
	})

	-- ---------------------------------------------------------------
	-- <leader>sn — Generate ShortName from Name (CSV field 4 from field 3)
	-- ---------------------------------------------------------------
	M.register_custom({
		key = "n",
		mode = "v",
		desc = "Generate ShortName from Name (uppercase letters and spaces)",
		fn = function()
			U.exit_visual()
			local buf, start_line, end_line, lines = U.get_visual_lines()

			for i, line in ipairs(lines) do
				if not line:match("^#") and line:match(",") then
					-- Split by comma, respecting quoted values
					local fields = {}
					local in_quotes = false
					local current_field = ""

					for j = 1, #line do
						local char = line:sub(j, j)
						if char == '"' then
							in_quotes = not in_quotes
							current_field = current_field .. char
						elseif char == "," and not in_quotes then
							table.insert(fields, current_field)
							current_field = ""
						else
							current_field = current_field .. char
						end
					end
					table.insert(fields, current_field)

					if #fields >= 3 then
						local name = fields[3]:gsub('"', "")
						local short_name = name:upper():gsub("[^A-Z ]", "")
						if #fields >= 4 then
							fields[4] = short_name
						end
						lines[i] = table.concat(fields, ",")
					end
				end
			end

			vim.api.nvim_buf_set_lines(buf, start_line - 1, end_line, false, lines)
		end,
	})

	-- ---------------------------------------------------------------
	-- <leader>sm — Contest → Precinct Split (BallotPosition=None)
	-- ---------------------------------------------------------------
	M.register_mapping({
		key = "m",
		desc = "Generate contest to precinct split mappings with BallotPosition=None",
		header = {
			"",
			"#ContestExternalId,PrecinctSplitExternalId,BallotPosition",
		},
		format = "%d,%d,None",
	})

	-- ---------------------------------------------------------------
	-- <leader>sd — Contest → District
	-- ---------------------------------------------------------------
	M.register_mapping({
		key = "d",
		desc = "Generate contest to district mappings",
		header = {
			"",
			"#FormatVersion 1",
			"#ContestExternalId,DistrictExternalId",
		},
	})

	-- ---------------------------------------------------------------
	-- <leader>sx — District → Precinct Split
	-- ---------------------------------------------------------------
	M.register_mapping({
		key = "x",
		desc = "Generate district to precinct split mappings",
		header = {
			"",
			"#FormatVersion 1",
			"#DistrictExternalId,PrecinctSplitExternalId",
		},
	})

	-- ---------------------------------------------------------------
	-- <leader>sa — Poll Place → Precinct Split
	-- ---------------------------------------------------------------
	M.register_mapping({
		key = "a",
		desc = "Generate associations from selected lines",
		header = {
			"",
			"#FormatVersion 1",
			"#PollPlaceExternalId,PrecinctSplitExternalId",
		},
	})

	-- ---------------------------------------------------------------
	-- <leader>sp — Precinct CSV generator (letter groups / numeric / !literal)
	-- ---------------------------------------------------------------
	local function parse_letter_group(group)
		local letter = group:match("^([a-zA-Z])")
		local rest = group:sub(2)
		local splits_str = rest:match("%((.-)%)$")
		local splits = U.parse_splits(splits_str)
		local ranges_part = rest:match("^(.-)%([^%)]+%)$")
		local numbers = {}
		for range_str in ranges_part:gmatch("[^,]+") do
			local token = range_str:match("^%s*(.-)%s*$")
			for _, num in ipairs(U.parse_range(token)) do
				table.insert(numbers, num)
			end
		end
		return letter:upper(), numbers, splits
	end

	local function parse_numeric_group(group)
		local splits_str = group:match("%((.-)%)$")
		local splits = U.parse_splits(splits_str)
		local precinct = group:match("^(.-)%(")
		precinct = precinct:match("^%s*(.-)%s*$")
		return precinct, splits
	end

	local function generate_precinct_lines(pattern)
		local lines = { "#Id,PrecinctName,Name,SequenceNumber" }
		local id = 1
		local seq = 1
		for group in pattern:gmatch("%S+") do
			if group:sub(1, 1) == "!" then
				local raw = group:sub(2)
				local precinct = raw:match("^(.-)%(") or raw
				local splits_str = raw:match("%((.-)%)")
				local splits = splits_str and U.parse_splits(splits_str) or { precinct }
				for _, split in ipairs(splits) do
					table.insert(lines, string.format('%d,"%s","%s",%d', id, precinct, split, seq))
					id = id + 1
					seq = seq + 1
				end
			elseif group:sub(1, 1):match("%d") then
				local precinct, splits = parse_numeric_group(group)
				for _, split in ipairs(splits) do
					table.insert(lines, string.format('%d,"%s","%s",%d', id, precinct, split, seq))
					id = id + 1
					seq = seq + 1
				end
			else
				local letter, numbers, splits = parse_letter_group(group)
				for _, num in ipairs(numbers) do
					local precinct = letter .. num
					for _, split in ipairs(splits) do
						table.insert(lines, string.format('%d,"%s","%s",%d', id, precinct, split, seq))
						id = id + 1
						seq = seq + 1
					end
				end
			end
		end
		return lines, id - 1
	end

	M.register_custom({
		key = "p",
		mode = "n",
		desc = "Generate CSV from pattern",
		fn = function()
			local pattern = vim.fn.getline(".")
			local csv_lines, count = generate_precinct_lines(pattern)
			vim.fn.append(vim.fn.line("."), csv_lines)
			print("Generated " .. count .. " rows - Inserted into buffer")
		end,
	})

	M.register_custom({
		key = "p",
		mode = "v",
		desc = "Generate CSV from selected pattern",
		fn = function()
			vim.cmd('normal! "vy')
			local pattern = vim.fn.getreg("v")
			local csv_lines, count = generate_precinct_lines(pattern)
			local end_line = vim.fn.line("'>")
			vim.fn.append(end_line, csv_lines)
			print("Generated " .. count .. " rows - Inserted into buffer")
		end,
	})

	-- ---------------------------------------------------------------
	-- <leader>sb — Ballot → Precinct Split (normal + visual, prints count)
	-- ---------------------------------------------------------------
	M.register_pattern_generator({
		key = "b",
		desc = "Generate Ballot/Precinct Split CSV",
		header = {
			"#FormatVersion 1",
			"#BallotTextExternalId,PrecinctSplitExternalId",
		},
		label = "ballot/precinct",
	})

	-- ---------------------------------------------------------------
	-- <leader>sv — Ballot → District (normal + visual, prints count)
	-- ---------------------------------------------------------------
	M.register_pattern_generator({
		key = "v",
		desc = "Generate Ballot/District CSV",
		header = {
			"#FormatVersion 1",
			"#BallotTextExternalId,DistrictExternalId",
		},
		label = "ballot/district",
	})

	-- ---------------------------------------------------------------
	-- <leader>se — Excel paste → CSV (whole buffer)
	-- ---------------------------------------------------------------
	local function excel_lines_to_csv(lines)
		for i, line in ipairs(lines) do
			local l = line:gsub("\r", "")
			l = l:gsub("\t", ",")
			lines[i] = l
		end
		return lines
	end

	M.register_transform({
		key = "e",
		mode = "n",
		desc = "Convert Excel paste to CSV",
		fn = excel_lines_to_csv,
	})

	-- ---------------------------------------------------------------
	-- <leader>ec — Excel paste → CSV (visual selection)
	-- NOTE: kept on its original lhs, outside the prefix.
	-- ---------------------------------------------------------------
	M.register_transform({
		lhs = "<leader>ec",
		mode = "v",
		desc = "Convert selected Excel lines to CSV",
		fn = excel_lines_to_csv,
	})

	-- ---------------------------------------------------------------
	-- <leader>sk — Show all registered csvgen keybinds
	-- ---------------------------------------------------------------
	M.register_custom({
		key = "k",
		mode = "n",
		desc = "Show csvgen keybinds",
		fn = M.list,
	})

	-- ---------------------------------------------------------------
	-- <leader>sD — District → PrecinctSplit by name match
	-- ---------------------------------------------------------------
	M.register_association_generator({
		key = "D",
		desc = "Associate districts to precinct splits by name match",
		match_col = 3,
		id_col = 1,
		output_header = {
			"",
			"#FormatVersion 1",
			"#DistrictExternalId,PrecinctSplitExternalId",
		},
		output_format = "%d,%d",
	})

	-- ---------------------------------------------------------------
	-- <leader>sP — Contest → PrecinctSplit by name match
	-- ---------------------------------------------------------------
	M.register_association_generator({
		key = "P",
		desc = "Associate contests to precinct splits by name match",
		match_col = 3,
		id_col = 1,
		output_header = {
			"",
			"#FormatVersion 2",
			"#ContestExternalId,PrecinctSplitExternalId,BallotPosition",
		},
		output_format = "%d,%d,None",
	})

	-- ---------------------------------------------------------------
	-- <leader>sC — Contest → District by name match
	-- ---------------------------------------------------------------
	M.register_association_generator({
		key = "C",
		desc = "Associate contests to districts by name match",
		match_col = 3,
		id_col = 1,
		output_header = {
			"",
			"#FormatVersion 1",
			"#ContestExternalId,DistrictExternalId",
		},
		output_format = "%d,%d",
	})

	-- ---------------------------------------------------------------
	-- <leader>sL — PollingPlace → PrecinctSplit by name match
	-- ---------------------------------------------------------------
	M.register_association_generator({
		key = "L",
		desc = "Associate polling places to precinct splits by name match",
		match_col = 3,
		id_col = 1,
		output_header = {
			"",
			"#FormatVersion 1",
			"#PollPlaceExternalId,PrecinctSplitExternalId",
		},
		output_format = "%d,%d",
	})
end

-- =========================================================================
-- SETUP
-- =========================================================================

function M.setup(opts)
	opts = opts or {}
	if opts.prefix then
		M.config.prefix = opts.prefix
	end
	register_builtins()

	-- Register any user-supplied generators passed straight into setup()
	for _, spec in ipairs(opts.mappings or {}) do
		M.register_mapping(spec)
	end
	for _, spec in ipairs(opts.pattern_generators or {}) do
		M.register_pattern_generator(spec)
	end
	for _, spec in ipairs(opts.transforms or {}) do
		M.register_transform(spec)
	end
	for _, spec in ipairs(opts.custom or {}) do
		M.register_custom(spec)
	end

	return M
end

return M

-- =========================================================================
-- USAGE EXAMPLES (copy into your init.lua)
-- =========================================================================
--
-- Basic setup (all original keymaps, unchanged):
--
--     require("csvgen").setup()
--
-- Add a new cartesian mapping inline (e.g. BallotType → Contest on <leader>st):
--
--     require("csvgen").setup({
--         mappings = {
--             {
--                 key = "t",
--                 desc = "Generate ballot type to contest mappings",
--                 header = {
--                     "",
--                     "#FormatVersion 1",
--                     "#BallotTypeExternalId,ContestExternalId",
--                 },
--                 -- format defaults to "%d,%d"; use a string or function(a,b) to customize
--             },
--         },
--     })
--
-- Or register later, anywhere after setup():
--
--     local csvgen = require("csvgen")
--
--     csvgen.register_mapping({
--         key = "t",
--         desc = "Generate ballot type to contest mappings",
--         header = { "", "#FormatVersion 1", "#BallotTypeExternalId,ContestExternalId" },
--     })
--
--     csvgen.register_pattern_generator({
--         key = "q",
--         desc = "Generate Header/Thing CSV",
--         header = { "#FormatVersion 1", "#HeaderId,ThingId" },
--         label = "header/thing",
--     })
--
--     csvgen.register_transform({
--         key = "u",
--         mode = "v",
--         desc = "Uppercase selected lines",
--         fn = function(lines)
--             for i, l in ipairs(lines) do lines[i] = l:upper() end
--             return lines
--         end,
--     })
--
--     csvgen.register_custom({
--         key = "z",
--         mode = "v",
--         desc = "My custom generator",
--         fn = function()
--             local U = csvgen.util
--             U.exit_visual()
--             local buf, _, end_line, lines = U.get_visual_lines()
--             local output = { "", "#MyHeader" }
--             U.for_each_segment(lines, function(segment)
--                 local left, right = U.parse_cartesian_segment(segment)
--                 if left and right then
--                     -- do whatever
--                 end
--             end)
--             U.insert_after(buf, end_line, output)
--         end,
--     })
--
-- List everything that's registered:
--
--     :lua require("csvgen").list()
