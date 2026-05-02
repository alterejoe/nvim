-- forge_nav.lua
-- Reads .forge/plan.json, indexes entries,
-- and provides navigation between related files (handler/templ/sqlc).

local M = {}

M._plan = nil
M._index = {}
M._templ_name_index = {}
M._project_root = nil

local function find_plan_file()
	local dir = vim.fn.getcwd()
	while dir ~= "/" do
		local plan = dir .. "/.forge/plan.json"
		if vim.fn.filereadable(plan) == 1 then
			M._project_root = dir
			return plan
		end
		dir = vim.fn.fnamemodify(dir, ":h")
	end
	return nil
end

local function jump_to(rel_path, search_term)
	if not rel_path then
		return
	end
	local full = M._project_root and (M._project_root .. "/" .. rel_path) or rel_path
	if vim.fn.filereadable(full) == 1 then
		vim.cmd("edit " .. vim.fn.fnameescape(full))
		if search_term then
			local found = vim.fn.search(search_term, "cw")
			if found == 0 then
				vim.notify("forge_nav: '" .. search_term .. "' not found in file", vim.log.levels.INFO)
			end
		end
	else
		vim.notify("forge_nav: file not found: " .. rel_path, vim.log.levels.WARN)
	end
end

function M.load()
	local plan_file = find_plan_file()
	if not plan_file then
		vim.notify("forge_nav: .forge/plan.json not found", vim.log.levels.WARN)
		return false
	end

	local f = io.open(plan_file, "r")
	if not f then
		vim.notify("forge_nav: cannot read " .. plan_file, vim.log.levels.ERROR)
		return false
	end

	local content = f:read("*a")
	f:close()

	local ok, parsed = pcall(vim.json.decode, content)
	if not ok then
		vim.notify("forge_nav: invalid JSON in plan.json", vim.log.levels.ERROR)
		return false
	end

	M._plan = parsed
	M._index = {}
	M._templ_name_index = {}

	for _, action in ipairs(parsed.actions or {}) do
		if action.output then
			M._index[action.output] = action
		end
		if action.label == "templ" and action.data and action.data.name then
			M._templ_name_index[action.data.name] = action
		end
	end

	vim.notify("forge_nav: loaded " .. vim.tbl_count(M._index) .. " actions", vim.log.levels.INFO)
	return true
end

function M.current_action()
	if not M._plan then
		M.load()
	end
	if not M._index or vim.tbl_isempty(M._index) then
		return nil
	end
	local bufpath = vim.fn.expand("%:p")
	if M._project_root then
		bufpath = bufpath:sub(#M._project_root + 2)
	end
	return M._index[bufpath]
end

function M.toggle()
	local cur = M.current_action()
	if not cur then
		vim.notify("forge_nav: no action for current file", vim.log.levels.WARN)
		return
	end

	if cur.label == "handler" then
		-- try cursor context first
		local line = vim.api.nvim_get_current_line()
		for name, action in pairs(M._templ_name_index) do
			if line:find(name, 1, true) then
				jump_to(action.output, name)
				return
			end
		end

		-- fallback to data.templ list
		local templ_names = cur.data and cur.data.templ
		if not templ_names or #templ_names == 0 then
			vim.notify("forge_nav: handler has no templ references", vim.log.levels.WARN)
			return
		end

		local matches = {}
		for _, tname in ipairs(templ_names) do
			local templ_action = M._templ_name_index[tname]
			if templ_action then
				table.insert(matches, templ_action)
			end
		end

		if #matches == 0 then
			vim.notify("forge_nav: no templ found for " .. table.concat(templ_names, ", "), vim.log.levels.WARN)
		elseif #matches == 1 then
			jump_to(matches[1].output, matches[1].data and matches[1].data.name)
		else
			M._pick_actions(matches, "Forge: pick templ")
		end
	elseif cur.label == "templ" or cur.label == "templ_helper" then
		local cur_name = cur.data and cur.data.name
		if not cur_name then
			vim.notify("forge_nav: templ has no name", vim.log.levels.WARN)
			return
		end

		local matches = {}
		for _, action in ipairs(M._plan.actions or {}) do
			if action.label == "handler" and action.data and action.data.templ then
				for _, tname in ipairs(action.data.templ) do
					if tname == cur_name then
						table.insert(matches, action)
						break
					end
				end
			end
		end

		if #matches == 0 then
			vim.notify("forge_nav: no handler references " .. cur_name, vim.log.levels.WARN)
		elseif #matches == 1 then
			jump_to(matches[1].output, matches[1].data and matches[1].data.handler_func)
		else
			M._pick_actions(matches, "Forge: pick handler")
		end
	else
		vim.notify("forge_nav: toggle only works from handler/templ", vim.log.levels.INFO)
	end
end

function M.goto_sqlc()
	local cur = M.current_action()
	if not cur then
		vim.notify("forge_nav: no action for current file", vim.log.levels.WARN)
		return
	end

	local resource = cur.resource
	if not resource then
		vim.notify("forge_nav: no resource on current action", vim.log.levels.WARN)
		return
	end

	local matches = {}
	for _, action in ipairs(M._plan.actions or {}) do
		if action.label == "sqlc" and action.resource == resource then
			table.insert(matches, action)
		end
	end

	if #matches == 0 then
		vim.notify("forge_nav: no sqlc for resource " .. resource, vim.log.levels.WARN)
	elseif #matches == 1 then
		jump_to(matches[1].output)
	else
		M._pick_actions(matches, "Forge: pick sqlc")
	end
end

function M._pick_actions(actions, title)
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local act = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	local items = {}
	for _, a in ipairs(actions) do
		local name = a.data and (a.data.handler_func or a.data.name) or a.resource or "?"
		local label = string.format("[%s] %s  %s", a.label or "?", name, a.output or "")
		table.insert(items, { label = label, action = a })
	end

	pickers
		.new({}, {
			prompt_title = title,
			finder = finders.new_table({
				results = items,
				entry_maker = function(item)
					return {
						value = item,
						display = item.label,
						ordinal = item.label,
						path = M._project_root and (M._project_root .. "/" .. item.action.output) or item.action.output,
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr)
				act.select_default:replace(function()
					act.close(prompt_bufnr)
					local sel = action_state.get_selected_entry()
					if sel and sel.value then
						local a = sel.value.action
						jump_to(a.output, a.data and (a.data.handler_func or a.data.name))
					end
				end)
				return true
			end,
		})
		:find()
end

function M.pick()
	if not M._plan then
		if not M.load() then
			return
		end
	end
	M._pick_actions(M._plan.actions or {}, "Forge Entries")
end

function M.pick_type(entry_type)
	if not M._plan then
		if not M.load() then
			return
		end
	end

	local filtered = {}
	for _, a in ipairs(M._plan.actions or {}) do
		if a.label == entry_type then
			table.insert(filtered, a)
		end
	end

	M._pick_actions(filtered, "Forge: " .. entry_type)
end

function M.reload()
	M._plan = nil
	M._index = {}
	M._templ_name_index = {}
	M.load()
end

return M
