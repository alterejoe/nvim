-- browser/dashboard/tabops.lua
-- Tab list operations: fetch, build, navigate, on_save.
-- All functions that require per-open state accept a `state` table.

local M = {}

local util = require("browser.dashboard.util")

local function send_cmd(cmd)
	return require("browser.session").send_cmd(cmd)
end

local function tags_path()
	return require("browser.session").DEVPROXY_DIR .. "/tags.yaml"
end

function M.load_tags()
	local path = tags_path()
	if vim.fn.filereadable(path) == 0 then
		return {}
	end
	local raw = vim.fn.system("yq -o=json . " .. vim.fn.shellescape(path) .. " 2>/dev/null")
	local ok, data = pcall(vim.json.decode, raw)
	if not ok or not data or not data.tags or type(data.tags) ~= "table" then
		return {}
	end
	local result = {}
	for name, paths in pairs(data.tags) do
		result[name] = type(paths) == "table" and paths or {}
	end
	return result
end

function M.save_tags(tags)
	local path = tags_path()
	local names = {}
	for name in pairs(tags) do
		table.insert(names, name)
	end
	table.sort(names)
	local lines = { "tags:" }
	for _, name in ipairs(names) do
		table.insert(lines, "  " .. name .. ":")
		for _, p in ipairs(tags[name] or {}) do
			table.insert(lines, "    - " .. p)
		end
	end
	local f = io.open(path, "w")
	if f then
		f:write(table.concat(lines, "\n") .. "\n")
		f:close()
	end
end

local function get_base_url()
	local raw = send_cmd("active-server")
	if raw then
		local port = raw:match("port (%d+)")
		if port then
			return "http://localhost:" .. port
		end
	end
	return "http://localhost:3333"
end

-- ============================================================
-- groups_chi_list
-- Returns a flat list of all chi_path templates from groups.yaml.
-- Used as fallback when plan.json routes don't cover a path.
-- ============================================================
local function groups_chi_list()
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

-- ============================================================
-- infer_chi_path
-- Returns the chi_path template for a tab. Checks the tab's own
-- chi_path first, then groups, then all routes from plan.json.
-- ============================================================
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

-- ============================================================
-- make_content
-- Builds the display string for a tab line (without GET prefix).
-- htmx preference comes from the saved test file when available.
-- ============================================================
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
	local display_path = (show_chi_path and chi) or raw_path
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
	return (display_path or raw_path) .. "  [" .. short_id .. "]" .. htmx_ann .. tag_ann
end

-- ============================================================
-- fetch_tabs
-- Syncs tab state from devproxy. Returns a list of tab objects.
-- tab_htmx: table of tab_id -> bool, carries htmx preference across refreshes.
-- ============================================================
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
	local gchi = groups_chi_list()

	-- Always re-infer chi_path from the current tab URL on every sync.
	-- Checks routes (plan.json) first, then groups.yaml as fallback.
	-- Groups are the user's explicit source of truth and cover paths that
	-- plan.json may omit or name differently.
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
		-- On first load tab_htmx is empty. Seed from the saved test file so
		-- that CR and t use the correct partial/full preference immediately.
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

-- ============================================================
-- build_tab_lines
-- Builds display lines sorted under group headers.
-- A tab can appear under multiple group headers simultaneously.
-- Tags are shown as annotations [tagname] on each line.
-- Returns: lines (list), metadata (content_key -> meta).
-- ============================================================
function M.build_tab_lines(tabs, show_chi_path)
	local groups = require("browser.groups").load_groups()
	local group_names = {}
	for name in pairs(groups) do
		table.insert(group_names, name)
	end
	table.sort(group_names)

	-- Map each tab to ALL groups it belongs to.
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
					if util.path_matches_chi(decoded, cp) then
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

	-- Load tags: shown as [tagname] annotations but do NOT create extra group headers.
	local all_tags = M.load_tags()
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
						if util.path_matches_chi(decoded, cp) then
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

	local grouped, ungrouped = {}, {}
	for _, t in ipairs(tabs) do
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

	local lines = {}
	local meta = {}

	local function emit(t)
		local tag_names = get_tag_names(t.id)
		local content = M.make_content(t, show_chi_path, tag_names)
		table.insert(lines, "GET " .. content)
		meta[content] = {
			tab_id = t.id,
			path = t.path,
			chi_path = t.chi_path,
			htmx = t.htmx,
			active = t.active,
		}
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

	return lines, meta
end

-- ============================================================
-- navigate_tab
-- Switches to a tab and navigates it using the active context params.
-- ============================================================
function M.navigate_tab(meta, htmx, tab_htmx)
	if not meta then
		return
	end
	tab_htmx[meta.tab_id] = htmx
	send_cmd("switch " .. meta.tab_id)

	local chi = meta.chi_path or M.infer_chi_path(meta)
	if chi then
		local views = require("browser.views")
		local params = views.params_for_context(views.get_active_context())
		local resolved = chi
		for param in chi:gmatch("{([^}]+)}") do
			local v = params[param]
			if v and v ~= "" and not v:find("{") and not v:match("%%7[Bb]") then
				resolved = resolved:gsub("{" .. vim.pesc(param) .. "}", v, 1)
			end
		end
		if resolved:find("{") then
			vim.notify("browser: unresolved params in " .. chi, vim.log.levels.WARN)
			return
		end
		local saved = views.load_test_for_path(chi)
		local qp = (saved and saved.qp ~= "" and ("?" .. saved.qp)) or ""
		local base = views.get_active_base()
		local cmd = htmx and "navigate" or "navigate-full"
		send_cmd(cmd .. " " .. base .. resolved .. qp)
		vim.notify(string.format("browser: %s%s%s", resolved, qp, htmx and " [partial]" or " [full]"))
	else
		local cmd = htmx and "navigate" or "navigate-full"
		send_cmd(cmd .. " " .. get_base_url() .. meta.path)
		vim.notify("browser: " .. (htmx and "[partial]" or "[full]") .. " " .. meta.path)
	end
end

-- ============================================================
-- open_path
-- Always opens a new tab. Tab management is manual via dd+W.
-- ============================================================
function M.open_path(chi_path, buf, tab_metadata, do_buf_refresh_fn)
	local views = require("browser.views")
	local base = views.get_active_base()
	local saved = views.load_test_for_path(chi_path)
	local path = views.resolve_path(chi_path)
	local qp = (saved and saved.qp ~= "" and ("?" .. saved.qp)) or ""
	send_cmd("open " .. base .. path .. qp)
	vim.notify("browser: opened tab -> " .. path)
	vim.defer_fn(function()
		if vim.api.nvim_buf_is_valid(buf) then
			do_buf_refresh_fn(buf)
		end
	end, 600)
end

-- ============================================================
-- on_save_tabs
-- ============================================================
function M.on_save_tabs(state)
	local buf = state.primary_buf
	local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local routes_ref = require("browser.views").get_routes()
	local groups_chi_ref = groups_chi_list()

	local function extract_tab_short(line)
		return line:match("%[(%x%x%x%x%x%x%x%x)%]")
	end

	local short_to_meta = {}
	for _, m in pairs(state.tab_metadata) do
		short_to_meta[m.tab_id:sub(1, 8):upper()] = m
	end

	local present_ids = {}
	local edited_tabs = {}

	for _, line in ipairs(buf_lines) do
		local trimmed = vim.trim(line)
		if trimmed == "" or trimmed:sub(1, 2) == "##" then
			goto scan_next
		end

		local short = extract_tab_short(trimmed)
		if short then
			local m = short_to_meta[short:upper()]
			if m then
				present_ids[m.tab_id] = true
				local content = util.strip_prefix(trimmed)
				if not state.tab_metadata[content] then
					local p = content
						:gsub("^%u+%s+", "")
						:gsub("%s+%[[%x]+%].*$", "")
						:gsub("%s+%[partial%].*$", "")
						:gsub("%s+%[full%].*$", "")
						:gsub("%s+%[%a[%a%d%-_]*%].*$", "") -- strip tag annotations
					p = vim.trim(p)
					if p ~= "" and p:sub(1, 1) == "/" then
						local chi = m.chi_path
						if not chi then
							for _, r in ipairs(routes_ref) do
								if r.chi_path and util.path_matches_chi(p, r.chi_path) then
									chi = r.chi_path
									break
								end
							end
						end
						if not chi then
							for _, cp in ipairs(groups_chi_ref) do
								if util.path_matches_chi(p, cp) then
									chi = cp
									break
								end
							end
						end
						edited_tabs[m.tab_id] = { path = p, chi_path = chi, htmx = m.htmx or false }
					end
				end
			end
		else
			local meta = state.tab_metadata[util.strip_prefix(trimmed)]
			if meta then
				present_ids[meta.tab_id] = true
			end
		end
		::scan_next::
	end

	local needs_refresh = false
	local had_param_changes = false
	local closed_count = 0
	local total_count = 0

	for _, meta in pairs(state.tab_metadata) do
		total_count = total_count + 1
		if not present_ids[meta.tab_id] then
			send_cmd("close-tab " .. meta.tab_id)
			state.tab_htmx[meta.tab_id] = nil
			vim.notify("browser: closed " .. meta.path)
			needs_refresh = true
			closed_count = closed_count + 1
		end
	end

	if closed_count > 0 and closed_count >= total_count then
		vim.defer_fn(function()
			send_cmd("open " .. get_base_url())
			vim.notify("browser: all tabs closed - opened new tab")
		end, 400)
	end

	if next(edited_tabs) then
		local views = require("browser.views")
		local session = require("browser.session")
		local ctx = views.get_active_context()
		local ctx_key = ctx == "" and "default" or ctx
		local yaml_path = session.DEVPROXY_DIR .. "/config.yaml"
		local params_changed = {}

		for _, info in pairs(edited_tabs) do
			if not info.chi_path then
				goto skip_params
			end
			local chi_s = util.segs(info.chi_path)
			local res_s = util.segs(info.path)
			if #chi_s == #res_s then
				for i, c in ipairs(chi_s) do
					if c:sub(1, 1) == "{" then
						local pname = c:match("{(.+)}")
						local val = res_s[i]
						if pname and val and val ~= "" and not val:find("{") and not val:match("%%7[Bb]") then
							params_changed[pname] = val
						end
					end
				end
			end
			::skip_params::
		end

		if next(params_changed) then
			if vim.fn.filereadable(yaml_path) == 1 then
				for k, v in pairs(params_changed) do
					vim.fn.system(
						string.format(
							"yq -i '.contexts.%s.%s = \"%s\"' %s 2>/dev/null",
							ctx_key,
							k,
							v:gsub('"', '\\"'),
							vim.fn.shellescape(yaml_path)
						)
					)
					if vim.v.shell_error ~= 0 then
						vim.notify("browser: yq write failed for " .. k, vim.log.levels.WARN)
					end
				end
				views.reload_config_silent()
				had_param_changes = true
			else
				vim.notify("browser: config.yaml not found - params not saved", vim.log.levels.WARN)
			end

			local written = {}
			for _, m in pairs(state.tab_metadata) do
				local info = edited_tabs[m.tab_id]
				if info and not written[info.chi_path] then
					written[info.chi_path] = true
					local fpath = views.test_file_path(info.chi_path, ctx)
					vim.fn.mkdir(vim.fn.fnamemodify(fpath, ":h"), "p")
					local wf = io.open(fpath, "w")
					if wf then
						wf:write("htmx: " .. tostring(m.htmx or false) .. "\n")
						wf:close()
					end
				end
			end

			local base = views.get_active_base()
			local existing = views.params_for_context(views.get_active_context())
			local function resolve_direct(cp)
				local result = cp
				for param in cp:gmatch("{([^}]+)}") do
					local v = params_changed[param]
					if not v or v == "" or v:find("{") or v:match("%%7[Bb]") then
						v = existing[param] or ""
					end
					if v ~= "" and not v:find("{") and not v:match("%%7[Bb]") then
						result = result:gsub("{" .. vim.pesc(param) .. "}", v, 1)
					end
				end
				return result
			end

			local meta_snapshot = {}
			for k, v in pairs(state.tab_metadata) do
				meta_snapshot[k] = v
			end

			vim.schedule(function()
				for _, m in pairs(meta_snapshot) do
					if edited_tabs[m.tab_id] then
						goto nav_next
					end
					local chi = m.chi_path
					if not chi then
						local decoded = m.path:gsub("%%7B", "{"):gsub("%%7D", "}")
						for _, r in ipairs(routes_ref) do
							if r.chi_path and util.path_matches_chi(decoded, r.chi_path) then
								chi = r.chi_path
								break
							end
						end
						if not chi then
							for _, cp in ipairs(groups_chi_ref) do
								if util.path_matches_chi(decoded, cp) then
									chi = cp
									break
								end
							end
						end
					end
					if not chi then
						goto nav_next
					end
					local should_nav = false
					for param in chi:gmatch("{([^}]+)}") do
						if params_changed[param] then
							should_nav = true
							break
						end
					end
					if should_nav then
						local nav = resolve_direct(chi)
						if not nav:find("{") then
							send_cmd("switch " .. m.tab_id)
							local cmd = (m.htmx or false) and "navigate" or "navigate-full"
							send_cmd(cmd .. " " .. base .. nav)
						end
					end
					::nav_next::
				end
			end)

			vim.notify(
				string.format(
					"browser: [%s] updated %s - re-navigating affected tabs",
					ctx,
					vim.inspect(params_changed):gsub('[{} "\n]', "")
				)
			)
		end

		local base = require("browser.views").get_active_base()
		local edited_nav = {}
		for tab_id, info in pairs(edited_tabs) do
			if not info.path:find("{") and not info.path:match("%%7[Bb]") then
				table.insert(edited_nav, { tab_id = tab_id, info = info })
				needs_refresh = true
			end
		end
		if #edited_nav > 0 then
			vim.schedule(function()
				for _, en in ipairs(edited_nav) do
					send_cmd("switch " .. en.tab_id)
					local cmd = en.info.htmx and "navigate" or "navigate-full"
					send_cmd(cmd .. " " .. base .. en.info.path)
					vim.notify("browser: " .. (en.info.htmx and "[partial]" or "[full]") .. " " .. en.info.path)
				end
			end)
		end
	end

	for _, line in ipairs(buf_lines) do
		local trimmed = vim.trim(line)
		if trimmed == "" or trimmed:sub(1, 2) == "##" then
			goto continue
		end
		if not trimmed:match("%[%x%x%x%x%x%x%x%x%]") then
			local new_path = util.strip_prefix(trimmed)
				:gsub("^%u+%s+", "")
				:gsub("%s+%[[%x]+%].*$", "")
				:gsub("%s+%[partial%].*$", "")
				:gsub("%s+%[full%].*$", "")
			new_path = vim.trim(new_path)
			if new_path ~= "" and new_path:sub(1, 1) == "/" then
				send_cmd("open " .. get_base_url() .. new_path)
				vim.notify("browser: opened tab -> " .. new_path)
				needs_refresh = true
			end
		end
		::continue::
	end

	return not needs_refresh and not had_param_changes
end

return M
