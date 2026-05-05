-- browser/dashboard/httpops/panel.lua
--
-- open_http_panel renders the "e" view: a per-context section listing
-- path / htmx / params for the tab's chi_path. After rendering it
-- registers the params picker (`:` keymap).
--
-- find_http_file resolves the .http test file for a given chi_path and
-- context, falling back to structurally equivalent routes (same static
-- segments and param positions, any param names) when the canonical
-- file isn't present.
--
-- Buffer format produced:
--   # <chi_path>
--
--   --- context: <name> ---
--   path: <resolved>           (display only; not persisted as-is)
--   htmx: true|false
--   params:
--     key: value
--     key: value
--
-- Storage:
--   path params  -> contexts.<ctx>.<key>                (config.yaml)
--   query params -> contexts.<ctx>.query.<chi>.<key>    (config.yaml)
--   htmx         -> .devproxy/tests/<...>.http
--
-- This module is the natural place to extend the rendered format if
-- the panel grows beyond path/htmx/params (e.g. headers, body, form).
-- Add new sections here, and pair the addition with parse.lua.

local M = {}

local util = require("browser.dashboard.util")
local picker = require("browser.dashboard.httpops.picker")

-- ============================================================
-- find_http_file
-- ============================================================
function M.find_http_file(chi_path, ctx)
	local session = require("browser.session")
	local function make_path(cp)
		local slug = cp:gsub("/$", ""):gsub("^/", ""):gsub("/", "-"):gsub("{", ""):gsub("}", "")
		if ctx and ctx ~= "default" and ctx ~= "" then
			return session.TESTS_DIR .. "/" .. ctx .. "/" .. slug .. ".http"
		end
		return session.TESTS_DIR .. "/" .. slug .. ".http"
	end
	local p = make_path(chi_path)
	if vim.fn.filereadable(p) == 1 then
		return p
	end

	-- Fallback: try other routes whose template structurally matches
	-- (same number of segments, params in the same positions).
	local routes = require("browser.views").get_routes()
	local cp_segs = util.segs(chi_path)
	for _, r in ipairs(routes) do
		if r.chi_path ~= chi_path then
			local r_segs = util.segs(r.chi_path)
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

-- ============================================================
-- open_http_panel
-- Renders the panel into buf and sets state.view_mode = "http".
-- Populates state.http_tab_meta, state.http_chi_path, state.http_section_paths.
-- ============================================================
function M.open_http_panel(meta, buf, state)
	local views = require("browser.views")
	local routes = views.get_routes()

	-- Resolve to the canonical chi_path from plan.json.
	local chi_path = meta.chi_path or meta.path
	for _, r in ipairs(routes) do
		if util.path_matches_chi(meta.path, r.chi_path) then
			chi_path = r.chi_path
			break
		end
	end

	local contexts = views.get_contexts()
	state.http_section_paths = {}
	state.http_tab_meta = meta
	state.http_chi_path = chi_path

	-- Read test files for each context to source the htmx flag.
	-- Only htmx lives in test files now; query lives in config.yaml.
	local sections = {}
	for _, ctx in ipairs(contexts) do
		local fpath = M.find_http_file(chi_path, ctx)
		state.http_section_paths[ctx] = fpath
		local htmx_val = nil
		local f = io.open(fpath, "r")
		if f then
			for line in f:lines() do
				local label, val = line:match("^([%w%.%-_]+):%s*(.*)")
				if label and label:lower() == "htmx" then
					htmx_val = vim.trim(val) == "true"
				end
			end
			f:close()
		end
		table.insert(sections, { context = ctx, htmx = htmx_val })
	end

	-- Build the buffer text: one section per context.
	local new_lines = { "# " .. chi_path, "" }
	for i, sec in ipairs(sections) do
		table.insert(new_lines, "--- context: " .. sec.context .. " ---")
		local injected = views.resolve_path_for_context(chi_path, sec.context)
		table.insert(new_lines, "path: " .. injected)
		if sec.htmx ~= nil then
			table.insert(new_lines, "htmx: " .. tostring(sec.htmx))
		else
			table.insert(new_lines, "htmx: false")
		end
		table.insert(new_lines, "params:")
		local q = views.query_for_route(sec.context, chi_path)
		local keys = {}
		for k in pairs(q) do
			table.insert(keys, k)
		end
		table.sort(keys)
		for _, k in ipairs(keys) do
			table.insert(new_lines, "  " .. k .. ": " .. q[k])
		end
		if i < #sections then
			table.insert(new_lines, "")
		end
	end

	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
	vim.bo[buf].filetype = "http"
	vim.bo[buf].modified = false
	state.view_mode = "http"

	-- Register `:` to fire the param picker when inside a params block.
	picker.install(buf, state)

	vim.notify("browser: http editor - W=save  :=add param  <leader>w=curl  e/r=back")
end

return M
