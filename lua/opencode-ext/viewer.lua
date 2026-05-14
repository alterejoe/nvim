-- lua/opencode-ext/viewer.lua
local db = require("opencode-ext.db")
local model = require("opencode-ext.model")

local M = {}

local VALID_EXTS = {
	go = true,
	templ = true,
	js = true,
	ts = true,
	jsx = true,
	tsx = true,
	sql = true,
	py = true,
	rb = true,
	rs = true,
	lua = true,
	md = true,
	yaml = true,
	yml = true,
	json = true,
	xml = true,
	css = true,
	scss = true,
	html = true,
	htm = true,
	sh = true,
	bash = true,
	zsh = true,
	toml = true,
	cfg = true,
	conf = true,
	env = true,
	gitignore = true,
	dockerfile = true,
	mjs = true,
	cjs = true,
	mts = true,
	cts = true,
	dart = true,
	kt = true,
	swift = true,
	c = true,
	cpp = true,
	h = true,
	hpp = true,
}

local function strip_comment(line)
	local t = vim.trim(line)
	return t:match("^//%s*(.+)$") or t:match("^#%s*(.+)$") or t:match("^%-%-%s*(.+)$") or t:match("^;%s*(.+)$")
end

local function detect_path(lines)
	if not lines or #lines == 0 then
		return ""
	end
	local first = vim.trim(lines[1])
	local path = first:match("^[%w_%-/%.~]+%.[%w_]+$")
	if path and VALID_EXTS[path:match("%.(%w+)$")] then
		return path
	end
	local stripped = strip_comment(first)
	if stripped then
		path = stripped:match("^[%w_%-/%.~]+%.[%w_]+$")
		if path and VALID_EXTS[path:match("%.(%w+)$")] then
			return path
		end
		path = stripped:match("([%w_%-/%.~]+%.[%w_]+)")
		if path and VALID_EXTS[path:match("%.(%w+)$")] then
			return path
		end
	end
	path = first:match("([%w_%-/%.~]+%.[%w_]+)")
	if path and VALID_EXTS[path:match("%.(%w+)$")] then
		return path
	end
	return ""
end

local function detect_version(lines)
	if not lines or #lines == 0 then
		return 0
	end
	local stripped = strip_comment(vim.trim(lines[1]))
	if not stripped then
		return 0
	end
	local v = stripped:match("FINAL%-(%d+)$")
	if v then
		return tonumber(v)
	end
	if stripped:match("FINAL$") then
		return 1
	end
	return 0
end

local function is_path_comment(line)
	local t = vim.trim(line)
	return not not (
		t:match("^//%s*[%w_%-/%.~]+%.[%w_]+")
		or t:match("^#%s*[%w_%-/%.~]+%.[%w_]+")
		or t:match("^%-%-%s*[%w_%-/%.~]+%.[%w_]+")
	)
end

local function code_snippet(lines)
	if not lines or #lines == 0 then
		return ""
	end
	for _, l in ipairs(lines) do
		local t = vim.trim(l)
		if t ~= "" and not is_path_comment(t) then
			return t:sub(1, 60)
		end
	end
	return vim.trim(lines[1]):sub(1, 60)
end

local function context_tail(lines, max_lines)
	if not lines or #lines == 0 then
		return {}
	end
	local end_idx = #lines
	while end_idx > 0 and vim.trim(lines[end_idx]) == "" do
		end_idx = end_idx - 1
	end
	if end_idx == 0 then
		return {}
	end
	if end_idx <= max_lines then
		local r = {}
		for i = 1, end_idx do
			r[#r + 1] = lines[i]
		end
		return r
	end
	local r = { "… (truncated)" }
	for i = end_idx - max_lines + 1, end_idx do
		r[#r + 1] = lines[i]
	end
	return r
end

local function detect_steps(context)
	if not context then
		return ""
	end
	local s = {}
	for _, l in ipairs(context) do
		local n = l:match("Step (%d+)")
		if n then
			s[tonumber(n)] = true
		end
	end
	local k = vim.tbl_keys(s)
	if #k == 0 then
		return ""
	end
	table.sort(k)
	return #k == 1 and "Step " .. k[1] or "Steps " .. k[1] .. "-" .. k[#k]
end

local filename_cache = {}
local function clear_cache()
	filename_cache = {}
end

-- Find ALL files matching a name in the project (glob by basename).
local function find_all_files(name, project_root)
	if not name or name == "" or not project_root then
		return {}
	end
	local cache_key = "all|" .. project_root .. "|" .. name
	if filename_cache[cache_key] ~= nil then
		return filename_cache[cache_key]
	end
	local basename = name:match("([^/]+)$") or name
	local found = vim.fn.glob(project_root .. "/**/" .. basename, false, true)
	if #found == 0 then
		local abs = project_root .. "/" .. name
		if vim.fn.filereadable(abs) == 1 then
			filename_cache[cache_key] = { name }
			return { name }
		end
		filename_cache[cache_key] = {}
		return {}
	end
	local seen = {}
	local results = {}
	for _, f in ipairs(found) do
		local rel = f:sub(#project_root + 2)
		if not seen[rel] then
			seen[rel] = true
			results[#results + 1] = rel
		end
	end
	table.sort(results, function(a, b)
		return #a < #b
	end)
	filename_cache[cache_key] = results
	return results
end

-- Convenience: first shortest match only.
local function find_file_in_project(name, project_root)
	local all = find_all_files(name, project_root)
	return #all > 0 and all[1] or ""
end

local function extract_filenames(lines)
	local names = {}
	for _, l in ipairs(lines or {}) do
		if not is_path_comment(l) then
			for match in l:gmatch("([%w_%-/%.~]+%.[%w_]+)") do
				local ext = match:match("%.(%w+)$")
				if ext and VALID_EXTS[ext] then
					names[#names + 1] = match
				end
			end
		end
	end
	return names
end

-- Resolve path for a code block. Returns {best_path, all_candidates}.
-- Tries: line-1 comment → filenames in code → context cross-validated → context directly.
local function resolve_path(lines, context, project_root)
	local candidates = {}
	local seen = {}
	local function add(names)
		for _, n in ipairs(names) do
			if not seen[n] then
				seen[n] = true
				candidates[#candidates + 1] = n
			end
		end
	end

	-- 1. Path comment on line 1 (most authoritative)
	local path = detect_path(lines)
	if path ~= "" then
		local found = find_all_files(path, project_root)
		if #found > 0 then
			add(found)
			return found[1], candidates
		end
		return path, { path }
	end

	-- 2. Filenames inside code text
	for _, name in ipairs(extract_filenames(lines)) do
		local found = find_all_files(name, project_root)
		if #found > 0 then
			add(found)
			return found[1], candidates
		end
		add({ name })
	end

	-- 3. Context filenames cross-validated against code text
	local ctx_names = extract_filenames(context)
	if #ctx_names > 0 and lines and #lines > 0 then
		local code_text = table.concat(lines, "\n")
		for _, name in ipairs(ctx_names) do
			local basename = name:match("([^/]+)$") or name
			if code_text:find(basename, 1, true) then
				local found = find_all_files(name, project_root)
				if #found > 0 then
					add(found)
					return found[1], candidates
				end
				add({ name })
			end
		end
	end

	-- 4. Context filenames directly (catches bare names like path_like_this.go)
	for _, name in ipairs(ctx_names) do
		local found = find_all_files(name, project_root)
		if #found > 0 then
			add(found)
			return found[1], candidates
		end
		add({ name })
	end

	return "", candidates
end

local accumulator = {}

local function flush_accumulator()
	if #accumulator == 0 then
		vim.notify("Accumulator empty", vim.log.levels.INFO)
		return
	end
	local text = table.concat(accumulator, "\n\n")
	vim.fn.setreg("+", text)
	vim.fn.setreg('"', text)
	local c = #accumulator
	accumulator = {}
	vim.notify(string.format("Flushed %d blocks (%d chars)", c, #text), vim.log.levels.INFO)
end

local function dedupe_by_final(entries)
	local by_path = {}
	local has_final = {}
	for _, e in ipairs(entries) do
		if e.section_header then
			goto n
		end
		local p = e.value.path
		if p and p ~= "" then
			by_path[p] = by_path[p] or {}
			by_path[p][#by_path[p] + 1] = e
			if e.value.version > 0 then
				has_final[p] = true
			end
		end
		::n::
	end
	if not next(has_final) then
		return entries
	end
	local r = {}
	local ins = {}
	for _, e in ipairs(entries) do
		if e.section_header then
			r[#r + 1] = e
		else
			local p = e.value.path
			if not p or p == "" then
				r[#r + 1] = e
			elseif not ins[p] then
				ins[p] = true
				if has_final[p] then
					local best = e
					for _, e2 in ipairs(by_path[p]) do
						if e2.value.version > best.value.version then
							best = e2
						end
					end
					r[#r + 1] = best
				else
					for _, e2 in ipairs(by_path[p]) do
						r[#r + 1] = e2
					end
				end
			end
		end
	end
	return r
end

-- Per-block context: split text_lines so code block N only sees text written before it.
local function compute_per_block_contexts(text_lines, code_blocks)
	if #code_blocks <= 1 then
		return { text_lines or {} }
	end
	-- Find step marker indices in text_lines
	local step_indices = {}
	for i, l in ipairs(text_lines or {}) do
		local t = vim.trim(l)
		if t:match("^%*%*Step %d+") or t:match("^Step %d+") then
			step_indices[#step_indices + 1] = i
		end
	end
	if #step_indices == 0 or #step_indices ~= #code_blocks then
		-- Fallback: distribute evenly
		local per_block = {}
		local total = #text_lines or 0
		if total == 0 then
			for _ = 1, #code_blocks do
				per_block[#per_block + 1] = {}
			end
			return per_block
		end
		local chunk_size = math.ceil(total / #code_blocks)
		for i = 1, #code_blocks do
			local start = (i - 1) * chunk_size + 1
			local end_idx = math.min(i * chunk_size, total)
			per_block[#per_block + 1] = vim.list_slice(text_lines, start, end_idx)
		end
		return per_block
	end
	-- Split at Step boundaries: block K gets text from Step K to Step K+1
	local contexts = {}
	for i = 1, #step_indices do
		local start = step_indices[i]
		local end_idx = (i < #step_indices) and (step_indices[i + 1] - 1) or #text_lines
		contexts[#contexts + 1] = vim.list_slice(text_lines or {}, start, end_idx)
	end
	return contexts
end

-- viewer.lua:398 FINAL
local ed = require("telescope.pickers.entry_display")
local code_display = ed.create({
	separator = " ",
	items = {
		{ width = 12 },
		{ width = 30 },
		{ remaining = true },
	},
})

-- viewer.lua:399-492 FINAL
local function build_entries(raw, project_path, parsed)
	clear_cache()
	local conversations = model.build(raw)
	local entries = {}
	for _, conv in ipairs(conversations) do
		local label = (conv.label or ""):gsub("\n", " "):sub(1, 70)
		if label ~= "" then
			entries[#entries + 1] = {
				display = ("── %s ──"):format(label),
				ordinal = label,
				section_header = true,
				user_label = label,
				value = {},
			}
		end
		for _, asst in ipairs(conv.asst_sections) do
			local per_block_ctx = compute_per_block_contexts(asst.text_lines or {}, asst.code_blocks)
			for bi, cb in ipairs(asst.code_blocks) do
				local context = per_block_ctx[bi] or {}
				local step_tag = detect_steps(context)
				local path, candidates = resolve_path(cb.lines, context, project_path)
				local version = detect_version(cb.lines)
				local snippet = code_snippet(cb.lines)
				local lt = cb.lang ~= "" and "(" .. cb.lang .. ")" or "(?)"

				local path_exists = path ~= ""
					and project_path
					and vim.fn.filereadable(project_path .. "/" .. path) == 1
				local icon = path_exists and "✓" or (path ~= "" and "▸") or (#candidates > 0 and "?") or "○"
				local icon_hl = path_exists and "Identifier"
					or (path ~= "" and "Special")
					or (#candidates > 0 and "WarningMsg")
					or "NonText"
				local ord = (step_tag ~= "" and step_tag .. " " or "") .. (path ~= "" and path or lt) .. " " .. snippet

				entries[#entries + 1] = {
					display = function()
						local first = icon
						if step_tag ~= "" then
							first = step_tag .. ": " .. icon
						end
						if path ~= "" then
							return code_display({
								{ first, icon_hl },
								{ path, "Directory" },
								{ snippet, "String" },
							})
						else
							return code_display({
								{ first, icon_hl },
								{ lt, "Comment" },
								{ snippet, "String" },
							})
						end
					end,
					ordinal = ord,
					value = {
						lines = cb.lines,
						context = context,
						lang = cb.lang,
						path = path,
						candidates = candidates,
						path_exists = path_exists,
						version = version,
						project = project_path,
					},
				}
			end
		end
	end
	if parsed then
		entries = dedupe_by_final(entries)
	end
	local r = {}
	for i = #entries, 1, -1 do
		r[#r + 1] = entries[i]
	end
	return r
end

-- Open a picker to resolve/customize a path for a code block.
-- Shows existing candidates, then falls back to project-wide filename search.
local function pick_path(entry, project_root, on_pick)
	local block = entry.value
	local candidates = {}
	local seen = {}

	-- Collect from existing candidates
	for _, c in ipairs(block.candidates or {}) do
		if not seen[c] then
			seen[c] = true
			candidates[#candidates + 1] = c
		end
	end

	-- Add project files matching the block's language extension
	if block.lang ~= "" and project_root then
		local lang_exts = {
			go = "*.go",
			lua = "*.lua",
			py = "*.py",
			js = "*.js",
			ts = "*.ts",
			tsx = "*.tsx",
			jsx = "*.jsx",
			rs = "*.rs",
			templ = "*.templ",
			sql = "*.sql",
			md = "*.md",
			yaml = "*.{yaml,yml}",
			json = "*.json",
		}
		local pat = lang_exts[block.lang]
		if pat then
			local project_files = vim.fn.glob(project_root .. "/**/" .. pat, false, true)
			for _, f in ipairs(project_files) do
				local rel = f:sub(#project_root + 2)
				if not seen[rel] then
					seen[rel] = true
					candidates[#candidates + 1] = rel
				end
			end
		end
	end

	if #candidates == 0 then
		-- No candidates — let user type a path directly
		local path = vim.fn.input("File path: ", "", "file")
		if path and path ~= "" then
			on_pick(path)
		end
		return
	end

	table.sort(candidates, function(a, b)
		return #a < #b
	end)

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	local picker_entries = {}
	for _, c in ipairs(candidates) do
		picker_entries[#picker_entries + 1] = { path = c }
	end

	pickers
		.new({}, {
			prompt_title = "File path  (<CR>=select, <c-s>=save typed)",
			finder = finders.new_table({
				results = picker_entries,
				entry_maker = function(e)
					return {
						value = e,
						display = e.path,
						ordinal = e.path,
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					local sel = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if sel and sel.value then
						on_pick(sel.value.path)
					end
				end)
				-- <c-s> uses whatever the user typed in the prompt
				map("i", "<c-s>", function()
					local typed = vim.trim(action_state.get_current_line())
					actions.close(prompt_bufnr)
					on_pick(typed ~= "" and typed or nil)
				end)
				return true
			end,
		})
		:find()
end

local function open_picker(sid, project_path)
	local raw, err = db.fetch_session(sid)
	if not raw then
		vim.notify(err or "Failed to load session", vim.log.levels.ERROR)
		return
	end
	local parsed_mode = false
	local function get_entries()
		return build_entries(raw, project_path, parsed_mode)
	end
	local entries = get_entries()
	if #entries == 0 then
		vim.notify("No code blocks in this session", vim.log.levels.WARN)
		return
	end

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local previewers = require("telescope.previewers")
	local current_project = project_path

	local function is_header(e)
		return e and e.section_header
	end

	-- FIXED: build_content returns raw code lines as-is. No path comment reconstruction.
	-- The path is for display and navigation only.
	local function build_content(block)
		local parts = {}
		for _, l in ipairs(block.lines) do
			table.insert(parts, l)
		end
		return table.concat(parts, "\n")
	end

	local function copy_block(entry)
		local text = build_content(entry.value)
		vim.fn.setreg("+", text)
		vim.fn.setreg('"', text)
		vim.notify(string.format("Copied (%d chars)", #text), vim.log.levels.INFO)
	end

	local function accumulate_block(entry)
		local text = build_content(entry.value)
		accumulator[#accumulator + 1] = text
		vim.notify(string.format("Accumulated (%d blocks)", #accumulator), vim.log.levels.INFO)
	end

	local function get_abs_path(entry)
		local block = entry.value
		if not block.path or block.path == "" then
			return nil, "No file path for this block"
		end
		return (current_project or vim.fn.getcwd()) .. "/" .. block.path, nil
	end

	local function open_abs(abs, warn)
		if vim.fn.filereadable(abs) ~= 1 then
			if warn then
				vim.notify("File not found: " .. abs, vim.log.levels.WARN)
			end
			return false
		end
		vim.cmd("vsplit " .. vim.fn.fnameescape(abs))
		return true
	end

	local function create_file(entry, with_content)
		local abs, err = get_abs_path(entry)
		if not abs then
			vim.notify(err, vim.log.levels.WARN)
			return false
		end
		if vim.fn.filereadable(abs) == 1 then
			return open_abs(abs, false)
		end
		local dir = vim.fn.fnamemodify(abs, ":h")
		if vim.fn.isdirectory(dir) ~= 1 then
			vim.notify("Directory doesn't exist: " .. dir, vim.log.levels.WARN)
			return false
		end
		local answer = vim.fn.input(string.format("Create %s? (y/N): ", entry.value.path))
		if answer:lower() ~= "y" then
			return false
		end
		local fd = io.open(abs, "w")
		if not fd then
			vim.notify("Failed to create: " .. entry.value.path, vim.log.levels.ERROR)
			return false
		end
		if with_content then
			local lines = {}
			for _, l in ipairs(entry.value.lines) do
				lines[#lines + 1] = l
			end
			fd:write(table.concat(lines, "\n") .. "\n")
		end
		fd:close()
		vim.notify("Created: " .. entry.value.path, vim.log.levels.INFO)
		vim.cmd("vsplit " .. vim.fn.fnameescape(abs))
		return true
	end

	local previewer = previewers.new_buffer_previewer({
		define_preview = function(self, entry)
			if entry.section_header then
				vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, {
					("── %s ──"):format(entry.user_label or ""),
					"",
					"  Icon legend:",
					"    ✓  file exists on disk",
					"    ▸  path known, file doesn't exist yet",
					"    ?  multiple candidate files found",
					"    ○  no path information",
				})
				vim.bo[self.state.bufnr].filetype = "markdown"
				return
			end
			local block = entry.value
			local lines = {}
			local ctx = context_tail(block.context, 5)
			for _, l in ipairs(ctx) do
				lines[#lines + 1] = l
			end
			if #ctx > 0 then
				lines[#lines + 1] = ""
				lines[#lines + 1] = "───"
				lines[#lines + 1] = ""
			end
			for _, l in ipairs(block.lines) do
				lines[#lines + 1] = l
			end
			vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
			vim.bo[self.state.bufnr].filetype = "markdown"
		end,
	})

	local prompt_title = string.format(
		"Code Blocks [%s]  ↵=copy+open  c=copy  o=open  a=create  A=create+fill  C=acc  f=flush  p=path  r=refresh  s=session  t=toggle",
		parsed_mode and "parsed" or "raw"
	)

	pickers
		.new({}, {
			prompt_title = prompt_title,
			finder = finders.new_table({
				results = entries,
				entry_maker = function(e)
					return e
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = previewer,
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					local entry = action_state.get_selected_entry()
					if not entry or is_header(entry) then
						return
					end
					copy_block(entry)
					local abs = get_abs_path(entry)
					if abs then
						open_abs(abs, false)
					end
				end)
				map("n", "c", function()
					local entry = action_state.get_selected_entry()
					if entry and not is_header(entry) then
						copy_block(entry)
					end
				end)
				map("n", "C", function()
					local entry = action_state.get_selected_entry()
					if entry and not is_header(entry) then
						accumulate_block(entry)
					end
				end)
				map("n", "f", flush_accumulator)
				map("n", "o", function()
					local entry = action_state.get_selected_entry()
					if not entry or is_header(entry) then
						return
					end
					local abs, err = get_abs_path(entry)
					if not abs then
						vim.notify(err, vim.log.levels.WARN)
						return
					end
					open_abs(abs, true)
				end)
				map("n", "p", function()
					local entry = action_state.get_selected_entry()
					if not entry or is_header(entry) then
						return
					end
					pick_path(entry, current_project, function(chosen)
						if not chosen then
							return
						end
						entry.value.path = chosen
						entry.value.path_exists = vim.fn.filereadable(
							(current_project or vim.fn.getcwd()) .. "/" .. chosen
						) == 1
						vim.notify(string.format("Path set: %s", chosen), vim.log.levels.INFO)
						-- If the path looks valid, try to open/create
						local abs = (current_project or vim.fn.getcwd()) .. "/" .. chosen
						if vim.fn.filereadable(abs) == 1 then
							vim.cmd("vsplit " .. vim.fn.fnameescape(abs))
						else
							local dir = vim.fn.fnamemodify(abs, ":h")
							if vim.fn.isdirectory(dir) == 1 then
								local answer = vim.fn.input(string.format("Create %s? (y/N): ", chosen))
								if answer:lower() == "y" then
									local fd = io.open(abs, "w")
									if fd then
										fd:close()
										vim.cmd("vsplit " .. vim.fn.fnameescape(abs))
									end
								end
							end
						end
					end)
				end)
				map("n", "a", function()
					local entry = action_state.get_selected_entry()
					if entry and not is_header(entry) then
						create_file(entry, false)
					end
				end)
				map("n", "A", function()
					local entry = action_state.get_selected_entry()
					if entry and not is_header(entry) then
						create_file(entry, true)
					end
				end)
				map("n", "r", function()
					local new_raw, new_err = db.fetch_session(sid)
					if not new_raw then
						vim.notify(new_err or "Refresh failed", vim.log.levels.WARN)
						return
					end
					raw = new_raw
					local new_e = get_entries()
					local p = action_state.get_current_picker(prompt_bufnr)
					if p then
						p:set_finder(finders.new_table({
							results = new_e,
							entry_maker = function(e)
								return e
							end,
						}))
					end
					vim.notify(string.format("Refreshed (%d blocks)", #new_e), vim.log.levels.INFO)
				end)
				map("n", "s", function()
					actions.close(prompt_bufnr)
					pick_session()
				end)
				map("n", "t", function()
					parsed_mode = not parsed_mode
					local new_e = get_entries()
					local p = action_state.get_current_picker(prompt_bufnr)
					if p then
						p:set_finder(finders.new_table({
							results = new_e,
							entry_maker = function(e)
								return e
							end,
						}))
					end
					vim.notify(
						string.format("Switched to %s mode (%d blocks)", parsed_mode and "parsed" or "raw", #new_e),
						vim.log.levels.INFO
					)
				end)
				return true
			end,
		})
		:find()
end

local function pick_session()
	local sessions, err = db.fetch_sessions()
	if not sessions then
		vim.notify(err or "No sessions", vim.log.levels.WARN)
		return
	end
	if #sessions == 0 then
		vim.notify("No opencode sessions found", vim.log.levels.WARN)
		return
	end

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	local all_sessions = sessions

	local function format_time(ts)
		if not ts then
			return "?"
		end
		local diff = os.time() - ts
		if diff < 60 then
			return "now"
		elseif diff < 3600 then
			return math.floor(diff / 60) .. "m"
		elseif diff < 86400 then
			return math.floor(diff / 3600) .. "h"
		elseif diff < 604800 then
			return math.floor(diff / 86400) .. "d"
		end
		return os.date("%b %d", ts)
	end

	local function make_entry(s)
		local title = (s.title or ""):gsub("\n", " "):sub(1, 60)
		if title == "" then
			title = "(untitled)"
		end
		local proj = s.project or ""
		local proj_short = ""
		if proj ~= "" then
			local p = vim.split(proj, "/")
			proj_short = #p >= 2 and p[#p - 1] .. "/" .. p[#p] or p[#p]
		end
		return {
			value = s,
			display = string.format(
				"%-60s %-28s %6s  %d msgs",
				title,
				proj_short,
				format_time(s.time_updated),
				s.msg_count or 0
			),
			ordinal = title .. " " .. proj,
		}
	end

	pickers
		.new({}, {
			prompt_title = "Opencode Sessions",
			finder = finders.new_table({ results = all_sessions, entry_maker = make_entry }),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					local s = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if s and s.value then
						open_picker(s.value.id, s.value.project)
					end
				end)
				map("n", "c", function()
					local cwd = vim.fn.getcwd()
					local filtered = {}
					for _, s in ipairs(all_sessions) do
						if s.project and cwd:find(s.project, 1, true) == 1 then
							filtered[#filtered + 1] = s
						end
					end
					if #filtered == 0 then
						vim.notify("No sessions for current project", vim.log.levels.WARN)
						return
					end
					local p = action_state.get_current_picker(prompt_bufnr)
					if p then
						p:set_finder(finders.new_table({ results = filtered, entry_maker = make_entry }))
					end
				end)
				map("n", "<Esc>", function()
					local p = action_state.get_current_picker(prompt_bufnr)
					if p then
						p:set_finder(finders.new_table({ results = all_sessions, entry_maker = make_entry }))
					end
				end)
				return true
			end,
		})
		:find()
end

function M.toggle()
	local raw, err = db.fetch_all()
	if raw and raw.sid and raw.sid ~= vim.NIL then
		open_picker(raw.sid, vim.fn.getcwd())
	else
		pick_session()
	end
end

vim.keymap.set("n", "<leader>ae", M.toggle, { desc = "Opencode: code block picker" })
return M
