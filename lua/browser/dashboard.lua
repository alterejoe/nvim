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

-- Browser dashboard highlight groups - defined once, used in all pane windows
vim.api.nvim_set_hl(0, "BrowserParam", { fg = "#e5a445", bold = true })
vim.api.nvim_set_hl(0, "BrowserPartial", { fg = "#4a9eff", bold = true })
vim.api.nvim_set_hl(0, "BrowserFull", { fg = "#4caf50" })
vim.api.nvim_set_hl(0, "BrowserMethod", { fg = "#56b6c2", bold = true })
vim.api.nvim_set_hl(0, "BrowserGroup", { fg = "#c678dd", bold = true })
vim.api.nvim_set_hl(0, "BrowserTabID", { fg = "#555566" })
-- HTTP response preview
vim.api.nvim_set_hl(0, "BrowserHttp2xx", { fg = "#4caf50", bold = true })
vim.api.nvim_set_hl(0, "BrowserHttp3xx", { fg = "#e5a445", bold = true })
vim.api.nvim_set_hl(0, "BrowserHttp4xx", { fg = "#ff9800", bold = true })
vim.api.nvim_set_hl(0, "BrowserHttp5xx", { fg = "#f44336", bold = true })
vim.api.nvim_set_hl(0, "BrowserHdrKey", { fg = "#56b6c2" })
vim.api.nvim_set_hl(0, "BrowserHdrVal", { fg = "#888899" })
vim.api.nvim_set_hl(0, "BrowserJsonKey", { fg = "#c678dd" })
vim.api.nvim_set_hl(0, "BrowserJsonStr", { fg = "#98c379" })

local function browser_highlights(target_win)
	local function ma(pat, hl, pri)
		pcall(vim.fn.matchadd, hl, pat, pri, -1, { window = target_win })
	end
	ma("{[^}]\\+}", "BrowserParam", 12)
	ma("\\[partial\\]", "BrowserPartial", 13)
	ma("\\[full\\]", "BrowserFull", 13)
	ma("^\\%(GET\\|POST\\|PUT\\|PATCH\\|DELETE\\) ", "BrowserMethod", 11)
	ma("^## .*", "BrowserGroup", 11)
	ma("\\s\\+\\[[0-9A-Fa-f]\\{8\\}\\]", "BrowserTabID", 10)
end

local function preview_highlights(target_win)
	local function ma(pat, hl, pri)
		pcall(vim.fn.matchadd, hl, pat, pri, -1, { window = target_win })
	end
	-- Status line
	ma("^HTTP/[^ ]\\+ [12]\\d\\d", "BrowserHttp2xx", 15)
	ma("^HTTP/[^ ]\\+ 3\\d\\d", "BrowserHttp3xx", 15)
	ma("^HTTP/[^ ]\\+ 4\\d\\d", "BrowserHttp4xx", 15)
	ma("^HTTP/[^ ]\\+ 5\\d\\d", "BrowserHttp5xx", 15)
	-- Header keys (before the colon)
	ma("^[A-Za-z0-9_-]\\+:", "BrowserHdrKey", 12)
	-- Header values (after ": ")
	ma(":\\s\\+\\zs.*$", "BrowserHdrVal", 11)
	-- JSON keys "key":
	ma('"[^"]\\+"\\ze\\s*:', "BrowserJsonKey", 13)
	-- JSON string values
	ma(':\\s*\\zs"[^"]*"', "BrowserJsonStr", 12)
end

-- Module-level html search patterns - global across dashboard opens, usable in any buffer
local _html_patterns = {}
local UUID_PATTERN = [[\v[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}]]

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
-- HTML formatter - tries tidy, prettier, falls back to tag-splitting.
-- Tag-splitting puts each tag on its own line so vim's html indent
-- can handle indentation with gg=G even without external tools.
-- ============================================================
local function format_html(raw)
	if vim.fn.executable("tidy") == 1 then
		local result = vim.fn.system("tidy -indent -quiet -utf8 --show-errors 0 --show-warnings 0 -", raw)
		if vim.v.shell_error <= 1 and result and #result > 0 then
			return result
		end
	end
	if vim.fn.executable("prettier") == 1 then
		local result = vim.fn.system("prettier --parser html 2>/dev/null", raw)
		if vim.v.shell_error == 0 and result and #result > 0 then
			return result
		end
	end
	-- Fallback: split on tag boundaries so there is at least one tag per line,
	-- then vim's html indent plugin handles the rest via gg=G.
	return raw:gsub("><", ">\n<")
end

-- ============================================================
-- Inline floating path picker
-- Modes: insert (typing) and normal (navigate/close).
-- j/k in insert  normal mode. i/a in normal  insert.
-- q/Q in normal  close. CR=new tab, C-j=replace.
-- Fuzzy matching: subsequence score, rg-assisted for large lists.
-- ============================================================
local function path_picker(items, on_select)
	if #items == 0 then
		vim.notify("browser: no items", vim.log.levels.WARN)
		return
	end

	-- Fuzzy score: returns score > 0 if all query chars appear in order in str.
	-- Higher score = better match (consecutive runs, start-of-segment bonuses).
	local function fuzzy_score(str, q)
		if q == "" then
			return 1
		end
		local s = str:lower()
		local qi = 1
		local score = 0
		local last = -1
		for si = 1, #s do
			if s:sub(si, si) == q:sub(qi, qi) then
				if last == si - 1 then
					score = score + 4
				else
					score = score + 1
				end
				if
					si == 1
					or s:sub(si - 1, si - 1) == "/"
					or s:sub(si - 1, si - 1) == "-"
					or s:sub(si - 1, si - 1) == "{"
				then
					score = score + 3
				end
				last = si
				qi = qi + 1
				if qi > #q then
					return score
				end
			end
		end
		return 0 -- not all chars matched
	end

	-- Filter and rank items. Use rg for large lists when available.
	local function filter_items(q)
		if q == "" then
			return vim.deepcopy(items)
		end
		-- rg path: write to tempfile, use rg -i for fast grep pre-filter
		local use_rg = vim.fn.executable("rg") == 1 and #items > 80
		local candidates = items
		if use_rg then
			local tmp = vim.fn.tempname()
			local f = io.open(tmp, "w")
			if f then
				for _, it in ipairs(items) do
					f:write(it .. "\n")
				end
				f:close()
				-- rg with each char of query loosely (chars in order as pattern)
				local pat = table.concat(vim.split(q, "", { plain = true }), ".*")
				local out = vim.fn.system("rg -i --no-line-number " .. vim.fn.shellescape(pat) .. " " .. tmp)
				os.remove(tmp)
				if vim.v.shell_error == 0 and out ~= "" then
					local set = {}
					for _, it in ipairs(items) do
						set[it] = true
					end
					candidates = {}
					for line in out:gmatch("[^\n]+") do
						if set[line] then
							table.insert(candidates, line)
						end
					end
				end
			end
		end
		local scored = {}
		for _, it in ipairs(candidates) do
			local sc = fuzzy_score(it, q:lower())
			if sc > 0 then
				table.insert(scored, { item = it, score = sc })
			end
		end
		table.sort(scored, function(a, b)
			return a.score > b.score
		end)
		local result = {}
		for _, v in ipairs(scored) do
			table.insert(result, v.item)
		end
		return result
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = false

	local width = math.min(76, vim.o.columns - 4)
	local height = math.min(22, vim.o.lines - 6)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " / Navigate  CR=new tab  C-j=replace ",
		title_pos = "center",
	})
	vim.wo[win].cursorline = true
	browser_highlights(win)

	local query = ""
	local filtered = {}
	local cursor_row = 1
	local mode = "insert" -- "insert" | "normal"

	local function update_title()
		local mode_ind = mode == "insert" and "-- INSERT -- /" or "-- NORMAL -- /"
		vim.api.nvim_win_set_config(win, {
			title = " " .. mode_ind .. query .. "  CR=new  C-j=replace ",
			title_pos = "center",
		})
	end

	local function render()
		filtered = filter_items(query)
		if #filtered == 0 then
			filtered = vim.deepcopy(items)
		end
		cursor_row = math.min(cursor_row, math.max(#filtered, 1))
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, filtered)
		vim.bo[buf].modifiable = false
		pcall(vim.api.nvim_win_set_cursor, win, { cursor_row, 0 })
		update_title()
		vim.cmd("redraw")
	end

	render()

	local function close()
		pcall(vim.api.nvim_win_close, win, true)
	end

	local function select(replace)
		local sel = filtered[cursor_row]
		close()
		if sel then
			on_select(sel, replace)
		end
	end

	local function move(delta)
		cursor_row = math.max(1, math.min(cursor_row + delta, #filtered))
		pcall(vim.api.nvim_win_set_cursor, win, { cursor_row, 0 })
		vim.cmd("redraw")
	end

	local function is_backspace(ch)
		local b = ch:byte(1)
		return b == 8 or b == 127 or ch == "\x80kb" or ch == "\x80\xfd-"
	end

	while true do
		local ok, ch = pcall(vim.fn.getcharstr)
		if not ok then
			close()
			return
		end

		if mode == "insert" then
			if ch == "\27" then -- Esc: clear query or close
				if query ~= "" then
					query = ""
					cursor_row = 1
					render()
				else
					close()
					return
				end
			elseif ch == "\r" then
				select(false)
				return
			elseif ch == "\n" then
				select(true)
				return
			elseif ch == "j" or ch == "\14" then
				mode = "normal"
				move(1)
				update_title()
				vim.cmd("redraw")
			elseif ch == "k" or ch == "\16" then
				mode = "normal"
				move(-1)
				update_title()
				vim.cmd("redraw")
			elseif is_backspace(ch) then
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
		else -- normal mode
			if ch == "q" or ch == "Q" or ch == "\27" then
				close()
				return
			elseif ch == "\r" then
				select(false)
				return
			elseif ch == "\n" then
				select(true)
				return
			elseif ch == "j" or ch == "\14" then
				move(1)
				vim.cmd("redraw")
			elseif ch == "k" or ch == "\16" then
				move(-1)
				vim.cmd("redraw")
			elseif ch == "i" or ch == "a" or ch == "/" then
				mode = "insert"
				update_title()
				vim.cmd("redraw")
			elseif ch == "G" then
				cursor_row = #filtered
				pcall(vim.api.nvim_win_set_cursor, win, { cursor_row, 0 })
				vim.cmd("redraw")
			elseif ch == "g" then
				-- peek for second g
				local ok2, ch2 = pcall(vim.fn.getcharstr)
				if ok2 and ch2 == "g" then
					cursor_row = 1
					pcall(vim.api.nvim_win_set_cursor, win, { cursor_row, 0 })
					vim.cmd("redraw")
				end
			elseif #ch == 1 and ch:byte() >= 32 then
				-- any printable char: switch to insert and append
				mode = "insert"
				query = query .. ch
				cursor_row = 1
				render()
			end
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
			local path = vim.trim(line)
			-- Strip leading HTTP method (GET /path  /path) and trailing tab metadata
			path = path:gsub("^%u+%s+", "") -- strip GET/POST/etc prefix
			path = path:gsub("%s+%[%x+%].*$", "") -- strip  [tabid] suffix
			path = path:gsub("%s+%[partial%].*$", "") -- strip [partial] suffix
			path = path:gsub("%s+%[full%].*$", "") -- strip [full] suffix
			path = vim.trim(path)
			if path ~= "" then
				table.insert(gs[current], path)
			end
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

	-- "tabs" | "groups" | "http" | "html" | "console" | "network"
	local view_mode = "tabs"
	-- Toggle between resolved URL path and chi_path template (\ key)
	local show_chi_path = true

	-- Populated when e is pressed; maps context name  file path
	local _http_section_paths = {}
	-- Meta and chi_path of the tab that was under the cursor when e was pressed
	local _http_tab_meta = nil
	local _http_chi_path = nil

	-- HTML view state (reset on each H press)
	local _html_body_lines = nil
	local _html_full_lines = nil
	local _html_show_full = false
	local _html_source_meta = nil

	-- Network view state: entries indexed by line number, response toggle
	local _net_entries = {}
	local _net_show_response = false

	-- Split pane state (S key)
	local _split_win = nil
	local _primary_w = nil
	local _split_buf = nil
	local _split_view = "tabs"
	local _split_meta = {}
	local _split_selected_tab_id = nil -- persists across view switches, like preview_tab_id
	local _split_html_body = nil
	local _split_html_full = nil
	local _split_html_show_full = false
	local _split_html_meta = nil
	local _registered_keymaps = {} -- all map() calls stored here for split copy

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
		local chi = infer_chi_path(t)
		-- Prefer saved test file htmx preference; fall back to live tab state
		local is_partial = t.htmx
		if chi then
			local saved = require("browser.views").load_test_for_path(chi)
			if saved and saved.htmx ~= nil then
				is_partial = saved.htmx
			end
		end
		local htmx_ann = is_partial and "  [partial]" or ""
		local display_path = (show_chi_path and chi) or t.path
		return (display_path or t.path) .. "  [" .. short_id .. "]" .. htmx_ann
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
		"CR switch   dd+W close  W save    r refresh   q back  Q quit",
		":  paths    P toggle    t partial  T full      \\  name",
		"gz groups   +  +group   e  http    H  html",
		"c  console  C  clr-con  n  network N  clr-net",
		"n: v req/res  H: b head  U uuid  A +pat  ? pats",
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
	-- Network / console helpers (must live outside scratchbuf.open table)
	-- --------------------------------------------------------
	local function build_net_preview(entry, show_response)
		-- Strip embedded newlines from a value so nvim_buf_set_lines never errors
		local function s(v)
			return tostring(v):gsub("[\r\n]+", " ")
		end
		local lines = {}
		if show_response then
			table.insert(lines, "HTTP/1.1 " .. s(entry.status or "?"))
			if entry.res_headers then
				for k, v in pairs(entry.res_headers) do
					table.insert(lines, s(k) .. ": " .. s(v))
				end
			end
			local body = entry.res_body or ""
			if body ~= "" then
				table.insert(lines, "")
				local ok, decoded = pcall(vim.json.decode, body)
				if ok then
					local encoded = vim.fn.json_encode(decoded)
					for _, l in ipairs(vim.split(encoded, "\n", { plain = true })) do
						table.insert(lines, l)
					end
				else
					for _, l in ipairs(vim.split(body, "\n", { plain = true })) do
						table.insert(lines, l)
					end
				end
			end
		else
			local method = s(entry.method or "GET")
			local url = s(entry.url or "")
			local path = url:match("https?://[^/]+(/[^%s]*)") or url
			local host = url:match("https?://([^/]+)") or ""
			table.insert(lines, method .. " " .. path .. " HTTP/1.1")
			if host ~= "" then
				table.insert(lines, "Host: " .. host)
			end
			if entry.req_headers then
				for k, v in pairs(entry.req_headers) do
					if k:lower() ~= "host" then
						table.insert(lines, s(k) .. ": " .. s(v))
					end
				end
			end
			local body = entry.req_body or ""
			if body ~= "" then
				table.insert(lines, "")
				for _, l in ipairs(vim.split(body, "\n", { plain = true })) do
					table.insert(lines, l)
				end
			end
		end
		if #lines == 0 then
			table.insert(lines, "-- no " .. (show_response and "response" or "request") .. " data --")
		end
		return lines
	end

	local function build_net_lines(raw)
		_net_entries = {}
		local lines = {}
		local ok, entries = pcall(vim.json.decode, raw)
		if ok and type(entries) == "table" then
			for _, entry in ipairs(entries) do
				local method = entry.method or "?"
				local url = entry.url or "?"
				local path = url:match("https?://[^/]+(/[^%s]*)") or url
				local status = entry.status or ""
				local ct = ""
				if entry.res_headers then
					ct = entry.res_headers["Content-Type"] or entry.res_headers["content-type"] or ""
					ct = ct:match("^([^;]+)") or ct
				end
				local s = status ~= "" and ("[" .. status .. "] ") or ""
				local t = ct ~= "" and ("  " .. ct) or ""
				table.insert(lines, string.format("%s%s %s%s", s, method, path, t))
				_net_entries[#lines] = entry
			end
		else
			for _, l in ipairs(vim.split(raw, "\n", { plain = true })) do
				if vim.trim(l) ~= "" then
					table.insert(lines, l)
				end
			end
		end
		if #lines == 0 then
			lines = { "-- no network entries --" }
		end
		return lines
	end

	local function build_console_lines(raw)
		local lines = {}
		local ok, entries = pcall(vim.json.decode, raw)
		if ok and type(entries) == "table" then
			for _, entry in ipairs(entries) do
				local level = (entry.level or entry.type or "log"):upper()
				local msg = entry.message or entry.text or vim.inspect(entry):gsub("[\r\n]+", " ")
				-- flatten any remaining embedded newlines in the message itself
				msg = tostring(msg):gsub("[\r\n]+", " ")
				table.insert(lines, string.format("[%s] %s", level, msg))
			end
		else
			for _, l in ipairs(vim.split(raw, "\n", { plain = true })) do
				if vim.trim(l) ~= "" then
					table.insert(lines, l)
				end
			end
		end
		if #lines == 0 then
			lines = { "-- no console entries --" }
		end
		return lines
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
			-- In non-tabs views (http/html/groups), return current buffer content
			-- unchanged so on_save triggering a refresh doesn't blow away the view.
			if view_mode ~= "tabs" and _primary_buf and vim.api.nvim_buf_is_valid(_primary_buf) then
				return vim.api.nvim_buf_get_lines(_primary_buf, 0, -1, false)
			end
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
				if _http_tab_meta and _http_chi_path then
					-- Don't switch browser focus - stay in e-view
					require("browser.views").do_navigate(_http_chi_path, _http_tab_meta.htmx or false)
					-- Show response in preview pane after request settles
					vim.defer_fn(function()
						if not _layout then
							return
						end
						local raw = send_cmd("netlog")
						if not raw or vim.startswith(raw, "err:") then
							return
						end
						local ok, entries = pcall(vim.json.decode, raw)
						if ok and type(entries) == "table" and #entries > 0 then
							local last = entries[#entries]
							local preview = build_net_preview(last, true)
							_layout.set(PREVIEW_TITLE, preview)
						end
					end, 900)
				end
				return true
			end

			-- html view: readonly, no-op
			if view_mode == "html" then
				return true
			end

			-- console/network views: readonly, no-op
			if view_mode == "console" or view_mode == "network" then
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

			-- Open new tabs for lines not in metadata (manually typed).
			-- Handles "GET /path", bare "/path", and annotated lines.
			for _, line in ipairs(buf_lines) do
				local trimmed = vim.trim(line)
				if trimmed == "" or trimmed:sub(1, 2) == "##" then
					goto continue
				end
				local content = strip_prefix(trimmed)
				if not tab_metadata[content] then
					local new_path = content
						:gsub("^%u+%s+", "")
						:gsub("%s+%[[%x]+%].*$", "")
						:gsub("%s+%[partial%].*$", "")
						:gsub("%s+%[full%].*$", "")
					new_path = vim.trim(new_path)
					if new_path ~= "" and new_path:sub(1, 1) == "/" then
						send_cmd("open " .. get_base_url() .. new_path)
						vim.notify("browser: opened tab -> " .. new_path)
						needs_refresh = true
					end
				end
				::continue::
			end

			return not needs_refresh
		end,

		on_cursor = function(line, parsed, layout)
			if not layout then
				return
			end
			if view_mode == "network" then
				-- Show request/response for the entry under cursor in the preview pane
				if _primary_win and vim.api.nvim_win_is_valid(_primary_win) then
					local lnum = vim.api.nvim_win_get_cursor(_primary_win)[1]
					local entry = _net_entries[lnum]
					if entry then
						layout.set(PREVIEW_TITLE, build_net_preview(entry, _net_show_response))
					end
				end
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
				close_on_open = false,
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
					local views = require("browser.views")
					views.switch_context(name)
					-- Refresh context pane to show updated * marker
					if _layout then
						_layout.set(CTX_TITLE, build_context_lines())
					end
					-- Navigate the tab under primary cursor using new context params
					-- without switching browser focus to that tab
					if preview_tab_id then
						for _, m in pairs(tab_metadata) do
							if m.tab_id == preview_tab_id then
								local chi = m.chi_path or m.path
								if chi then
									views.do_navigate(chi, m.htmx or false)
								end
								break
							end
						end
					end
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
			browser_highlights(win)
			-- Apply HTTP response highlights to the preview pane window
			vim.schedule(function()
				for _, w in ipairs(vim.api.nvim_list_wins()) do
					local wbuf = vim.api.nvim_win_get_buf(w)
					if vim.b[wbuf] and vim.b[wbuf]._scratchbuf == TITLE and w ~= win then
						local title_ok, conf = pcall(vim.api.nvim_win_get_config, w)
						if title_ok and conf.title then
							local t = type(conf.title) == "string" and conf.title
								or (type(conf.title) == "table" and conf.title[1] and conf.title[1][1])
								or ""
							if t:find(PREVIEW_TITLE, 1, true) then
								preview_highlights(w)
							end
						end
					end
				end
			end)

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
				table.insert(_registered_keymaps, { lhs = lhs, fn = fn, desc = desc })
			end

			-- Split helpers - must be defined before any keymap closures that reference them
			local function is_in_split()
				return _split_win
					and vim.api.nvim_win_is_valid(_split_win)
					and vim.api.nvim_get_current_win() == _split_win
			end

			local function split_current_meta()
				if not (_split_win and vim.api.nvim_win_is_valid(_split_win)) then
					return nil
				end
				local lnum = vim.api.nvim_win_get_cursor(_split_win)[1]
				local raw = vim.api.nvim_buf_get_lines(_split_buf, lnum - 1, lnum, false)[1] or ""
				return _split_meta[strip_prefix(raw)]
			end

			-- Persists the split's selected tab across view switches (like preview_tab_id).
			-- Updated by CursorMoved when split is in tabs view.
			local function split_selected_meta()
				if not _split_selected_tab_id then
					return nil
				end
				for _, m in pairs(_split_meta) do
					if m.tab_id == _split_selected_tab_id then
						return m
					end
				end
				return nil
			end

			local function split_set(lines, ft, readonly)
				if not (vim.api.nvim_buf_is_valid(_split_buf or -1)) then
					return
				end
				vim.bo[_split_buf].modifiable = true
				vim.api.nvim_buf_set_lines(_split_buf, 0, -1, false, lines)
				vim.bo[_split_buf].filetype = ft or "scratchbuf"
				vim.bo[_split_buf].modifiable = not readonly
				vim.bo[_split_buf].modified = false
			end

			local function split_restore_tabs()
				local tabs = fetch_tabs()
				local lines, meta = build_tab_lines(tabs)
				_split_meta = meta
				_split_selected_tab_id = nil
				split_set(lines, "scratchbuf", false)
				_split_view = "tabs"
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
			-- <leader>w: in e-view, run the request with current buffer params using curl
			-- without navigating the browser - nvim stays focused. W saves + navigates.
			map("<leader>w", function()
				if view_mode ~= "http" then
					return
				end
				if not (_http_tab_meta and _http_chi_path) then
					vim.notify("browser: no active http context", vim.log.levels.WARN)
					return
				end
				if _primary_buf and vim.api.nvim_buf_is_valid(_primary_buf) then
					local all_lines = vim.api.nvim_buf_get_lines(_primary_buf, 0, -1, false)
					local in_section = false
					local qp, path = "", nil
					for _, l in ipairs(all_lines) do
						if l:match("^%-%-%- context:") then
							in_section = true
						elseif in_section then
							local label, val = l:match("^([%w%.%-_]+):%s*(.*)")
							if label then
								local low = label:lower()
								if low == "query" then
									qp = vim.trim(val)
								end
								if low == "path" then
									path = vim.trim(val)
								end
							end
						end
					end
					local views = require("browser.views")
					local base = views.get_active_base()
					local resolved = path or _http_chi_path
					local full_url = base .. resolved .. (qp ~= "" and ("?" .. qp) or "")
					local method = _http_tab_meta.htmx and "GET" or "GET"
					local hx_flag = _http_tab_meta.htmx
							and " -H 'HX-Request: true' -H 'HX-Current-URL: " .. full_url .. "'"
						or ""
					vim.notify("browser: " .. method .. " " .. resolved .. (qp ~= "" and ("?" .. qp) or ""))
					local cookie_file = require("browser.session").DEVPROXY_DIR .. "/cookies.txt"
					local cookie_flag = vim.fn.filereadable(cookie_file) == 1
							and (" -b " .. vim.fn.shellescape(cookie_file))
						or ""
					vim.fn.jobstart("curl -siL" .. hx_flag .. cookie_flag .. " " .. vim.fn.shellescape(full_url), {
						stdout_buffered = true,
						on_stdout = function(_, data)
							if not data then
								return
							end
							local all = {}
							for _, l in ipairs(data) do
								if l ~= nil then
									local cleaned = tostring(l):gsub("\r", "")
									table.insert(all, cleaned)
								end
							end
							if #all == 0 then
								return
							end
							-- Split into response blocks (each starts with HTTP/)
							local blocks = {}
							local current = {}
							for _, l in ipairs(all) do
								if l:match("^HTTP/") and #current > 0 then
									table.insert(blocks, current)
									current = {}
								end
								table.insert(current, l)
							end
							if #current > 0 then
								table.insert(blocks, current)
							end
							-- Reverse block order so most recent response is first
							local out = {}
							for i = #blocks, 1, -1 do
								local block = blocks[i]
								-- Drop HTML bodies - stop at blank line followed by HTML
								local in_body = false
								for _, l in ipairs(block) do
									if in_body then
										-- skip HTML content
									elseif l == "" then
										in_body = true
										table.insert(out, l)
									else
										table.insert(out, l)
									end
								end
								if i > 1 then
									table.insert(out, "")
								end
							end
							vim.schedule(function()
								if _layout then
									_layout.set(PREVIEW_TITLE, out)
								end
							end)
						end,
					})
				end
			end, "Navigate without saving (<leader>w)")
			map("q", function()
				restore_tabs(buf)
			end, "Return to tab list")
			map("r", function()
				if is_in_split() then
					if _split_view == "console" then
						local raw = send_cmd("consolelog")
						if raw and not vim.startswith(raw, "err:") then
							split_set(build_console_lines(raw), "text", true)
						end
						vim.notify("browser: split console refreshed")
					elseif _split_view == "network" then
						local raw = send_cmd("netlog")
						if raw and not vim.startswith(raw, "err:") then
							split_set(build_net_lines(raw), "text", true)
						end
						vim.notify("browser: split network refreshed")
					else
						split_restore_tabs()
					end
					return
				end
				if view_mode == "console" then
					local raw = send_cmd("consolelog")
					if raw and not vim.startswith(raw, "err:") then
						local lines = build_console_lines(raw)
						vim.bo[buf].modifiable = true
						vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
						vim.bo[buf].modifiable = false
						vim.bo[buf].modified = false
					end
					vim.notify("browser: console refreshed")
					return
				end
				if view_mode == "network" then
					local raw = send_cmd("netlog")
					if raw and not vim.startswith(raw, "err:") then
						local lines = build_net_lines(raw)
						_net_show_response = false
						vim.bo[buf].modifiable = true
						vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
						vim.bo[buf].modifiable = false
						vim.bo[buf].modified = false
						if _layout then
							_layout.set(PREVIEW_TITLE, { "-- move cursor to a request --" })
						end
					end
					vim.notify("browser: network refreshed")
					return
				end
				restore_tabs(buf)
			end, "Refresh / return to tab list")

			map("<C-o>", function()
				if is_in_split() then
					split_restore_tabs()
					return
				end
				restore_tabs(buf)
			end, "Return to tab list")

			map("<leader>e", function()
				if is_in_split() then
					split_restore_tabs()
					return
				end
				restore_tabs(buf)
			end, "Return to tab list")

			-- s: switch focus between primary and split pane
			map("s", function()
				if not (_split_win and vim.api.nvim_win_is_valid(_split_win)) then
					return
				end
				local cur = vim.api.nvim_get_current_win()
				if cur == _split_win then
					if vim.api.nvim_win_is_valid(win) then
						vim.api.nvim_set_current_win(win)
					end
				else
					vim.api.nvim_set_current_win(_split_win)
				end
			end, "Switch between primary and split pane")
			map("S", function()
				if _split_win and vim.api.nvim_win_is_valid(_split_win) then
					vim.api.nvim_win_close(_split_win, true)
					_split_win = nil
					if _split_buf and vim.api.nvim_buf_is_valid(_split_buf) then
						vim.api.nvim_buf_delete(_split_buf, { force = true })
					end
					_split_buf = nil
					_split_meta = {}
					_split_view = "tabs"
					_split_html_body = nil
					_split_html_full = nil
					if _primary_w and vim.api.nvim_win_is_valid(win) then
						vim.api.nvim_win_set_width(win, _primary_w)
					end
					_primary_w = nil
					if vim.api.nvim_win_is_valid(win) then
						vim.api.nvim_set_current_win(win)
					end
					return
				end
				if not vim.api.nvim_win_is_valid(win) then
					return
				end
				local pos = vim.api.nvim_win_get_position(win)
				local w = vim.api.nvim_win_get_width(win)
				local h = vim.api.nvim_win_get_height(win)
				local half = math.floor(w / 2) - 1
				if half < 10 then
					vim.notify("browser: not enough space to split", vim.log.levels.WARN)
					return
				end
				_primary_w = w
				vim.api.nvim_win_set_width(win, half)
				-- Create an independent buffer for the split (never shares content with primary)
				_split_buf = vim.api.nvim_create_buf(false, true)
				vim.b[_split_buf]._scratchbuf = TITLE
				vim.bo[_split_buf].bufhidden = "wipe"
				vim.bo[_split_buf].swapfile = false
				local tabs = fetch_tabs()
				local lines, smeta = build_tab_lines(tabs)
				_split_meta = smeta
				_split_view = "tabs"
				vim.api.nvim_buf_set_lines(_split_buf, 0, -1, false, lines)
				vim.bo[_split_buf].filetype = "scratchbuf"
				vim.bo[_split_buf].modified = false
				_split_win = vim.api.nvim_open_win(_split_buf, true, {
					relative = "editor",
					row = pos[1],
					col = pos[2] + half + 2,
					width = w - half - 2,
					height = h,
					style = "minimal",
					border = "rounded",
					title = TITLE .. " [S]",
					title_pos = "left",
				})
				vim.wo[_split_win].cursorline = true
				vim.wo[_split_win].number = true
				vim.wo[_split_win].signcolumn = "no"
				vim.wo[_split_win].wrap = false
				vim.wo[_split_win].winhighlight = "Visual:ScratchbufVisual,CursorLine:ScratchbufCursorLine"
				browser_highlights(_split_win)
				-- Apply all registered keymaps to split buf - reliable since we
				-- stored the actual Lua callbacks, not via nvim_buf_get_keymap.
				for _, km in ipairs(_registered_keymaps) do
					pcall(vim.keymap.set, "n", km.lhs, km.fn, {
						buffer = _split_buf,
						nowait = true,
						noremap = true,
						desc = km.desc,
					})
				end
				-- q/Q/Esc/S/C-w in split close only the split, not the whole dashboard
				local function close_split_only()
					if _split_win and vim.api.nvim_win_is_valid(_split_win) then
						vim.api.nvim_win_close(_split_win, true)
					end
					if _split_buf and vim.api.nvim_buf_is_valid(_split_buf) then
						vim.api.nvim_buf_delete(_split_buf, { force = true })
					end
					_split_win = nil
					_split_buf = nil
					_split_meta = {}
					_split_view = "tabs"
					_split_html_body = nil
					_split_html_full = nil
					if _primary_w and vim.api.nvim_win_is_valid(win) then
						vim.api.nvim_win_set_width(win, _primary_w)
					end
					_primary_w = nil
					if vim.api.nvim_win_is_valid(win) then
						vim.api.nvim_set_current_win(win)
					end
				end
				for _, lhs in ipairs({ "q", "<Esc>", "S", "<C-w>" }) do
					vim.keymap.set("n", lhs, close_split_only, { buffer = _split_buf, nowait = true, noremap = true })
				end
				vim.api.nvim_create_autocmd("ModeChanged", {
					buffer = _split_buf,
					callback = function()
						if not vim.api.nvim_win_is_valid(_split_win) then
							return
						end
						local mode = vim.api.nvim_get_mode().mode
						vim.wo[_split_win].winhighlight = (mode == "v" or mode == "\22")
								and "Visual:ScratchbufVisual,CursorLine:ScratchbufCursorLineV"
							or "Visual:ScratchbufVisual,CursorLine:ScratchbufCursorLine"
					end,
				})
				-- Track which tab is selected in the split (persists across view switches)
				vim.api.nvim_create_autocmd("CursorMoved", {
					buffer = _split_buf,
					callback = function()
						if _split_view ~= "tabs" then
							return
						end
						if
							not (vim.api.nvim_win_is_valid(_split_win) and vim.api.nvim_get_current_win() == _split_win)
						then
							return
						end
						local lnum = vim.api.nvim_win_get_cursor(_split_win)[1]
						local raw = vim.api.nvim_buf_get_lines(_split_buf, lnum - 1, lnum, false)[1] or ""
						local m = _split_meta[strip_prefix(raw)]
						if m then
							_split_selected_tab_id = m.tab_id
						end
					end,
				})
				-- Close split when the dashboard closes (q/Q/<Esc> etc.)
				vim.api.nvim_create_autocmd("BufWipeout", {
					buffer = buf,
					once = true,
					callback = function()
						vim.schedule(function()
							if _split_win and vim.api.nvim_win_is_valid(_split_win) then
								vim.api.nvim_win_close(_split_win, true)
							end
							if _split_buf and vim.api.nvim_buf_is_valid(_split_buf) then
								vim.api.nvim_buf_delete(_split_buf, { force = true })
							end
							_split_win = nil
							_split_buf = nil
						end)
					end,
				})
			end, "Toggle split pane")

			-- <C-w> / <C-w>l / <C-w>h: close split if open (when in split), else close dashboard.
			local function _close_dashboard()
				vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("q", true, false, true), "m", false)
			end
			local function _close_or_split()
				if _split_win and vim.api.nvim_win_is_valid(_split_win) then
					local cur = vim.api.nvim_get_current_win()
					if cur == _split_win then
						-- Close just the split, return focus to primary
						vim.api.nvim_win_close(_split_win, true)
						_split_win = nil
						if _split_buf and vim.api.nvim_buf_is_valid(_split_buf) then
							vim.api.nvim_buf_delete(_split_buf, { force = true })
							_split_buf = nil
							_split_html_body = nil
							_split_html_full = nil
						end
						if _primary_w and vim.api.nvim_win_is_valid(win) then
							vim.api.nvim_win_set_width(win, _primary_w)
						end
						_primary_w = nil
						if vim.api.nvim_win_is_valid(win) then
							vim.api.nvim_set_current_win(win)
						end
						return
					end
				end
				_close_dashboard()
			end
			vim.keymap.set(
				"n",
				"<C-w>",
				_close_or_split,
				{ buffer = buf, nowait = false, noremap = true, desc = "Close split or dashboard" }
			)
			map("<C-w>l", _close_or_split, "Close dashboard (move right)")
			map("<C-w>h", _close_or_split, "Close dashboard (move left)")
			map("<C-w>j", _close_or_split, "Close dashboard (move down)")
			map("<C-w>k", _close_or_split, "Close dashboard (move up)")

			-- \: toggle between resolved URL path and chi_path template display
			map("\\", function()
				if view_mode ~= "tabs" then
					return
				end
				show_chi_path = not show_chi_path
				do_buf_refresh(buf)
				vim.notify("browser: showing " .. (show_chi_path and "chi_path templates" or "resolved paths"))
			end, "Toggle chi_path / resolved path display")

			-- c: toggle console log - split-aware
			map("c", function()
				if is_in_split() then
					if _split_view == "console" then
						split_restore_tabs()
						return
					end
					local meta = split_selected_meta()
					local tab_arg = meta and (" " .. meta.tab_id) or ""
					local raw = send_cmd("consolelog" .. tab_arg)
					if not raw or vim.startswith(raw, "err:") then
						vim.notify("browser: " .. (raw or "no response"), vim.log.levels.WARN)
						return
					end
					split_set(build_console_lines(raw), "text", true)
					_split_view = "console"
					vim.notify("browser: split console - C=clear  r=refresh  c/r=back")
					return
				end
				if view_mode == "console" then
					restore_tabs(buf)
					return
				end
				local raw = send_cmd("consolelog")
				if not raw or vim.startswith(raw, "err:") then
					vim.notify("browser: " .. (raw or "no response"), vim.log.levels.WARN)
					return
				end
				local lines = build_console_lines(raw)
				vim.bo[buf].filetype = "text"
				vim.bo[buf].modifiable = true
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
				vim.bo[buf].modifiable = false
				vim.bo[buf].modified = false
				view_mode = "console"
				vim.notify("browser: console log - C=clear  r=refresh  c/<C-o>=back")
			end, "Console log")

			-- C: clear console log - split-aware
			map("C", function()
				if is_in_split() then
					if _split_view ~= "tabs" and _split_view ~= "console" then
						return
					end
					send_cmd("consoleclear")
					vim.notify("browser: split console cleared")
					if _split_view == "console" then
						split_set({ "-- console cleared --" }, "text", true)
					end
					return
				end
				if view_mode ~= "tabs" and view_mode ~= "console" then
					return
				end
				send_cmd("consoleclear")
				vim.notify("browser: console log cleared")
				if view_mode == "console" then
					vim.bo[buf].modifiable = true
					vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "-- console cleared --" })
					vim.bo[buf].modifiable = false
					vim.bo[buf].modified = false
				end
			end, "Clear console log")

			-- n: toggle network log - split-aware
			map("n", function()
				if is_in_split() then
					if _split_view == "network" then
						split_restore_tabs()
						return
					end
					local meta = split_selected_meta()
					local tab_arg = meta and (" " .. meta.tab_id) or ""
					local raw = send_cmd("netlog" .. tab_arg)
					if not raw or vim.startswith(raw, "err:") then
						vim.notify("browser: " .. (raw or "no response"), vim.log.levels.WARN)
						return
					end
					_net_show_response = false
					split_set(build_net_lines(raw), "text", true)
					_split_view = "network"
					vim.notify("browser: split network - R=req/res  N=clear  r=refresh  n/r=back")
					return
				end
				if view_mode == "network" then
					restore_tabs(buf)
					return
				end
				local raw = send_cmd("netlog")
				if not raw or vim.startswith(raw, "err:") then
					vim.notify("browser: " .. (raw or "no response"), vim.log.levels.WARN)
					return
				end
				_net_show_response = false
				local lines = build_net_lines(raw)
				vim.bo[buf].filetype = "text"
				vim.bo[buf].modifiable = true
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
				vim.bo[buf].modifiable = false
				vim.bo[buf].modified = false
				if _layout then
					_layout.set(PREVIEW_TITLE, { "-- move cursor to a request --" })
				end
				view_mode = "network"
				vim.notify("browser: network log - R=req/res  N=clear  r=refresh  n/<C-o>=back")
			end, "Network log")

			-- N: clear network log - split-aware
			map("N", function()
				if is_in_split() then
					if _split_view ~= "tabs" and _split_view ~= "network" then
						return
					end
					send_cmd("netclear")
					vim.notify("browser: split network cleared")
					if _split_view == "network" then
						_net_entries = {}
						split_set({ "-- network log cleared --" }, "text", true)
					end
					return
				end
				if view_mode ~= "tabs" and view_mode ~= "network" then
					return
				end
				send_cmd("netclear")
				vim.notify("browser: network log cleared")
				if view_mode == "network" then
					_net_entries = {}
					vim.bo[buf].modifiable = true
					vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "-- network log cleared --" })
					vim.bo[buf].modifiable = false
					vim.bo[buf].modified = false
					if _layout then
						_layout.set(PREVIEW_TITLE, { "-- network cleared --" })
					end
				end
			end, "Clear network log")

			-- R: toggle request / response in network preview pane
			map("R", function()
				if view_mode ~= "network" then
					return
				end
				_net_show_response = not _net_show_response
				if _primary_win and vim.api.nvim_win_is_valid(_primary_win) then
					local lnum = vim.api.nvim_win_get_cursor(_primary_win)[1]
					local entry = _net_entries[lnum]
					if entry and _layout then
						_layout.set(PREVIEW_TITLE, build_net_preview(entry, _net_show_response))
					end
				end
				vim.notify("browser: " .. (_net_show_response and "response" or "request") .. " preview")
			end, "Toggle request/response preview")

			-- /: native vim incremental search in all views.
			-- Scratchbuf maps / to its line-filter which crashes when the buffer
			-- is non-modifiable (html view). Override it here so / always hits
			-- vim's built-in search - works correctly with modifiable=false and
			-- gives the standard n/N highlight navigation the user expects.
			map("/", function()
				vim.api.nvim_feedkeys("/", "n", false)
			end, "Search")

			map("P", function()
				if view_mode ~= "tabs" then
					return
				end
				local meta = current_meta()
				if not meta then
					vim.notify("browser: tab not found", vim.log.levels.WARN)
					return
				end
				local new_htmx = not meta.htmx
				navigate_tab(meta, new_htmx)
				local chi = infer_chi_path(meta) or meta.chi_path or meta.path
				if chi then
					require("browser.views").save_htmx_for_path(chi, new_htmx)
				end
				vim.defer_fn(function()
					if vim.api.nvim_buf_is_valid(buf) then
						do_buf_refresh(buf)
					end
				end, 400)
			end, "Toggle partial/full")

			map("t", function()
				if view_mode ~= "tabs" then
					return
				end
				local meta = current_meta()
				if not meta then
					return
				end
				navigate_tab(meta, true)
				local chi = infer_chi_path(meta) or meta.chi_path or meta.path
				if chi then
					require("browser.views").save_htmx_for_path(chi, true)
				end
				vim.defer_fn(function()
					if vim.api.nvim_buf_is_valid(buf) then
						do_buf_refresh(buf)
					end
				end, 400)
			end, "Navigate partial (htmx)")

			map("T", function()
				if view_mode ~= "tabs" then
					return
				end
				local meta = current_meta()
				if not meta then
					return
				end
				navigate_tab(meta, false)
				local chi = infer_chi_path(meta) or meta.chi_path or meta.path
				if chi then
					require("browser.views").save_htmx_for_path(chi, false)
				end
				vim.defer_fn(function()
					if vim.api.nvim_buf_is_valid(buf) then
						do_buf_refresh(buf)
					end
				end, 400)
			end, "Navigate full page")

			-- gg: explicit binding so it works even with g mapped below
			-- gg is native now that g has no mapping

			-- <M-g>: toggle group editor
			local _g_fn = function()
				if view_mode == "groups" then
					restore_tabs(buf)
					return
				end
				if view_mode ~= "tabs" then
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
				vim.notify("browser: group editor - W=save  :=add path  CR=open  gz/r=back")
			end
			-- gz: group editor - z is not mapped so gz completes cleanly
			vim.keymap.set("n", "gz", _g_fn, { buffer = buf, nowait = true, noremap = true, desc = "Group editor" })
			table.insert(_registered_keymaps, { lhs = "gz", fn = _g_fn, desc = "Group editor" })

			-- +: add current tab's chi_path to a group (was G, freed for last-line motion)
			map("+", function()
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
				if is_in_split() then
					if _split_view == "http" then
						split_restore_tabs()
						return
					end
					local meta = split_selected_meta()
					if not meta then
						vim.notify("browser: no tab selected", vim.log.levels.WARN)
						return
					end
					local chi_path = meta.chi_path or meta.path
					do
						local routes = require("browser.views").get_routes()
						for _, r in ipairs(routes) do
							if path_matches_chi(meta.path, r.chi_path) then
								chi_path = r.chi_path
								break
							end
						end
					end
					local session = require("browser.session")
					local contexts = require("browser.views").get_contexts()
					local lines = { "# " .. chi_path }
					for _, ctx in ipairs(contexts) do
						local saved = require("browser.views").load_test_for_path(chi_path)
						table.insert(lines, "--- context: " .. ctx .. " ---")
						if saved then
							table.insert(lines, "query: " .. (saved.qp or ""))
							table.insert(lines, "path: " .. (saved.path or chi_path))
						else
							table.insert(lines, "query: ")
							table.insert(lines, "path: " .. chi_path)
						end
					end
					split_set(lines, "http", false)
					_split_view = "http"
					vim.notify("browser: split http - e/r=back")
					return
				end
				if view_mode == "http" then
					restore_tabs(buf)
					return
				end
				local meta = current_meta()
				if not meta then
					for _, m in pairs(tab_metadata) do
						if m.tab_id == preview_tab_id then
							meta = m
							break
						end
					end
				end
				if not meta then
					vim.notify("browser: no tab selected", vim.log.levels.WARN)
					return
				end
				local chi_path = meta.chi_path or meta.path
				do
					local routes = require("browser.views").get_routes()
					for _, r in ipairs(routes) do
						if path_matches_chi(meta.path, r.chi_path) then
							chi_path = r.chi_path
							break
						end
					end
				end
				local session = require("browser.session")
				local views = require("browser.views")
				local contexts = views.get_contexts()
				local slug = chi_path:gsub("/$", ""):gsub("^/", ""):gsub("/", "-"):gsub("{", ""):gsub("}", "")

				_http_section_paths = {}
				_http_tab_meta = meta
				_http_chi_path = chi_path
				local function find_http_file(cp, ctx)
					local function make_path(c)
						local s = c:gsub("/$", ""):gsub("^/", ""):gsub("/", "-"):gsub("{", ""):gsub("}", "")
						if ctx and ctx ~= "default" and ctx ~= "" then
							return session.TESTS_DIR .. "/" .. ctx .. "/" .. s .. ".http"
						else
							return session.TESTS_DIR .. "/" .. s .. ".http"
						end
					end
					local p = make_path(cp)
					if vim.fn.filereadable(p) == 1 then
						return p
					end
					local routes = require("browser.views").get_routes()
					local cp_segs = {}
					for s in cp:gmatch("[^/]+") do
						table.insert(cp_segs, s)
					end
					for _, r in ipairs(routes) do
						if r.chi_path ~= cp then
							local r_segs = {}
							for s in r.chi_path:gmatch("[^/]+") do
								table.insert(r_segs, s)
							end
							if #r_segs == #cp_segs then
								local same = true
								for i, cs in ipairs(cp_segs) do
									local rs = r_segs[i]
									local c_p = cs:sub(1, 1) == "{"
									local r_p = rs:sub(1, 1) == "{"
									if c_p ~= r_p or (not c_p and cs ~= rs) then
										same = false
										break
									end
								end
								if same then
									local alt = make_path(r.chi_path)
									if vim.fn.filereadable(alt) == 1 then
										return alt
									end
								end
							end
						end
					end
					return p
				end
				local sections = {}
				for _, ctx in ipairs(contexts) do
					local fpath = find_http_file(chi_path, ctx)
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
				table.insert(new_lines, "# " .. chi_path)
				table.insert(new_lines, "")
				for i, sec in ipairs(sections) do
					table.insert(new_lines, "--- context: " .. sec.context .. " ---")
					if #sec.lines > 0 then
						for _, l in ipairs(sec.lines) do
							table.insert(new_lines, l)
						end
					else
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

			-- H: toggle HTML source - split-aware
			map("H", function()
				if is_in_split() then
					if _split_view == "html" then
						split_restore_tabs()
						return
					end
					local meta = split_selected_meta()
					local body = send_cmd("page-source-body " .. meta.tab_id)
					if not body or vim.startswith(body, "err:") then
						vim.notify("browser: " .. (body or "no response"), vim.log.levels.WARN)
						return
					end
					_split_html_body = vim.split(format_html(body), "\n", { plain = true })
					_split_html_full = nil
					_split_html_show_full = false
					_split_html_meta = meta
					split_set(_split_html_body, "html", true)
					_split_view = "html"
					vim.notify("browser: split html - b=head  U=uuid  H/r=back")
					return
				end
				if view_mode == "html" then
					restore_tabs(buf)
					return
				end
				-- When not in tabs view, cursor isn't on a tab line - use last known tab
				local meta = current_meta()
				if not meta then
					for _, m in pairs(tab_metadata) do
						if m.tab_id == preview_tab_id then
							meta = m
							break
						end
					end
				end
				if not meta then
					vim.notify("browser: no tab selected", vim.log.levels.WARN)
					return
				end
				local body = send_cmd("page-source-body " .. meta.tab_id)
				if not body or vim.startswith(body, "err:") then
					vim.notify("browser: " .. (body or "no response"), vim.log.levels.WARN)
					return
				end
				local html_lines = vim.split(format_html(body), "\n", { plain = true })
				_html_body_lines = html_lines
				_html_full_lines = nil
				_html_show_full = false
				_html_source_meta = meta
				vim.bo[buf].modifiable = true
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, html_lines)
				vim.bo[buf].filetype = "html"
				vim.bo[buf].modifiable = false
				vim.bo[buf].modified = false
				view_mode = "html"
				vim.notify("browser: html body - b=head  U=uuid  A=+pat  ?=patterns  H/r/<C-o>=back")
			end, "HTML source viewer")

			-- b: body/head toggle (html view) OR bg: group editor.
			-- getchar(0) is non-blocking - peeks at already-pending input.
			-- b: body/head toggle (html view only). gz for groups via g keymap.
			local _b_fn = function()
				if is_in_split() then
					if _split_view ~= "html" then
						return
					end
					local lines
					if _split_html_show_full then
						_split_html_show_full = false
						lines = _split_html_body or { "-- no body --" }
					else
						if not _split_html_full and _split_html_meta then
							local full = send_cmd("page-source " .. _split_html_meta.tab_id)
							if full and not vim.startswith(full, "err:") then
								_split_html_full = vim.split(format_html(full), "\n", { plain = true })
							end
						end
						_split_html_show_full = true
						lines = _split_html_full or { "-- no full html --" }
					end
					split_set(lines, "html", true)
					return
				end
				if view_mode ~= "html" then
					return
				end
				local lines
				if _html_show_full then
					_html_show_full = false
					lines = _html_body_lines or { "-- no body --" }
					vim.notify("browser: html body view")
				else
					if not _html_full_lines and _html_source_meta then
						local full = send_cmd("page-source " .. _html_source_meta.tab_id)
						if full and not vim.startswith(full, "err:") then
							_html_full_lines = vim.split(format_html(full), "\n", { plain = true })
						end
					end
					_html_show_full = true
					lines = _html_full_lines or { "-- no full html --" }
					vim.notify("browser: html full page - b=back to body")
				end
				vim.bo[buf].modifiable = true
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
				vim.bo[buf].modifiable = false
				vim.bo[buf].modified = false
			end
			map("b", _b_fn, "Toggle body / full HTML")

			-- U: jump to next UUID in html view (u is left free for native undo)
			map("U", function()
				local in_html = view_mode == "html" or (is_in_split() and _split_view == "html")
				if not in_html then
					return
				end
				local found = vim.fn.search(UUID_PATTERN, "w")
				if found == 0 then
					vim.notify("browser: no UUID found", vim.log.levels.INFO)
				end
			end, "Next UUID")

			-- A: add a named vim-regex pattern to the global html pattern list
			map("A", function()
				if view_mode ~= "html" then
					return
				end
				vim.ui.input({ prompt = "Pattern name: " }, function(name)
					if not name or name == "" then
						return
					end
					vim.ui.input({ prompt = "Vim regex: " }, function(pat)
						if not pat or pat == "" then
							return
						end
						table.insert(_html_patterns, { name = name, pattern = pat })
						vim.notify("browser: pattern '" .. name .. "' added - ? to search")
					end)
				end)
			end, "Add html search pattern")

			-- ?: inline pattern picker - same style as : picker
			map("?", function()
				if view_mode ~= "html" then
					return
				end
				if #_html_patterns == 0 then
					vim.notify("browser: no patterns - use A to add one", vim.log.levels.WARN)
					return
				end
				local items = {}
				for _, p in ipairs(_html_patterns) do
					table.insert(items, p.name .. "  " .. p.pattern)
				end
				path_picker(items, function(sel, _)
					for _, p in ipairs(_html_patterns) do
						if (p.name .. "  " .. p.pattern) == sel then
							vim.fn.search(p.pattern)
							break
						end
					end
				end)
			end, "Pattern picker")

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
				-- Annotate each route with [partial] or [full] from its saved test file
				local items = {}
				for _, r in ipairs(routes) do
					local saved = views.load_test_for_path(r.chi_path)
					local ann = (saved and saved.htmx == true) and "  [partial]" or "  [full]"
					table.insert(items, r.chi_path .. ann)
				end
				-- Strip annotation to recover the bare chi_path
				local function strip_ann(s)
					return s:match("^(.-)%s+%[") or s
				end

				if view_mode == "groups" then
					path_picker(items, function(sel, _)
						local chi_path = strip_ann(sel)
						local lnum = vim.api.nvim_win_get_cursor(win)[1]
						vim.api.nvim_buf_set_lines(buf, lnum, lnum, false, { chi_path })
						vim.bo[buf].modified = true
						pcall(vim.api.nvim_win_set_cursor, win, { lnum + 1, 0 })
					end)
					return
				end

				path_picker(items, function(sel, replace_current)
					local chi_path = strip_ann(sel)
					local session = require("browser.session")
					if vim.fn.filereadable(session.SOCKET) == 0 then
						session.start()
						vim.notify("browser: starting Brave... opening tab in ~7s")
						vim.defer_fn(function()
							open_path(chi_path, buf)
						end, 7000)
						return
					end
					-- Use saved htmx preference if available
					local saved = views.load_test_for_path(chi_path)
					local use_htmx = saved and saved.htmx ~= nil and saved.htmx or false
					local meta = current_meta()
					if replace_current and meta then
						navigate_tab(meta, use_htmx)
						views.do_navigate(chi_path, use_htmx)
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

-- Expose html pattern list for global <leader>ha keymap in browser.lua
function M.get_patterns()
	return _html_patterns
end

return M
