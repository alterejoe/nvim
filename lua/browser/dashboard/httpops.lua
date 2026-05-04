-- browser/dashboard/httpops.lua
-- HTTP panel (e view): open, on_save, and curl preview.
--
-- Bug 2 fix: on_save_http no longer gates param extraction on
-- `not sec.path:find("{")`. Params are extracted per-segment;
-- only segments where the resolved value is still a template token
-- or URL-encoded brace are skipped individually.
--
-- Bug 3 fix: curl_preview no longer references undefined `method`.

local M = {}

local util = require("browser.dashboard.util")

local function send_cmd(cmd)
	return require("browser.session").send_cmd(cmd)
end

-- ============================================================
-- find_http_file (private)
-- Resolves the .http test file path for a chi_path and context.
-- Falls back to structurally equivalent routes (same static segments
-- and param positions, any param names).
-- ============================================================
local function find_http_file(chi_path, ctx)
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
-- Opens the e-panel for the given tab meta in buf.
-- Populates state.http_tab_meta, state.http_chi_path,
-- state.http_section_paths.
--
-- Each context section shows:
--   --- context: <name> ---
--   path: <resolved with context params>  (display only; not persisted)
--   query: <from test file>
--   htmx: <from test file>
-- ============================================================
function M.open_http_panel(meta, buf, state)
	local views = require("browser.views")
	local routes = views.get_routes()

	-- Resolve to the canonical chi_path from plan.json
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

	-- Read test files for each context
	local sections = {}
	for _, ctx in ipairs(contexts) do
		local fpath = find_http_file(chi_path, ctx)
		state.http_section_paths[ctx] = fpath
		local content_lines = {}
		local f = io.open(fpath, "r")
		if f then
			for line in f:lines() do
				table.insert(content_lines, line)
			end
			f:close()
		end
		table.insert(sections, { context = ctx, lines = content_lines })
	end

	-- Build buffer: one section per context
	local new_lines = { "# " .. chi_path, "" }
	for i, sec in ipairs(sections) do
		table.insert(new_lines, "--- context: " .. sec.context .. " ---")
		-- Inject current param values so user sees resolved path, not {tokens}
		local injected = views.resolve_path_for_context(chi_path, sec.context)
		table.insert(new_lines, "path: " .. injected)
		-- Include query/htmx from test file; exclude any stale path: lines
		for _, l in ipairs(sec.lines) do
			local label = l:match("^([%w%.%-_]+):")
			if not label or label:lower() ~= "path" then
				table.insert(new_lines, l)
			end
		end
		if #sec.lines == 0 then
			table.insert(new_lines, "query: ")
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
	vim.notify("browser: http editor - W=save  <leader>w=curl  e/r=back")
end

-- ============================================================
-- on_save_http
-- Parses the e-panel buffer into context sections, extracts params,
-- writes to the central store, writes query/htmx to test files,
-- reloads config, and re-navigates affected tabs.
--
-- Returns true (no deferred refresh needed - the http view stays open).
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

	-- Parse buffer into context sections
	local sections, cur = {}, nil
	for _, l in ipairs(all_lines) do
		local ctx_name = l:match("^%-%-%- context: (.+) %-%-%-%s*$")
		if ctx_name then
			if cur then
				table.insert(sections, cur)
			end
			cur = { ctx = ctx_name, path = nil, query = "", htmx = nil }
		elseif cur then
			local label, val = l:match("^([%w%.%-_]+):%s*(.*)")
			if label then
				local low = label:lower()
				if low == "path" then
					cur.path = vim.trim(val)
				elseif low == "query" then
					cur.query = vim.trim(val)
				elseif low == "htmx" then
					cur.htmx = vim.trim(val) == "true"
				end
			end
		end
	end
	if cur then
		table.insert(sections, cur)
	end

	local active_params_changed = {}
	local yaml_ok = vim.fn.filereadable(yaml_path) == 1
	if not yaml_ok then
		vim.notify("browser: config.yaml not found - params not saved", vim.log.levels.WARN)
	end

	for _, sec in ipairs(sections) do
		-- Extract chi_path params from the displayed (injected) path.
		-- Bug 2 fix: extraction is per-segment. We no longer require that the
		-- entire path is fully resolved - segments that are still template tokens
		-- or URL-encoded braces are skipped individually.
		local sec_params = {}
		if sec.path and sec.path ~= "" then
			local chi_s = util.segs(chi_path)
			local res_s = util.segs(sec.path)
			if #chi_s == #res_s then
				for i, c in ipairs(chi_s) do
					if c:sub(1, 1) == "{" then
						local pname = c:match("{(.+)}")
						local val = res_s[i]
						if pname and val and val ~= "" and not val:find("{") and not val:match("%%7[Bb]") then
							sec_params[pname] = val
						end
					end
				end
			end
		end

		-- Write changed params to contexts.<ctx> in config.yaml
		if yaml_ok and next(sec_params) then
			local ctx_key = sec.ctx == "" and "default" or sec.ctx
			for k, v in pairs(sec_params) do
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
		end

		-- Write query and htmx to test file (path is never persisted)
		local fpath = views.test_file_path(chi_path, sec.ctx)
		vim.fn.mkdir(vim.fn.fnamemodify(fpath, ":h"), "p")
		local wf = io.open(fpath, "w")
		if wf then
			if sec.query and sec.query ~= "" then
				wf:write("query: " .. sec.query .. "\n")
			end
			if sec.htmx ~= nil then
				wf:write("htmx: " .. tostring(sec.htmx) .. "\n")
			end
			wf:close()
		else
			vim.notify("browser: could not write test file " .. fpath, vim.log.levels.WARN)
		end

		local sec_ctx_key = sec.ctx == "" and "default" or sec.ctx
		if sec_ctx_key == active_ctx_key then
			active_params_changed = sec_params
		end
	end

	-- Persist updated config so future navigations pick up new values.
	-- This is fire-and-forget for persistence only - we do NOT rely on
	-- config reload for the actual navigation below.
	views.reload_config_silent()

	-- Build a resolved path directly from the params the user just entered.
	-- We never go through the config for the current tab's navigation: we
	-- have the chi_path template and the new values right here.
	--
	-- For any param the user did NOT edit (still {token} in the path), we
	-- fill from active_params() which has the freshly reloaded values.
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

	-- Navigate current tab with the directly-resolved path.
	if state.http_tab_meta and chi_path then
		-- Find the active context's section so we can use its query param too.
		local active_sec = nil
		for _, sec in ipairs(sections) do
			local k = sec.ctx == "" and "default" or sec.ctx
			if k == active_ctx_key then
				active_sec = sec
				break
			end
		end
		local nav_params = active_sec and active_params_changed or {}
		local nav_path = resolve_direct(chi_path, nav_params)
		if not nav_path:find("{") then
			local qp = (active_sec and active_sec.query ~= "" and ("?" .. active_sec.query)) or ""
			local base = views.get_active_base()
			local htmx = state.http_tab_meta.htmx or false
			send_cmd("switch " .. state.http_tab_meta.tab_id)
			send_cmd((htmx and "navigate" or "navigate-full") .. " " .. base .. nav_path .. qp)
			vim.notify(string.format("browser: %s%s%s", nav_path, qp, htmx and " [partial]" or " [full]"))
		else
			vim.notify("browser: unresolved params in " .. chi_path, vim.log.levels.WARN)
		end
	end

	-- Re-navigate all other open tabs that share any of the updated params.
	if next(active_params_changed) then
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
					if active_params_changed[param] then
						should_nav = true
						break
					end
				end
				if should_nav then
					local nav = resolve_direct(chi, active_params_changed)
					if not nav:find("{") then
						send_cmd("switch " .. m.tab_id)
						local cmd = (m.htmx or false) and "navigate" or "navigate-full"
						send_cmd(cmd .. " " .. views.get_active_base() .. nav)
					end
				end
				::next_tab::
			end
		end)
		vim.notify(
			string.format(
				"browser: saved - updated %d param(s) in [%s], re-navigating affected tabs",
				vim.tbl_count(active_params_changed),
				active_ctx_key
			)
		)
	else
		vim.notify("browser: saved")
	end

	return true
end

-- ============================================================
-- curl_preview
-- Fires a curl -siL request against the current buffer's path
-- and displays the response in the HTTP Preview pane.
-- No browser navigation, no writes.
--
-- Bug 3 fix: was referencing undefined global `method`.
-- Now always sends GET (the e-panel only handles GET routes).
-- ============================================================
function M.curl_preview(state)
	local buf = state.primary_buf
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	if not (state.http_tab_meta and state.http_chi_path) then
		vim.notify("browser: no active http context", vim.log.levels.WARN)
		return
	end

	-- Read path and query from the first context section in the buffer
	local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local in_section = false
	local qp, path = "", nil

	for _, l in ipairs(all_lines) do
		if l:match("^%-%-%- context:") then
			in_section = true
		elseif in_section then
			local label, val = l:match("^([%w%.%-_]+):%s*(.*)")
			if label then
				local low = label:lower()
				if low == "query" then
					qp = vim.trim(val)
				elseif low == "path" then
					path = vim.trim(val)
				end
			end
		end
	end

	local views = require("browser.views")
	local base = views.get_active_base()
	local resolved = (path and path ~= "") and path or views.resolve_path(state.http_chi_path)
	local full_url = base .. resolved .. (qp ~= "" and ("?" .. qp) or "")

	local hx_flag = state.http_tab_meta.htmx and (" -H 'HX-Request: true' -H 'HX-Current-URL: " .. full_url .. "'")
		or ""

	local cookie_file = require("browser.session").DEVPROXY_DIR .. "/cookies.txt"
	local cookie_flag = vim.fn.filereadable(cookie_file) == 1 and (" -b " .. vim.fn.shellescape(cookie_file)) or ""

	vim.notify("browser: GET " .. resolved .. (qp ~= "" and ("?" .. qp) or ""))

	vim.fn.jobstart("curl -siL" .. hx_flag .. cookie_flag .. " " .. vim.fn.shellescape(full_url), {
		stdout_buffered = true,
		on_stdout = function(_, data)
			if not data then
				return
			end
			local all = {}
			for _, l in ipairs(data) do
				if l ~= nil then
					table.insert(all, (tostring(l):gsub("\r", "")))
				end
			end
			if #all == 0 then
				return
			end

			-- Split into HTTP response blocks (each starts with "HTTP/")
			local blocks, current = {}, {}
			for _, l in ipairs(all) do
				if l:match("^HTTP/") and #current > 0 then
					table.insert(blocks, current)
					current = {}
				end
				table.insert(current, l)
			end
			if #current > 0 then
				table.insert(blocks, current)
			end

			-- Reverse so most recent response is first; strip HTML bodies
			local out = {}
			for i = #blocks, 1, -1 do
				local block = blocks[i]
				local in_body = false
				for _, l in ipairs(block) do
					if in_body then
						-- HTML body content is dropped
					elseif l == "" then
						in_body = true
						table.insert(out, l)
					else
						table.insert(out, l)
					end
				end
				if i > 1 then
					table.insert(out, "")
				end
			end

			vim.schedule(function()
				if state.layout then
					state.layout.set(require("browser.dashboard.util").PREVIEW_TITLE, out)
				end
			end)
		end,
	})
end

return M
