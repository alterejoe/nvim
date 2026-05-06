-- browser/dashboard/tabops/render.lua
--
-- build_tab_lines: turn a list of fetched tabs into the multi-section
-- text view shown in the dashboard primary buffer.
--
-- Layout per line:
--   <prefix><GET ><content>
--
-- prefix is "(server) " when the tab matches a #### server tag, empty
-- otherwise. The meta map is keyed by content (without prefix and
-- without "GET "), so util.strip_prefix on a buffer line returns the
-- same string. This lets every existing tab_metadata lookup work
-- without per-call adjustments.

local M = {}

local fetch = require("browser.dashboard.tabops.fetch")
local yaml_io = require("browser.dashboard.tabops.yaml_io")

function M.build_tab_lines(tabs, show_chi_path)
	local groups = require("browser.groups").load_groups()
	local headings = yaml_io.load_headings()
	local server_tags = yaml_io.load_server_tags()

	local yaml_order = require("browser.yaml_order")
	local sess = require("browser.session")
	local group_names = yaml_order.resolve_order(
		nil,
		groups,
		yaml_order.read_top_level_order(sess.DEVPROXY_DIR .. "/groups.yaml", "groups")
	)
	local server_tag_order = yaml_order.read_top_level_order(sess.DEVPROXY_DIR .. "/server_tags.yaml", "server_tags")

	for _, t in ipairs(tabs) do
		local decoded = (t.path or ""):gsub("%%7B", "{"):gsub("%%7D", "}")
		t.server = yaml_io.tab_server_for(decoded, server_tags, server_tag_order)
	end

	local tab_to_groups = {}
	for _, name in ipairs(group_names) do
		local chi_paths = type(groups[name]) == "table" and groups[name] or {}
		for _, t in ipairs(tabs) do
			local matched = false
			if t.chi_path then
				for _, cp in ipairs(chi_paths) do
					if t.chi_path == cp then
						matched = true
						break
					end
				end
			end
			if not matched then
				local decoded = t.path:gsub("%%7B", "{"):gsub("%%7D", "}")
				for _, cp in ipairs(chi_paths) do
					if require("browser.dashboard.util").path_matches_chi(decoded, cp) then
						matched = true
						break
					end
				end
			end
			if matched then
				tab_to_groups[t.id] = tab_to_groups[t.id] or {}
				tab_to_groups[t.id][name] = true
			end
		end
	end

	local all_tags = yaml_io.load_tags()
	local tab_to_tags = {}
	for tag_name, chi_paths in pairs(all_tags) do
		if type(chi_paths) == "table" then
			for _, t in ipairs(tabs) do
				local matched = false
				if t.chi_path then
					for _, cp in ipairs(chi_paths) do
						if t.chi_path == cp then
							matched = true
							break
						end
					end
				end
				if not matched then
					local decoded = t.path:gsub("%%7B", "{"):gsub("%%7D", "}")
					for _, cp in ipairs(chi_paths) do
						if require("browser.dashboard.util").path_matches_chi(decoded, cp) then
							matched = true
							break
						end
					end
				end
				if matched then
					tab_to_tags[t.id] = tab_to_tags[t.id] or {}
					tab_to_tags[t.id][tag_name] = true
				end
			end
		end
	end

	local function get_tag_names(tab_id)
		local ts = tab_to_tags[tab_id]
		if not ts then
			return nil
		end
		local result = {}
		for tn in pairs(ts) do
			table.insert(result, tn)
		end
		table.sort(result)
		return result
	end

	local lines = {}
	local meta = {}
	local counts = {}

	local function emit(t)
		local tag_names = get_tag_names(t.id)
		local content = fetch.make_content(t, show_chi_path, tag_names)
		local prefix = ""
		if t.server and t.server ~= "" then
			prefix = "(" .. t.server .. ") "
		end
		table.insert(lines, prefix .. "GET " .. content)
		meta[content] = {
			tab_id = t.id,
			path = t.path,
			chi_path = t.chi_path,
			htmx = t.htmx,
			active = t.active,
			server = t.server,
		}
		counts[t.id] = (counts[t.id] or 0) + 1
	end

	local function emit_under_heading(heading_tabs)
		local seen_in_heading = {}
		for _, name in ipairs(group_names) do
			local group_tabs = {}
			for _, t in ipairs(heading_tabs) do
				if tab_to_groups[t.id] and tab_to_groups[t.id][name] and not seen_in_heading[t.id] then
					table.insert(group_tabs, t)
					seen_in_heading[t.id] = true
				end
			end
			if #group_tabs > 0 then
				table.sort(group_tabs, function(a, b)
					return a.path < b.path
				end)
				table.insert(lines, "## " .. name)
				for _, t in ipairs(group_tabs) do
					emit(t)
				end
			end
		end
		local ungrouped_h = {}
		for _, t in ipairs(heading_tabs) do
			if not seen_in_heading[t.id] then
				table.insert(ungrouped_h, t)
			end
		end
		if #ungrouped_h > 0 then
			table.sort(ungrouped_h, function(a, b)
				return a.path < b.path
			end)
			table.insert(lines, "## ungrouped")
			for _, t in ipairs(ungrouped_h) do
				emit(t)
			end
		end
	end

	local seen_tab_ids = {}
	for _, hname in ipairs(headings.order) do
		local pats = headings.patterns[hname] or {}
		if #pats > 0 then
			local heading_tabs = {}
			for _, t in ipairs(tabs) do
				if not seen_tab_ids[t.id] and yaml_io.tab_matches_heading(t.path, pats) then
					table.insert(heading_tabs, t)
					seen_tab_ids[t.id] = true
				end
			end
			if #heading_tabs > 0 then
				table.insert(lines, "### " .. hname)
				emit_under_heading(heading_tabs)
			end
		end
	end

	local remaining = {}
	for _, t in ipairs(tabs) do
		if not seen_tab_ids[t.id] then
			table.insert(remaining, t)
		end
	end

	if #remaining > 0 then
		if #headings.order > 0 then
			table.insert(lines, "### Other")
		end
		local grouped, ungrouped = {}, {}
		for _, t in ipairs(remaining) do
			local gs = tab_to_groups[t.id]
			if gs and next(gs) then
				for name in pairs(gs) do
					grouped[name] = grouped[name] or {}
					table.insert(grouped[name], t)
				end
			else
				table.insert(ungrouped, t)
			end
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
	end

	return lines, meta, counts
end

return M
