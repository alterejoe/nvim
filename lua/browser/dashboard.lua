-- browser/dashboard.lua
-- Scratchbuf-based browser management dashboard.
-- Keymap: <leader>bt
--
-- Primary pane (left): Tab list / toggle views
--   Tabs are sorted under group headers when their URL matches a group's chi_path
--   pattern (e.g. /admin/county/contests/{contestID}/{groupID} matches
--   /admin/county/contests/1/1). No session state required.
--
--   CR        switch to tab in Brave (tabs view) / open group or navigate path (g view)
--   dd+W      close tab in Brave
--   W         apply changes / save groups (g view) / save http contexts (e view)
--   r         refresh tab list / return to tab list from any view
--   p         toggle partial/full, re-navigate
--   t         navigate as partial (htmx)
--   T         navigate as full page
--   :         inline path picker - open/navigate tab (tabs view) / insert path (g view)
--   g         toggle group editor in primary pane (press again to return)
--   e         toggle HTTP multi-context editor in primary pane (press again to return)
--   h         toggle HTML source in primary pane (press again to return)
--
-- Context pane (top right):
--   CR        switch active context
--   o+W       create new context subdir
--   dd+W      delete context subdir (only if empty)
--   r         refresh
--
-- HTTP Preview pane (middle right, editable):
--   W         re-navigate tab under primary cursor
--
-- Help pane (bottom right, readonly).

local M = {}

local _saved_state = {
	tab_cursor = 1,
}

local TITLE = "Browser Tabs"
local CTX_TITLE = "Context"
local PREVIEW_TITLE = "HTTP Preview"
local HELP_TITLE = "Keys"

local PREFIXES = { "GET ", "POST ", "PUT ", "PATCH ", "DELETE " }

local function send_cmd(cmd)
	return require("browser.session").send_cmd(cmd)
end

local function get_base_url()
	local raw = send_cmd("active-server")
	if raw then
		local port = raw:match("port (%d+)")
		if port then
			return "http://localhost:" .. port
		end
	end
	return "http://localhost:3333"
end

local function strip_prefix(line)
	for _, pfx in ipairs(PREFIXES) do
		if vim.startswith(line, pfx) then
			return vim.trim(line:sub(#pfx + 1))
		end
	end
	return vim.trim(line)
end

-- Returns true if tab_path (e.g. /admin/county/contests/1/1?foo=bar)
-- matches chi_path pattern (e.g. /admin/county/contests/{contestID}/{groupID}).
-- Query string is stripped before comparison. {param} segments match any value.
local function path_matches_chi(tab_path, chi_path)
	local path_only = tab_path:match("^([^?#]+)") or tab_path
	-- URL-decode %7B/%7D so encoded braces in tab paths still match
	path_only = path_only:gsub("%%7B", "{"):gsub("%%7D", "}")
	local function segments(s)
		local t = {}
		for seg in s:gmatch("[^/]+") do
			table.insert(t, seg)
		end
		return t
	end
	local t_segs = segments(path_only)
	local c_segs = segments(chi_path)
	if #t_segs ~= #c_segs then
		return false
	end
	for i, c in ipairs(c_segs) do
		if c:sub(1, 1) ~= "{" and c ~= t_segs[i] then
			return false
		end
	end
	return true
end

-- ============================================================
-- Inline floating path picker
-- ============================================================
local function path_picker(items, on_select)
	if #items == 0 then
		vim.notify("browser: no routes found", vim.log.levels.WARN)
		return
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = false

	local width = math.min(72, vim.o.columns - 4)
	local height = math.min(20, vim.o.lines - 6)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " : Navigate  CR=new tab  C-j=replace ",
		title_pos = "center",
	})
	vim.wo[win].cursorline = true

	local query = ""
	local filtered = {}
	local cursor_row = 1

	local function render()
		filtered = {}
		for _, item in ipairs(items) do
			if query == "" or item:lower():find(query:lower(), 1, true) then
				table.insert(filtered, item)
			end
		end
		if #filtered == 0 then
			filtered = vim.deepcopy(items)
		end
		cursor_row = math.min(cursor_row, math.max(#filtered, 1))
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, filtered)
		vim.bo[buf].modifiable = false
		pcall(vim.api.nvim_win_set_cursor, win, { cursor_row, 0 })
		vim.api.nvim_win_set_config(win, {
			title = " /" .. query .. "  CR=new  C-j=replace ",
			title_pos = "center",
		})
		vim.cmd("redraw")
	end

	render()

	while true do
		local ok, ch = pcall(vim.fn.getcharstr)
		if not ok or ch == "\27" then
			pcall(vim.api.nvim_win_close, win, true)
			return
		elseif ch == "\r" then
			local sel = filtered[cursor_row]
			pcall(vim.api.nvim_win_close, win, true)
			if sel then
				on_select(sel, false)
			end
			return
		elseif ch == "\n" then
			local sel = filtered[cursor_row]
			pcall(vim.api.nvim_win_close, win, true)
			if sel then
				on_select(sel, true)
			end
			return
		elseif ch == "\14" or ch == "j" then
			cursor_row = math.min(cursor_row + 1, #filtered)
			pcall(vim.api.nvim_win_set_cursor, win, { cursor_row, 0 })
			vim.cmd("redraw")
		elseif ch == "\16" or ch == "k" then
			cursor_row = math.max(cursor_row - 1, 1)
			pcall(vim.api.nvim_win_set_cursor, win, { cursor_row, 0 })
			vim.cmd("redraw")
		elseif
			ch == "\8"
			or ch == "\127"
			or ch == "\x80kb"
			or ch == "\x80\xfd-"
			or ch:byte(1) == 8
			or ch:byte(1) == 127
		then
			if #query > 0 then
				query = query:sub(1, -2)
				cursor_row = 1
				render()
			end
		elseif #ch == 1 and ch:byte() >= 32 then
			query = query .. ch
			cursor_row = 1
			render()
		end
	end
end

-- ============================================================
-- Parse group editor buffer format into groups table.
-- # groupname / /chi/path lines
-- ============================================================
local function parse_group_buf(lines)
	local gs = {}
	local current = nil
	for _, line in ipairs(lines) do
		local name = line:match("^#%s*(.+)")
		if name then
			name = vim.trim(name)
			current = name
			gs[current] = gs[current] or {}
		elseif current and vim.trim(line) ~= "" then
			table.insert(gs[current], vim.trim(line))
		end
	end
	return gs
end

-- ============================================================
-- M.open
-- ============================================================
function M.open()
	if vim.fn.filereadable(require("browser.session").SOCKET) == 0 then
		vim.notify("browser: devproxy not running", vim.log.levels.WARN)
		return
	end

	-- --------------------------------------------------------
	-- Per-open state
	-- --------------------------------------------------------
	local tab_htmx = {}
	local tab_metadata = {}
	local preview_tab_id = nil
	local _layout = nil
	local _primary_buf = nil
	local _primary_win = nil

	-- "tabs" | "groups" | "http" | "html"
	local view_mode = "tabs"
	-- Toggle between resolved URL path and chi_path template (n key)
	local show_chi_path = true

	-- Populated when e is pressed; maps context name  file path
	local _http_section_paths = {}
	-- Meta and chi_path of the tab that was under the cursor when e was pressed
	local _http_tab_meta = nil
	local _http_chi_path = nil

	-- Infer the chi_path template for a tab whose chi_path isn't explicitly known.
	-- Checks groups first, then all routes from the plan.
	local function infer_chi_path(t)
		if t.chi_path then
			return t.chi_path
		end
		local groups_mod = require("browser.groups")
		local groups = groups_mod.load_groups()
		for _, paths in pairs(groups) do
			for _, cp in ipairs(paths) do
				if path_matches_chi(t.path, cp) then
					return cp
				end
			end
		end
		local routes = require("browser.views").get_routes()
		for _, r in ipairs(routes) do
			if path_matches_chi(t.path, r.chi_path) then
				return r.chi_path
			end
		end
		return nil
	end

	local function make_content(t)
		local short_id = t.id:sub(1, 8)
		local htmx_ann = t.htmx and "  [partial]" or ""
		local display_path
		if show_chi_path then
			display_path = infer_chi_path(t) or t.path
		else
			display_path = t.path
		end
		return display_path .. "  [" .. short_id .. "]" .. htmx_ann
	end

	local function fetch_tabs()
		local raw = send_cmd("sync-tabs")
		if not raw or raw:sub(1, 1) ~= "[" then
			return {}
		end
		local ok, tabs = pcall(vim.json.decode, raw)
		if not ok then
			return {}
		end
		local session = require("browser.session")
		local result = {}
		for _, t in ipairs(tabs) do
			table.insert(result, {
				id = t.id,
				path = t.path or t.id,
				chi_path = session._tab_paths and session._tab_paths[t.id],
				active = t.active,
				htmx = tab_htmx[t.id] or false,
			})
		end
		return result
	end

	-- Build tab lines sorted under group headers.
	-- Matching uses chi_path exact match first, then URL path pattern match
	-- against group chi_path patterns (treating {param} as wildcard segments).
	-- This means group headers appear regardless of session state.
	local function build_tab_lines(tabs)
		local groups_mod = require("browser.groups")
		local groups = groups_mod.load_groups()

		local group_names = {}
		for name in pairs(groups) do
			table.insert(group_names, name)
		end
		table.sort(group_names)

		local tab_to_group = {}
		for _, name in ipairs(group_names) do
			local chi_paths = groups[name] or {}
			for _, t in ipairs(tabs) do
				if not tab_to_group[t.id] then
					-- exact chi_path match
					if t.chi_path then
						for _, cp in ipairs(chi_paths) do
							if t.chi_path == cp then
								tab_to_group[t.id] = name
								break
							end
						end
					end
					-- pattern match against tab URL path
					if not tab_to_group[t.id] then
						for _, cp in ipairs(chi_paths) do
							if path_matches_chi(t.path, cp) then
								tab_to_group[t.id] = name
								break
							end
						end
					end
				end
			end
		end

		local grouped = {}
		local ungrouped = {}
		for _, t in ipairs(tabs) do
			local g = tab_to_group[t.id]
			if g then
				grouped[g] = grouped[g] or {}
				table.insert(grouped[g], t)
			else
				table.insert(ungrouped, t)
			end
		end

		local lines = {}
		local meta = {}

		local function emit(t)
			local content = make_content(t)
			table.insert(lines, "GET " .. content)
			meta[content] = {
				tab_id = t.id,
				path = t.path,
				chi_path = t.chi_path,
				htmx = t.htmx,
				active = t.active,
			}
		end

		local any_groups = false
		for _, name in ipairs(group_names) do
			if grouped[name] and #grouped[name] > 0 then
				any_groups = true
				table.sort(grouped[name], function(a, b)
					return a.path < b.path
				end)
				table.insert(lines, "## " .. name)
				for _, t in ipairs(grouped[name]) do
					emit(t)
				end
			end
		end

		if #ungrouped > 0 then
			table.sort(ungrouped, function(a, b)
				return a.path < b.path
			end)
			if any_groups then
				table.insert(lines, "## ungrouped")
			end
			for _, t in ipairs(ungrouped) do
				emit(t)
			end
		end

		return lines, meta
	end

	local function get_meta(content)
		return tab_metadata[content]
	end

	local function restore_tabs(buf)
		local fresh_tabs = fetch_tabs()
		local fresh_lines, fresh_meta = build_tab_lines(fresh_tabs)
		tab_metadata = fresh_meta
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, fresh_lines)
		vim.bo[buf].filetype = "scratchbuf"
		vim.bo[buf].modified = false
		view_mode = "tabs"
	end

	local function build_context_lines()
		local views = require("browser.views")
		local active = views.get_active_context()
		local names = views.get_contexts()
		local result = {}
		for _, name in ipairs(names) do
			table.insert(result, (name == active and "* " or "  ") .. name)
		end
		return result
	end

	local function build_preview_lines(meta)
		if not meta then
			return { "-- move cursor to a tab --" }
		end
		local views = require("browser.views")
		local chi_path = meta.chi_path or meta.path
		local saved = views.load_test_for_path(chi_path)
		local resolved = meta.path
		local query = ""
		if saved then
			resolved = saved.path or resolved
			query = saved.qp ~= "" and ("?" .. saved.qp) or ""
		end
		local base = get_base_url()
		local host = base:match("//([^/]+)") or "localhost"
		local lines = { "GET " .. resolved .. query .. " HTTP/1.1", "Host: " .. host }
		if meta.htmx then
			table.insert(lines, "HX-Request: true")
		end
		return lines
	end

	local help_lines = {
		"CR switch   dd+W close  W save    r refresh   q/Q close",
		":  paths    p toggle    t partial  T full",
		"g  groups   G  +group   e  http    H  html",
	}

	local function do_buf_refresh(buf)
		local fresh_tabs = fetch_tabs()
		local fresh_lines, fresh_meta = build_tab_lines(fresh_tabs)
		tab_metadata = fresh_meta
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, fresh_lines)
			vim.bo[buf].modified = false
		end
	end

	local function navigate_tab(meta, htmx)
		if not meta then
			return
		end
		tab_htmx[meta.tab_id] = htmx
		send_cmd("switch " .. meta.tab_id)
		if meta.chi_path then
			require("browser.views").do_navigate(meta.chi_path, htmx)
		else
			local base = get_base_url()
			local cmd = htmx and "navigate" or "navigate-full"
			send_cmd(cmd .. " " .. base .. meta.path)
			vim.notify("browser: " .. (htmx and "[partial]" or "[full]") .. " " .. meta.path)
		end
	end

	local function open_path(chi_path, buf)
		-- Switch to existing tab for this chi_path if one exists
		for _, meta in pairs(tab_metadata) do
			if meta.chi_path == chi_path or path_matches_chi(meta.path, chi_path) then
				send_cmd("switch " .. meta.tab_id)
				vim.notify("browser: switched to existing tab -> " .. (meta.path or chi_path))
				return
			end
		end
		local views2 = require("browser.views")
		local base = views2.get_active_base()
		local saved = views2.load_test_for_path(chi_path)
		local path = (saved and saved.path) or chi_path
		local qp = (saved and saved.qp ~= "" and ("?" .. saved.qp)) or ""
		send_cmd("open " .. base .. path .. qp)
		vim.notify("browser: opened tab -> " .. path)
		vim.defer_fn(function()
			if vim.api.nvim_buf_is_valid(buf) then
				do_buf_refresh(buf)
			end
		end, 600)
	end

	-- --------------------------------------------------------
	-- Initial data
	-- --------------------------------------------------------
	local tabs = fetch_tabs()
	if #tabs == 0 then
		vim.notify("browser: no open tabs", vim.log.levels.WARN)
		return
	end

	local tab_lines, meta_init = build_tab_lines(tabs)
	tab_metadata = meta_init

	local ctx_lines = build_context_lines()

	local active_line
	for _, t in ipairs(tabs) do
		if t.active then
			active_line = "GET " .. make_content(t)
			break
		end
	end

	-- --------------------------------------------------------
	-- Open scratchbuf
	-- --------------------------------------------------------
	require("scratchbuf").open({
		title = TITLE,
		lines = tab_lines,
		prefixes = PREFIXES,
		metadata = tab_metadata,
		current = active_line,
		filetype = "scratchbuf",
		close_on_open = false,

		refresh = function()
			local fresh_tabs = fetch_tabs()
			local fresh_lines, fresh_meta = build_tab_lines(fresh_tabs)
			tab_metadata = fresh_meta
			return fresh_lines
		end,

		-- on_open is defined but CR is fully overridden in on_ready to handle
		-- all view modes. This is kept as a no-op fallback.
		on_open = function(_content, _parsed) end,

		on_save = function(changes)
			-- groups view: parse buffer and save groups
			if view_mode == "groups" then
				if not _primary_buf or not vim.api.nvim_buf_is_valid(_primary_buf) then
					return true
				end
				local all_lines = vim.api.nvim_buf_get_lines(_primary_buf, 0, -1, false)
				local gs = parse_group_buf(all_lines)
				require("browser.groups").save_groups(gs)
				vim.notify("browser.groups: saved")
				return true
			end

			-- http view: write context sections back to disk
			if view_mode == "http" then
				if not _primary_buf or not vim.api.nvim_buf_is_valid(_primary_buf) then
					return true
				end
				local all_lines = vim.api.nvim_buf_get_lines(_primary_buf, 0, -1, false)
				local current_ctx = nil
				local current_lines = {}
				local written = {}
				local function flush()
					if not current_ctx then
						return
					end
					local fpath = _http_section_paths[current_ctx]
					if not fpath then
						return
					end
					while #current_lines > 0 and vim.trim(current_lines[#current_lines]) == "" do
						table.remove(current_lines)
					end
					local dir = vim.fn.fnamemodify(fpath, ":h")
					vim.fn.mkdir(dir, "p")
					local f = io.open(fpath, "w")
					if f then
						for _, l in ipairs(current_lines) do
							f:write(l .. "\n")
						end
						f:close()
						table.insert(written, current_ctx)
					else
						vim.notify("browser: cannot write " .. fpath, vim.log.levels.WARN)
					end
				end
				for _, l in ipairs(all_lines) do
					local ctx = l:match("^%-%-%- context: (.+) %-%-%-%s*$")
					if ctx then
						flush()
						current_ctx = ctx
						current_lines = {}
					elseif current_ctx then
						table.insert(current_lines, l)
					end
				end
				flush()
				vim.notify(string.format("browser: saved %d context(s) - navigating", #written))
				-- Navigate the tab using the active context's freshly saved params
				if _http_tab_meta and _http_chi_path then
					send_cmd("switch " .. _http_tab_meta.tab_id)
					require("browser.views").do_navigate(_http_chi_path, _http_tab_meta.htmx or false)
				end
				-- Reset view_mode before scratchbuf's deferred refresh so the
				-- tab list is restored cleanly after navigation settles
				view_mode = "tabs"
				return false
			end

			-- html view: readonly, no-op
			if view_mode == "html" then
				return true
			end

			-- tabs view: scan buffer directly for which tabs remain.
			-- typed_diff positional matching is unreliable when header lines
			-- (## groupname, ## ungrouped) are mixed in - deleting a tab line
			-- at position i causes the line at i in current to be detected as a
			-- rename instead of a delete. Direct scan avoids this entirely.
			if not _primary_buf or not vim.api.nvim_buf_is_valid(_primary_buf) then
				return true
			end
			local buf_lines = vim.api.nvim_buf_get_lines(_primary_buf, 0, -1, false)

			-- Build set of tab IDs still visible in the buffer
			local present_ids = {}
			for _, line in ipairs(buf_lines) do
				local content = strip_prefix(line)
				local meta = tab_metadata[content]
				if meta then
					present_ids[meta.tab_id] = true
				end
			end

			local needs_refresh = false
			local closed_count = 0
			local total_count = 0

			-- Close tabs that were removed from the buffer
			for _, meta in pairs(tab_metadata) do
				total_count = total_count + 1
				if not present_ids[meta.tab_id] then
					send_cmd("close-tab " .. meta.tab_id)
					tab_htmx[meta.tab_id] = nil
					vim.notify("browser: closed " .. meta.path)
					needs_refresh = true
					closed_count = closed_count + 1
				end
			end

			-- If all tabs were deleted open a controlled new tab so the browser
			-- doesn't sit empty or with unmanaged orphan tabs.
			if closed_count > 0 and closed_count >= total_count then
				vim.defer_fn(function()
					send_cmd("open " .. get_base_url())
					vim.notify("browser: all tabs closed - opened new tab")
				end, 400)
			end

			-- Open new tabs for GET lines not in metadata (manually typed by user)
			for _, line in ipairs(buf_lines) do
				if vim.startswith(line, "GET ") then
					local content = strip_prefix(line)
					if not tab_metadata[content] then
						local new_path = vim.trim(content:gsub("%s+%[[%w]+%]", ""):gsub("%s+%[partial%]", ""))
						if new_path ~= "" and new_path:sub(1, 1) == "/" then
							send_cmd("open " .. get_base_url() .. new_path)
							vim.notify("browser: opened tab -> " .. new_path)
							needs_refresh = true
						end
					end
				end
			end

			return not needs_refresh
		end,

		on_cursor = function(line, parsed, layout)
			if not layout then
				return
			end
			if view_mode ~= "tabs" then
				return
			end
			local meta = get_meta(parsed and parsed.content or "")
			if meta then
				preview_tab_id = meta.tab_id
			end
			layout.set(PREVIEW_TITLE, build_preview_lines(meta))
		end,

		right_width = 0.36,
		right = {
			-- Context pane
			{
				title = CTX_TITLE,
				height = 0.20,
				lines = ctx_lines,
				refresh = function()
					return build_context_lines()
				end,
				on_save = function(changes)
					local session = require("browser.session")
					local tests = session.TESTS_DIR
					for _, entry in ipairs(changes.created) do
						local name = vim.trim(entry:gsub("^[%*%s]+", ""))
						if name ~= "" and name ~= "default" then
							vim.fn.mkdir(tests .. "/" .. name, "p")
							vim.notify("browser: created context -> " .. name)
						end
					end
					for _, entry in ipairs(changes.deleted) do
						local name = vim.trim(entry:gsub("^[%*%s]+", ""))
						if name ~= "" and name ~= "default" then
							local dir = tests .. "/" .. name
							local handle = vim.loop.fs_scandir(dir)
							local empty = true
							if handle then
								local n = vim.loop.fs_scandir_next(handle)
								if n then
									empty = false
								end
							end
							if empty then
								vim.loop.fs_rmdir(dir)
								vim.notify("browser: deleted context -> " .. name)
							else
								vim.notify(
									"browser: context '" .. name .. "' has files - delete manually",
									vim.log.levels.WARN
								)
							end
						end
					end
					for _, entry in ipairs(changes.renamed) do
						local old = vim.trim(entry.old:gsub("^[%*%s]+", ""))
						local new = vim.trim(entry.new:gsub("^[%*%s]+", ""))
						if old ~= "" and new ~= "" and old ~= "default" and new ~= "default" then
							vim.loop.fs_rename(tests .. "/" .. old, tests .. "/" .. new)
							local views = require("browser.views")
							if views.get_active_context() == old then
								views.switch_context(new)
							end
							vim.notify("browser: renamed context " .. old .. " -> " .. new)
						end
					end
				end,
				on_open = function(line)
					local name = vim.trim(line:gsub("^[%*%s]+", ""))
					if name == "" then
						return
					end
					require("browser.views").switch_context(name)
					vim.notify("browser: context -> " .. name)
				end,
			},
			-- HTTP Preview pane (editable)
			{
				title = PREVIEW_TITLE,
				height = 0.50,
				lines = { "-- move cursor to a tab --" },
				on_save = function(_changes)
					if not _layout or not preview_tab_id then
						return true
					end
					local lines = _layout.get(PREVIEW_TITLE)
					if not lines or #lines == 0 then
						return true
					end
					local first = vim.trim(lines[1])
					local path_query = first:match("^%u+%s+(/[^%s]*)") or ""
					if path_query == "" then
						vim.notify("browser: could not parse request line", vim.log.levels.WARN)
						return true
					end
					local htmx = false
					for i = 2, #lines do
						if lines[i]:lower():find("hx%-request:%s*true") then
							htmx = true
							break
						end
					end
					local base = get_base_url()
					local cmd = htmx and "navigate" or "navigate-full"
					send_cmd("switch " .. preview_tab_id)
					send_cmd(cmd .. " " .. base .. path_query)
					tab_htmx[preview_tab_id] = htmx
					vim.notify("browser: " .. (htmx and "[partial]" or "[full]") .. " " .. path_query)
					return true
				end,
			},
			-- Help pane (readonly)
			{
				title = HELP_TITLE,
				role = "readonly",
				lines = help_lines,
			},
		},

		on_ready = function(buf, win, layout)
			_layout = layout
			_primary_buf = buf
			_primary_win = win

			if _saved_state.tab_cursor > 1 then
				local total = vim.api.nvim_buf_line_count(buf)
				local row = math.min(_saved_state.tab_cursor, total)
				pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
			end

			vim.api.nvim_create_autocmd("CursorMoved", {
				buffer = buf,
				callback = function()
					if vim.api.nvim_get_current_win() == win then
						_saved_state.tab_cursor = vim.api.nvim_win_get_cursor(win)[1]
					end
				end,
			})

			local function current_meta()
				local raw = vim.api.nvim_get_current_line()
				local content = strip_prefix(raw)
				return get_meta(content)
			end

			local function map(lhs, fn, desc)
				vim.keymap.set("n", lhs, fn, {
					buffer = buf,
					nowait = true,
					noremap = true,
					desc = desc,
				})
			end

			-- CR: handles all view modes
			map("<CR>", function()
				if view_mode == "groups" then
					local line = vim.api.nvim_get_current_line()
					local name = line:match("^#%s*(.+)")
					if name then
						name = vim.trim(name)
						local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
						local gs = parse_group_buf(all_lines)
						local paths = gs[name] or {}
						if #paths == 0 then
							vim.notify("browser.groups: group '" .. name .. "' has no paths", vim.log.levels.WARN)
							return
						end
						restore_tabs(buf)
						require("browser.groups").open_group(name, paths)
					else
						local p = vim.trim(line)
						if p ~= "" and p:sub(1, 1) == "/" then
							require("browser.views").do_navigate(p, false)
						end
					end
					return
				end
				if view_mode == "tabs" then
					local raw = vim.api.nvim_get_current_line()
					local content = strip_prefix(raw)
					local meta = get_meta(content)
					if meta then
						send_cmd("switch " .. meta.tab_id)
					end
				end
				-- html/http: no-op
			end, "Open entry / open group")

			-- r / C-o: always return to tab list and refresh
			map("r", function()
				restore_tabs(buf)
			end, "Refresh / return to tab list")

			map("<C-o>", function()
				restore_tabs(buf)
			end, "Return to tab list")

			-- n: toggle between resolved URL path and chi_path template display
			map("n", function()
				if view_mode ~= "tabs" then
					return
				end
				show_chi_path = not show_chi_path
				do_buf_refresh(buf)
				vim.notify("browser: showing " .. (show_chi_path and "chi_path templates" or "resolved paths"))
			end, "Toggle chi_path / resolved path display")

			-- /: native vim incremental search in all views.
			-- Scratchbuf maps / to its line-filter which crashes when the buffer
			-- is non-modifiable (html view). Override it here so / always hits
			-- vim's built-in search - works correctly with modifiable=false and
			-- gives the standard n/N highlight navigation the user expects.
			map("/", function()
				vim.api.nvim_feedkeys("/", "n", false)
			end, "Search")

			map("p", function()
				local meta = current_meta()
				if not meta then
					vim.notify("browser: tab not found", vim.log.levels.WARN)
					return
				end
				navigate_tab(meta, not meta.htmx)
				vim.defer_fn(function()
					if vim.api.nvim_buf_is_valid(buf) then
						do_buf_refresh(buf)
					end
				end, 400)
			end, "Toggle partial/full")

			map("t", function()
				local meta = current_meta()
				if not meta then
					return
				end
				navigate_tab(meta, true)
				vim.defer_fn(function()
					if vim.api.nvim_buf_is_valid(buf) then
						do_buf_refresh(buf)
					end
				end, 400)
			end, "Navigate partial (htmx)")

			map("T", function()
				local meta = current_meta()
				if not meta then
					return
				end
				navigate_tab(meta, false)
				vim.defer_fn(function()
					if vim.api.nvim_buf_is_valid(buf) then
						do_buf_refresh(buf)
					end
				end, 400)
			end, "Navigate full page")

			-- g: toggle group editor in primary pane
			map("g", function()
				if view_mode == "groups" then
					restore_tabs(buf)
					return
				end
				local groups_mod = require("browser.groups")
				local groups = groups_mod.load_groups()
				local names = {}
				for name in pairs(groups) do
					table.insert(names, name)
				end
				table.sort(names)
				local new_lines = {}
				for _, name in ipairs(names) do
					table.insert(new_lines, "# " .. name)
					for _, p in ipairs(groups[name] or {}) do
						table.insert(new_lines, p)
					end
					table.insert(new_lines, "")
				end
				if #names == 0 then
					table.insert(new_lines, "# new-group")
					table.insert(new_lines, "")
				end
				while #new_lines > 0 and new_lines[#new_lines] == "" do
					table.remove(new_lines)
				end
				vim.bo[buf].modifiable = true
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
				vim.bo[buf].filetype = "scratchbuf"
				vim.bo[buf].modified = false
				view_mode = "groups"
				vim.notify("browser: group editor - W=save  :=add path  CR=open  g/r=back")
			end, "Group editor")

			-- G: add current tab's chi_path to a group (picker, same style as :)
			map("G", function()
				if view_mode ~= "tabs" then
					return
				end
				local meta = current_meta()
				if not meta then
					vim.notify("browser: no tab selected", vim.log.levels.WARN)
					return
				end
				local chi_path = meta.chi_path or meta.path
				local groups_mod = require("browser.groups")
				local groups = groups_mod.load_groups()
				local names = {}
				for name in pairs(groups) do
					table.insert(names, name)
				end
				table.sort(names)
				if #names == 0 then
					vim.notify("browser: no groups defined - use g to create one", vim.log.levels.WARN)
					return
				end
				path_picker(names, function(name, _)
					local gs = groups_mod.load_groups()
					gs[name] = gs[name] or {}
					for _, p in ipairs(gs[name]) do
						if p == chi_path then
							vim.notify("browser: " .. chi_path .. " already in '" .. name .. "'")
							return
						end
					end
					table.insert(gs[name], chi_path)
					groups_mod.save_groups(gs)
					vim.notify("browser: added " .. chi_path .. " to '" .. name .. "'")
					do_buf_refresh(buf)
				end)
			end, "Add tab to group")

			-- e: toggle HTTP multi-context editor in primary pane
			map("e", function()
				if view_mode == "http" then
					restore_tabs(buf)
					return
				end
				local meta = current_meta()
				if not meta then
					vim.notify("browser: no tab selected", vim.log.levels.WARN)
					return
				end
				local chi_path = meta.chi_path or meta.path
				local session = require("browser.session")
				local views = require("browser.views")
				local contexts = views.get_contexts()
				local slug = chi_path:gsub("/$", ""):gsub("^/", ""):gsub("/", "-"):gsub("{", ""):gsub("}", "")

				_http_section_paths = {}
				_http_tab_meta = meta
				_http_chi_path = chi_path
				local sections = {}
				for _, ctx in ipairs(contexts) do
					local fpath
					if ctx == "default" then
						fpath = session.TESTS_DIR .. "/" .. slug .. ".http"
					else
						fpath = session.TESTS_DIR .. "/" .. ctx .. "/" .. slug .. ".http"
					end
					_http_section_paths[ctx] = fpath
					local content_lines = {}
					local f = io.open(fpath, "r")
					if f then
						for line in f:lines() do
							table.insert(content_lines, line)
						end
						f:close()
					end
					table.insert(sections, { context = ctx, lines = content_lines })
				end

				local new_lines = {}
				-- Show which endpoint is being edited
				table.insert(new_lines, "# " .. chi_path)
				table.insert(new_lines, "")
				for i, sec in ipairs(sections) do
					table.insert(new_lines, "--- context: " .. sec.context .. " ---")
					if #sec.lines > 0 then
						for _, l in ipairs(sec.lines) do
							table.insert(new_lines, l)
						end
					else
						-- Template for contexts with no test file yet
						table.insert(new_lines, "query: ")
						table.insert(new_lines, "path: " .. chi_path)
					end
					if i < #sections then
						table.insert(new_lines, "")
					end
				end

				vim.bo[buf].modifiable = true
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
				vim.bo[buf].filetype = "http"
				vim.bo[buf].modified = false
				view_mode = "http"
				vim.notify("browser: http editor - W=save  e/r=back")
			end, "HTTP context editor")

			-- H: toggle HTML source in primary pane
			map("H", function()
				if view_mode == "html" then
					restore_tabs(buf)
					return
				end
				local meta = current_meta()
				if not meta then
					vim.notify("browser: no tab selected", vim.log.levels.WARN)
					return
				end
				local html = send_cmd("page-source " .. meta.tab_id)
				if not html or vim.startswith(html, "err:") then
					vim.notify("browser: " .. (html or "no response"), vim.log.levels.WARN)
					return
				end
				local html_lines = vim.split(html, "\n", { plain = true })
				vim.bo[buf].modifiable = true
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, html_lines)
				vim.bo[buf].filetype = "html"
				vim.bo[buf].modifiable = false
				vim.bo[buf].modified = false
				view_mode = "html"
				vim.notify("browser: html source - H/r/<C-o>=back")
			end, "HTML source viewer")

			-- :: path picker for tab navigation (tabs view), path insertion (groups view),
			-- or attribute insertion compiled from test files (http view)
			map(":", function()
				-- http view: collect all key: value lines from test files as insertable attrs
				if view_mode == "http" then
					local session = require("browser.session")
					local tests = session.TESTS_DIR
					local seen = {}
					local attrs = {}
					local function scan_file(fpath)
						local f = io.open(fpath, "r")
						if not f then
							return
						end
						for line in f:lines() do
							line = vim.trim(line)
							if line ~= "" then
								if not seen[line] then
									seen[line] = true
									table.insert(attrs, line)
								end
								-- Also expose individual query params from query: lines
								local qp = line:match("^query:%s*(.*)")
								if qp then
									for param in qp:gmatch("[^&]+") do
										param = vim.trim(param)
										if param ~= "" and not seen[param] then
											seen[param] = true
											table.insert(attrs, param)
										end
									end
								end
							end
						end
						f:close()
					end
					-- Scan root test dir
					local h = vim.loop.fs_scandir(tests)
					if h then
						while true do
							local name, typ = vim.loop.fs_scandir_next(h)
							if not name then
								break
							end
							if typ == "file" and name:match("%.http$") then
								scan_file(tests .. "/" .. name)
							end
						end
					end
					-- Scan context subdirs
					h = vim.loop.fs_scandir(tests)
					if h then
						while true do
							local name, typ = vim.loop.fs_scandir_next(h)
							if not name then
								break
							end
							if typ == "directory" then
								local sub = vim.loop.fs_scandir(tests .. "/" .. name)
								if sub then
									while true do
										local fname, ftyp = vim.loop.fs_scandir_next(sub)
										if not fname then
											break
										end
										if ftyp == "file" and fname:match("%.http$") then
											scan_file(tests .. "/" .. name .. "/" .. fname)
										end
									end
								end
							end
						end
					end
					table.sort(attrs)
					if #attrs == 0 then
						vim.notify("browser: no test attributes found", vim.log.levels.WARN)
						return
					end
					path_picker(attrs, function(attr, _)
						local lnum = vim.api.nvim_win_get_cursor(win)[1]
						vim.api.nvim_buf_set_lines(buf, lnum, lnum, false, { attr })
						vim.bo[buf].modified = true
						pcall(vim.api.nvim_win_set_cursor, win, { lnum + 1, 0 })
					end)
					return
				end

				local views = require("browser.views")
				local routes = views.get_routes()
				if #routes == 0 then
					vim.notify("browser: no routes found", vim.log.levels.WARN)
					return
				end
				local items = {}
				for _, r in ipairs(routes) do
					table.insert(items, r.chi_path)
				end

				if view_mode == "groups" then
					path_picker(items, function(chi_path, _)
						local lnum = vim.api.nvim_win_get_cursor(win)[1]
						vim.api.nvim_buf_set_lines(buf, lnum, lnum, false, { chi_path })
						vim.bo[buf].modified = true
						pcall(vim.api.nvim_win_set_cursor, win, { lnum + 1, 0 })
					end)
					return
				end

				path_picker(items, function(chi_path, replace_current)
					local session = require("browser.session")
					if vim.fn.filereadable(session.SOCKET) == 0 then
						session.start()
						vim.notify("browser: starting Brave... opening tab in ~7s")
						vim.defer_fn(function()
							open_path(chi_path, buf)
						end, 7000)
						return
					end
					local meta = current_meta()
					if replace_current and meta then
						navigate_tab(meta, meta.htmx)
						views.do_navigate(chi_path, meta.htmx)
						vim.defer_fn(function()
							if vim.api.nvim_buf_is_valid(buf) then
								do_buf_refresh(buf)
							end
						end, 600)
					else
						open_path(chi_path, buf)
					end
				end)
			end, "Path picker / insert attr / insert path")
		end,
	})
end

return M
