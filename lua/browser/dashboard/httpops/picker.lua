-- browser/dashboard/httpops/picker.lua
--
-- The `:` keymap installed on the http panel buffer that opens a fuzzy
-- picker over candidate keys to insert into the nearest params: block.
--
-- Public:
--   M.install(buf, state)
--
-- Candidates: defaults + active context's path-param keys + any keys
-- already present in this section's params block. The user picks one;
-- it gets inserted as "  <key>: " under the params: anchor and the
-- cursor lands in insert mode at the value position.
--
-- The fuzzy_pick helper here is a tiny in-house picker (single buffer,
-- substring filter, raw getcharstr loop). Modeled on
-- scratchbuf.fuzzy_filter for consistency with the rest of the plugin.

local M = {}

-- ============================================================
-- Section navigation helpers (private)
-- ============================================================

-- in_params_section: walk backwards from lnum looking for the most
-- recent label (path:/htmx:/params:). Returns true iff that label is
-- params:, meaning the cursor is somewhere in a params block.
local function in_params_section(buf, lnum)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, lnum, false)
	for i = #lines, 1, -1 do
		local l = lines[i]
		local label = l:match("^([%w%.%-_]+):")
		if label then
			return label:lower() == "params"
		end
		if l:match("^%-%-%- context:") then
			return false
		end
	end
	return false
end

-- find_params_anchor: locate the line number of the nearest preceding
-- "params:" line within the current context section.
local function find_params_anchor(buf, lnum)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, lnum, false)
	for i = #lines, 1, -1 do
		if lines[i]:match("^params:%s*$") then
			return i
		end
		if lines[i]:match("^%-%-%- context:") then
			return nil
		end
	end
	return nil
end

-- existing_params_keys: read indented "  key:" lines below params_lnum
-- until next non-indented line or end of buffer. Returns set of keys
-- already present so the picker can offer them again (re-edit) and so
-- callers can avoid duplicate inserts if they choose to.
local function existing_params_keys(buf, params_lnum)
	local total = vim.api.nvim_buf_line_count(buf)
	local keys = {}
	for i = params_lnum + 1, total do
		local l = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
		if l == "" then
			break
		end
		local ik = l:match("^%s%s+([%w%.%-_]+):")
		if ik then
			keys[ik] = true
		else
			-- non-indented line ends the params block
			if not l:match("^%s") then
				break
			end
		end
	end
	return keys
end

-- ============================================================
-- fuzzy_pick (private)
-- Tiny floating-window picker with substring filter.
-- j/k move in normal mode, type-then-render in insert-like mode.
-- CR selects, Esc cancels.
-- ============================================================
local function fuzzy_pick(items, on_select)
	if #items == 0 then
		vim.notify("browser: no candidates", vim.log.levels.WARN)
		return
	end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = true

	local width = math.min(60, vim.o.columns - 4)
	local height = math.min(20, vim.o.lines - 6)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " params ",
		title_pos = "center",
	})

	local query = ""
	local filtered = {}
	local function render()
		filtered = {}
		local q = query:lower()
		for _, it in ipairs(items) do
			if q == "" or it:lower():find(q, 1, true) then
				table.insert(filtered, it)
			end
		end
		if #filtered == 0 then
			filtered = items
		end
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, filtered)
		vim.bo[buf].modifiable = false
		pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
		vim.api.nvim_win_set_config(win, {
			relative = "editor",
			row = math.floor((vim.o.lines - height) / 2),
			col = math.floor((vim.o.columns - width) / 2),
			width = width,
			height = height,
			title = " params  /" .. query .. " ",
			title_pos = "center",
		})
		vim.cmd("redraw")
	end
	render()

	local function close()
		pcall(vim.api.nvim_win_close, win, true)
	end

	while true do
		local ok, ch = pcall(vim.fn.getcharstr)
		if not ok then
			close()
			return
		end
		if ch == "\27" then -- Esc
			close()
			return
		elseif ch == "\r" then -- CR
			local row = vim.api.nvim_win_get_cursor(win)[1]
			local sel = filtered[row]
			close()
			if sel then
				on_select(sel)
			end
			return
		elseif ch == "\14" or ch == "j" then -- C-n / j
			if vim.api.nvim_get_mode().mode == "n" then
				local row = vim.api.nvim_win_get_cursor(win)[1]
				if row < #filtered then
					vim.api.nvim_win_set_cursor(win, { row + 1, 0 })
					vim.cmd("redraw")
				end
			else
				query = query .. ch
				render()
			end
		elseif ch == "\16" or ch == "k" then -- C-p / k
			if vim.api.nvim_get_mode().mode == "n" then
				local row = vim.api.nvim_win_get_cursor(win)[1]
				if row > 1 then
					vim.api.nvim_win_set_cursor(win, { row - 1, 0 })
					vim.cmd("redraw")
				end
			else
				query = query .. ch
				render()
			end
		elseif ch == "\8" or ch == "\127" then -- backspace
			if #query > 0 then
				query = query:sub(1, -2)
				render()
			end
		elseif #ch == 1 and ch:byte() >= 32 then -- printable
			query = query .. ch
			render()
		end
	end
end

-- ============================================================
-- install
-- Registers the `:` keymap on the http panel buffer. Outside the http
-- view (or outside a params block within it), `:` falls through to the
-- default vim command-line behavior.
-- ============================================================
function M.install(buf, state)
	vim.keymap.set("n", ":", function()
		if state.view_mode ~= "http" then
			vim.api.nvim_feedkeys(":", "n", false)
			return
		end
		local row = vim.api.nvim_win_get_cursor(0)[1]
		if not in_params_section(buf, row) then
			vim.api.nvim_feedkeys(":", "n", false)
			return
		end

		local views = require("browser.views")
		local cfg = views.get_config()
		local seen = {}
		local items = {}

		local function add(k)
			if k and k ~= "" and not seen[k] then
				seen[k] = true
				table.insert(items, k)
			end
		end

		-- defaults
		for k, _ in pairs(cfg.defaults or {}) do
			add(k)
		end
		-- active context (path params only - skip "query" sub-table)
		local active = views.get_active_context()
		local ctx = (cfg.contexts or {})[active] or {}
		for k, _ in pairs(ctx) do
			if k ~= "query" then
				add(k)
			end
		end
		-- keys already present in this section's params block
		local anchor = find_params_anchor(buf, row)
		if anchor then
			for k, _ in pairs(existing_params_keys(buf, anchor)) do
				add(k)
			end
		end

		table.sort(items)

		fuzzy_pick(items, function(key)
			-- Insert "  <key>: " just after the current line. If the
			-- cursor is on the params: anchor itself, that lands the
			-- new line directly under it.
			local ins_row = row
			local cur_line = vim.api.nvim_buf_get_lines(buf, ins_row - 1, ins_row, false)[1] or ""
			if cur_line:match("^params:%s*$") then
				ins_row = row
			end
			vim.bo[buf].modifiable = true
			vim.api.nvim_buf_set_lines(buf, ins_row, ins_row, false, { "  " .. key .. ": " })
			vim.bo[buf].modified = true
			-- Cursor onto the new line, after the colon+space.
			local new_row = ins_row + 1
			local new_col = #("  " .. key .. ": ")
			pcall(vim.api.nvim_win_set_cursor, 0, { new_row, new_col })
			vim.cmd("startinsert!")
		end)
	end, { buffer = buf, nowait = true, silent = true, desc = "browser: pick param key" })
end

return M
