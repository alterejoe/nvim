-- browser/dashboard/tabops/navigate.lua
--
-- Tab navigation actions:
--   navigate_tab(meta, htmx, tab_htmx)  - switch to an existing tab and
--                                         re-navigate its current chi_path
--                                         with current context query params
--   open_path(chi_path, ...)            - always open a new tab for chi_path.
--                                         Accepts chi_path with an optional
--                                         "?key=val&key=val" suffix; the keys
--                                         are persisted to the test file's
--                                         query: list and the values to
--                                         config.yaml under
--                                         contexts.<ctx>.query.<chi>.<key>
--
-- Both honor the active context's query_for_route (filtered by the test
-- file's declared keys) to compose the final ?key=val string.

local M = {}

local fetch = require("browser.dashboard.tabops.fetch")

local function send_cmd(cmd)
	return require("browser.session").send_cmd(cmd)
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
-- yq helpers (local to this module - small footprint, used only
-- when open_path needs to write inline query params to config.yaml)
-- ============================================================
local function yq_quote_path(s)
	return '"' .. s:gsub('"', '\\"') .. '"'
end

local function yq_set_string(yaml_path, dotted_path, value)
	local v = tostring(value):gsub('"', '\\"')
	vim.fn.system(string.format("yq -i '%s = \"%s\"' %s 2>/dev/null", dotted_path, v, vim.fn.shellescape(yaml_path)))
	return vim.v.shell_error == 0
end

-- ============================================================
-- split_query_from_path
-- Splits "/foo/bar?k=v&k=v" into ("/foo/bar", { k=v, k=v }).
-- Returns the path unchanged and an empty map when no "?" is present.
-- ============================================================
local function split_query_from_path(input)
	local q_idx = input:find("?", 1, true)
	if not q_idx then
		return input, {}
	end
	local path_part = input:sub(1, q_idx - 1)
	local q_str = input:sub(q_idx + 1)
	local out = {}
	for pair in q_str:gmatch("[^&]+") do
		local k, v = pair:match("^([^=]+)=(.*)$")
		if k and k ~= "" then
			out[k] = v or ""
		end
	end
	return path_part, out
end

-- ============================================================
-- navigate_tab
-- Switches to an existing tab and re-navigates it. Resolves the tab's
-- chi_path against the active context's path params and tacks on the
-- per-route query string filtered by the test file's declared keys.
-- ============================================================
function M.navigate_tab(meta, htmx, tab_htmx)
	if not meta then
		return
	end
	tab_htmx[meta.tab_id] = htmx
	-- Tab-view CR/T/p intent: bring the tab to focus AND navigate it.
	-- The switch is what gives the user the visible "now I'm on this
	-- tab" feedback in Brave. The navigate uses --tab= so devproxy is
	-- unambiguous about which tab to navigate, but the switch is still
	-- explicit user intent here (different from fan-out cases that
	-- operate WITHOUT changing focus).
	send_cmd("switch " .. meta.tab_id)

	local srv = (meta.server and meta.server ~= "") and (" --server=" .. meta.server) or ""
	vim.notify("browser: srv=" .. srv .. " server=" .. tostring(meta.server))
	local chi = meta.chi_path or fetch.infer_chi_path(meta)
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
		local qp = views.build_query_string(views.query_for_route(views.get_active_context(), chi, saved.query_keys))
		local base = views.get_active_base()
		local cmd = htmx and "navigate" or "navigate-full"
		send_cmd(cmd .. " --tab=" .. meta.tab_id .. srv .. " " .. base .. resolved .. qp)
		vim.notify(string.format("browser: %s%s%s", resolved, qp, htmx and " [partial]" or " [full]"))
	else
		-- No chi_path inferred; navigate using the literal path as-is.
		local cmd = htmx and "navigate" or "navigate-full"
		send_cmd(cmd .. " --tab=" .. meta.tab_id .. srv .. " " .. get_base_url() .. meta.path)
		vim.notify("browser: " .. (htmx and "[partial]" or "[full]") .. " " .. meta.path)
	end
end

-- ============================================================
-- open_path
-- Always opens a new tab for the given chi_path (template form).
-- chi_path may have an optional "?key=val&..." suffix; if so:
--   - the keys are appended to the test file's query: list
--   - the values are written to contexts.<ctx>.query.<chi>.<key>
--     in config.yaml
-- After persistence, opens the tab with the resolved URL + assembled
-- query (which now reflects the freshly-written values).
-- ============================================================
function M.open_path(chi_path, buf, tab_metadata, do_buf_refresh_fn)
	local views = require("browser.views")
	local session = require("browser.session")

	-- Split off any inline ?key=val suffix from the chi_path. The path
	-- portion is the actual chi template; the query portion drives both
	-- a config.yaml write (values) and a test file write (keys).
	local chi_template, inline_q = split_query_from_path(chi_path)

	-- Normalize to the canonical chi_path so storage keys are stable
	-- regardless of how the input was formatted.
	local norm_chi = views.normalize_chi_path(chi_template)
	local ctx = views.get_active_context()
	local ctx_key = ctx == "" and "default" or ctx

	-- Persist inline query params before resolving the URL so the
	-- query string we render below picks them up.
	if next(inline_q) then
		local yaml_path = session.DEVPROXY_DIR .. "/config.yaml"
		local yaml_ok = vim.fn.filereadable(yaml_path) == 1
		if yaml_ok then
			for k, v in pairs(inline_q) do
				local dotted = string.format(".contexts.%s.query[%s].%s", ctx_key, yq_quote_path(norm_chi), k)
				if not yq_set_string(yaml_path, dotted, v) then
					vim.notify("browser: yq write failed for " .. k, vim.log.levels.WARN)
				end
			end
			views.reload_config_silent()
		end

		-- Merge the new keys into the test file's existing query_keys
		-- list. write_test_file preserves htmx; we only pass the merged
		-- key list.
		local existing = views.load_test_for_path(norm_chi)
		local seen = {}
		local merged = {}
		for _, k in ipairs(existing.query_keys or {}) do
			if not seen[k] then
				seen[k] = true
				table.insert(merged, k)
			end
		end
		for k, _ in pairs(inline_q) do
			if not seen[k] then
				seen[k] = true
				table.insert(merged, k)
			end
		end
		views.write_test_file(norm_chi, ctx, { query_keys = merged })
	end

	-- Resolve URL using the (now possibly updated) test file + config.
	local saved = views.load_test_for_path(norm_chi)
	local base = views.get_active_base()
	local path = views.resolve_path(norm_chi)
	local qp = views.build_query_string(views.query_for_route(ctx, norm_chi, saved.query_keys))
	send_cmd("open " .. base .. path .. qp)
	vim.notify("browser: opened tab -> " .. path .. qp)
	vim.defer_fn(function()
		if vim.api.nvim_buf_is_valid(buf) then
			do_buf_refresh_fn(buf)
		end
	end, 600)
end

return M
