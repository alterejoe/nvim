-- /home/jmeyer/.config/nvim/lua/csvgen/registration.lua FINAL
-- csvgen/registration.lua — Registration functions for all generator types.
-- Attached to the parent module via .attach(parent, map, resolve_lhs, make_formatter).

local bool_expr = require("csvgen.bool_expr")

local M = {}

function M.attach(parent, map_fn, resolve_lhs_fn, make_formatter_fn)
	local U = parent.util

	-- 1) CARTESIAN MAPPING (visual mode)
	parent.register_mapping = function(spec)
		local formatter = make_formatter_fn(spec)
		local lhs = resolve_lhs_fn(spec)

		map_fn("v", lhs, function()
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

	-- 2) PATTERN GENERATOR (normal + visual)
	parent.register_pattern_generator = function(spec)
		local formatter = make_formatter_fn(spec)
		local lhs = resolve_lhs_fn(spec)
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

		map_fn("n", lhs, function()
			local pattern = vim.fn.getline(".")
			local csv_lines, count = generate(pattern)
			vim.fn.append(vim.fn.line("."), csv_lines)
			print("Generated " .. count .. " " .. label .. " rows - Inserted into buffer")
		end, spec.desc .. " from pattern")

		map_fn("v", lhs, function()
			vim.cmd('normal! "vy')
			local pattern = vim.fn.getreg("v")
			local csv_lines, count = generate(pattern)
			local end_line = vim.fn.line("'>")
			vim.fn.append(end_line, csv_lines)
			print("Generated " .. count .. " " .. label .. " rows - Inserted into buffer")
		end, spec.desc .. " from selected pattern")
	end

	-- 3) LINE TRANSFORM
	parent.register_transform = function(spec)
		local lhs = resolve_lhs_fn(spec)

		if spec.mode == "n" then
			map_fn("n", lhs, function()
				local buf = vim.api.nvim_get_current_buf()
				local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
				lines = spec.fn(lines)
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			end, spec.desc)
		else
			map_fn("v", lhs, function()
				local start_line = vim.fn.line("'<") - 1
				local end_line = vim.fn.line("'>")
				local buf = vim.api.nvim_get_current_buf()
				local lines = vim.api.nvim_buf_get_lines(buf, start_line, end_line, false)
				lines = spec.fn(lines)
				vim.api.nvim_buf_set_lines(buf, start_line, end_line, false, lines)
			end, spec.desc)
		end
	end

	-- 4) FULLY CUSTOM
	parent.register_custom = function(spec)
		local lhs = resolve_lhs_fn(spec)
		local modes = type(spec.mode) == "table" and spec.mode or { spec.mode }
		for _, mode in ipairs(modes) do
			map_fn(mode, lhs, spec.fn, spec.desc)
		end
	end

	-- 5) ASSOCIATION GENERATOR (name-match based)
	parent.register_association_generator = function(spec)
		local lhs = resolve_lhs_fn(spec)
		local extra_cols = spec.extra_match_cols or {}

		local function row_matches(expr, fields)
			local function check(col)
				local val = (fields[col] or ""):gsub('"', "")
				return bool_expr.eval(expr, val)
			end
			if check(spec.match_col) then
				return true
			end
			for _, col in ipairs(extra_cols) do
				if check(col) then
					return true
				end
			end
			return false
		end

		map_fn("n", lhs, function()
			local buf = vim.api.nvim_get_current_buf()
			local cur_line = vim.fn.line(".")
			local last_line = vim.api.nvim_buf_line_count(buf)

			local raw_line = vim.fn.getline(".")

			-- Parse optional ignore filter: [ids] at start, BEFORE normalization
			local ignore_ids = nil
			local pattern_text = raw_line
			if raw_line:match("^%[") then
				local filter_end = raw_line:find("%]")
				if filter_end then
					local filter_expr = raw_line:sub(2, filter_end - 1)
					filter_expr = filter_expr:gsub("%s+", ",")
					ignore_ids = {}
					for _, id in ipairs(U.expand_id_list(filter_expr)) do
						ignore_ids[id] = true
					end
					pattern_text = raw_line:sub(filter_end + 1)
				end
			end

			-- Normalize: trim, commas to spaces
			pattern_text = pattern_text:gsub(",", " "):gsub("^%s+", ""):gsub("%s+$", "")
			if pattern_text == "" then
				return
			end

			local targets = {}
			for l = cur_line, last_line do
				local raw = vim.api.nvim_buf_get_lines(buf, l, l + 1, false)[1]
				if raw == nil then
					break
				end
				local trimmed = U.trim(raw)
				if trimmed ~= "" and not trimmed:match("^#") then
					local fields = U.parse_csv_fields(trimmed)
					local id = tonumber((U.trim(fields[spec.id_col])))
					if id then
						table.insert(targets, { id = id, fields = fields })
					end
				end
			end

			local output = {}
			for _, h in ipairs(spec.output_header or {}) do
				table.insert(output, h)
			end

			local count = 0
			for token in pattern_text:gmatch("%S+") do
				local src_expr, expr_str = token:match("^(.+)%((.+)%)$")
				if src_expr and expr_str then
					local src_ids = U.expand_id_list(src_expr)
					local expr = bool_expr.parse(expr_str)
					if expr then
						for _, t in ipairs(targets) do
							if ignore_ids and ignore_ids[t.id] then
								-- skip filtered contests
							elseif row_matches(expr, t.fields) then
								for _, src_id in ipairs(src_ids) do
									local a, b = src_id, t.id
									if spec.swap_format then
										a, b = b, a
									end
									table.insert(output, string.format(spec.output_format, a, b))
									count = count + 1
								end
							end
						end
					end
				end
			end

			U.insert_after(buf, last_line, output)

			-- Output excluded contests as id() template for precinct mapping
			if ignore_ids and next(ignore_ids) then
				local sorted = {}
				for id in pairs(ignore_ids) do
					table.insert(sorted, id)
				end
				table.sort(sorted)
				local template_parts = {}
				for _, id in ipairs(sorted) do
					table.insert(template_parts, string.format("%d()", id))
				end
				local new_last = vim.api.nvim_buf_line_count(buf)
				U.insert_after(buf, new_last, { "", table.concat(template_parts, ",") })
			end

			print(string.format("Generated %d association rows", count))
		end, spec.desc)
	end
end

return M
