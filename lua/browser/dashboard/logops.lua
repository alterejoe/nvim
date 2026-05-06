-- browser/dashboard/logops.lua
-- Console and network log panel operations.
-- All functions that modify buffer state or panel state accept `state`.

local M = {}

local util = require("browser.dashboard.util")

local function send_cmd(cmd)
	return require("browser.session").send_cmd(cmd)
end

-- Pick the tab id this panel should target.
--
-- Console and network logs are per-tab. The panel was opened from a
-- tab line under the cursor; that tab's id was recorded onto
-- state.preview_tab_id by the on_cursor hook in dashboard.lua. We
-- reuse it here so c/n/C/N (and r refresh) operate on the same tab
-- the user was hovering over - not the active tab.
--
-- Returns "" when no tab is recorded; devproxy then falls back to
-- the active tab (the consolelog/netlog commands accept that, since
-- they aren't strict-mode yet).
local function panel_tab_id(state)
	return (state and state.preview_tab_id) or ""
end

-- Build the trailing arg for log commands. " <id>" when known, "" when not.
local function tab_arg(state)
	local id = panel_tab_id(state)
	if id == "" then
		return ""
	end
	return " " .. id
end

-- vim.json.decode turns JSON null into vim.NIL (userdata), which is truthy.
-- Use this to safely test fields that may be null.
local function nz(v)
	if v == nil or v == vim.NIL then
		return nil
	end
	return v
end

-- ============================================================
-- build_console_lines
-- Parses raw consolelog JSON into display lines.
-- Always emits a header line so the user can see what panel they're in.
-- ============================================================
function M.build_console_lines(raw)
	local entries_lines = {}
	local count_total = 0
	local count_err = 0
	local ok, entries = pcall(vim.json.decode, raw)
	if ok and type(entries) == "table" then
		for _, entry in ipairs(entries) do
			local level = (nz(entry.level) or nz(entry.type) or "log"):upper()
			local msg = nz(entry.message) or nz(entry.text) or vim.inspect(entry):gsub("[\r\n]+", " ")
			msg = tostring(msg):gsub("[\r\n]+", " ")
			table.insert(entries_lines, string.format("[%s] %s", level, msg))
			count_total = count_total + 1
			if level == "ERROR" or level == "WARN" or level == "WARNING" then
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
		string.format("-- CONSOLE  (%d total, %d errors/warnings) --", count_total, count_err),
		"",
	}
	if #entries_lines == 0 then
		table.insert(lines, "  (no console entries)")
		return lines
	end
	for _, l in ipairs(entries_lines) do
		table.insert(lines, l)
	end
	return lines
end

-- ============================================================
-- build_net_lines
-- Parses raw netlog JSON into display lines.
-- Always emits a header line so the user can see what panel they're in.
-- Also updates state.net_entries (line_number -> raw entry object)
-- so the cursor callback can build a preview for each line.
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
	-- The header takes up 2 lines, so each entry's line in the buffer is
	-- offset by 2 from its index in entries_lines. Track that for the
	-- net_entries map used by on_cursor to build previews.
	local base = #lines
	if #entries_lines == 0 then
		table.insert(lines, "  (no network entries)")
		return lines
	end
	for i, l in ipairs(entries_lines) do
		table.insert(lines, l)
		-- Re-decode just to get the entry back into net_entries with
		-- the correct line index.
	end
	-- Re-walk to populate net_entries with correct line numbers.
	if ok and type(entries) == "table" then
		for i, entry in ipairs(entries) do
			state.net_entries[base + i] = entry
		end
	end
	return lines
end

-- ============================================================
-- build_net_preview
-- Builds HTTP request or response lines for a single net entry.
-- Used by on_cursor to populate the HTTP Preview pane.
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

function M.open_console(buf, state)
	local raw = send_cmd("consolelog" .. tab_arg(state))
	if not raw or vim.startswith(raw, "err:") then
		vim.notify("browser: " .. (raw or "no response"), vim.log.levels.WARN)
		return
	end
	local lines = M.build_console_lines(raw)
	vim.bo[buf].filetype = "text"
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modified = false
	state.view_mode = "console"
	if state._update_help_pane then
		state._update_help_pane()
	end
	vim.notify("browser: console - r=refresh  C=clear  c/r=back")
end

function M.refresh_console(buf, state)
	local raw = send_cmd("consolelog" .. tab_arg(state))
	if not raw or vim.startswith(raw, "err:") then
		vim.notify("browser: " .. (raw or "no response"), vim.log.levels.WARN)
		return
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.build_console_lines(raw))
	vim.bo[buf].modified = false
	vim.notify("browser: console refreshed")
end

function M.clear_console(buf, state)
	send_cmd("consoleclear" .. tab_arg(state))
	if state.view_mode == "console" and vim.api.nvim_buf_is_valid(buf) then
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.build_console_lines("[]"))
		vim.bo[buf].modified = false
	end
	vim.notify("browser: console cleared")
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
	vim.notify("browser: network - r=refresh  N=clear  R=req/res  n/r=back")
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
