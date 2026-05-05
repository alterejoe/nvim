-- browser/dashboard/assetops.lua
-- Assets panel operations.
-- Pulls page-assets (URLs referenced in the DOM) and netlog-all (URLs
-- actually fetched, including static assets), diffs them, and renders
-- three sections: MISSING, LOADED, EXTRA.
--
-- Uses netlog-all (not netlog) because the legacy netlog command filters
-- out static assets at read time. The assets panel needs the unfiltered
-- view to diff correctly.
--
-- Note: this panel keeps the buffer MODIFIABLE so scratchbuf's post-save
-- refresh path (which writes refresh()'s return value back to the buffer)
-- can succeed. We just clear `modified` after each write so W still works.

local M = {}

local util = require("browser.dashboard.util")

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
	return (state and state.preview_tab_id) or ""
end

local function tab_arg(state)
	local id = panel_tab_id(state)
	if id == "" then
		return ""
	end
	return " " .. id
end

-- Look up the meta object in state.tab_metadata for the given tab_id.
-- Returns nil if no entry matches.
local function meta_for_tab(state, tab_id)
	if not state or not state.tab_metadata or not tab_id or tab_id == "" then
		return nil
	end
	for _, m in pairs(state.tab_metadata) do
		if m.tab_id == tab_id then
			return m
		end
	end
	return nil
end

-- Resolve the htmx setting for a tab the same way <CR> does:
-- prefer the tab's saved test file value, fall back to meta.htmx,
-- fall back to false.
local function resolve_htmx(meta)
	local htmx = meta and meta.htmx or false
	if meta and meta.chi_path then
		local saved = require("browser.views").load_test_for_path(meta.chi_path)
		if saved and saved.htmx ~= nil then
			htmx = saved.htmx
		end
	end
	return htmx
end

local function fetch_referenced(state)
	local id = panel_tab_id(state)
	if id == "" then
		return {}, "no tab selected"
	end
	local raw = send_cmd("page-assets " .. id)
	if not raw or vim.startswith(raw, "err:") then
		return {}, raw or "no response"
	end
	local ok, decoded = pcall(vim.json.decode, raw)
	if not ok or type(decoded) ~= "table" or type(decoded.referenced) ~= "table" then
		return {}, "could not parse page-assets response"
	end
	local out = {}
	for _, e in ipairs(decoded.referenced) do
		table.insert(out, {
			tag = nz(e.tag) or "?",
			url = nz(e.url) or "",
			attr = nz(e.attr) or "",
		})
	end
	return out, nil
end

local function fetch_netlog(state)
	local raw = send_cmd("netlog-all" .. tab_arg(state))
	if not raw or vim.startswith(raw, "err:") then
		return {}, raw or "no response"
	end
	local ok, decoded = pcall(vim.json.decode, raw)
	if not ok or type(decoded) ~= "table" then
		return {}, "could not parse netlog-all response"
	end
	return decoded, nil
end

local function content_type(entry)
	local rh = nz(entry.res_headers)
	if not rh then
		return ""
	end
	local ct = rh["Content-Type"] or rh["content-type"] or ""
	ct = ct:match("^([^;]+)") or ct
	return tostring(ct):lower()
end

local function strip_host(url)
	return url:match("https?://[^/]+(/[^%s]*)") or url
end

local function compute_diff(referenced, fetched, include_html)
	local fetched_set = {}
	local fetched_kept = {}
	for _, entry in ipairs(fetched) do
		local ct = content_type(entry)
		if include_html or ct ~= "text/html" then
			local url = nz(entry.url) or ""
			if url ~= "" then
				fetched_set[url] = true
				table.insert(fetched_kept, entry)
			end
		end
	end

	local referenced_set = {}
	for _, r in ipairs(referenced) do
		referenced_set[r.url] = true
	end

	local loaded, missing = {}, {}
	for _, r in ipairs(referenced) do
		if fetched_set[r.url] then
			table.insert(loaded, r)
		else
			table.insert(missing, r)
		end
	end

	local extra = {}
	for _, entry in ipairs(fetched_kept) do
		local url = nz(entry.url) or ""
		if not referenced_set[url] then
			table.insert(extra, entry)
		end
	end

	return loaded, missing, extra
end

local function format_referenced_line(r, src_only)
	local url = src_only and strip_host(r.url) or r.url
	return string.format("[%s %s] %s", r.tag, r.attr, url)
end

local function format_fetched_line(entry, src_only)
	local method = nz(entry.method) or "?"
	local status = nz(entry.status) or ""
	local ct = content_type(entry)
	local url = nz(entry.url) or ""
	if src_only then
		url = strip_host(url)
	end
	local s = status ~= "" and ("[" .. method .. " " .. status .. (ct ~= "" and (" " .. ct) or "") .. "]")
		or ("[" .. method .. "]")
	return s .. " " .. url
end

function M.build_lines(state)
	local referenced = state.assets_referenced or {}
	local loaded = state.assets_loaded or {}
	local missing = state.assets_missing or {}
	local extra = state.assets_extra or {}
	local filter = state.assets_filter or "all"
	local src_only = state.assets_src_only or false

	local lines = {}

	table.insert(
		lines,
		string.format(
			"-- ASSETS  (%d referenced, %d loaded, %d missing, %d extra) --",
			#referenced,
			#loaded,
			#missing,
			#extra
		)
	)
	table.insert(lines, "")

	local function show(name)
		return filter == "all" or filter == name
	end

	if show("missing") then
		table.insert(lines, "== MISSING (referenced in HTML, not in netlog) ==")
		if #missing == 0 then
			table.insert(lines, "  (none)")
		else
			for _, r in ipairs(missing) do
				table.insert(lines, format_referenced_line(r, src_only))
			end
		end
		table.insert(lines, "")
	end

	if show("loaded") then
		table.insert(lines, "== LOADED (referenced and fetched) ==")
		if #loaded == 0 then
			table.insert(lines, "  (none)")
		else
			for _, r in ipairs(loaded) do
				table.insert(lines, format_referenced_line(r, src_only))
			end
		end
		table.insert(lines, "")
	end

	if show("extra") then
		local hdr = state.assets_show_html and "== EXTRA (fetched, not in HTML - includes document responses) =="
			or "== EXTRA (fetched, not in HTML) =="
		table.insert(lines, hdr)
		if #extra == 0 then
			table.insert(lines, "  (none)")
		else
			for _, entry in ipairs(extra) do
				table.insert(lines, format_fetched_line(entry, src_only))
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
	local referenced, ref_err = fetch_referenced(state)
	if ref_err then
		vim.notify("browser: " .. ref_err, vim.log.levels.WARN)
		return false
	end
	local fetched, net_err = fetch_netlog(state)
	if net_err then
		vim.notify("browser: " .. net_err, vim.log.levels.WARN)
		return false
	end
	local loaded, missing, extra = compute_diff(referenced, fetched, state.assets_show_html or false)
	state.assets_referenced = referenced
	state.assets_loaded = loaded
	state.assets_missing = missing
	state.assets_extra = extra
	write_buf(buf, M.build_lines(state))
	return true
end

function M.redraw(buf, state)
	write_buf(buf, M.build_lines(state))
end

function M.open(buf, state)
	state.assets_filter = "all"
	state.assets_src_only = false
	state.assets_show_html = false
	state.assets_referenced = {}
	state.assets_loaded = {}
	state.assets_missing = {}
	state.assets_extra = {}
	if not recompute_and_render(buf, state) then
		return
	end
	state.view_mode = "assets"
	if state._update_help_pane then
		state._update_help_pane()
	end
	vim.notify("browser: assets - W reevaluate  b src  m/l/x/A filter  R +html  r refresh  a/<C-o> back")
end

function M.refresh(buf, state)
	if not recompute_and_render(buf, state) then
		return
	end
	vim.notify("browser: assets refreshed")
end

-- W handler: clear netlog, reload page using the tab's saved htmx setting
-- (so partials get partial-injected scripts, full pages stay full), wait,
-- recompute. Mirrors the htmx-resolution logic in keymaps/core.lua's <CR>
-- handler so the re-evaluation matches what a regular navigation does.
function M.reevaluate(buf, state)
	local id = panel_tab_id(state)
	if id == "" then
		vim.notify("browser: no tab selected", vim.log.levels.WARN)
		return
	end
	local meta = meta_for_tab(state, id)
	if not meta then
		vim.notify("browser: no metadata for tab " .. id:sub(1, 8), vim.log.levels.WARN)
		return
	end
	local htmx = resolve_htmx(meta)
	send_cmd("netclear " .. id)
	-- navigate_tab handles switch + targeted navigate using the right cmd.
	local tabops = require("browser.dashboard.tabops")
	tabops.navigate_tab(meta, htmx, state.tab_htmx)
	vim.notify("browser: reloading tab (" .. (htmx and "partial" or "full") .. ") and re-evaluating assets...")
	vim.defer_fn(function()
		if not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		if not recompute_and_render(buf, state) then
			return
		end
		vim.notify("browser: assets re-evaluated")
	end, 1500)
end

function M.toggle_src_only(buf, state)
	state.assets_src_only = not state.assets_src_only
	M.redraw(buf, state)
end

function M.set_filter(buf, state, name)
	state.assets_filter = name
	M.redraw(buf, state)
end

function M.toggle_show_html(buf, state)
	state.assets_show_html = not state.assets_show_html
	local fetched, _ = fetch_netlog(state)
	local loaded, missing, extra = compute_diff(state.assets_referenced or {}, fetched or {}, state.assets_show_html)
	state.assets_loaded = loaded
	state.assets_missing = missing
	state.assets_extra = extra
	M.redraw(buf, state)
end

local function split_recompute(state)
	local referenced, ref_err = fetch_referenced(state)
	if ref_err then
		vim.notify("browser: " .. ref_err, vim.log.levels.WARN)
		return false
	end
	local fetched, net_err = fetch_netlog(state)
	if net_err then
		vim.notify("browser: " .. net_err, vim.log.levels.WARN)
		return false
	end
	local loaded, missing, extra = compute_diff(referenced, fetched, state.split_assets_show_html or false)
	state.split_assets_referenced = referenced
	state.split_assets_loaded = loaded
	state.split_assets_missing = missing
	state.split_assets_extra = extra
	return true
end

local function split_build_lines(state)
	local proxy = {
		assets_referenced = state.split_assets_referenced,
		assets_loaded = state.split_assets_loaded,
		assets_missing = state.split_assets_missing,
		assets_extra = state.split_assets_extra,
		assets_filter = state.split_assets_filter,
		assets_src_only = state.split_assets_src_only,
		assets_show_html = state.split_assets_show_html,
	}
	return M.build_lines(proxy)
end

function M.split_open(state, split_set)
	state.split_assets_filter = "all"
	state.split_assets_src_only = false
	state.split_assets_show_html = false
	if not split_recompute(state) then
		return
	end
	split_set(split_build_lines(state), "text", true)
	state.split_view = "assets"
	if state._update_help_pane then
		state._update_help_pane()
	end
	vim.notify("browser: split assets - W reevaluate  b src  m/l/x/A filter  R +html  r refresh  a/r back")
end

function M.split_refresh(state, split_set)
	if not split_recompute(state) then
		return
	end
	split_set(split_build_lines(state), "text", true)
	vim.notify("browser: split assets refreshed")
end

function M.split_redraw(state, split_set)
	split_set(split_build_lines(state), "text", true)
end

function M.split_toggle_src_only(state, split_set)
	state.split_assets_src_only = not state.split_assets_src_only
	M.split_redraw(state, split_set)
end

function M.split_set_filter(state, split_set, name)
	state.split_assets_filter = name
	M.split_redraw(state, split_set)
end

function M.split_toggle_show_html(state, split_set)
	state.split_assets_show_html = not state.split_assets_show_html
	local fetched, _ = fetch_netlog(state)
	local loaded, missing, extra =
		compute_diff(state.split_assets_referenced or {}, fetched or {}, state.split_assets_show_html)
	state.split_assets_loaded = loaded
	state.split_assets_missing = missing
	state.split_assets_extra = extra
	M.split_redraw(state, split_set)
end

function M.split_reevaluate(state, split_set)
	local id = panel_tab_id(state)
	if id == "" then
		vim.notify("browser: no tab selected", vim.log.levels.WARN)
		return
	end
	local meta = meta_for_tab(state, id)
	if not meta then
		vim.notify("browser: no metadata for tab " .. id:sub(1, 8), vim.log.levels.WARN)
		return
	end
	local htmx = resolve_htmx(meta)
	send_cmd("netclear " .. id)
	local tabops = require("browser.dashboard.tabops")
	tabops.navigate_tab(meta, htmx, state.tab_htmx)
	vim.notify("browser: split reloading tab (" .. (htmx and "partial" or "full") .. ") and re-evaluating assets...")
	vim.defer_fn(function()
		if not split_recompute(state) then
			return
		end
		split_set(split_build_lines(state), "text", true)
		vim.notify("browser: split assets re-evaluated")
	end, 1500)
end

return M
