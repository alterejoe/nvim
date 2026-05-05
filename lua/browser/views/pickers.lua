-- browser/views/pickers.lua
--
-- Telescope pickers + views.yaml management.
--
-- Public functions (re-exported by orchestrator):
--   pick           - main view/route picker (CR=full, p=partial, t/T=new tab, o=file)
--   pick_recent    - recent navigations
--   context_pick   - switch context picker
--   server_pick    - switch server picker
--   reload         - send views-reload to devproxy
--   edit           - :edit views.yaml
--   quick_add      - prompt-driven view creation
--   _append_view   - file write helper used by quick_add
--   keys           - shared keymap table for the picker
--
-- The view-server URL serves rendered view templates - separate from
-- the dev app server that handles route navigation.

local M = {}

local config = require("browser.views.config")
local routes = require("browser.views.routes")
local test_files = require("browser.views.test_files")
local navigate = require("browser.views.navigate")

local VIEW_SERVER = "http://localhost:19878"

local function send_cmd(cmd)
	return require("browser.session").send_cmd(cmd)
end

local function views_path()
	return require("browser.session").VIEWS_PATH
end

-- ============================================================
-- Picker keymaps. Used by pick(); exposed because external code may
-- rely on these defaults for muscle memory.
-- ============================================================
M.keys = { full = "<CR>", partial = "p", tab_full = "t", tab_partial = "T", file = "o" }

-- ============================================================
-- get_views
-- Fetches the views list from the running view server. Falls back to
-- parsing views.yaml directly when the server isn't reachable.
-- ============================================================
local function get_views()
	local raw = vim.fn.system("curl -s " .. VIEW_SERVER .. "/views 2>/dev/null")
	local ok, data = pcall(vim.json.decode, raw)
	if not ok or not data then
		local yr = vim.fn.system("yq -o=json . " .. vim.fn.shellescape(views_path()) .. " 2>/dev/null")
		local yok, ydata = pcall(vim.json.decode, yr)
		if not yok or not ydata or not ydata.views then
			return {}
		end
		local out = {}
		for name, v in pairs(ydata.views) do
			table.insert(out, { name = name, layout = v.layout or v.template or "custom", kind = "view" })
		end
		return out
	end
	for _, v in ipairs(data) do
		v.kind = "view"
	end
	return data
end

-- ============================================================
-- pick
-- Main picker: views + routes. Five actions:
--   CR   navigate active tab full
--   p    navigate active tab partial
--   t    new tab full
--   T    new tab partial (open + deferred navigate)
--   o    open the handler source file
-- ============================================================
function M.pick()
	local views = get_views()
	local route_list = routes.get_routes()
	local items = {}
	for _, v in ipairs(views) do
		table.insert(items, {
			display = string.format("[view]  %-30s  %s", v.name, v.layout or ""),
			ordinal = v.name,
			kind = "view",
			name = v.name,
		})
	end
	for _, r in ipairs(route_list) do
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
	local orch = require("browser.views")
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
					local htmx = orch._last_nav and orch._last_nav.htmx or false
					if item.kind == "view" then
						local cmd = htmx and "navigate" or "navigate-full"
						-- Phase 1 strict: navigate against the active tab.
						local session = require("browser.session")
						local id = session.active_tab_id()
						if not id then
							vim.notify("browser: no active tab", vim.log.levels.WARN)
							return
						end
						send_cmd(cmd .. " --tab=" .. id .. " " .. VIEW_SERVER .. "/view?name=" .. item.name)
						vim.notify("browser: [" .. (htmx and "partial" or "full") .. "] view " .. item.name)
					else
						navigate.do_navigate(item.chi_path, htmx)
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
						local session = require("browser.session")
						local id = session.active_tab_id()
						if not id then
							vim.notify("browser: no active tab", vim.log.levels.WARN)
							return
						end
						send_cmd("navigate --tab=" .. id .. " " .. VIEW_SERVER .. "/view?name=" .. item.name)
					else
						navigate.do_navigate(item.chi_path, true)
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
						local path = routes.resolve_path(item.chi_path)
						config.ensure_context_loaded()
						local saved = test_files.load_test_for_path(item.chi_path)
						local qp = test_files.build_query_string(
							test_files.query_for_route(config.get_active_context(), item.chi_path, saved.query_keys)
						)
						local url = config.get_active_base() .. path .. qp
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
						local path = routes.resolve_path(item.chi_path)
						config.ensure_context_loaded()
						local saved = test_files.load_test_for_path(item.chi_path)
						local qp = test_files.build_query_string(
							test_files.query_for_route(config.get_active_context(), item.chi_path, saved.query_keys)
						)
						local url = config.get_active_base() .. path .. qp
						local open_resp = send_cmd("open " .. url) or ""
						local new_id = open_resp:match("opened tab (%S+)")
						if new_id then
							vim.defer_fn(function()
								send_cmd("navigate --tab=" .. new_id .. " " .. url)
							end, 500)
						end
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
					local root = config.find_project_root()
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

-- ============================================================
-- pick_recent
-- Telescope picker over the in-memory navigation history.
-- ============================================================
function M.pick_recent()
	local orch = require("browser.views")
	if not orch._nav_history or #orch._nav_history == 0 then
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
				results = orch._nav_history,
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
					navigate.do_navigate(sel.value.chi_path, sel.value.htmx)
				end)
				map("n", "p", function()
					local sel = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if not sel then
						return
					end
					navigate.do_navigate(sel.value.chi_path, true)
				end)
				return true
			end,
		})
		:find()
end

-- ============================================================
-- context_pick
-- Switch active context via telescope. Lists all defined contexts
-- with their non-query params previewed inline.
-- ============================================================
function M.context_pick()
	local cfg = config.get_config()
	local active = config.get_active_context()
	local contexts = {}
	for name, vals in pairs(cfg.contexts) do
		local active_marker = name == active and " [active]" or ""
		local preview = {}
		for k, v in pairs(vals) do
			if k ~= "query" and v ~= vim.NIL then
				table.insert(preview, k .. "=" .. tostring(v))
			end
		end
		table.insert(contexts, {
			name = name,
			display = string.format("%-20s %s%s", name, table.concat(preview, "  "), active_marker),
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
					config.switch_context(sel.value.name)
					vim.notify("browser.views: context -> " .. config.get_active_context())
				end)
				return true
			end,
		})
		:find()
end

-- ============================================================
-- server_pick
-- Switch the active dev app server via telescope.
-- ============================================================
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

-- ============================================================
-- Views config management (views.yaml).
-- ============================================================

function M.reload()
	local r = send_cmd("views-reload")
	if r then
		vim.notify("browser.views: " .. r)
	end
end

function M.edit()
	vim.cmd("edit " .. vim.fn.fnameescape(views_path()))
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

return M
