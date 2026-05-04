-- browser/dashboard/util.lua
-- Stateless utilities shared across all dashboard modules.
-- No state, no side effects beyond vim highlight registration on load.

local M = {}

-- ============================================================
-- Constants
-- ============================================================
M.TITLE = "Browser Tabs"
M.CTX_TITLE = "Context"
M.PREVIEW_TITLE = "HTTP Preview"
M.HELP_TITLE = "Keys"
M.PREFIXES = { "GET ", "POST ", "PUT ", "PATCH ", "DELETE " }

-- ============================================================
-- Highlight groups - registered once at module load
-- ============================================================
vim.api.nvim_set_hl(0, "BrowserParam", { fg = "#e5a445", bold = true })
vim.api.nvim_set_hl(0, "BrowserPartial", { fg = "#4a9eff", bold = true })
vim.api.nvim_set_hl(0, "BrowserFull", { fg = "#4caf50" })
vim.api.nvim_set_hl(0, "BrowserMethod", { fg = "#56b6c2", bold = true })
vim.api.nvim_set_hl(0, "BrowserGroup", { fg = "#c678dd", bold = true })
vim.api.nvim_set_hl(0, "BrowserHeading", { fg = "#e06c75", bold = true, italic = true })
vim.api.nvim_set_hl(0, "BrowserTabID", { fg = "#555566" })
vim.api.nvim_set_hl(0, "BrowserHttp2xx", { fg = "#4caf50", bold = true })
vim.api.nvim_set_hl(0, "BrowserHttp3xx", { fg = "#e5a445", bold = true })
vim.api.nvim_set_hl(0, "BrowserHttp4xx", { fg = "#ff9800", bold = true })
vim.api.nvim_set_hl(0, "BrowserHttp5xx", { fg = "#f44336", bold = true })
vim.api.nvim_set_hl(0, "BrowserHdrKey", { fg = "#56b6c2" })
vim.api.nvim_set_hl(0, "BrowserHdrVal", { fg = "#888899" })
vim.api.nvim_set_hl(0, "BrowserTag", { fg = "#e06c75", italic = true })
vim.api.nvim_set_hl(0, "BrowserJsonKey", { fg = "#c678dd" })
vim.api.nvim_set_hl(0, "BrowserJsonStr", { fg = "#98c379" })

function M.browser_highlights(target_win)
	local function ma(pat, hl, pri)
		pcall(vim.fn.matchadd, hl, pat, pri, -1, { window = target_win })
	end
	ma("^###\\s\\+.*", "BrowserHeading", 14)
	ma("{[^}]\\+}", "BrowserParam", 12)
	ma("\\[partial\\]", "BrowserPartial", 13)
	ma("\\[full\\]", "BrowserFull", 13)
	ma("^\\%(GET\\|POST\\|PUT\\|PATCH\\|DELETE\\) ", "BrowserMethod", 11)
	ma("^## .*", "BrowserGroup", 11)
	ma("\\s\\+\\[[0-9A-Fa-f]\\{8\\}\\]", "BrowserTabID", 10)
	ma("\\s\\+\\[\\a\\w*\\]", "BrowserTag", 11)
end

function M.preview_highlights(target_win)
	local function ma(pat, hl, pri)
		pcall(vim.fn.matchadd, hl, pat, pri, -1, { window = target_win })
	end
	ma("^HTTP/[^ ]\\+ [12]\\d\\d", "BrowserHttp2xx", 15)
	ma("^HTTP/[^ ]\\+ 3\\d\\d", "BrowserHttp3xx", 15)
	ma("^HTTP/[^ ]\\+ 4\\d\\d", "BrowserHttp4xx", 15)
	ma("^HTTP/[^ ]\\+ 5\\d\\d", "BrowserHttp5xx", 15)
	ma("^[A-Za-z0-9_-]\\+:", "BrowserHdrKey", 12)
	ma(":\\s\\+\\zs.*$", "BrowserHdrVal", 11)
	ma('"[^"]\\+"\\ze\\s*:', "BrowserJsonKey", 13)
	ma(':\\s*\\zs"[^"]*"', "BrowserJsonStr", 12)
end

-- ============================================================
-- strip_prefix
-- Strips a leading HTTP method prefix (e.g. "GET ") from a line.
-- ============================================================
function M.strip_prefix(line)
	for _, pfx in ipairs(M.PREFIXES) do
		if vim.startswith(line, pfx) then
			return vim.trim(line:sub(#pfx + 1))
		end
	end
	return vim.trim(line)
end

-- ============================================================
-- path_matches_chi
-- Returns true if tab_path matches a chi_path template.
-- {param} segments match any concrete value.
-- Query string is stripped before comparison.
-- URL-encoded braces (%7B/%7D) in tab_path are normalised first.
-- ============================================================
function M.path_matches_chi(tab_path, chi_path)
	local path_only = tab_path:match("^([^?#]+)") or tab_path
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
-- segs
-- Splits a path into segments, stripping query string.
-- Shared by tabops and httpops for param extraction.
-- ============================================================
function M.segs(s)
	local t = {}
	for seg in s:gsub("?.*$", ""):gmatch("[^/]+") do
		table.insert(t, seg)
	end
	return t
end

-- ============================================================
-- format_html
-- Tries tidy then prettier, falls back to tag-splitting so that
-- vim's html indent plugin can handle gg=G without external tools.
-- ============================================================
function M.format_html(raw)
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
	return raw:gsub("><", ">\n<")
end

-- ============================================================
-- parse_group_buf
-- Parses group editor buffer format into a groups table.
-- Lines starting with # begin a new group. Other non-empty lines
-- are chi_path entries for the current group.
-- ============================================================
function M.parse_group_buf(lines)
	-- ## heading   glob patterns below it define which tabs appear under it in the panel
	-- #  group     chi_path templates for grouping tabs
	-- ### tag      chi_path templates for tab annotations
	-- Returns: groups, tags, headings
	--   groups   = { name = [chi_paths] }
	--   tags     = { name = [chi_paths] }
	--   headings = { order = [names], patterns = { name = [globs] } }
	local groups = {}
	local tags = {}
	local headings = { order = {}, patterns = {} }
	local current = nil
	local current_type = nil -- "group" | "tag" | "heading"

	local function strip_path(line)
		local p = vim.trim(line)
		p = p:gsub("^%u+%s+", "")
		p = p:gsub("%s+%[%x+%].*$", "")
		p = p:gsub("%s+%[partial%].*$", "")
		p = p:gsub("%s+%[full%].*$", "")
		p = p:gsub("%s+%[%a[%a%d%-_]*%].*$", "")
		return vim.trim(p)
	end

	for _, line in ipairs(lines) do
		local tag_name = line:match("^###%s*(.+)")
		local hdg_name = not tag_name and (line:match("^##([^#].*)") or line:match("^##$"))
		local grp_name = not tag_name and not hdg_name and (line:match("^#([^#].*)") or line:match("^#$"))

		if tag_name then
			current = vim.trim(tag_name)
			current_type = "tag"
			tags[current] = tags[current] or {}
		elseif hdg_name then
			hdg_name = vim.trim(hdg_name)
			if hdg_name == "" then
				hdg_name = "unnamed"
			end
			current = hdg_name
			current_type = "heading"
			if not headings.patterns[hdg_name] then
				table.insert(headings.order, hdg_name)
				headings.patterns[hdg_name] = {}
			end
		elseif grp_name then
			current = vim.trim(grp_name)
			current_type = "group"
			groups[current] = groups[current] or {}
		elseif current and vim.trim(line) ~= "" then
			local path = strip_path(line)
			if path ~= "" then
				if current_type == "tag" then
					table.insert(tags[current], path)
				elseif current_type == "group" then
					table.insert(groups[current], path)
				elseif current_type == "heading" then
					table.insert(headings.patterns[current], path)
				end
			end
		end
	end
	return groups, tags, headings
end

-- ============================================================
-- path_picker
-- Inline floating fuzzy picker. Two modes: insert (typing) and
-- normal (navigate/close). CR = open new tab, C-j = replace current.
-- Fuzzy scoring: subsequence match with consecutive-run and
-- segment-boundary bonuses. rg pre-filter for large lists (>80 items).
-- ============================================================
function M.path_picker(items, on_select)
	if #items == 0 then
		vim.notify("browser: no items", vim.log.levels.WARN)
		return
	end

	local function fuzzy_score(str, q)
		if q == "" then
			return 1
		end
		local s = str:lower()
		local qi, score, last = 1, 0, -1
		for si = 1, #s do
			if s:sub(si, si) == q:sub(qi, qi) then
				score = score + (last == si - 1 and 4 or 1)
				local prev = si > 1 and s:sub(si - 1, si - 1) or ""
				if si == 1 or prev == "/" or prev == "-" or prev == "{" then
					score = score + 3
				end
				last = si
				qi = qi + 1
				if qi > #q then
					return score
				end
			end
		end
		return 0
	end

	local function filter_items(q)
		if q == "" then
			return vim.deepcopy(items)
		end
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
	M.browser_highlights(win)

	local query = ""
	local filtered = {}
	local cursor_row = 1
	local mode = "insert"

	local function update_title()
		local ind = mode == "insert" and "-- INSERT -- /" or "-- NORMAL -- /"
		vim.api.nvim_win_set_config(win, {
			title = " " .. ind .. query .. "  CR=new  C-j=replace ",
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
			if ch == "\27" then
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
		else
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
				local ok2, ch2 = pcall(vim.fn.getcharstr)
				if ok2 and ch2 == "g" then
					cursor_row = 1
					pcall(vim.api.nvim_win_set_cursor, win, { cursor_row, 0 })
					vim.cmd("redraw")
				end
			elseif #ch == 1 and ch:byte() >= 32 then
				mode = "insert"
				query = query .. ch
				cursor_row = 1
				render()
			end
		end
	end
end

return M
