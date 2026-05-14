-- lua/opencode-ext/viewer.lua
local db = require("opencode-ext.db")
local model = require("opencode-ext.model")

local M = {}

-- ── path detection ─────────────────────────────────────

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

	-- Plain file path on first line
	local path = first:match("^[%w_%-/%.~]+%.[%w_]+$")
	if path and VALID_EXTS[path:match("%.(%w+)$")] then
		return path
	end

	-- Comment-prefixed
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
		local result = {}
		for i = 1, end_idx do
			table.insert(result, lines[i])
		end
		return result
	end
	local result = { "… (truncated)" }
	for i = end_idx - max_lines + 1, end_idx do
		table.insert(result, lines[i])
	end
	return result
end

-- ── filesystem-assisted path resolution ──────────────

local filename_cache = {}

local function clear_cache()
	filename_cache = {}
end

local function find_file_in_project(name, project_root)
	if not name or name == "" or not project_root then
		return ""
	end
	local key = project_root .. "|" .. name
	if filename_cache[key] ~= nil then
		return filename_cache[key]
	end

	local abs = project_root .. "/" .. name
	if vim.fn.filereadable(abs) == 1 then
		filename_cache[key] = name
		return name
	end

	local basename = name:match("([^/]+)$") or name
	local found = vim.fn.glob(project_root .. "/**/" .. basename, false, true)
	if #found > 0 then
		table.sort(found, function(a, b)
			return #a < #b
		end)
		filename_cache[key] = found[1]:sub(#project_root + 2)
		return filename_cache[key]
	end

	filename_cache[key] = ""
	return ""
end

local function extract_filenames(lines)
	local names = {}
	for _, l in ipairs(lines or {}) do
		if not is_path_comment(l) then
			for match in l:gmatch("([%w_%-/%.~]+%.[%w_]+)") do
				local ext = match:match("%.(%w+)$")
				if ext and VALID_EXTS[ext] then
					table.insert(names, match)
				end
			end
		end
	end
	return names
end

local function resolve_path(lines, context, project_root)
	local path = detect_path(lines)
	if path ~= "" then
		return path
	end

	for _, name in ipairs(extract_filenames(lines)) do
		path = find_file_in_project(name, project_root)
		if path ~= "" then
			return path
		end
	end

	for _, name in ipairs(extract_filenames(context)) do
		path = find_file_in_project(name, project_root)
		if path ~= "" then
			return path
		end
	end

	return ""
end

-- ── accumulator ──────────────────────────────────────

local accumulator = {}

local function flush_accumulator()
	if #accumulator == 0 then
		vim.notify("Accumulator empty", vim.log.levels.INFO)
		return
	end
	local text = table.concat(accumulator, "\n\n")
	vim.fn.setreg("+", text)
	vim.fn.setreg('"', text)
	local count = #accumulator
	accumulator = {}
	vim.notify(string.format("Flushed %d blocks (%d chars)", count, #text), vim.log.levels.INFO)
end

-- ── dedup by FINAL markers ──────────────────────────

local function dedupe_by_final(entries)
	local by_path = {}
	local has_final = {}

	for _, entry in ipairs(entries) do
		local p = entry.value.path
		if p and p ~= "" then
			by_path[p] = by_path[p] or {}
			table.insert(by_path[p], entry)
			if entry.value.version > 0 then
				has_final[p] = true
			end
		end
	end

	if not next(has_final) then
		return entries
	end

	local result = {}
	local inserted_path = {}

	for _, entry in ipairs(entries) do
		local p = entry.value.path
		if not p or p == "" then
			table.insert(result, entry)
		elseif not inserted_path[p] then
			inserted_path[p] = true
			if has_final[p] then
				local best = entry
				for _, e in ipairs(by_path[p]) do
					if e.value.version > best.value.version then
						best = e
					end
				end
				table.insert(result, best)
			else
				for _, e in ipairs(by_path[p]) do
					table.insert(result, e)
				end
			end
		end
	end

	return result
end

-- ── build entries from session data ──────────────────

local function build_entries(raw, project_path, parsed)
	clear_cache()
	local conversations = model.build(raw)
	local entries = {}

	for _, conv in ipairs(conversations) do
		for _, asst in ipairs(conv.asst_sections) do
			local context = asst.text_lines or {}
			for _, cb in ipairs(asst.code_blocks) do
				local path = resolve_path(cb.lines, context, project_path)
				local version = detect_version(cb.lines)
				local snippet = code_snippet(cb.lines)
				local lang_tag = cb.lang ~= "" and "(" .. cb.lang .. ")" or "(?)"

				local display
				if path ~= "" then
					display = string.format("%-30s %s", path, snippet)
				else
					display = string.format("%-8s %s", lang_tag, snippet)
				end

				table.insert(entries, {
					display = display,
					ordinal = (path ~= "" and path or lang_tag) .. " " .. snippet,
					value = {
						lines = cb.lines,
						context = context,
						lang = cb.lang,
						path = path,
						version = version,
						project = project_path,
					},
				})
			end
		end
	end

	if parsed then
		entries = dedupe_by_final(entries)
	end

	local reversed = {}
	for i = #entries, 1, -1 do
		table.insert(reversed, entries[i])
	end
	return reversed
end

-- ── Telescope picker ────────────────────────────────

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

	-- ── block helpers ──────────────────────────────

	local function build_content(block)
		local parts = {}
		if block.path and block.path ~= "" then
			local comment = "// "
			local py_langs = { py = true, python = true, rb = true, yaml = true, yml = true, sh = true }
			if py_langs[block.lang] then
				comment = "# "
			elseif block.lang == "lua" or block.lang == "sql" then
				comment = "-- "
			end
			table.insert(parts, comment .. block.path)
		end
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
		table.insert(accumulator, text)
		vim.notify(string.format("Accumulated (%d blocks)", #accumulator), vim.log.levels.INFO)
	end

	local function get_abs_path(entry)
		local block = entry.value
		if not block.path or block.path == "" then
			return nil, "No file path for this block"
		end
		local root = current_project or vim.fn.getcwd()
		return root .. "/" .. block.path, nil
	end

	local function open_abs(abs, warn)
		if vim.fn.filereadable(abs) ~= 1 then
			if warn then
				vim.notify(string.format("File not found: %s", abs), vim.log.levels.WARN)
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
			vim.notify(string.format("Directory doesn't exist: %s", dir), vim.log.levels.WARN)
			return false
		end

		local answer = vim.fn.input(string.format("Create %s? (y/N): ", entry.value.path))
		if answer:lower() ~= "y" then
			return false
		end

		local fd = io.open(abs, "w")
		if not fd then
			vim.notify(string.format("Failed to create: %s", entry.value.path), vim.log.levels.ERROR)
			return false
		end

		if with_content then
			local lines = {}
			for _, l in ipairs(entry.value.lines) do
				table.insert(lines, l)
			end
			fd:write(table.concat(lines, "\n"))
		end
		fd:close()

		vim.notify(string.format("Created: %s", entry.value.path), vim.log.levels.INFO)
		vim.cmd("vsplit " .. vim.fn.fnameescape(abs))
		return true
	end

	-- ── previewer ───────────────────────────────────

	local previewer = previewers.new_buffer_previewer({
		define_preview = function(self, entry)
			local block = entry.value
			local lines = {}

			local ctx = context_tail(block.context, 5)
			for _, l in ipairs(ctx) do
				table.insert(lines, l)
			end
			if #ctx > 0 then
				table.insert(lines, "")
				table.insert(lines, "───")
				table.insert(lines, "")
			end

			if block.path and block.path ~= "" then
				table.insert(lines, "// " .. block.path)
			end

			for _, l in ipairs(block.lines) do
				table.insert(lines, l)
			end

			vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
			vim.bo[self.state.bufnr].filetype = "markdown"
		end,
	})

	-- ── picker ──────────────────────────────────────

	local mode_label = parsed_mode and "parsed" or "raw"
	local prompt_title = string.format(
		"Code Blocks [%s]  ↵=copy+open  c=copy  o=open  a=create+open  A=create+fill  C=acc  f=flush  r=refresh  s=session  t=toggle",
		mode_label
	)

	local picker = pickers.new({}, {
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
			-- <CR> = copy + navigate (silent if file missing)
			actions.select_default:replace(function()
				local entry = action_state.get_selected_entry()
				if not entry then
					return
				end
				copy_block(entry)
				local abs = get_abs_path(entry)
				if abs then
					open_abs(abs, false)
				end
			end)

			-- c = copy only
			map("n", "c", function()
				local entry = action_state.get_selected_entry()
				if entry then
					copy_block(entry)
				end
			end)

			-- C = accumulate
			map("n", "C", function()
				local entry = action_state.get_selected_entry()
				if entry then
					accumulate_block(entry)
				end
			end)

			-- f = flush accumulator
			map("n", "f", function()
				flush_accumulator()
			end)

			-- o = navigate only, warn if missing
			map("n", "o", function()
				local entry = action_state.get_selected_entry()
				if not entry then
					return
				end
				local abs, err = get_abs_path(entry)
				if not abs then
					vim.notify(err, vim.log.levels.WARN)
					return
				end
				open_abs(abs, true)
			end)

			-- a = create file (prompt) + open
			map("n", "a", function()
				local entry = action_state.get_selected_entry()
				if entry then
					create_file(entry, false)
				end
			end)

			-- A = create file (prompt) + write content + open
			map("n", "A", function()
				local entry = action_state.get_selected_entry()
				if entry then
					create_file(entry, true)
				end
			end)

			-- r = refresh from DB
			map("n", "r", function()
				local new_raw, new_err = db.fetch_session(sid)
				if not new_raw then
					vim.notify(new_err or "Refresh failed", vim.log.levels.WARN)
					return
				end
				raw = new_raw
				local new_entries = get_entries()
				local p = action_state.get_current_picker(prompt_bufnr)
				if p then
					p:set_finder(finders.new_table({
						results = new_entries,
						entry_maker = function(e)
							return e
						end,
					}))
				end
				vim.notify(string.format("Refreshed (%d blocks)", #new_entries), vim.log.levels.INFO)
			end)

			-- s = switch session
			map("n", "s", function()
				actions.close(prompt_bufnr)
				pick_session()
			end)

			-- t = toggle parsed / raw
			map("n", "t", function()
				parsed_mode = not parsed_mode
				local new_entries = get_entries()
				local p = action_state.get_current_picker(prompt_bufnr)
				if p then
					p:set_finder(finders.new_table({
						results = new_entries,
						entry_maker = function(e)
							return e
						end,
					}))
				end
				vim.notify(
					string.format("Switched to %s mode (%d blocks)", parsed_mode and "parsed" or "raw", #new_entries),
					vim.log.levels.INFO
				)
			end)

			return true
		end,
	})
	picker:find()
end

-- ── session picker ───────────────────────────────────

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
			local parts = vim.split(proj, "/")
			proj_short = #parts >= 2 and parts[#parts - 1] .. "/" .. parts[#parts] or parts[#parts]
		end
		local display =
			string.format("%-60s %-28s %6s  %d msgs", title, proj_short, format_time(s.time_updated), s.msg_count or 0)
		return {
			value = s,
			display = display,
			ordinal = title .. " " .. proj,
		}
	end

	local picker = pickers.new({}, {
		prompt_title = "Opencode Sessions",
		finder = finders.new_table({
			results = all_sessions,
			entry_maker = make_entry,
		}),
		sorter = conf.generic_sorter({}),
		attach_mappings = function(prompt_bufnr, map)
			actions.select_default:replace(function()
				local selection = action_state.get_selected_entry()
				actions.close(prompt_bufnr)
				if selection and selection.value then
					open_picker(selection.value.id, selection.value.project)
				end
			end)

			map("n", "c", function()
				local cwd = vim.fn.getcwd()
				local filtered = {}
				for _, s in ipairs(all_sessions) do
					if s.project and cwd:find(s.project, 1, true) == 1 then
						table.insert(filtered, s)
					end
				end
				if #filtered == 0 then
					vim.notify("No sessions for current project", vim.log.levels.WARN)
					return
				end
				local p = action_state.get_current_picker(prompt_bufnr)
				if p then
					p:set_finder(finders.new_table({
						results = filtered,
						entry_maker = make_entry,
					}))
				end
			end)

			map("n", "<Esc>", function()
				local p = action_state.get_current_picker(prompt_bufnr)
				if p then
					p:set_finder(finders.new_table({
						results = all_sessions,
						entry_maker = make_entry,
					}))
				end
			end)

			return true
		end,
	})
	picker:find()
end

-- ── entry point ─────────────────────────────────────

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
