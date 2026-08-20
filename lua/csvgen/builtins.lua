-- /home/jmeyer/.config/nvim/lua/csvgen/builtins.lua FINAL
-- csvgen/builtins.lua — All built-in generator registrations.

local M = {}

function M.register(parent)
	local U = parent.util
	-- /home/jmeyer/.config/nvim/lua/csvgen/builtins.lua FINAL (partial — full sY section)
	-- ---------------------------------------------------------------
	-- <leader>sY — Generate Choice→Party associations
	-- ---------------------------------------------------------------
	-- Pattern:
	--   1(5-10)      = party 1, choice IDs 5-10 (contest looked up from data)
	--   1(c28-31)    = party 1, contest IDs 28-31 (all choices in those contests)
	-- Normal mode: cursor on pattern line, data below
	-- Visual mode: select pattern lines, data below selection
	local function do_choice_party(pattern_text, data_start_line)
		-- Normalize: insert spaces between concatenated tokens
		pattern_text = pattern_text:gsub("%)%s*(%d+)", ") %1"):gsub("^%s+", ""):gsub("%s+$", "")

		local buf = vim.api.nvim_get_current_buf()
		local last_line = vim.api.nvim_buf_line_count(buf)

		-- Build contest_of / choices_in from data below
		local contest_of = {}
		local choices_in = {}
		for l = data_start_line, last_line do
			local raw = vim.api.nvim_buf_get_lines(buf, l, l + 1, false)[1]
			if raw == nil then
				break
			end
			local trimmed = U.trim(raw)
			if trimmed ~= "" and not trimmed:match("^#") then
				local fields = U.parse_csv_fields(trimmed)
				local choice_id = tonumber((U.trim(fields[1])))
				local contest_id = tonumber((U.trim(fields[2])))
				if choice_id and contest_id then
					contest_of[choice_id] = contest_id
					choices_in[contest_id] = choices_in[contest_id] or {}
					table.insert(choices_in[contest_id], choice_id)
				end
			end
		end

		local output = {
			"",
			"#FormatVersion 1",
			"#ContestExternalId,ChoiceExternalId,PartyExternalId",
		}

		local count = 0
		for token in pattern_text:gmatch("%S+") do
			-- Contest mode: 1(c28-31) — c inside parens after the number
			local party_str, contest_expr = token:match("^(%d+)%(c(.+)%)$")
			if party_str and contest_expr then
				local party_id = tonumber(party_str)
				local contest_ids = U.expand_id_list(contest_expr)
				for _, contest_id in ipairs(contest_ids) do
					local cids = choices_in[contest_id]
					if cids then
						for _, choice_id in ipairs(cids) do
							table.insert(output, string.format("%d,%d,%d", contest_id, choice_id, party_id))
							count = count + 1
						end
					end
				end
			else
				-- Choice mode: 1(5-10)
				party_str, contest_expr = token:match("^(%d+)%((.+)%)$")
				if party_str and contest_expr then
					local party_id = tonumber(party_str)
					local choice_ids = U.expand_id_list(contest_expr)
					for _, choice_id in ipairs(choice_ids) do
						local contest_id = contest_of[choice_id]
						if contest_id then
							table.insert(output, string.format("%d,%d,%d", contest_id, choice_id, party_id))
							count = count + 1
						end
					end
				end
			end
		end

		if count == 0 then
			print("No matches — check IDs exist in the data below")
			return
		end

		U.insert_after(buf, last_line, output)
		print(string.format("Generated %d choice-party association rows", count))
	end

	-- /home/jmeyer/.config/nvim/lua/csvgen/builtins.lua:464 FINAL

	-- /home/jmeyer/.config/nvim/lua/csvgen/builtins.lua:464 FINAL

	-- <leader>sDn — District → PrecinctSplit by PrecinctName match (column 2)
	parent.register_association_generator({
		key = "Dn",
		desc = "Associate districts to precinct splits by PrecinctName match",
		match_col = 2,
		id_col = 1,
		output_header = {
			"",
			"#FormatVersion 1",
			"#DistrictExternalId,PrecinctSplitExternalId",
		},
		output_format = "%d,%d",
	})

	-- <leader>sDp — District → PrecinctSplit by Name match (column 3)
	parent.register_association_generator({
		key = "Dp",
		desc = "Associate districts to precinct splits by Name match",
		match_col = 3,
		id_col = 1,
		output_header = {
			"",
			"#FormatVersion 1",
			"#DistrictExternalId,PrecinctSplitExternalId",
		},
		output_format = "%d,%d",
	})
	parent.register_custom({
		key = "Y",
		mode = "n",
		desc = "Generate choice to party associations",
		fn = function()
			local raw_line = vim.fn.getline("."):gsub(",", " ")
			if raw_line == "" then
				return
			end
			do_choice_party(raw_line, vim.fn.line("."))
		end,
	})

	parent.register_custom({
		key = "Y",
		mode = "v",
		desc = "Generate choice to party associations from selection",
		fn = function()
			U.exit_visual()
			local buf, start_line, end_line, lines = U.get_visual_lines()
			local parts = {}
			for _, line in ipairs(lines) do
				local l = U.trim(line)
				if l ~= "" and not l:match("^#") then
					table.insert(parts, l)
				end
			end
			local pattern_text = table.concat(parts, " "):gsub(",", " ")
			if pattern_text == "" then
				return
			end
			do_choice_party(pattern_text, end_line + 1)
		end,
	})

	parent.register_custom({
		key = "Y",
		mode = "n",
		desc = "Generate choice to party associations",
		fn = function()
			local raw_line = vim.fn.getline("."):gsub(",", " "):gsub("^%s+", ""):gsub("%s+$", "")
			if raw_line == "" then
				return
			end
			do_choice_party(raw_line, vim.fn.line("."))
		end,
	})

	parent.register_custom({
		key = "Y",
		mode = "v",
		desc = "Generate choice to party associations from selection",
		fn = function()
			U.exit_visual()
			local buf, start_line, end_line, lines = U.get_visual_lines()
			-- Concatenate selected lines into a single pattern string
			local parts = {}
			for _, line in ipairs(lines) do
				local l = U.trim(line)
				if l ~= "" and not l:match("^#") then
					table.insert(parts, l)
				end
			end
			local pattern_text = table.concat(parts, " "):gsub(",", " ")
			if pattern_text == "" then
				return
			end
			-- Data starts after the visual selection
			do_choice_party(pattern_text, end_line + 1)
		end,
	})
	parent.register_custom({
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

	-- <leader>sg — Contest template
	parent.register_custom({
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

	-- <leader>sn — ShortName from Name
	parent.register_custom({
		key = "n",
		mode = "v",
		desc = "Generate ShortName from Name (uppercase letters and spaces)",
		fn = function()
			U.exit_visual()
			local buf, start_line, end_line, lines = U.get_visual_lines()

			for i, line in ipairs(lines) do
				if not line:match("^#") and line:match(",") then
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

	-- <leader>sm — Contest → Precinct Split (BallotPosition=None)
	parent.register_mapping({
		key = "m",
		desc = "Generate contest to precinct split mappings with BallotPosition=None",
		header = {
			"",
			"#ContestExternalId,PrecinctSplitExternalId,BallotPosition",
		},
		format = "%d,%d,None",
	})

	-- <leader>sd — Contest → District
	parent.register_mapping({
		key = "d",
		desc = "Generate contest to district mappings",
		header = {
			"",
			"#FormatVersion 1",
			"#ContestExternalId,DistrictExternalId",
		},
	})

	-- <leader>sx — District → Precinct Split
	parent.register_mapping({
		key = "x",
		desc = "Generate district to precinct split mappings",
		header = {
			"",
			"#FormatVersion 1",
			"#DistrictExternalId,PrecinctSplitExternalId",
		},
	})

	-- <leader>sa — Poll Place → Precinct Split
	parent.register_mapping({
		key = "a",
		desc = "Generate associations from selected lines",
		header = {
			"",
			"#FormatVersion 1",
			"#PollPlaceExternalId,PrecinctSplitExternalId",
		},
	})

	-- <leader>sp — Precinct CSV generator
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

	parent.register_custom({
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

	parent.register_custom({
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

	-- <leader>sb — Ballot → Precinct Split
	parent.register_pattern_generator({
		key = "b",
		desc = "Generate Ballot/Precinct Split CSV",
		header = {
			"#FormatVersion 1",
			"#BallotTextExternalId,PrecinctSplitExternalId",
		},
		label = "ballot/precinct",
	})

	-- <leader>sv — Ballot → District
	parent.register_pattern_generator({
		key = "v",
		desc = "Generate Ballot/District CSV",
		header = {
			"#FormatVersion 1",
			"#BallotTextExternalId,DistrictExternalId",
		},
		label = "ballot/district",
	})

	-- <leader>se — Excel paste → CSV
	local function excel_lines_to_csv(lines)
		for i, line in ipairs(lines) do
			local l = line:gsub("\r", "")
			l = l:gsub("\t", ",")
			lines[i] = l
		end
		return lines
	end

	parent.register_transform({
		key = "e",
		mode = "n",
		desc = "Convert Excel paste to CSV",
		fn = excel_lines_to_csv,
	})

	-- <leader>ec — Excel paste → CSV (visual)
	parent.register_transform({
		lhs = "<leader>ec",
		mode = "v",
		desc = "Convert selected Excel lines to CSV",
		fn = excel_lines_to_csv,
	})

	-- <leader>sk — Show keybinds
	parent.register_custom({
		key = "k",
		mode = "n",
		desc = "Show csvgen keybinds",
		fn = parent.list,
	})

	-- <leader>sD — District → PrecinctSplit by PrecinctName match
	parent.register_association_generator({
		key = "D",
		desc = "Associate districts to precinct splits by precinct name match",
		match_col = 2,
		id_col = 1,
		output_header = {
			"",
			"#FormatVersion 1",
			"#DistrictExternalId,PrecinctSplitExternalId",
		},
		output_format = "%d,%d",
	})

	-- <leader>sP — Contest → PrecinctSplit by PrecinctName match
	parent.register_association_generator({
		key = "P",
		desc = "Associate contests to precinct splits by precinct name match",
		match_col = 2,
		id_col = 1,
		output_header = {
			"",
			"#FormatVersion 2",
			"#ContestExternalId,PrecinctSplitExternalId,BallotPosition",
		},
		output_format = "%d,%d,None",
	})

	-- <leader>sC — Contest → District by party/notes match
	parent.register_association_generator({
		key = "C",
		desc = "Associate contests to districts by party/notes match",
		match_col = 4,
		extra_match_cols = { 5 },
		id_col = 1,
		swap_format = true,
		output_header = {
			"",
			"#FormatVersion 1",
			"#ContestExternalId,DistrictExternalId",
		},
		output_format = "%d,%d",
	})

	-- <leader>sL — PollingPlace → PrecinctSplit by PrecinctName match
	parent.register_association_generator({
		key = "L",
		desc = "Associate polling places to precinct splits by precinct name match",
		match_col = 2,
		id_col = 1,
		output_header = {
			"",
			"#FormatVersion 1",
			"#PollPlaceExternalId,PrecinctSplitExternalId",
		},
		output_format = "%d,%d",
	})

	-- ---------------------------------------------------------------
	-- <leader>sr — Reorder choices by last name within each contest
	-- ---------------------------------------------------------------
	local suffix_set = {}
	for _, s in ipairs({ "jr", "sr", "i", "ii", "iii", "iv", "v", "vi", "esq", "phd", "md" }) do
		suffix_set[s] = true
	end

	local function is_suffix(word)
		return suffix_set[word:lower():gsub("%.$", "")]
	end

	local function extract_last_name(name)
		local words = {}
		for w in name:gmatch("%S+") do
			table.insert(words, w)
		end
		if #words == 0 then
			return ""
		end
		local last = words[#words]
		if #words >= 2 and is_suffix(last) then
			return words[#words - 1]:gsub("[^%a]", "")
		end
		return last:gsub("[^%a]", "")
	end

	local function csv_field(s)
		if s == nil or s == "" then
			return ""
		end
		return '"' .. tostring(s):gsub('"', '""') .. '"'
	end

	parent.register_custom({
		key = "r",
		mode = "n",
		desc = "Reorder choices by last name within each contest",
		fn = function()
			local buf = vim.api.nvim_get_current_buf()
			local total = vim.api.nvim_buf_line_count(buf)
			local cur = vim.fn.line(".")

			-- Scan up to find the header
			local header_line = nil
			for l = cur, 1, -1 do
				local raw = vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1]
				if raw and raw:match("^#ExternalChoiceId,ExternalContestId") then
					header_line = l
					break
				end
			end
			if not header_line then
				print("No choices header found above cursor")
				return
			end

			-- Scan down to collect data rows
			local rows = {}
			for l = header_line + 1, total do
				local raw = vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1]
				if raw == nil or U.trim(raw) == "" or raw:match("^#") then
					break
				end
				local fields = U.parse_csv_fields(raw)
				if #fields >= 6 then
					local choice_id = tonumber((U.trim(fields[1])))
					local contest_id = tonumber((U.trim(fields[2])))
					local name = (fields[3] or ""):gsub('"', "")
					if choice_id and contest_id and name ~= "" then
						table.insert(rows, {
							choice_id = choice_id,
							contest_id = contest_id,
							name = name,
							short_name = fields[4] or "",
							is_disabled = fields[5] or "",
							second_name = fields[7] or "",
						})
					end
				end
			end

			if #rows == 0 then
				print("No choice data found")
				return
			end

			-- Group by contest, sort by last name, reassign sequence
			local groups = {}
			for _, r in ipairs(rows) do
				groups[r.contest_id] = groups[r.contest_id] or {}
				table.insert(groups[r.contest_id], r)
			end

			local output = {}
			table.insert(output, "#FormatVersion 3")
			table.insert(
				output,
				"#ExternalChoiceId,ExternalContestId,Name,ShortName,IsDisabled,SequenceNumber,SecondName"
			)

			local cids = {}
			for cid in pairs(groups) do
				table.insert(cids, cid)
			end
			table.sort(cids)

			for _, cid in ipairs(cids) do
				local group = groups[cid]
				table.sort(group, function(a, b)
					local la = extract_last_name(a.name)
					local lb = extract_last_name(b.name)
					if la ~= lb then
						return la < lb
					end
					return a.name < b.name
				end)
				for seq, r in ipairs(group) do
					local parts = {
						csv_field(r.choice_id),
						csv_field(r.contest_id),
						csv_field(r.name),
						csv_field(r.short_name),
						csv_field(r.is_disabled),
						csv_field(seq),
						csv_field(r.second_name),
					}
					table.insert(output, table.concat(parts, ","))
				end
			end

			-- Append below the last data row
			local last_data_line = header_line + #rows
			U.insert_after(buf, last_data_line, output)
			print(string.format("Reordered %d choices across %d contests", #rows, #cids))
		end,
	})
end

return M
