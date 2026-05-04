-- browser/views.lua
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
-- Config
-- ------------------------------------------------------------
local _config = nil
local _context = "default"
local _context_loaded = false

local function persist_context(name)
	local f = io.open(devproxy_dir() .. "/active_context", "w")
	if f then
		f:write(name)
		f:close()
	end
end

local function ensure_context_loaded()
	if _context_loaded then
		return
	end
	_context_loaded = true
	local f = io.open(devproxy_dir() .. "/active_context", "r")
	if f then
		local name = vim.trim(f:read("*a"))
		f:close()
		if name and name ~= "" then
			_context = name
		end
	end
end

local function load_config()
	local path = devproxy_dir() .. "/config.yaml"
	if vim.fn.filereadable(path) == 0 then
		_config = { defaults = {}, query_params = {}, contexts = {}, exceptions = {} }
		return
	end
	local raw = vim.fn.system("yq -o=json . " .. vim.fn.shellescape(path) .. " 2>/dev/null")
	local ok, data = pcall(vim.json.decode, raw)
	if not ok or not data then
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

-- Returns merged params for the active context: defaults < contexts.<ctx>
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
	return params
end

-- Returns merged params for a specific named context
local function params_for_context(ctx_name)
	local cfg = get_config()
	local params = {}
	for k, v in pairs(cfg.defaults) do
		params[k] = tostring(v)
	end
	local ctx = cfg.contexts[ctx_name] or {}
	for k, v in pairs(ctx) do
		params[k] = tostring(v)
	end
	return params
end

-- Resolve a chi_path template using the active context params.
-- Any {param} without a value stays as-is.
local function resolve_path(chi_path)
	local params = active_params()
	local result = chi_path
	for param in chi_path:gmatch("{([^}]+)}") do
		if params[param] and params[param] ~= "" then
			result = result:gsub("{" .. param .. "}", params[param], 1)
		end
	end
	return result
end

-- Resolve a chi_path template using a specific context's params.
local function resolve_path_for_context(chi_path, ctx_name)
	local params = params_for_context(ctx_name)
	local result = chi_path
	for param in chi_path:gmatch("{([^}]+)}") do
		if params[param] and params[param] ~= "" then
			result = result:gsub("{" .. param .. "}", params[param], 1)
		end
	end
	return result
end

-- ------------------------------------------------------------
-- Routes from plan.json
-- ------------------------------------------------------------
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

-- Normalize any chi_path expression to the canonical plan.json form.
local function normalize_chi_path(chi_path)
	if not chi_path then
		return chi_path
	end
	local routes = get_routes()
	for _, r in ipairs(routes) do
		if r.chi_path == chi_path then
			return chi_path
		end
	end
	local function segs(s)
		local t = {}
		for seg in s:gsub("?.*$", ""):gmatch("[^/]+") do
			table.insert(t, seg)
		end
		return t
	end
	local c_segs = segs(chi_path)
	for _, r in ipairs(routes) do
		local r_segs = segs(r.chi_path)
		if #r_segs == #c_segs then
			local same = true
			for i, c in ipairs(c_segs) do
				local rs = r_segs[i]
				local c_param = c:sub(1, 1) == "{"
				local r_param = rs:sub(1, 1) == "{"
				if c_param ~= r_param or (not c_param and c ~= rs) then
					same = false
					break
				end
			end
			if same then
				return r.chi_path
			end
		end
	end
	return chi_path
end

-- ------------------------------------------------------------
-- Test file lookup
-- Test files store ONLY endpoint-specific data: query: and htmx:
-- Path is ALWAYS resolved from chi_path + active context at navigate time.
-- ------------------------------------------------------------
local function test_file_path(chi_path, ctx_name)
	chi_path = normalize_chi_path(chi_path)
	local session = require("browser.session")
	local slug = (chi_path or "unknown"):gsub("/$", ""):gsub("^/", ""):gsub("/", "-"):gsub("{", ""):gsub("}", "")
	if ctx_name and ctx_name ~= "default" and ctx_name ~= "" then
		return session.TESTS_DIR .. "/" .. ctx_name .. "/" .. slug .. ".http"
	else
		return session.TESTS_DIR .. "/" .. slug .. ".http"
	end
end

local function load_test_for_path(chi_path)
	ensure_context_loaded()
	local fpath = test_file_path(chi_path, _context)
	if vim.fn.filereadable(fpath) == 0 then
		return nil
	end
	local f = io.open(fpath, "r")
	if not f then
		return nil
	end
	local qp = ""
	local htmx_val = nil
	for line in f:lines() do
		local label, val = line:match("^([%w%.%-_]+):%s*(.*)")
		if label then
			local low = label:lower()
			if low == "query" then
				qp = vim.trim(val)
			end
			if low == "htmx" then
				htmx_val = vim.trim(val) == "true"
			end
			-- "path" intentionally ignored - always resolved from chi_path + context
		end
	end
	f:close()
	return { qp = qp, htmx = htmx_val }
end

-- ------------------------------------------------------------
-- Navigation
-- Always resolves path from chi_path + active context.
-- Test file provides query params and htmx preference only.
-- ------------------------------------------------------------
M._last_nav = nil

local function do_navigate(chi_path, htmx)
	chi_path = normalize_chi_path(chi_path)
	local path = resolve_path(chi_path)
	if not path or path:find("{") then
		vim.notify("browser: unresolved params in " .. chi_path, vim.log.levels.WARN)
		return
	end
	local saved = load_test_for_path(chi_path)
	local qp = (saved and saved.qp ~= "" and ("?" .. saved.qp)) or ""
	M._last_nav = {
		chi_path = chi_path,
		resolved = path,
		qp = qp,
		htmx = htmx,
		params_used = active_params(),
		skip = {},
	}
	local base = get_active_base()
	local cmd = htmx and "navigate" or "navigate-full"
	send_cmd(cmd .. " " .. base .. path .. qp)
	local hx_label = htmx and " [partial]" or " [full]"
	vim.notify(string.format("browser: %s%s%s", path, qp, hx_label))
end

-- ------------------------------------------------------------
-- Context management
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

function M.cycle_context(dir)
	ensure_context_loaded()
	local contexts = get_contexts()
	if #contexts <= 1 then
		vim.notify("browser: only one context available", vim.log.levels.INFO)
		return _context
	end
	local idx = 1
	for i, name in ipairs(contexts) do
		if name == _context then
			idx = i
			break
		end
	end
	_context = contexts[((idx - 1 + dir) % #contexts) + 1]
	persist_context(_context)
	vim.notify("browser: context -> " .. _context)
	return _context
end

function M.context_show()
	ensure_context_loaded()
	local params = active_params()
	local lines = { "Context: " .. _context, "Project: " .. find_project_root(), "", "Active params:" }
	for k, v in pairs(params) do
		table.insert(lines, string.format("  %-20s = %s", k, v))
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
		vim.notify("browser.views: no servers in config", vim.log.levels.WARN)
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
					return {
						value = s,
						display = string.format("%-15s  port %d%s", s.name, s.port, active),
						ordinal = s.name,
					}
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

-- ------------------------------------------------------------
-- Picker
-- ------------------------------------------------------------
M.keys = { full = "<CR>", partial = "p", tab_full = "t", tab_partial = "T", file = "o" }

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

function M.pick()
	local views = get_views()
	local routes = get_routes()
	local items = {}
	for _, v in ipairs(views) do
		table.insert(
			items,
			{
				display = string.format("[view]  %-30s  %s", v.name, v.layout or ""),
				ordinal = v.name,
				kind = "view",
				name = v.name,
			}
		)
	end
	for _, r in ipairs(routes) do
		table.insert(
			items,
			{
				display = string.format("[route] %-30s  %s", r.chi_path, r.handler or ""),
				ordinal = r.chi_path,
				kind = "route",
				chi_path = r.chi_path,
				output = r.output,
			}
		)
	end
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	pickers
		.new({}, {
			prompt_title = "Browser  [CR=full  p=partial  t=new tab full  T=new tab partial  o=file]",
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
				map("n", M.keys.partial, function()
					local sel = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if not sel then
						return
					end
					local item = sel.value
					if item.kind == "view" then
						send_cmd("navigate " .. VIEW_SERVER .. "/view?name=" .. item.name)
					else
						do_navigate(item.chi_path, true)
					end
				end)
				map("n", M.keys.tab_full, function()
					local sel = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if not sel then
						return
					end
					local item = sel.value
					if item.kind == "route" then
						local path = resolve_path(item.chi_path)
						local saved = load_test_for_path(item.chi_path)
						local qp = saved and (saved.qp ~= "" and ("?" .. saved.qp)) or ""
						local url = get_active_base() .. path .. qp
						send_cmd("open " .. url)
						vim.notify("browser: new tab (full) -> " .. url)
					end
				end)
				map("n", M.keys.tab_partial, function()
					local sel = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if not sel then
						return
					end
					local item = sel.value
					if item.kind == "route" then
						local path = resolve_path(item.chi_path)
						local saved = load_test_for_path(item.chi_path)
						local qp = saved and (saved.qp ~= "" and ("?" .. saved.qp)) or ""
						local url = get_active_base() .. path .. qp
						send_cmd("open " .. url)
						vim.defer_fn(function()
							send_cmd("navigate " .. url)
						end, 500)
						vim.notify("browser: new tab (partial) -> " .. url)
					end
				end)
				map("n", M.keys.file, function()
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
				end)
				return true
			end,
		})
		:find()
end

-- ------------------------------------------------------------
-- Views config management
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

function M.quick_add()
	vim.ui.input({ prompt = "View name: " }, function(name)
		if not name or name == "" then
			return
		end
		local LAYOUTS = { "single", "side-by-side", "vertical-stack", "grid" }
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
			attach_mappings = function(prompt_bufnr, _map)
				actions.select_default:replace(function()
					local sel = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if not sel then
						return
					end
					M.switch_context(sel.value.name)
					vim.notify("browser.views: context -> " .. _context)
				end)
				return true
			end,
		})
		:find()
end

function M.toggle_mode()
	local nav = M._last_nav
	if not nav then
		vim.notify("browser: no navigation recorded", vim.log.levels.WARN)
		return
	end
	do_navigate(nav.chi_path, not nav.htmx)
end

function M.open_in_tab(chi_path)
	chi_path = normalize_chi_path(chi_path)
	local path = resolve_path(chi_path)
	if not path then
		return nil
	end
	local saved = load_test_for_path(chi_path)
	local qp = saved and (saved.qp ~= "" and ("?" .. saved.qp)) or ""
	local port = (send_cmd("active-server") or ""):match("port (%d+)") or "3333"
	local url = "http://localhost:" .. port .. path .. qp
	send_cmd("open " .. url)
	local htmx = saved and saved.htmx
	if htmx then
		vim.defer_fn(function()
			send_cmd("navigate " .. url)
		end, 800)
	end
	return url
end

-- ------------------------------------------------------------
-- Dashboard exports
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
function M.test_file_path(chi_path, ctx)
	return test_file_path(chi_path, ctx)
end
function M.resolve_path(chi_path)
	return resolve_path(chi_path)
end
function M.resolve_path_for_context(chi_path, ctx)
	return resolve_path_for_context(chi_path, ctx)
end
function M.params_for_context(ctx_name)
	return params_for_context(ctx_name)
end
function M.normalize_chi_path(chi_path)
	return normalize_chi_path(chi_path)
end
M.get_config = get_config

function M.save_htmx_for_path(chi_path, htmx)
	chi_path = normalize_chi_path(chi_path)
	ensure_context_loaded()
	local fpath = test_file_path(chi_path, _context)
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
