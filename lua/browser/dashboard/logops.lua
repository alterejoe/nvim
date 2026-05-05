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
-- ============================================================
function M.build_console_lines(raw)
	local lines = {}
	local ok, entries = pcall(vim.json.decode, raw)
	if ok and type(entries) == "table" then
		for _, entry in ipairs(entries) do
			local level = (nz(entry.level) or nz(entry.type) or "log"):upper()
			local msg = nz(entry.message) or nz(entry.text) or vim.inspect(entry):gsub("[\r\n]+", " ")
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

-- ============================================================
-- build_net_lines
-- Parses raw netlog JSON into display lines.
-- Also updates state.net_entries (line_number -> raw entry object)
-- so the cursor callback can build a preview for each line.
-- ============================================================
function M.build_net_lines(raw, state)
	state.net_entries = {}
	local lines = {}
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
			table.insert(lines, string.format("%s%s %s%s", s, method, path, t))
			state.net_entries[#lines] = entry
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
			local body_lines = ok and vim.split(vim.fn.json_encode(decoded), "\n", { plain = true })
				or vim.split(body, "\n", { plain = true })
			for _, l in ipairs(body_lines) do
				table.insert(lines, l)
			end
		end
	else
		local method = s(nz(entry.method) or "GET")
		local url = s(nz(entry.url) or "")
		local path = url:match("https?://[^/]+(/[^%s]*)") or url
		local host = url:match("https?://([^/]+)") or ""
		table.insert(lines, method .. " " .. path .. " HTTP/1.1")
		if host ~= "" then
			table.insert(lines, "Host: " .. host)
		end
		local qh = nz(entry.req_headers)
		if qh then
			for k, v in pairs(qh) do
				if k:lower() ~= "host" then
					table.insert(lines, s(k) .. ": " .. s(v))
				end
			end
		end
		local body = nz(entry.req_body) or ""
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

-- ============================================================
-- Console open / refresh / clear
-- All target the tab under cursor (state.preview_tab_id) instead
-- of the active tab. devproxy's consolelog/consoleclear accept an
-- optional tab id positional and fall back to active when absent.
-- ============================================================
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
	vim.bo[buf].modifiable = false
	vim.bo[buf].modified = false
	state.view_mode = "console"
	vim.notify("browser: console log - C=clear  r=refresh  c/<C-o>=back")
end

function M.refresh_console(buf, state)
	local raw = send_cmd("consolelog" .. tab_arg(state))
	if not raw or vim.startswith(raw, "err:") then
		vim.notify("browser: " .. (raw or "no response"), vim.log.levels.WARN)
		return
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.build_console_lines(raw))
	vim.bo[buf].modifiable = false
	vim.bo[buf].modified = false
	vim.notify("browser: console refreshed")
end

function M.clear_console(buf, state)
	send_cmd("consoleclear" .. tab_arg(state))
	vim.notify("browser: console log cleared")
	if state.view_mode == "console" then
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "-- console cleared --" })
		vim.bo[buf].modifiable = false
		vim.bo[buf].modified = false
	end
end

-- ============================================================
-- Network open / refresh / clear / toggle request-response
-- Same per-tab targeting as console.
-- ============================================================
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
	vim.bo[buf].modifiable = false
	vim.bo[buf].modified = false
	if state.layout then
		state.layout.set(util.PREVIEW_TITLE, { "-- move cursor to a request --" })
	end
	state.view_mode = "network"
	vim.notify("browser: network log - R=req/res  N=clear  r=refresh  n/<C-o>=back")
end

function M.refresh_network(buf, state)
	local raw = send_cmd("netlog" .. tab_arg(state))
	if not raw or vim.startswith(raw, "err:") then
		vim.notify("browser: " .. (raw or "no response"), vim.log.levels.WARN)
		return
	end
	state.net_show_response = false
	local lines = M.build_net_lines(raw, state)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].modified = false
	if state.layout then
		state.layout.set(util.PREVIEW_TITLE, { "-- move cursor to a request --" })
	end
	vim.notify("browser: network refreshed")
end

function M.clear_network(buf, state)
	send_cmd("netclear" .. tab_arg(state))
	vim.notify("browser: network log cleared")
	if state.view_mode == "network" then
		state.net_entries = {}
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "-- network log cleared --" })
		vim.bo[buf].modifiable = false
		vim.bo[buf].modified = false
		if state.layout then
			state.layout.set(util.PREVIEW_TITLE, { "-- network cleared --" })
		end
	end
end

function M.toggle_net_response(state)
	if state.view_mode ~= "network" then
		return
	end
	state.net_show_response = not state.net_show_response
	local win = state.primary_win
	if win and vim.api.nvim_win_is_valid(win) then
		local lnum = vim.api.nvim_win_get_cursor(win)[1]
		local entry = state.net_entries[lnum]
		if entry and state.layout then
			state.layout.set(util.PREVIEW_TITLE, M.build_net_preview(entry, state.net_show_response))
		end
	end
	vim.notify("browser: " .. (state.net_show_response and "response" or "request") .. " preview")
end

return M
