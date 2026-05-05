-- browser/dashboard/httpops/save.lua
--
-- on_save_http is the W handler for the http panel. It reads every
-- per-context section, derives:
--   path params  from the displayed (resolved) path, by segment-matching
--                against the chi_path template,
--   htmx         from each section's htmx: line,
--   query params from each section's params: block,
-- then persists each according to the storage layout:
--   path params  -> contexts.<ctx>.<key>            in config.yaml
--   query params -> contexts.<ctx>.query.<chi>.<k>  in config.yaml (wipe
--                   route block first, then write each entry; deleting
--                   a line removes the entry from config)
--   htmx         -> tests/<ctx?>/<slug>.http
--   query KEYS   -> same test file, under
--                     query:
--                       - keyname
--                   The key list is the source of truth for "what keys
--                   this route uses." Values stay in config.yaml so
--                   they're context-swappable.
--
-- After persistence:
--   - reload_config_silent so other readers see the changes,
--   - re-navigate the active tab to its new resolved URL,
--   - fan out: re-navigate other open tabs whose chi_path shares any
--     of the changed PATH params (query params are per-route and
--     don't fan out).

local M = {}

local util = require("browser.dashboard.util")
local parse = require("browser.dashboard.httpops.parse")

local function send_cmd(cmd)
	return require("browser.session").send_cmd(cmd)
end

-- ============================================================
-- yq helpers
-- All write operations go through yq so config.yaml stays clean
-- (preserves unrelated keys, comments, and ordering).
-- ============================================================
local function yq_quote_path(s)
	-- chi_paths contain slashes and braces; quote with double quotes
	-- inside the yq path expression so they're treated as a single key.
	return '"' .. s:gsub('"', '\\"') .. '"'
end

local function yq_set_string(yaml_path, dotted_path, value)
	local v = tostring(value):gsub('"', '\\"')
	vim.fn.system(string.format("yq -i '%s = \"%s\"' %s 2>/dev/null", dotted_path, v, vim.fn.shellescape(yaml_path)))
	return vim.v.shell_error == 0
end

local function yq_delete(yaml_path, dotted_path)
	vim.fn.system(string.format("yq -i 'del(%s)' %s 2>/dev/null", dotted_path, vim.fn.shellescape(yaml_path)))
	return vim.v.shell_error == 0
end

-- ============================================================
-- on_save_http
-- ============================================================
function M.on_save_http(state)
	local buf = state.primary_buf
	local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local views = require("browser.views")
	local session = require("browser.session")
	local yaml_path = session.DEVPROXY_DIR .. "/config.yaml"
	local active_ctx = views.get_active_context()
	local active_ctx_key = active_ctx == "" and "default" or active_ctx
	local chi_path = state.http_chi_path

	if not chi_path then
		vim.notify("browser: no active http context", vim.log.levels.WARN)
		return true
	end

	local sections = parse.parse_buffer(all_lines)
	local active_path_params_changed = {}
	local active_query_params = {}
	local yaml_ok = vim.fn.filereadable(yaml_path) == 1
	if not yaml_ok then
		vim.notify("browser: config.yaml not found - params not saved", vim.log.levels.WARN)
	end

	for _, sec in ipairs(sections) do
		local sec_ctx_key = sec.ctx == "" and "default" or sec.ctx

		-- Derive path params from the displayed (injected) path. Walk
		-- the chi template segments; wherever there's a {param}, take
		-- the corresponding segment from the displayed path as its value.
		local sec_path_params = {}
		if sec.path and sec.path ~= "" then
			local chi_s = util.segs(chi_path)
			local res_s = util.segs(sec.path)
			if #chi_s == #res_s then
				for i, c in ipairs(chi_s) do
					if c:sub(1, 1) == "{" then
						local pname = c:match("{(.+)}")
						local val = res_s[i]
						if pname and val and val ~= "" and not val:find("{") and not val:match("%%7[Bb]") then
							sec_path_params[pname] = val
						end
					end
				end
			end
		end

		-- Persist path params under contexts.<ctx>.<key>.
		if yaml_ok and next(sec_path_params) then
			for k, v in pairs(sec_path_params) do
				if not yq_set_string(yaml_path, "." .. ".contexts." .. sec_ctx_key .. "." .. k, v) then
					vim.notify("browser: yq write failed for " .. k, vim.log.levels.WARN)
				end
			end
		end

		-- Build q_map (the section's params block as a key->value table)
		-- before writing. We need q_map for both the config.yaml writes
		-- AND the test file's query_keys list.
		local q_map = {}
		local sec_qkeys = {}
		for _, kv in ipairs(sec.params) do
			if kv.key ~= "" then
				q_map[kv.key] = kv.val
				table.insert(sec_qkeys, kv.key)
			end
		end

		-- Persist query params under contexts.<ctx>.query.<chi>.<key>.
		-- Wipe-and-rewrite: delete the route block first, then write
		-- each entry. Removing a line in the editor removes it from
		-- config.
		if yaml_ok then
			local route_path = string.format(".contexts.%s.query[%s]", sec_ctx_key, yq_quote_path(chi_path))
			yq_delete(yaml_path, route_path)
			for k, v in pairs(q_map) do
				local dotted = string.format(".contexts.%s.query[%s].%s", sec_ctx_key, yq_quote_path(chi_path), k)
				if not yq_set_string(yaml_path, dotted, v) then
					vim.notify("browser: yq query write failed for " .. k, vim.log.levels.WARN)
				end
			end
			if sec_ctx_key == active_ctx_key then
				active_query_params = q_map
			end
		end

		-- Persist htmx + query_keys to the test file. write_test_file
		-- preserves any field not provided, so passing both htmx and
		-- query_keys here makes the edited section authoritative for
		-- both. q_map keys order isn't deterministic; sort for stability.
		table.sort(sec_qkeys)
		views.write_test_file(chi_path, sec.ctx, {
			htmx = sec.htmx,
			query_keys = sec_qkeys,
		})

		if sec_ctx_key == active_ctx_key then
			active_path_params_changed = sec_path_params
		end
	end

	views.reload_config_silent()

	-- Resolve a chi_path with the freshly-edited params, falling back
	-- to the stored context for any param the user did not edit here.
	local function resolve_direct(cp, new_params)
		local existing = views.params_for_context(views.get_active_context())
		local result = cp
		for param in cp:gmatch("{([^}]+)}") do
			local v = new_params[param]
			if not v or v == "" or v:find("{") or v:match("%%7[Bb]") then
				v = existing[param] or ""
			end
			if v ~= "" and not v:find("{") and not v:match("%%7[Bb]") then
				result = result:gsub("{" .. vim.pesc(param) .. "}", v, 1)
			end
		end
		return result
	end

	-- Re-navigate the current tab.
	if state.http_tab_meta and chi_path then
		local nav_path = resolve_direct(chi_path, active_path_params_changed)
		if not nav_path:find("{") then
			local qp = views.build_query_string(active_query_params)
			local base = views.get_active_base()
			-- Pick up htmx from the active context's section. Falls back
			-- to the tab's stored htmx if the section didn't set it.
			local htmx = state.http_tab_meta.htmx or false
			for _, sec in ipairs(sections) do
				local k = sec.ctx == "" and "default" or sec.ctx
				if k == active_ctx_key and sec.htmx ~= nil then
					htmx = sec.htmx
					break
				end
			end
			send_cmd("switch " .. state.http_tab_meta.tab_id)
			send_cmd((htmx and "navigate" or "navigate-full") .. " " .. base .. nav_path .. qp)
			vim.notify(string.format("browser: %s%s%s", nav_path, qp, htmx and " [partial]" or " [full]"))
		else
			vim.notify("browser: unresolved params in " .. chi_path, vim.log.levels.WARN)
		end
	end

	-- Fan out: re-navigate other tabs that share any of the updated
	-- PATH params. Query params are per-route and don't fan out.
	if next(active_path_params_changed) then
		local routes = views.get_routes()
		vim.schedule(function()
			for _, m in pairs(state.tab_metadata) do
				if m.tab_id == (state.http_tab_meta and state.http_tab_meta.tab_id) then
					goto next_tab
				end
				local chi = m.chi_path
				if not chi then
					for _, r in ipairs(routes) do
						if util.path_matches_chi(m.path, r.chi_path) then
							chi = r.chi_path
							break
						end
					end
				end
				if not chi then
					goto next_tab
				end
				local should_nav = false
				for param in chi:gmatch("{([^}]+)}") do
					if active_path_params_changed[param] then
						should_nav = true
						break
					end
				end
				if should_nav then
					local nav = resolve_direct(chi, active_path_params_changed)
					if not nav:find("{") then
						-- Filter query by the test file's declared keys.
						local saved = views.load_test_for_path(chi)
						local q = views.build_query_string(views.query_for_route(active_ctx_key, chi, saved.query_keys))
						send_cmd("switch " .. m.tab_id)
						local cmd = (m.htmx or false) and "navigate" or "navigate-full"
						send_cmd(cmd .. " " .. views.get_active_base() .. nav .. q)
					end
				end
				::next_tab::
			end
		end)

		-- Re-focus the edited tab AFTER the fan-out completes. The
		-- fan-out loop above issues `switch <tab_id>` for every
		-- affected tab; whichever happens last leaves devproxy
		-- focused on the wrong tab. Queueing this second
		-- vim.schedule guarantees it runs after the fan-out (FIFO),
		-- so the user lands back on the tab they just edited.
		if state.http_tab_meta and state.http_tab_meta.tab_id then
			local edited_id = state.http_tab_meta.tab_id
			vim.schedule(function()
				send_cmd("switch " .. edited_id)
			end)
		end

		vim.notify(
			string.format(
				"browser: saved - updated %d path param(s) in [%s], re-navigating affected tabs",
				vim.tbl_count(active_path_params_changed),
				active_ctx_key
			)
		)
	else
		vim.notify("browser: saved")
	end

	return true
end

return M
