-- browser/views.lua
--
-- View/route picker for devproxy. Pure module - no keymaps.
-- All keymaps live in after/plugin/browser.lua.

local M = {}

local VIEW_SERVER = "http://localhost:19878"

local function send_cmd(cmd)
	return require("browser.session").send_cmd(cmd)
end

local function views_path()
	return require("browser.session").VIEWS_PATH
end

local function devproxy_dir()
	return require("browser.session").DEVPROXY_DIR
end

local function get_active_base()
	local raw = send_cmd("active-server")
	if raw then
		local port = raw:match("port (%d+)")
		if port then
			return "http://localhost:" .. port
		end
	end
	return "http://localhost:3333"
end

-- ------------------------------------------------------------
-- devproxy project config
-- ------------------------------------------------------------
local _config = nil
local _context = "default"
local _context_loaded = false -- lazy-load from disk once
local _session_defaults = {}

-- Persist active context to disk so it survives session restarts
local function persist_context(name)
	local path = devproxy_dir() .. "/active_context"
	local f = io.open(path, "w")
	if f then
		f:write(name)
		f:close()
	end
end

-- Load active context from disk on first use
local function ensure_context_loaded()
	if _context_loaded then
		return
	end
	_context_loaded = true
	local path = devproxy_dir() .. "/active_context"
	local f = io.open(path, "r")
	if f then
		local name = vim.trim(f:read("*a"))
		f:close()
		if name and name ~= "" then
			_context = name
		end
	end
end

function M.clear_session_default(key)
	_session_defaults[key] = nil
end

local function load_config()
	local dir = devproxy_dir()
	local path = dir .. "/config.yaml"
	if vim.fn.filereadable(path) == 0 then
		_config = { defaults = {}, query_params = {}, contexts = {}, exceptions = {} }
		return
	end
	local raw = vim.fn.system("yq -o=json . " .. vim.fn.shellescape(path) .. " 2>/dev/null")
	local ok, data = pcall(vim.json.decode, raw)
	if not ok or not data then
		vim.notify("browser.views: failed to parse " .. path, vim.log.levels.WARN)
		_config = { defaults = {}, query_params = {}, contexts = {}, exceptions = {} }
	else
		_config = {
			defaults = data.defaults or {},
			query_params = data.query_params or {},
			contexts = data.contexts or {},
			exceptions = data.exceptions or {},
		}
	end
end

local function get_config()
	if not _config then
		load_config()
	end
	return _config
end

local function find_project_root()
	local nav = package.loaded["forge_nav"]
	if nav and nav._project_root then
		return nav._project_root
	end
	local dir = devproxy_dir()
	if dir and dir ~= "" then
		return vim.fn.fnamemodify(dir, ":h")
	end
	return vim.fn.getcwd()
end

local function active_params()
	ensure_context_loaded()
	local cfg = get_config()
	local params = {}
	for k, v in pairs(cfg.defaults) do
		params[k] = tostring(v)
	end
	local ctx = cfg.contexts[_context] or {}
	for k, v in pairs(ctx) do
		params[k] = tostring(v)
	end
	for k, v in pairs(_session_defaults) do
		params[k] = v
	end
	return params
end

local function skip_for_path(_path)
	return {}
end

local function resolve_path(chi_path)
	local params = active_params()
	local skip = skip_for_path(chi_path)
	local result = chi_path
	for param in chi_path:gmatch("{([^}]+)}") do
		if skip[param] then
			result = result:gsub("{" .. param .. "}", "", 1)
		elseif params[param] and params[param] ~= "" then
			result = result:gsub("{" .. param .. "}", params[param], 1)
		else
			-- local val = vim.fn.input("Value for {" .. param .. "}: ")
			-- if val == "" then
			-- 	return nil
			-- end
			-- _session_defaults[param] = val
			-- result = result:gsub("{" .. param .. "}", val, 1)
		end
	end
	return result
end

local function build_query_params(path)
	local cfg = get_config()
	local skip = skip_for_path(path)
	local merged = {}
	for k, v in pairs(cfg.query_params) do
		merged[k] = tostring(v)
	end
	local ctx = cfg.contexts[_context] or {}
	for k, v in pairs(ctx) do
		merged[k] = tostring(v)
	end
	for k, v in pairs(_session_defaults) do
		merged[k] = v
	end
	local qp = {}
	for k, v in pairs(merged) do
		if not skip[k] and v ~= "" then
			table.insert(qp, k .. "=" .. v)
		end
	end
	if #qp == 0 then
		return ""
	end
	return "?" .. table.concat(qp, "&")
end

-- ------------------------------------------------------------
-- test file param lookup
-- Context-isolated: no fallback between contexts.
--   default context   tests/{slug}.http only
--   other context     tests/{context}/{slug}.http only
-- ------------------------------------------------------------
local function load_test_for_path(chi_path)
	ensure_context_loaded()
	local session = require("browser.session")
	local slug = (chi_path or "unknown"):gsub("/$", ""):gsub("^/", ""):gsub("/", "-"):gsub("{", ""):gsub("}", "")

	local path
	if _context and _context ~= "default" and _context ~= "" then
		path = session.TESTS_DIR .. "/" .. _context .. "/" .. slug .. ".http"
	else
		path = session.TESTS_DIR .. "/" .. slug .. ".http"
	end

	if vim.fn.filereadable(path) == 0 then
		local chi_segs = {}
		for s in (chi_path or ""):gmatch("[^/]+") do
			table.insert(chi_segs, s)
		end
		for _, r in ipairs(require("browser.views").get_routes()) do
			if r.chi_path ~= chi_path then
				local r_segs = {}
				for s in r.chi_path:gmatch("[^/]+") do
					table.insert(r_segs, s)
				end
				if #r_segs == #chi_segs then
					local same = true
					for i, cs in ipairs(chi_segs) do
						local rs = r_segs[i]
						local c_p = cs:sub(1, 1) == "{"
						local r_p = rs:sub(1, 1) == "{"
						if c_p ~= r_p or (not c_p and cs ~= rs) then
							same = false
							break
						end
					end
					if same then
						local alt = r.chi_path:gsub("/$", ""):gsub("^/", ""):gsub("/", "-"):gsub("{", ""):gsub("}", "")
						local alt_path
						if _context and _context ~= "default" and _context ~= "" then
							alt_path = session.TESTS_DIR .. "/" .. _context .. "/" .. alt .. ".http"
						else
							alt_path = session.TESTS_DIR .. "/" .. alt .. ".http"
						end
						if vim.fn.filereadable(alt_path) == 1 then
							path = alt_path
							break
						end
					end
				end
			end
		end
		if vim.fn.filereadable(path) == 0 then
			return nil
		end
	end

	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local qp = ""
	local resolved_path = nil
	local htmx_val = nil
	for line in f:lines() do
		local label, val = line:match("^([%w%.%-_]+):%s*(.*)")
		if label then
			local low = label:lower()
			if low == "query" then
				qp = vim.trim(val)
			end
			if low == "path" then
				resolved_path = vim.trim(val)
			end
			if low == "htmx" then
				htmx_val = vim.trim(val) == "true"
			end
		end
	end
	f:close()
	return { qp = qp, path = resolved_path, htmx = htmx_val }
end

local function resolve_qp(chi_path)
	local saved = load_test_for_path(chi_path)
	if saved ~= nil then
		return saved.qp ~= "" and ("?" .. saved.qp) or ""
	end
	return build_query_params(chi_path)
end

-- ------------------------------------------------------------
-- context management
-- ------------------------------------------------------------
function M.reload_config()
	_config = nil
	load_config()
	vim.notify("browser.views: config reloaded from " .. (devproxy_dir() or "?"))
end

function M.reload_config_silent()
	_config = nil
	load_config()
end

function M.switch_context(name)
	ensure_context_loaded()
	_context = name
	persist_context(name)
end

function M.get_active_context()
	ensure_context_loaded()
	return _context
end

-- Scan TESTS_DIR subdirectories for available contexts.
-- Always includes "default" first, then subdirs alphabetically.
local function get_contexts()
	local session = require("browser.session")
	local tests = session.TESTS_DIR
	local contexts = { "default" }
	local handle = vim.loop.fs_scandir(tests)
	if handle then
		while true do
			local name, typ = vim.loop.fs_scandir_next(handle)
			if not name then
				break
			end
			if typ == "directory" then
				table.insert(contexts, name)
			end
		end
	end
	table.sort(contexts, function(a, b)
		if a == "default" then
			return true
		end
		if b == "default" then
			return false
		end
		return a < b
	end)
	return contexts
end

function M.get_contexts()
	return get_contexts()
end

-- Cycle active context forward (dir=1) or backward (dir=-1). Wraps around.
function M.cycle_context(dir)
	ensure_context_loaded()
	local contexts = get_contexts()
	if #contexts <= 1 then
		vim.notify("browser: only one context available", vim.log.levels.INFO)
		return _context
	end
	local current_idx = 1
	for i, name in ipairs(contexts) do
		if name == _context then
			current_idx = i
			break
		end
	end
	local next_idx = ((current_idx - 1 + dir) % #contexts) + 1
	_context = contexts[next_idx]
	persist_context(_context)
	vim.notify("browser: context -> " .. _context)
	return _context
end

function M.context_pick()
	local cfg = get_config()
	local contexts = {}
	for name, vals in pairs(cfg.contexts) do
		local active = name == _context and " [active]" or ""
		local preview = {}
		for k, v in pairs(vals) do
			table.insert(preview, k .. "=" .. tostring(v))
		end
		table.insert(contexts, {
			name = name,
			display = string.format("%-20s %s%s", name, table.concat(preview, "  "), active),
			vals = vals,
		})
	end
	if next(_session_defaults) then
		local preview = {}
		for k, v in pairs(_session_defaults) do
			table.insert(preview, k .. "=" .. v)
		end
		table.insert(contexts, {
			name = "[session]",
			display = string.format("%-20s %s", "[session overrides]", table.concat(preview, "  ")),
			vals = _session_defaults,
		})
	end
	if #contexts == 0 then
		vim.notify("browser.views: no contexts defined in .devproxy/config.yaml", vim.log.levels.WARN)
		return
	end
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	pickers
		.new({}, {
			prompt_title = "Switch Context",
			finder = finders.new_table({
				results = contexts,
				entry_maker = function(c)
					return { value = c, display = c.display, ordinal = c.name }
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					local sel = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if not sel then
						return
					end
					if sel.value.name ~= "[session]" then
						M.switch_context(sel.value.name)
						vim.notify("browser.views: context -> " .. _context)
					end
				end)
				map("n", "x", function()
					actions.close(prompt_bufnr)
					_session_defaults = {}
					vim.notify("browser.views: session defaults cleared")
				end)
				return true
			end,
		})
		:find()
end

function M.context_show()
	ensure_context_loaded()
	local params = active_params()
	local lines = { "Context: " .. _context, "Project: " .. find_project_root(), "", "Active params:" }
	for k, v in pairs(params) do
		table.insert(lines, string.format("  %-20s = %s", k, v))
	end
	if next(_session_defaults) then
		table.insert(lines, "")
		table.insert(lines, "Session overrides:")
		for k, v in pairs(_session_defaults) do
			table.insert(lines, string.format("  %-20s = %s", k, v))
		end
	end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"
	vim.api.nvim_buf_set_name(buf, "devproxy-context")
	vim.cmd("vsplit")
	vim.api.nvim_win_set_buf(0, buf)
end

function M.server_pick()
	local raw = send_cmd("servers")
	if not raw or raw == "[]" or raw:sub(1, 1) ~= "[" then
		vim.notify("browser.views: no servers configured in .devproxy/config.yaml", vim.log.levels.WARN)
		return
	end
	local ok, servers = pcall(vim.json.decode, raw)
	if not ok or #servers == 0 then
		return
	end
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	pickers
		.new({}, {
			prompt_title = "Switch Server",
			finder = finders.new_table({
				results = servers,
				entry_maker = function(s)
					local active = s.active and " [active]" or ""
					local display = string.format("%-15s  port %d%s", s.name, s.port, active)
					return { value = s, display = display, ordinal = s.name }
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					local sel = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if not sel then
						return
					end
					local r = send_cmd("switch-server " .. sel.value.name)
					if r then
						vim.notify(r)
					end
				end)
				return true
			end,
		})
		:find()
end

local function find_plan_path()
	local nav = package.loaded["forge_nav"]
	if nav and nav._project_root then
		return nav._project_root .. "/.forge/plan.json"
	end
	local dir = vim.fn.getcwd()
	while dir ~= "/" do
		local p = dir .. "/.forge/plan.json"
		if vim.fn.filereadable(p) == 1 then
			return p
		end
		dir = vim.fn.fnamemodify(dir, ":h")
	end
	return nil
end

-- ------------------------------------------------------------
-- picker keymap config
-- ------------------------------------------------------------
M.keys = { full = "<CR>", partial = "p", tab_full = "t", tab_partial = "T", file = "o" }

-- ------------------------------------------------------------
-- view list
-- ------------------------------------------------------------
local function get_views()
	local raw = vim.fn.system("curl -s " .. VIEW_SERVER .. "/views 2>/dev/null")
	local ok, data = pcall(vim.json.decode, raw)
	if not ok or not data then
		local yr = vim.fn.system("yq -o=json . " .. vim.fn.shellescape(views_path()) .. " 2>/dev/null")
		local yok, ydata = pcall(vim.json.decode, yr)
		if not yok or not ydata or not ydata.views then
			return {}
		end
		local views = {}
		for name, v in pairs(ydata.views) do
			table.insert(views, { name = name, layout = v.layout or v.template or "custom", kind = "view" })
		end
		return views
	end
	for _, v in ipairs(data) do
		v.kind = "view"
	end
	return data
end

-- ------------------------------------------------------------
-- route list from plan.json
-- ------------------------------------------------------------
local function get_routes()
	local plan_path = find_plan_path()
	if not plan_path then
		return {}
	end
	local f = io.open(plan_path, "r")
	if not f then
		return {}
	end
	local raw = f:read("*a")
	f:close()
	local ok, plan = pcall(vim.json.decode, raw)
	if not ok or not plan or not plan.actions then
		return {}
	end
	local routes = {}
	for _, action in ipairs(plan.actions) do
		if action.label == "handler" and action.data then
			local method = (action.data.route_method or "get"):upper()
			if method == "GET" and action.data.chi_path then
				table.insert(routes, {
					kind = "route",
					name = action.data.chi_path,
					method = method,
					chi_path = action.data.chi_path,
					handler = action.data.handler_func,
					output = action.output,
				})
			end
		end
	end
	table.sort(routes, function(a, b)
		return (a.chi_path or "") < (b.chi_path or "")
	end)
	return routes
end

-- ------------------------------------------------------------
-- last nav tracking
-- ------------------------------------------------------------
M._last_nav = nil

local function do_navigate(chi_path, htmx)
	local saved = load_test_for_path(chi_path)
	local path
	if saved and saved.path then
		path = saved.path
	else
		path = resolve_path(chi_path)
		if not path then
			return
		end
	end
	local qp
	if saved then
		qp = saved.qp ~= "" and ("?" .. saved.qp) or ""
	else
		qp = build_query_params(chi_path)
	end
	local params = active_params()
	local skip = skip_for_path(chi_path)
	M._last_nav = {
		chi_path = chi_path,
		resolved = path,
		qp = qp,
		htmx = htmx,
		params_used = params,
		skip = skip,
	}
	local base = get_active_base()
	local cmd = htmx and "navigate" or "navigate-full"
	local src = saved and " [from test file]" or ""
	local hx_label = htmx and " [HX-Request: true]" or " [full page]"
	send_cmd(cmd .. " " .. base .. path .. qp)
	vim.notify(string.format("browser: %s%s%s%s", path, qp, hx_label, src))
end

-- ------------------------------------------------------------
-- param editor
-- ------------------------------------------------------------
function M.edit_params()
	local SOCKET = require("browser.session").SOCKET
	local raw_net = vim.fn.filereadable(SOCKET) == 1
			and vim.trim(vim.fn.system("echo netlog | socat -t 5 - UNIX-CONNECT:" .. SOCKET .. " 2>/dev/null"))
		or ""
	local last_status = nil
	if raw_net ~= "" and raw_net:sub(1, 1) == "[" then
		local ok, entries = pcall(vim.json.decode, raw_net)
		if ok and #entries > 0 then
			last_status = entries[#entries].status
		end
	end
	local nav = M._last_nav
	if not nav then
		vim.notify("browser: no navigation recorded yet", vim.log.levels.WARN)
		return
	end
	local status_str = last_status and string.format(" [%d]", last_status) or ""
	local is_error = last_status and last_status >= 400
	local editable = {}
	for param in (nav.chi_path or ""):gmatch("{([^}]+)}") do
		if not nav.skip[param] then
			table.insert(editable, { key = param, val = nav.params_used[param] or "", source = "path" })
		end
	end
	local cfg = get_config()
	for k, v in pairs(cfg.query_params or {}) do
		if not nav.skip[k] then
			local found = false
			for _, e in ipairs(editable) do
				if e.key == k then
					found = true
				end
			end
			if not found then
				table.insert(editable, { key = k, val = nav.params_used[k] or tostring(v), source = "query" })
			end
		end
	end
	if #editable == 0 then
		vim.notify("browser: no params to edit for " .. (nav.resolved or "?"))
		return
	end
	local title = string.format(
		"Params for %s%s%s - edit and re-navigate",
		nav.resolved or "?",
		status_str,
		is_error and " ? error" or ""
	)
	vim.notify(title, is_error and vim.log.levels.WARN or vim.log.levels.INFO)
	local idx = 1
	local new_vals = {}
	local function persist_changes(vals)
		local yaml_path = devproxy_dir() .. "/config.yaml"
		if vim.fn.filereadable(yaml_path) == 0 then
			return
		end
		local cfg2 = get_config()
		local persisted = {}
		for k, v in pairs(vals) do
			if v == "" then
				goto continue
			end
			if cfg2.defaults and cfg2.defaults[k] ~= nil then
				local out = vim.fn.system(
					string.format(
						"yq -i '.defaults.%s = \"%s\"' %s 2>&1",
						k,
						v:gsub('"', '\\"'),
						vim.fn.shellescape(yaml_path)
					)
				)
				if vim.v.shell_error ~= 0 then
					vim.notify("browser: yq defaults error for " .. k .. ": " .. out, vim.log.levels.WARN)
				else
					persisted[k] = true
				end
			end
			if cfg2.query_params and cfg2.query_params[k] ~= nil then
				local out = vim.fn.system(
					string.format(
						"yq -i '.query_params.%s = \"%s\"' %s 2>&1",
						k,
						v:gsub('"', '\\"'),
						vim.fn.shellescape(yaml_path)
					)
				)
				if vim.v.shell_error ~= 0 then
					vim.notify("browser: yq query_params error for " .. k .. ": " .. out, vim.log.levels.WARN)
				else
					persisted[k] = true
				end
			end
			for ctx_name, ctx_vals in pairs(cfg2.contexts or {}) do
				if ctx_vals[k] ~= nil then
					local out = vim.fn.system(
						string.format(
							"yq -i '.contexts.%s.%s = \"%s\"' %s 2>&1",
							ctx_name,
							k,
							v:gsub('"', '\\"'),
							vim.fn.shellescape(yaml_path)
						)
					)
					if vim.v.shell_error ~= 0 then
						vim.notify(
							"browser: yq context error for " .. ctx_name .. "." .. k .. ": " .. out,
							vim.log.levels.WARN
						)
					else
						persisted[k] = true
					end
				end
			end
			::continue::
		end
		for k in pairs(persisted) do
			_session_defaults[k] = nil
		end
		M.reload_config()
		vim.notify("browser: defaults updated in config.yaml")
	end
	local function prompt_next()
		if idx > #editable then
			for _, e in ipairs(editable) do
				if new_vals[e.key] ~= nil then
					_session_defaults[e.key] = new_vals[e.key]
				end
			end
			do_navigate(nav.chi_path, nav.htmx)
			persist_changes(new_vals)
			return
		end
		local e = editable[idx]
		vim.ui.input({ prompt = string.format("[%s] %s = ", e.source, e.key), default = e.val }, function(val)
			if val == nil then
				vim.notify("browser: cancelled", vim.log.levels.INFO)
				return
			end
			new_vals[e.key] = val
			idx = idx + 1
			prompt_next()
		end)
	end
	prompt_next()
end

-- ------------------------------------------------------------
-- main picker
-- ------------------------------------------------------------
function M.pick()
	local views = get_views()
	local routes = get_routes()
	local items = {}
	for _, v in ipairs(views) do
		table.insert(items, {
			display = string.format("[view]  %-30s  %s", v.name, v.layout or ""),
			ordinal = v.name,
			kind = "view",
			name = v.name,
		})
	end
	for _, r in ipairs(routes) do
		table.insert(items, {
			display = string.format("[route] %-30s  %s", r.chi_path, r.handler or ""),
			ordinal = r.chi_path,
			kind = "route",
			chi_path = r.chi_path,
			output = r.output,
		})
	end
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	pickers
		.new({}, {
			prompt_title = "Browser  [CR=full  p=partial  t=new tab (full)  T=new tab (partial)  o=file]",
			finder = finders.new_table({
				results = items,
				entry_maker = function(item)
					return { value = item, display = item.display, ordinal = item.ordinal }
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					local sel = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if not sel then
						return
					end
					local item = sel.value
					local htmx = M._last_nav and M._last_nav.htmx or false
					if item.kind == "view" then
						local cmd = htmx and "navigate" or "navigate-full"
						send_cmd(cmd .. " " .. VIEW_SERVER .. "/view?name=" .. item.name)
						vim.notify("browser: [" .. (htmx and "partial" or "full") .. "] view " .. item.name)
					else
						do_navigate(item.chi_path, htmx)
					end
				end)
				local function do_partial()
					local sel = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if not sel then
						return
					end
					local item = sel.value
					if item.kind == "view" then
						send_cmd("navigate " .. VIEW_SERVER .. "/view?name=" .. item.name)
						vim.notify("browser: [partial] view " .. item.name)
					else
						do_navigate(item.chi_path, true)
					end
				end
				map("n", M.keys.partial, do_partial)
				local function do_tab_full()
					local sel = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if not sel then
						return
					end
					local item = sel.value
					local url
					if item.kind == "view" then
						url = VIEW_SERVER .. "/view?name=" .. item.name
					else
						local saved = load_test_for_path(item.chi_path)
						local path = (saved and saved.path) or resolve_path(item.chi_path)
						if not path then
							return
						end
						local qp = saved and (saved.qp ~= "" and ("?" .. saved.qp) or "")
							or build_query_params(item.chi_path)
						url = get_active_base() .. path .. qp
					end
					local raw = send_cmd("tabs")
					if raw and raw:sub(1, 1) == "[" then
						local tok, tabs = pcall(vim.json.decode, raw)
						if tok then
							for _, t in ipairs(tabs) do
								if t.path and url:find(vim.pesc(t.path), 1) then
									send_cmd("switch " .. t.id)
									vim.notify("browser: switched to tab -> " .. t.path)
									return
								end
							end
						end
					end
					send_cmd("open " .. url)
					vim.notify("browser: new tab (full) -> " .. url)
					vim.defer_fn(function()
						local raw2 = send_cmd("tabs")
						if not raw2 or raw2:sub(1, 1) ~= "[" then
							return
						end
						local ok2, tabs2 = pcall(vim.json.decode, raw2)
						if not ok2 then
							return
						end
						local best
						for _, t in ipairs(tabs2) do
							if not t.active and t.path and url:find(vim.pesc(t.path), 1) then
								best = t
							end
						end
						if best then
							send_cmd("switch " .. best.id)
						end
					end, 800)
				end
				map("n", M.keys.tab_full, do_tab_full)
				local function do_tab_partial()
					local sel = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if not sel then
						return
					end
					local item = sel.value
					local url
					if item.kind == "view" then
						url = VIEW_SERVER .. "/view?name=" .. item.name
					else
						local saved = load_test_for_path(item.chi_path)
						local path = (saved and saved.path) or resolve_path(item.chi_path)
						if not path then
							return
						end
						local qp = saved and (saved.qp ~= "" and ("?" .. saved.qp) or "")
							or build_query_params(item.chi_path)
						url = get_active_base() .. path .. qp
					end
					send_cmd("open " .. url)
					vim.notify("browser: new tab (partial) -> " .. url)
					vim.defer_fn(function()
						send_cmd("navigate " .. url)
					end, 500)
				end
				map("n", M.keys.tab_partial, do_tab_partial)
				local function do_file()
					local sel = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if not sel or sel.value.kind ~= "route" or not sel.value.output then
						vim.notify("browser: no file for this entry", vim.log.levels.WARN)
						return
					end
					local root = find_project_root()
					if not root then
						vim.notify("browser: cannot find project root", vim.log.levels.WARN)
						return
					end
					local full = root .. "/" .. sel.value.output
					if vim.fn.filereadable(full) == 1 then
						vim.cmd("edit " .. vim.fn.fnameescape(full))
					else
						vim.notify("browser: file not found: " .. full, vim.log.levels.WARN)
					end
				end
				map("n", M.keys.file, do_file)
				return true
			end,
		})
		:find()
end

-- ------------------------------------------------------------
-- views config management
-- ------------------------------------------------------------
function M.reload()
	local r = send_cmd("views-reload")
	if r then
		vim.notify("browser.views: " .. r)
	end
end

function M.edit()
	vim.cmd("edit " .. vim.fn.fnameescape(views_path()))
end

local LAYOUTS = { "single", "side-by-side", "vertical-stack", "grid" }

function M.quick_add()
	vim.ui.input({ prompt = "View name: " }, function(name)
		if not name or name == "" then
			return
		end
		local layout_choice = vim.fn.inputlist(vim.list_extend(
			{ "Select layout:" },
			vim.tbl_map(function(i)
				return i .. ". " .. LAYOUTS[i]
			end, vim.fn.range(1, #LAYOUTS))
		))
		if layout_choice <= 0 or layout_choice > #LAYOUTS then
			return
		end
		local layout = LAYOUTS[layout_choice]
		local yaml_lines = { "  " .. name .. ":", "    layout: " .. layout, "    autorefresh: 0" }
		if layout == "single" then
			vim.ui.input({ prompt = "URL path: " }, function(url)
				if not url or url == "" then
					return
				end
				table.insert(yaml_lines, "    url: " .. url)
				M._append_view(yaml_lines, name)
			end)
		else
			local panels = {}
			local function collect(idx)
				vim.ui.input({ prompt = string.format("Panel %d URL (empty to finish): ", idx) }, function(url)
					if not url or url == "" then
						if #panels == 0 then
							return
						end
						table.insert(yaml_lines, "    panels:")
						for _, p in ipairs(panels) do
							table.insert(yaml_lines, "      - url: " .. p.url)
							if p.label ~= "" then
								table.insert(yaml_lines, "        label: " .. p.label)
							end
						end
						M._append_view(yaml_lines, name)
					else
						vim.ui.input({ prompt = "  Label (optional): " }, function(label)
							table.insert(panels, { url = url, label = label or "" })
							collect(idx + 1)
						end)
					end
				end)
			end
			collect(1)
		end
	end)
end

function M._append_view(yaml_lines, name)
	local f = io.open(views_path(), "a")
	if not f then
		vim.notify("browser.views: cannot write " .. views_path(), vim.log.levels.ERROR)
		return
	end
	f:write("\n")
	for _, line in ipairs(yaml_lines) do
		f:write(line .. "\n")
	end
	f:close()
	send_cmd("views-reload")
	vim.notify("browser.views: added view '" .. name .. "'")
end

function M.toggle_mode()
	local nav = M._last_nav
	if not nav then
		vim.notify("browser: no navigation recorded", vim.log.levels.WARN)
		return
	end
	do_navigate(nav.chi_path, not nav.htmx)
end

function M.pick_recent()
	if not M._nav_history or #M._nav_history == 0 then
		vim.notify("browser: no recent navigations this session", vim.log.levels.WARN)
		return
	end
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	pickers
		.new({}, {
			prompt_title = "Recent  [CR=full  p=partial]",
			finder = finders.new_table({
				results = M._nav_history,
				entry_maker = function(nav)
					local hx = nav.htmx and " [partial]" or " [full]"
					return { value = nav, display = nav.resolved .. nav.qp .. hx, ordinal = nav.resolved }
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					local sel = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if not sel then
						return
					end
					do_navigate(sel.value.chi_path, sel.value.htmx)
				end)
				map("n", "p", function()
					local sel = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if not sel then
						return
					end
					do_navigate(sel.value.chi_path, true)
				end)
				return true
			end,
		})
		:find()
end

function M.open_in_tab(chi_path)
	local saved = load_test_for_path(chi_path)
	local path = (saved and saved.path) or resolve_path(chi_path)
	if not path then
		return nil
	end
	local qp = saved and (saved.qp ~= "" and ("?" .. saved.qp) or "") or build_query_params(chi_path)
	local raw_srv = send_cmd("active-server")
	local port = raw_srv and raw_srv:match("port (%d+)") or "3333"
	local url = "http://localhost:" .. port .. path .. qp
	send_cmd("open " .. url)
	return url
end

-- ------------------------------------------------------------
-- dashboard exports
-- ------------------------------------------------------------
function M.get_routes()
	return get_routes()
end
function M.get_active_base()
	return get_active_base()
end
function M.do_navigate(chi_path, htmx)
	do_navigate(chi_path, htmx)
end
function M.load_test_for_path(chi_path)
	return load_test_for_path(chi_path)
end
M.get_config = get_config

function M.save_htmx_for_path(chi_path, htmx)
	ensure_context_loaded()
	local session = require("browser.session")
	local slug = (chi_path or "unknown"):gsub("/$", ""):gsub("^/", ""):gsub("/", "-"):gsub("{", ""):gsub("}", "")
	local fpath
	if _context and _context ~= "default" and _context ~= "" then
		fpath = session.TESTS_DIR .. "/" .. _context .. "/" .. slug .. ".http"
	else
		fpath = session.TESTS_DIR .. "/" .. slug .. ".http"
	end
	local lines = {}
	local found = false
	local f = io.open(fpath, "r")
	if f then
		for line in f:lines() do
			local label = line:match("^([%w%.%-_]+):")
			if label and label:lower() == "htmx" then
				table.insert(lines, "htmx: " .. tostring(htmx))
				found = true
			else
				table.insert(lines, line)
			end
		end
		f:close()
	end
	if not found then
		table.insert(lines, "htmx: " .. tostring(htmx))
	end
	vim.fn.mkdir(vim.fn.fnamemodify(fpath, ":h"), "p")
	local wf = io.open(fpath, "w")
	if wf then
		for _, l in ipairs(lines) do
			wf:write(l .. "\n")
		end
		wf:close()
	end
end

return M
