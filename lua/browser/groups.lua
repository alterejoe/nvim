-- browser/groups.lua
-- Group management for devproxy. Groups are named lists of chi_paths.
-- Saved to .devproxy/groups.yaml

local M = {}

M._active_group = nil
M._active_tab_ids = {}

local function send_cmd(cmd)
	return require("browser.session").send_cmd(cmd)
end

local function groups_path()
	return require("browser.session").DEVPROXY_DIR .. "/groups.yaml"
end

local function load_groups()
	local path = groups_path()
	if vim.fn.filereadable(path) == 0 then
		return {}
	end
	local raw = vim.fn.system("yq -o=json . " .. vim.fn.shellescape(path) .. " 2>/dev/null")
	local ok, data = pcall(vim.json.decode, raw)
	if not ok or not data or not data.groups then
		return {}
	end
	return data.groups
end

local function save_groups(groups)
	local path = groups_path()
	local lines = { "groups:" }
	for name, paths in pairs(groups) do
		table.insert(lines, "  " .. name .. ":")
		for _, p in ipairs(paths) do
			table.insert(lines, "    - " .. p)
		end
	end
	local f = io.open(path, "w")
	if not f then
		vim.notify("browser.groups: cannot write " .. path, vim.log.levels.ERROR)
		return
	end
	f:write(table.concat(lines, "\n") .. "\n")
	f:close()
end

local function close_active_group_tabs()
	if #M._active_tab_ids == 0 then
		return
	end
	for _, id in ipairs(M._active_tab_ids) do
		send_cmd("close-tab " .. id)
	end
	M._active_tab_ids = {}
	M._active_group = nil
end

local function get_current_tab_ids()
	local raw = send_cmd("tabs")
	if not raw or raw:sub(1, 1) ~= "[" then
		return {}
	end
	local ok, tabs = pcall(vim.json.decode, raw)
	if not ok then
		return {}
	end
	local ids = {}
	for _, t in ipairs(tabs) do
		table.insert(ids, t.id)
	end
	return ids
end

local function open_group(name, paths)
	close_active_group_tabs()
	local before_ids = get_current_tab_ids()
	local before_set = {}
	for _, id in ipairs(before_ids) do
		before_set[id] = true
	end
	for _, chi_path in ipairs(paths) do
		require("browser.views").open_in_tab(chi_path)
	end
	vim.defer_fn(function()
		local after_ids = get_current_tab_ids()
		local new_ids = {}
		for _, id in ipairs(after_ids) do
			if not before_set[id] then
				table.insert(new_ids, id)
			end
		end
		M._active_tab_ids = new_ids
		M._active_group = name
		for i, id in ipairs(new_ids) do
			local chi_path = paths[i]
			if chi_path then
				require("browser.session")._tab_paths[id] = chi_path
			end
		end
		if #new_ids > 0 then
			send_cmd("switch " .. new_ids[1])
			local views = require("browser.views")
			for i, id in ipairs(new_ids) do
				local chi_path = paths[i]
				if chi_path then
					require("browser.session")._tab_paths[id] = chi_path
				end
			end
			if paths[1] then
				local saved = views.load_test_for_path(paths[1])
				views._last_nav = {
					chi_path = paths[1],
					resolved = saved and saved.path or paths[1],
					qp = saved and (saved.qp ~= "" and ("?" .. saved.qp) or "") or "",
					htmx = true,
					params_used = {},
					skip = {},
				}
			end
		end
		vim.notify(string.format("browser: group '%s' opened (%d tabs)", name, #new_ids))
	end, 1000)
end

-- ------------------------------------------------------------
-- Exports for dashboard group editor
-- ------------------------------------------------------------
function M.load_groups()
	return load_groups()
end

function M.save_groups(groups)
	save_groups(groups)
end

function M.open_group(name, paths)
	open_group(name, paths)
end

function M.pick()
	local groups = load_groups()
	local names = {}
	for name in pairs(groups) do
		table.insert(names, name)
	end
	table.sort(names)
	if #names == 0 then
		vim.notify("browser.groups: no groups defined - use <leader>bG to create one", vim.log.levels.WARN)
		return
	end
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local items = {}
	for _, name in ipairs(names) do
		local paths = groups[name] or {}
		local active = name == M._active_group and " [active]" or ""
		table.insert(items, {
			name = name,
			paths = paths,
			display = string.format("%-20s  %d paths%s", name, #paths, active),
		})
	end
	pickers
		.new({}, {
			prompt_title = "Browser Groups  [CR=open  d=delete group]",
			finder = finders.new_table({
				results = items,
				entry_maker = function(item)
					return { value = item, display = item.display, ordinal = item.name }
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
					open_group(sel.value.name, sel.value.paths)
				end)
				map("n", "d", function()
					local sel = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if not sel then
						return
					end
					local gs = load_groups()
					gs[sel.value.name] = nil
					save_groups(gs)
					vim.notify("browser.groups: deleted group '" .. sel.value.name .. "'")
				end)
				return true
			end,
		})
		:find()
end

function M.manage()
	local nav = require("browser.views")._last_nav
	if not nav then
		vim.notify("browser.groups: no navigation recorded", vim.log.levels.WARN)
		return
	end
	local chi_path = nav.chi_path
	local groups = load_groups()
	local names = {}
	for name in pairs(groups) do
		table.insert(names, name)
	end
	table.sort(names)
	local member_of = {}
	for name, paths in pairs(groups) do
		for _, p in ipairs(paths) do
			if p == chi_path then
				member_of[name] = true
			end
		end
	end
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local items = {}
	for _, name in ipairs(names) do
		local in_group = member_of[name] and " [in group]" or ""
		table.insert(items, {
			name = name,
			is_new = false,
			in_group = member_of[name],
			display = string.format("%-20s%s", name, in_group),
		})
	end
	table.insert(items, { name = "[new group]", is_new = true, display = "[+ new group]" })
	pickers
		.new({}, {
			prompt_title = string.format("Groups for %s  [CR=toggle  n=new]", chi_path),
			finder = finders.new_table({
				results = items,
				entry_maker = function(item)
					return { value = item, display = item.display, ordinal = item.name }
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, _map)
				local function toggle_or_new(sel)
					if not sel then
						return
					end
					actions.close(prompt_bufnr)
					local gs = load_groups()
					if sel.value.is_new then
						vim.ui.input({ prompt = "New group name: " }, function(name)
							if not name or name == "" then
								return
							end
							gs[name] = gs[name] or {}
							table.insert(gs[name], chi_path)
							save_groups(gs)
							vim.notify("browser.groups: created group '" .. name .. "' with " .. chi_path)
						end)
					elseif sel.value.in_group then
						local new_paths = {}
						for _, p in ipairs(gs[sel.value.name] or {}) do
							if p ~= chi_path then
								table.insert(new_paths, p)
							end
						end
						gs[sel.value.name] = new_paths
						save_groups(gs)
						vim.notify("browser.groups: removed " .. chi_path .. " from '" .. sel.value.name .. "'")
					else
						gs[sel.value.name] = gs[sel.value.name] or {}
						table.insert(gs[sel.value.name], chi_path)
						save_groups(gs)
						vim.notify("browser.groups: added " .. chi_path .. " to '" .. sel.value.name .. "'")
					end
				end
				actions.select_default:replace(function()
					toggle_or_new(action_state.get_selected_entry())
				end)
				return true
			end,
		})
		:find()
end

function M.cycle_next()
	if #M._active_tab_ids == 0 then
		vim.notify("browser.groups: no active group", vim.log.levels.WARN)
		return
	end
	local raw = send_cmd("tabs")
	if not raw or raw:sub(1, 1) ~= "[" then
		return
	end
	local ok, tabs = pcall(vim.json.decode, raw)
	if not ok then
		return
	end
	local active_id
	for _, t in ipairs(tabs) do
		if t.active then
			active_id = t.id
			break
		end
	end
	local idx = 1
	for i, id in ipairs(M._active_tab_ids) do
		if id == active_id then
			idx = i
			break
		end
	end
	local next_idx = (idx % #M._active_tab_ids) + 1
	send_cmd("switch " .. M._active_tab_ids[next_idx])
end

function M.cycle_prev()
	if #M._active_tab_ids == 0 then
		vim.notify("browser.groups: no active group", vim.log.levels.WARN)
		return
	end
	local raw = send_cmd("tabs")
	if not raw or raw:sub(1, 1) ~= "[" then
		return
	end
	local ok, tabs = pcall(vim.json.decode, raw)
	if not ok then
		return
	end
	local active_id
	for _, t in ipairs(tabs) do
		if t.active then
			active_id = t.id
			break
		end
	end
	local idx = 1
	for i, id in ipairs(M._active_tab_ids) do
		if id == active_id then
			idx = i
			break
		end
	end
	local prev_idx = ((idx - 2) % #M._active_tab_ids) + 1
	send_cmd("switch " .. M._active_tab_ids[prev_idx])
end

function M.close_active()
	if not M._active_group then
		vim.notify("browser.groups: no active group", vim.log.levels.WARN)
		return
	end
	local name = M._active_group
	close_active_group_tabs()
	vim.notify("browser.groups: closed group '" .. name .. "'")
end

return M
