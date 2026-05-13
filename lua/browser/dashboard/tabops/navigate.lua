-- browser/dashboard/tabops/navigate.lua

local M = {}

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
	vim.fn.system(string.format("yq -i '%s = \"%s\"' %s 2>/dev/null", dotted_path, v, vim.fn.shellescape(yaml_path)))
	return vim.v.shell_error == 0
end

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

-- navigate_tab
-- Both partial and full page go through the server's dedicated proxy port.
-- Partial: send path only - CmdNavigate prepends the proxy base.
-- Full: send proxy base + path - browser lands at proxy, proxy forwards to app.
function M.navigate_tab(meta, htmx, tab_htmx)
	if not meta then
		return
	end
	tab_htmx[meta.tab_id] = htmx
	send_cmd("switch " .. meta.tab_id)

	local server = (meta.server and meta.server ~= "") and meta.server or nil
	local srv_flag = server and (" --server=" .. server) or ""
	local proxy = get_proxy_base(server)
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
		local cmd = htmx and "navigate" or "navigate-full"
		local url = htmx and (resolved .. qp) or (proxy .. resolved .. qp)
		send_cmd(cmd .. " --tab=" .. meta.tab_id .. srv_flag .. " " .. url)
		vim.notify(string.format("browser: %s%s%s", resolved, qp, htmx and " [partial]" or " [full]"))
	else
		local cmd = htmx and "navigate" or "navigate-full"
		local url = htmx and meta.path or (proxy .. meta.path)
		send_cmd(cmd .. " --tab=" .. meta.tab_id .. srv_flag .. " " .. url)
		vim.notify("browser: " .. (htmx and "[partial]" or "[full]") .. " " .. meta.path)
	end
end

function M.open_path(chi_path, buf, tab_metadata, do_buf_refresh_fn)
	local views = require("browser.views")
	local session = require("browser.session")

	local chi_template, inline_q = split_query_from_path(chi_path)
	local norm_chi = views.normalize_chi_path(chi_template)
	local ctx = views.get_active_context()
	local ctx_key = ctx == "" and "default" or ctx

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

	local saved = views.load_test_for_path(norm_chi)
	local path = views.resolve_path(norm_chi)
	local qp = views.build_query_string(views.query_for_route(ctx, norm_chi, saved.query_keys))
	-- open uses active server's proxy port
	local proxy = get_proxy_base(nil)
	send_cmd("open " .. proxy .. path .. qp)
	vim.notify("browser: opened tab -> " .. path .. qp)
	vim.defer_fn(function()
		if vim.api.nvim_buf_is_valid(buf) then
			do_buf_refresh_fn(buf)
		end
	end, 600)
end

return M
