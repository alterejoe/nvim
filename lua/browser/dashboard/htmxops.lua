-- browser/dashboard/htmxops.lua
-- htmx event log panel.
-- Pulls window.__devproxy_htmx_log from the hovered tab and renders
-- entries grouped by status: errors first, then successful swaps.
-- Targets state.log_tab_id (set at panel-open time, not cursor position).

local M = {}

local function send_cmd(cmd)
	return require("browser.session").send_cmd(cmd)
end

local function nz(v)
	if v == nil or v == vim.NIL then
		return nil
	end
	return v
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

local function fetch_entries(state)
	local raw = send_cmd("htmx-log" .. tab_arg(state))
	if not raw or vim.startswith(raw, "err:") then
		return {}, raw or "no response"
	end
	local ok, decoded = pcall(vim.json.decode, raw)
	if not ok or type(decoded) ~= "table" then
		return {}, "could not parse htmx-log response"
	end
	return decoded, nil
end

local function is_error(entry)
	local t = nz(entry.type) or ""
	if t == "targetError" or t == "swapError" or t == "responseError" or t == "sendError" then
		return true
	end
	if entry.target_missing then
		return true
	end
	return false
end

local function group_lifecycles(entries)
	local groups = {}
	local current
	for _, e in ipairs(entries) do
		local t = nz(e.type) or ""
		if t == "beforeRequest" then
			if current then
				table.insert(groups, current)
			end
			current = {
				path = nz(e.path) or "",
				method = nz(e.method) or "?",
				trigger_elt = nz(e.trigger_elt) or "",
				target = nz(e.target) or "",
				target_id = nz(e.target_id) or "",
				timestamp = nz(e.timestamp) or 0,
				events = { e },
				had_error = false,
				final_status = 0,
			}
		else
			if not current then
				current = {
					path = nz(e.path) or "",
					method = nz(e.method) or "?",
					trigger_elt = nz(e.trigger_elt) or "",
					target = nz(e.target) or "",
					target_id = nz(e.target_id) or "",
					timestamp = nz(e.timestamp) or 0,
					events = {},
					had_error = false,
					final_status = 0,
				}
			end
			table.insert(current.events, e)
		end
		if is_error(e) then
			current.had_error = true
		end
		local s = nz(e.status)
		if s and s ~= 0 then
			current.final_status = s
		end
	end
	if current then
		table.insert(groups, current)
	end
	return groups
end

local function fmt_time(ms)
	if not ms or ms == 0 then
		return "--:--:--"
	end
	local secs = math.floor(ms / 1000)
	return os.date("%H:%M:%S", secs)
end

local function render_group(group, expanded, src_only)
	local lines = {}
	local time = fmt_time(group.timestamp)
	local status = group.final_status ~= 0 and ("[" .. group.final_status .. "]") or "[---]"
	local marker = group.had_error and "!" or " "
	local path = group.path
	if src_only then
		path = path:match("https?://[^/]+(/[^%s]*)") or path
	end
	local header = string.format("%s %s %s %-6s %s", marker, time, status, group.method, path)
	table.insert(lines, header)
	if expanded then
		table.insert(lines, "    trigger: " .. (group.trigger_elt ~= "" and group.trigger_elt or "(none)"))
		table.insert(lines, "    target:  " .. (group.target ~= "" and group.target or "(none)"))
		for _, e in ipairs(group.events) do
			local t = nz(e.type) or "?"
			local err = nz(e.error) or ""
			local ts = fmt_time(nz(e.timestamp) or 0)
			local line = string.format("      %s  %-15s", ts, t)
			if err ~= "" then
				line = line .. "  ERROR: " .. err
			end
			if e.target_missing then
				line = line .. "  (target not found)"
			end
			table.insert(lines, line)
		end
		table.insert(lines, "")
	end
	return lines
end

function M.build_lines(state)
	local groups = state.htmx_groups or {}
	local filter = state.htmx_filter or "all"
	local src_only = state.htmx_src_only or false
	local expanded = state.htmx_expanded or {}

	local errors = 0
	local total = #groups
	for _, g in ipairs(groups) do
		if g.had_error then
			errors = errors + 1
		end
	end

	local lines = {
		string.format("-- HTMX  (%d total, %d errors) --", total, errors),
		"",
	}

	local function show(g)
		if filter == "all" then
			return true
		end
		if filter == "errors" then
			return g.had_error
		end
		return true
	end

	if total == 0 then
		table.insert(lines, "  (no htmx events recorded)")
		return lines
	end

	for i, g in ipairs(groups) do
		if show(g) then
			local exp = expanded[i] or false
			for _, l in ipairs(render_group(g, exp, src_only)) do
				table.insert(lines, l)
			end
		end
	end

	return lines
end

local function write_buf(buf, lines)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	vim.bo[buf].filetype = "text"
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modified = false
end

local function recompute_and_render(buf, state)
	local entries, err = fetch_entries(state)
	if err then
		vim.notify("browser: " .. err, vim.log.levels.WARN)
		return false
	end
	state.htmx_groups = group_lifecycles(entries)
	write_buf(buf, M.build_lines(state))
	return true
end

function M.redraw(buf, state)
	write_buf(buf, M.build_lines(state))
end

function M.open(buf, state)
	state.htmx_groups = {}
	state.htmx_filter = "all"
	state.htmx_src_only = false
	state.htmx_expanded = {}
	if not recompute_and_render(buf, state) then
		return
	end
	state.view_mode = "htmx"
	if state._update_help_pane then
		state._update_help_pane()
	end
	vim.notify("browser: htmx - CR expand  e errors  A all  b src  N clear  r refresh  M/<C-o> back")
end

function M.refresh(buf, state)
	if not recompute_and_render(buf, state) then
		return
	end
	vim.notify("browser: htmx refreshed")
end

function M.clear(buf, state)
	send_cmd("htmx-clear" .. tab_arg(state))
	state.htmx_groups = {}
	state.htmx_expanded = {}
	write_buf(buf, M.build_lines(state))
	vim.notify("browser: htmx log cleared")
end

function M.toggle_src_only(buf, state)
	state.htmx_src_only = not state.htmx_src_only
	M.redraw(buf, state)
end

function M.set_filter(buf, state, name)
	state.htmx_filter = name
	M.redraw(buf, state)
end

function M.toggle_expand_at_cursor(buf, state)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local win = state.primary_win
	if not (win and vim.api.nvim_win_is_valid(win)) then
		return
	end
	local cur_lnum = vim.api.nvim_win_get_cursor(win)[1]
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local group_idx = 0
	local groups = state.htmx_groups or {}
	for lnum, line in ipairs(lines) do
		if line:match("^[! ] %d%d:%d%d:%d%d ") then
			group_idx = group_idx + 1
			if lnum == cur_lnum then
				state.htmx_expanded = state.htmx_expanded or {}
				local actual_idx = nil
				local visible = 0
				for i, g in ipairs(groups) do
					if state.htmx_filter == "all" or (state.htmx_filter == "errors" and g.had_error) then
						visible = visible + 1
						if visible == group_idx then
							actual_idx = i
							break
						end
					end
				end
				if actual_idx then
					state.htmx_expanded[actual_idx] = not state.htmx_expanded[actual_idx]
					M.redraw(buf, state)
				end
				return
			end
		end
	end
end

local function split_recompute(state)
	local entries, err = fetch_entries(state)
	if err then
		vim.notify("browser: " .. err, vim.log.levels.WARN)
		return false
	end
	state.split_htmx_groups = group_lifecycles(entries)
	return true
end

local function split_build_lines(state)
	local proxy = {
		htmx_groups = state.split_htmx_groups,
		htmx_filter = state.split_htmx_filter,
		htmx_src_only = state.split_htmx_src_only,
		htmx_expanded = state.split_htmx_expanded,
	}
	return M.build_lines(proxy)
end

function M.split_open(state, split_set)
	state.split_htmx_groups = {}
	state.split_htmx_filter = "all"
	state.split_htmx_src_only = false
	state.split_htmx_expanded = {}
	if not split_recompute(state) then
		return
	end
	split_set(split_build_lines(state), "text", true)
	state.split_view = "htmx"
	if state._update_help_pane then
		state._update_help_pane()
	end
	vim.notify("browser: split htmx - CR expand  e errors  A all  b src  N clear  r refresh  M/r back")
end

function M.split_refresh(state, split_set)
	if not split_recompute(state) then
		return
	end
	split_set(split_build_lines(state), "text", true)
	vim.notify("browser: split htmx refreshed")
end

function M.split_redraw(state, split_set)
	split_set(split_build_lines(state), "text", true)
end

function M.split_clear(state, split_set)
	send_cmd("htmx-clear" .. tab_arg(state))
	state.split_htmx_groups = {}
	state.split_htmx_expanded = {}
	split_set(split_build_lines(state), "text", true)
	vim.notify("browser: split htmx log cleared")
end

function M.split_toggle_src_only(state, split_set)
	state.split_htmx_src_only = not state.split_htmx_src_only
	M.split_redraw(state, split_set)
end

function M.split_set_filter(state, split_set, name)
	state.split_htmx_filter = name
	M.split_redraw(state, split_set)
end

return M
