-- browser/dashboard/logops.lua
-- Console and network log panel operations.
-- All functions that modify buffer state or panel state accept `state`.

local M = {}

local util = require("browser.dashboard.util")

local function send_cmd(cmd)
	return require("browser.session").send_cmd(cmd)
end

local function panel_tab_id(state)
	return (state and state.log_tab_id) or ""
end

local function tab_arg(state)
	local id = panel_tab_id(state)
	if id == "" then
		return ""
	end
	return " " .. id
end

local function nz(v)
	if v == nil or v == vim.NIL then
		return nil
	end
	return v
end

-- ============================================================
-- Console: expandable args
--
-- Each entry renders as a single header line. If the entry has
-- args with object data, pressing CR on the header toggles
-- indented JSON lines beneath it (same model as htmx groups).
--
-- state.console_expanded: { [entry_index] = true/false }
-- state.console_entries:  array of raw decoded entry objects
--                         (set by build_console_lines, read by
--                          toggle_expand_console_at_cursor)
-- ============================================================

local level_icons = {
	log = "[log]  ",
	info = "[info] ",
	warn = "[warn] ",
	warning = "[warn] ",
	error = "[err]  ",
	dir = "[dir]  ",
	table = "[tbl]  ",
}

local function format_arg(raw)
	-- raw is a json.RawMessage value (already decoded by vim.json.decode
	-- into a Lua table/string/number/bool).
	if type(raw) == "table" then
		-- Pretty-print as indented lines
		local lines = {}
		for _, l in ipairs(vim.split(vim.inspect(raw), "\n", { plain = true })) do
			table.insert(lines, "    " .. l)
		end
		return lines
	elseif type(raw) == "string" then
		return { "    " .. raw }
	else
		return { "    " .. tostring(raw) }
	end
end

function M.build_console_lines(raw, state)
	-- state is optional; when provided we populate state.console_entries
	-- so the expand toggle can find entries by line number.
	local entries_decoded = {}
	local count_total = 0
	local count_err = 0

	local ok, entries = pcall(vim.json.decode, raw)
	if ok and type(entries) == "table" then
		for _, entry in ipairs(entries) do
			table.insert(entries_decoded, entry)
			count_total = count_total + 1
			local level = (nz(entry.level) or nz(entry.type) or "log"):upper()
			if level == "ERROR" or level == "WARN" or level == "WARNING" then
				count_err = count_err + 1
			end
		end
	else
		-- non-JSON fallback: treat as plain text lines
		for _, l in ipairs(vim.split(raw, "\n", { plain = true })) do
			if vim.trim(l) ~= "" then
				table.insert(entries_decoded, { text = l, level = "log", _plain = true })
				count_total = count_total + 1
			end
		end
	end

	if state then
		state.console_entries = entries_decoded
	end

	local expanded = (state and state.console_expanded) or {}

	local lines = {
		string.format("-- CONSOLE  (%d total, %d errors/warnings) --", count_total, count_err),
		"",
	}

	if #entries_decoded == 0 then
		table.insert(lines, "  (no console entries)")
		return lines
	end

	-- line_to_entry_idx maps buffer line number -> entry index for the
	-- header lines only (used by toggle_expand_console_at_cursor).
	local line_to_entry_idx = {}

	for i, entry in ipairs(entries_decoded) do
		local level = (nz(entry.level) or nz(entry.type) or "log"):lower()
		local icon = level_icons[level] or "       "
		local msg = nz(entry.message) or nz(entry.text) or ""
		msg = tostring(msg):gsub("[\r\n]+", " ")

		local loc = ""
		local url = nz(entry.url)
		if url and url ~= "" then
			local path = url:match("/([^/]+)$") or url
			loc = "  " .. path .. ":" .. (nz(entry.line) or 0)
		end

		-- Does this entry have expandable args?
		local args = nz(entry.args)
		local has_args = args and type(args) == "table" and #args > 0
		local expand_marker = has_args and (expanded[i] and " " or "? ") or "  "

		local header = string.format("%s%s%s%s", expand_marker, icon, msg, loc)
		line_to_entry_idx[#lines + 1] = i
		table.insert(lines, header)

		if has_args and expanded[i] then
			for _, arg in ipairs(args) do
				for _, l in ipairs(format_arg(arg)) do
					table.insert(lines, l)
				end
			end
			table.insert(lines, "")
		end
	end

	if state then
		state.console_line_to_entry = line_to_entry_idx
	end

	return lines
end

function M.toggle_expand_console_at_cursor(buf, state)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local win = state.primary_win
	if not (win and vim.api.nvim_win_is_valid(win)) then
		return
	end
	local cur_lnum = vim.api.nvim_win_get_cursor(win)[1]
	local map = state.console_line_to_entry or {}
	local idx = map[cur_lnum]
	if not idx then
		return
	end
	local entries = state.console_entries or {}
	local entry = entries[idx]
	if not entry then
		return
	end
	local args = nz(entry.args)
	if not (args and type(args) == "table" and #args > 0) then
		vim.notify("browser: no object args to expand on this entry", vim.log.levels.INFO)
		return
	end
	state.console_expanded = state.console_expanded or {}
	state.console_expanded[idx] = not state.console_expanded[idx]
	local raw = send_cmd("consolelog" .. tab_arg(state))
	if not raw or vim.startswith(raw, "err:") then
		return
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.build_console_lines(raw, state))
	vim.bo[buf].modified = false
	-- Restore cursor to the header line (it may have shifted due to expansion)
	local new_map = state.console_line_to_entry or {}
	for lnum, i in pairs(new_map) do
		if i == idx then
			pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 })
			break
		end
	end
end

function M.open_console(buf, state)
	state.console_expanded = {}
	state.console_entries = {}
	state.console_line_to_entry = {}
	local raw = send_cmd("consolelog" .. tab_arg(state))
	if not raw or vim.startswith(raw, "err:") then
		vim.notify("browser: " .. (raw or "no response"), vim.log.levels.WARN)
		return
	end
	local lines = M.build_console_lines(raw, state)
	vim.bo[buf].filetype = "text"
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modified = false
	state.view_mode = "console"
	if state._update_help_pane then
		state._update_help_pane()
	end
	vim.notify("browser: console - CR expand  r refresh  C clear  c/<C-o> back")
end

function M.refresh_console(buf, state)
	local raw = send_cmd("consolelog" .. tab_arg(state))
	if not raw or vim.startswith(raw, "err:") then
		vim.notify("browser: " .. (raw or "no response"), vim.log.levels.WARN)
		return
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.build_console_lines(raw, state))
	vim.bo[buf].modified = false
	vim.notify("browser: console refreshed")
end

function M.clear_console(buf, state)
	send_cmd("consoleclear" .. tab_arg(state))
	state.console_expanded = {}
	state.console_entries = {}
	state.console_line_to_entry = {}
	if state.view_mode == "console" and vim.api.nvim_buf_is_valid(buf) then
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.build_console_lines("[]", state))
		vim.bo[buf].modified = false
	end
	vim.notify("browser: console cleared")
end

-- ============================================================
-- build_net_lines
-- ============================================================
function M.build_net_lines(raw, state)
	state.net_entries = {}
	local entries_lines = {}
	local count_total = 0
	local count_err = 0
	local ok, entries = pcall(vim.json.decode, raw)
	if ok and type(entries) == "table" then
		for _, entry in ipairs(entries) do
			local method = nz(entry.method) or "?"
			local url = nz(entry.url) or "?"
			local path = url:match("https?://[^/]+(/[^%s]*)") or url
			local status = nz(entry.status) or ""
			local ct = ""
			local rh = nz(entry.res_headers)
			if rh then
				ct = rh["Content-Type"] or rh["content-type"] or ""
				ct = ct:match("^([^;]+)") or ct
			end
			local s = status ~= "" and ("[" .. status .. "] ") or ""
			local t = ct ~= "" and ("  " .. ct) or ""
			table.insert(entries_lines, string.format("%s%s %s%s", s, method, path, t))
			count_total = count_total + 1
			if type(status) == "number" and status >= 400 then
				count_err = count_err + 1
			end
		end
	else
		for _, l in ipairs(vim.split(raw, "\n", { plain = true })) do
			if vim.trim(l) ~= "" then
				table.insert(entries_lines, l)
				count_total = count_total + 1
			end
		end
	end
	local lines = {
		string.format("-- NETWORK  (%d total, %d errors) --", count_total, count_err),
		"",
	}
	local base = #lines
	if #entries_lines == 0 then
		table.insert(lines, "  (no network entries)")
		return lines
	end
	for _, l in ipairs(entries_lines) do
		table.insert(lines, l)
	end
	if ok and type(entries) == "table" then
		for i, entry in ipairs(entries) do
			state.net_entries[base + i] = entry
		end
	end
	return lines
end

-- ============================================================
-- build_net_preview
-- ============================================================
function M.build_net_preview(entry, show_response)
	local function s(v)
		return tostring(v):gsub("[\r\n]+", " ")
	end
	local lines = {}
	if show_response then
		table.insert(lines, "HTTP/1.1 " .. s(nz(entry.status) or "?"))
		local rh = nz(entry.res_headers)
		if rh then
			for k, v in pairs(rh) do
				table.insert(lines, s(k) .. ": " .. s(v))
			end
		end
		local body = nz(entry.res_body) or ""
		if body ~= "" then
			table.insert(lines, "")
			local ok, decoded = pcall(vim.json.decode, body)
			if ok then
				for _, l in ipairs(vim.split(vim.inspect(decoded), "\n", { plain = true })) do
					table.insert(lines, l)
				end
			else
				for _, l in ipairs(vim.split(body, "\n", { plain = true })) do
					table.insert(lines, l)
				end
			end
		end
	else
		local method = nz(entry.method) or "GET"
		local url = nz(entry.url) or "/"
		local path = url:match("https?://[^/]+(/.*)") or url
		table.insert(lines, method .. " " .. path .. " HTTP/1.1")
		local rh = nz(entry.req_headers)
		if rh then
			for k, v in pairs(rh) do
				table.insert(lines, s(k) .. ": " .. s(v))
			end
		end
	end
	return lines
end

function M.toggle_net_response(state)
	state.net_show_response = not state.net_show_response
	if not state.layout then
		return
	end
	local cur_win = state.split_win
		and vim.api.nvim_win_is_valid(state.split_win)
		and vim.api.nvim_get_current_win() == state.split_win
	local target_buf = cur_win and state.split_buf or state.primary_buf
	local target_win = cur_win and state.split_win or state.primary_win
	if
		not (
			target_buf
			and target_win
			and vim.api.nvim_buf_is_valid(target_buf)
			and vim.api.nvim_win_is_valid(target_win)
		)
	then
		return
	end
	if state.view_mode ~= "network" and state.split_view ~= "network" then
		return
	end
	local lnum = vim.api.nvim_win_get_cursor(target_win)[1]
	local entry = state.net_entries[lnum]
	if entry then
		state.layout.set(util.PREVIEW_TITLE, M.build_net_preview(entry, state.net_show_response))
	end
end

function M.open_network(buf, state)
	local raw = send_cmd("netlog" .. tab_arg(state))
	if not raw or vim.startswith(raw, "err:") then
		vim.notify("browser: " .. (raw or "no response"), vim.log.levels.WARN)
		return
	end
	state.net_show_response = false
	local lines = M.build_net_lines(raw, state)
	vim.bo[buf].filetype = "text"
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modified = false
	state.view_mode = "network"
	if state._update_help_pane then
		state._update_help_pane()
	end
	vim.notify("browser: network - r refresh  N clear  R req/res  9/<C-o> back")
end

function M.refresh_network(buf, state)
	local raw = send_cmd("netlog" .. tab_arg(state))
	if not raw or vim.startswith(raw, "err:") then
		vim.notify("browser: " .. (raw or "no response"), vim.log.levels.WARN)
		return
	end
	local lines = M.build_net_lines(raw, state)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modified = false
	vim.notify("browser: network refreshed")
end

function M.clear_network(buf, state)
	send_cmd("netclear" .. tab_arg(state))
	if state.view_mode == "network" and vim.api.nvim_buf_is_valid(buf) then
		state.net_entries = {}
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.build_net_lines("[]", state))
		vim.bo[buf].modified = false
	end
	vim.notify("browser: network cleared")
end

return M
