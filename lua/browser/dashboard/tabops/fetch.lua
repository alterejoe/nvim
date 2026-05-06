-- browser/dashboard/tabops/fetch.lua
--
-- Tab fetching from devproxy and per-tab metadata helpers.
--
--   fetch_tabs(tab_htmx)            - sync-tabs over socket, attach inferred
--                                     chi_path and saved htmx preference
--   infer_chi_path(t)               - find the chi_path template for a tab
--   make_content(t, show_chi_path,  - build the display string for a tab
--                tag_names)            line (without the leading "GET "
--                                     and without the server prefix)
--
-- The server prefix "(name) " is rendered in render.lua's emit() so
-- that meta keys remain independent of the prefix. This keeps every
-- existing tab_metadata lookup site working: util.strip_prefix on a
-- raw line strips both "(server) " and "GET ", returning the same
-- string used as the meta key.

local M = {}

local util = require("browser.dashboard.util")

local function send_cmd(cmd)
	return require("browser.session").send_cmd(cmd)
end

function M.groups_chi_list()
	local result = {}
	local grps = require("browser.groups").load_groups()
	for _, paths in pairs(grps) do
		if type(paths) == "table" then
			for _, cp in ipairs(paths) do
				if cp and cp ~= "" then
					table.insert(result, cp)
				end
			end
		end
	end
	return result
end

function M.infer_chi_path(t)
	if t.chi_path then
		return t.chi_path
	end
	local groups = require("browser.groups").load_groups()
	for _, paths in pairs(groups) do
		if type(paths) == "table" then
			for _, cp in ipairs(paths) do
				if util.path_matches_chi(t.path, cp) then
					return cp
				end
			end
		end
	end
	local routes = require("browser.views").get_routes()
	for _, r in ipairs(routes) do
		if r.chi_path and util.path_matches_chi(t.path, r.chi_path) then
			return r.chi_path
		end
	end
	return nil
end

-- make_content
-- Builds the display string for a tab line WITHOUT the server prefix
-- and WITHOUT the leading "GET ". The server prefix is rendered by
-- the caller (render.emit) so that meta keys stay independent of
-- presentation.
function M.make_content(t, show_chi_path, tag_names)
	local short_id = t.id:sub(1, 8)
	local chi = M.infer_chi_path(t)
	local is_partial = t.htmx
	if chi then
		local saved = require("browser.views").load_test_for_path(chi)
		if saved and saved.htmx ~= nil then
			is_partial = saved.htmx
		end
	end
	local htmx_ann = is_partial and "  [partial]" or ""
	local raw_path = t.path:gsub("%%7B", "{"):gsub("%%7D", "}")

	local q_suffix = ""
	if chi then
		local views = require("browser.views")
		local q_map = views.query_for_route(views.get_active_context(), chi)
		if next(q_map) then
			if show_chi_path then
				q_suffix = views.build_query_template(q_map)
			else
				q_suffix = views.build_query_string(q_map)
			end
		end
	end

	local raw_path_no_q = raw_path:match("^([^?]+)") or raw_path
	local display_path
	if show_chi_path and chi then
		display_path = chi .. q_suffix
	else
		display_path = raw_path_no_q .. q_suffix
	end

	local tag_ann = ""
	if tag_names then
		local sorted = {}
		for _, tn in ipairs(tag_names) do
			table.insert(sorted, tn)
		end
		table.sort(sorted)
		for _, tn in ipairs(sorted) do
			tag_ann = tag_ann .. "  [" .. tn .. "]"
		end
	end
	return display_path .. "  [" .. short_id .. "]" .. htmx_ann .. tag_ann
end

function M.fetch_tabs(tab_htmx)
	local raw = send_cmd("sync-tabs")
	if not raw or raw:sub(1, 1) ~= "[" then
		return {}
	end
	local ok, tabs = pcall(vim.json.decode, raw)
	if not ok then
		return {}
	end
	local session = require("browser.session")
	local routes = require("browser.views").get_routes()
	local gchi = M.groups_chi_list()

	for _, t in ipairs(tabs) do
		local path = t.path or t.id
		local decoded = path:gsub("%%7B", "{"):gsub("%%7D", "}")
		local found = nil
		for _, r in ipairs(routes) do
			if r.chi_path and util.path_matches_chi(decoded, r.chi_path) then
				found = r.chi_path
				break
			end
		end
		if not found then
			for _, cp in ipairs(gchi) do
				if util.path_matches_chi(decoded, cp) then
					found = cp
					break
				end
			end
		end
		session._tab_paths[t.id] = found
	end

	local views = require("browser.views")
	local result = {}
	for _, t in ipairs(tabs) do
		local chi = session._tab_paths[t.id]
		if tab_htmx[t.id] == nil and chi then
			local saved = views.load_test_for_path(chi)
			if saved and saved.htmx ~= nil then
				tab_htmx[t.id] = saved.htmx
			end
		end
		table.insert(result, {
			id = t.id,
			path = t.path or t.id,
			chi_path = chi,
			active = t.active,
			htmx = tab_htmx[t.id] or false,
		})
	end
	return result
end

return M
