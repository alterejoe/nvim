-- browser/dashboard/tabops/save.lua

local M = {}

local util = require("browser.dashboard.util")
local fetch = require("browser.dashboard.tabops.fetch")

local function send_cmd(cmd)
	return require("browser.session").send_cmd(cmd)
end

local function get_proxy_base(server)
	local raw = send_cmd("proxy-port " .. (server or ""))
	if raw and raw ~= "" and not vim.startswith(raw, "err") then
		return "http://localhost:" .. vim.trim(raw)
	end
	return "http://localhost:19878"
end

local function yq_quote_path(s)
	return '"' .. s:gsub('"', '\\"') .. '"'
end

local function yq_set_string(yaml_path, dotted_path, value)
	local v = tostring(value):gsub('"', '\\"')
	vim.fn.system(
		string.format(
			"yq -i '%s = \"%s\"' %s 2>/dev/null",
			dotted_path,
			v,
			vim.fn.shellescape(yaml_path)
		)
	)
	return vim.v.shell_error == 0
end

local function parse_query_string(qs)
	local out = {}
	if not qs or qs == "" then
		return out
	end
	qs = qs:gsub("^%?", "")
	for pair in qs:gmatch("[^&]+") do
		local k, v = pair:match("^([^=]+)=(.*)$")
		if k and k ~= "" then
			out[k] = v or ""
		end
	end
	return out
end

function M.on_save_tabs(state)
	local buf = state.primary_buf
	local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local routes_ref = require("browser.views").get_routes()
	local groups_chi_ref = fetch.groups_chi_list()

	local function extract_tab_short(line)
		return line:match("%[(%x%x%x%x%x%x%x%x)%]")
	end

	local short_to_meta = {}
	for _, m in pairs(state.tab_metadata) do
		short_to_meta[m.tab_id:sub(1, 8):upper()] = m
	end

	local before_counts = state.tab_counts or {}
	local after_counts = {}
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
				after_counts[m.tab_id] = (after_counts[m.tab_id] or 0) + 1
				local content = util.strip_prefix(trimmed)
				if not state.tab_metadata[content] then
					local p = content
						:gsub("^%u+%s+", "")
						:gsub("%s+%[[%x]+%].*$", "")
						:gsub("%s+%[partial%].*$", "")
						:gsub("%s+%[full%].*$", "")
						:gsub("%s+%[%a[%a%d%-_]*%].*$", "")
					p = vim.trim(p)
					if p ~= "" and p:sub(1, 1) == "/" then
						local path_only = p:match("^([^?]+)") or p
						local query_str = p:match("%?(.*)$") or ""
						local chi = m.chi_path
						if not chi then
							for _, r in ipairs(routes_ref) do
								if r.chi_path and util.path_matches_chi(path_only, r.chi_path) then
									chi = r.chi_path
									break
								end
							end
						end
						if not chi then
							for _, cp in ipairs(groups_chi_ref) do
								if util.path_matches_chi(path_only, cp) then
									chi = cp
									break
								end
							end
						end
						edited_tabs[m.tab_id] = {
							path = path_only,
							query = query_str,
							chi_path = chi,
							htmx = m.htmx or false,
							server = m.server,
						}
					end
				end
			end
		else
			local meta = state.tab_metadata[util.strip_prefix(trimmed)]
			if meta then
				after_counts[meta.tab_id] = (after_counts[meta.tab_id] or 0) + 1
			end
		end
		::scan_next::
	end

	local needs_refresh = false
	local had_param_changes = false
	local closed_count = 0
	local total_count = 0
	local closed_ids = {}

	for _, meta in pairs(state.tab_metadata) do
		total_count = total_count + 1
		if closed_ids[meta.tab_id] then
			goto next_close
		end
		if (after_counts[meta.tab_id] or 0) < (before_counts[meta.tab_id] or 0) then
			send_cmd("close-tab " .. meta.tab_id)
			state.tab_htmx[meta.tab_id] = nil
			vim.notify("browser: closed " .. meta.path)
			needs_refresh = true
			closed_count = closed_count + 1
			closed_ids[meta.tab_id] = true
		end
		::next_close::
	end

	if closed_count > 0 and closed_count >= total_count then
		vim.defer_fn(function()
			send_cmd("open " .. get_proxy_base(nil))
			vim.notify("browser: all tabs closed - opened new tab")
		end, 400)
	end

	if next(edited_tabs) then
		local views = require("browser.views")
		local session = require("browser.session")
		local ctx = views.get_active_context()
		local ctx_key = ctx == "" and "default" or ctx
		local yaml_path = session.DEVPROXY_DIR .. "/config.yaml"
		local yaml_ok = vim.fn.filereadable(yaml_path) == 1
		local path_params_changed = {}
		local query_params_by_chi = {}

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
							path_params_changed[pname] = val
						end
					end
				end
			end
			query_params_by_chi[info.chi_path] = parse_query_string(info.query)
			::skip_params::
		end

		if not yaml_ok then
			vim.notify("browser: config.yaml not found - params not saved", vim.log.levels.WARN)
		end

		if yaml_ok and next(path_params_changed) then
			for k, v in pairs(path_params_changed) do
				local dotted = string.format(".contexts.%s.%s", ctx_key, k)
				if not yq_set_string(yaml_path, dotted, v) then
					vim.notify("browser: yq write failed for " .. k, vim.log.levels.WARN)
				end
			end
			had_param_changes = true
		end

		local merged_query_by_chi = {}
		if yaml_ok then
			for chi_path, qmap in pairs(query_params_by_chi) do
				merged_query_by_chi[chi_path] = merged_query_by_chi[chi_path] or {}
				for k, v in pairs(qmap) do
					merged_query_by_chi[chi_path][k] = v
				end
			end
			for chi_path, qmap in pairs(merged_query_by_chi) do
				local route_path = string.format(
					".contexts.%s.query[%s]",
					ctx_key,
					yq_quote_path(chi_path)
				)
				vim.fn.system(
					string.format(
						"yq -i 'del(%s)' %s 2>/dev/null",
						route_path,
						vim.fn.shellescape(yaml_path)
					)
				)
				for k, v in pairs(qmap) do
					local dotted = string.format(
						".contexts.%s.query[%s].%s",
						ctx_key,
						yq_quote_path(chi_path),
						k
					)
					if not yq_set_string(yaml_path, dotted, v) then
						vim.notify("browser: yq query write failed for " .. k, vim.log.levels.WARN)
					end
				end
				had_param_changes = true
			end
		end

		if had_param_changes then
			views.reload_config_silent()
		end

		local written = {}
		for _, m in pairs(state.tab_metadata) do
			local info = edited_tabs[m.tab_id]
			if info and info.chi_path and not written[info.chi_path] then
				written[info.chi_path] = true
				local qkeys = {}
				local qmap = merged_query_by_chi[info.chi_path] or {}
				for k, _ in pairs(qmap) do
					table.insert(qkeys, k)
				end
				table.sort(qkeys)
				views.write_test_file(info.chi_path, ctx, {
					htmx = m.htmx or false,
					query_keys = qkeys,
				})
			end
		end

		local existing = views.params_for_context(views.get_active_context())
		local function resolve_direct(cp)
			local result = cp
			for param in cp:gmatch("{([^}]+)}") do
				local v = path_params_changed[param]
				if not v or v == "" or v:find("{") or v:match("%%7[Bb]") then
					v = existing[param] or ""
				end
				if v ~= "" and not v:find("{") and not v:match("%%7[Bb]") then
					result = result:gsub("{" .. vim.pesc(param) .. "}", v, 1)
				end
			end
			return result
		end

		if next(path_params_changed) then
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
						if path_params_changed[param] then
							should_nav = true
							break
						end
					end
					if should_nav then
						local nav = resolve_direct(chi)
						if not nav:find("{") then
							local cmd = (m.htmx or false) and "navigate" or "navigate-full"
							local saved = views.load_test_for_path(chi)
							local q = views.build_query_string(views.query_for_route(ctx_key, chi, saved.query_keys))
							local fsrv = (m.server and m.server ~= "") and (" --server=" .. m.server) or ""
							local proxy = get_proxy_base(m.server)
							local url = (m.htmx or false) and (nav .. q) or (proxy .. nav .. q)
							send_cmd(cmd .. " --tab=" .. m.tab_id .. fsrv .. " " .. url)
						end
					end
					::nav_next::
				end
			end)

			vim.notify(
				string.format(
					"browser: [%s] updated %s - re-navigating affected tabs",
					ctx,
					vim.inspect(path_params_changed):gsub('[{} "\n]', "")
				)
			)
		end

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
					local q = ""
					if en.info.chi_path then
						local saved = views.load_test_for_path(en.info.chi_path)
						q = views.build_query_string(views.query_for_route(ctx_key, en.info.chi_path, saved.query_keys))
					end
					local em = short_to_meta[en.tab_id:sub(1, 8):upper()]
					local esrv = (em and em.server and em.server ~= "") and (" --server=" .. em.server) or ""
					local proxy = get_proxy_base(em and em.server or nil)
					local url = en.info.htmx and (en.info.path .. q) or (proxy .. en.info.path .. q)
					send_cmd(cmd .. " --tab=" .. en.tab_id .. esrv .. " " .. url)
					vim.notify("browser: " .. (en.info.htmx and "[partial]" or "[full]") .. " " .. en.info.path .. q)
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
				send_cmd("open " .. get_proxy_base(nil) .. new_path)
				vim.notify("browser: opened tab -> " .. new_path)
				needs_refresh = true
			end
		end
		::continue::
	end

	return not needs_refresh and not had_param_changes
end

return M
