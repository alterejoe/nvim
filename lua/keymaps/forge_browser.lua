-- lua/keymaps/forge_browser.lua
--
-- Open the current handler's route directly in Chromium via devproxy.
-- Reads .forge/plan.json (same as forge_nav), finds the chi_path for the
-- current file, and navigates Chromium to http://localhost:3333<chi_path>.
--
-- Keymaps:
--   <leader>fo   Open current handler's route in browser (full page)
--   <leader>fO   Open current handler's route in browser (partial)

local SOCKET = "/tmp/devproxy.sock"
local BASE_URL = "http://localhost:3333"

local function send_cmd(cmd)
	if vim.fn.filereadable(SOCKET) == 0 then
		vim.notify("forge_browser: devproxy not running", vim.log.levels.WARN)
		return nil
	end
	local result =
		vim.fn.system("echo " .. vim.fn.shellescape(cmd) .. " | socat -t 5 - UNIX-CONNECT:" .. SOCKET .. " 2>/dev/null")
	return vim.trim(result)
end

local function has_path_params(chi_path)
	return chi_path:find("{") ~= nil
end

local function fill_path_params(chi_path)
	-- find all {paramName} tokens and prompt for each
	local result = chi_path
	for param in chi_path:gmatch("{([^}]+)}") do
		local val = vim.fn.input("Value for {" .. param .. "}: ")
		if val == "" then
			return nil -- user cancelled
		end
		result = result:gsub("{" .. param .. "}", val, 1)
	end
	return result
end

local function open_handler_url(partial)
	local nav = require("forge_nav")
	if not nav._plan then
		if not nav.load() then
			return
		end
	end

	local action = nav.current_action()
	if not action then
		vim.notify("forge_browser: no forge action for current file", vim.log.levels.WARN)
		return
	end

	local chi_path = action.data and action.data.chi_path
	if not chi_path then
		vim.notify("forge_browser: no chi_path on action", vim.log.levels.WARN)
		return
	end

	local method = action.data.route_method or "get"
	if method ~= "get" then
		vim.notify(
			string.format("forge_browser: route is %s %s (not GET, opening anyway)", method:upper(), chi_path),
			vim.log.levels.INFO
		)
	end

	local path = chi_path
	if has_path_params(chi_path) then
		path = fill_path_params(chi_path)
		if not path then
			vim.notify("forge_browser: cancelled", vim.log.levels.INFO)
			return
		end
	end

	local url = BASE_URL .. path
	local cmd = partial and ("navigate " .. path) or ("navigate-full " .. "http://localhost:19878" .. path)

	local r = send_cmd(cmd)
	if r then
		vim.notify(string.format("[%s] %s", action.data.handler_func or "?", r))
	end
end

vim.keymap.set("n", "<leader>fo", function()
	open_handler_url(false)
end, { desc = "Forge: open handler route in browser (full)" })

vim.keymap.set("n", "<leader>fO", function()
	open_handler_url(true)
end, { desc = "Forge: open handler route in browser (partial)" })

-- Also add a telescope picker for browsing ALL handler routes
vim.keymap.set("n", "<leader>fB", function()
	local nav = require("forge_nav")
	if not nav._plan then
		if not nav.load() then
			return
		end
	end

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	local items = {}
	for _, action in ipairs(nav._plan.actions or {}) do
		if action.label == "handler" and action.data and action.data.chi_path then
			local method = (action.data.route_method or "get"):upper()
			table.insert(items, {
				display = string.format("%-6s %s", method, action.data.chi_path),
				chi_path = action.data.chi_path,
				method = method,
				func = action.data.handler_func or "?",
				output = action.output,
			})
		end
	end

	table.sort(items, function(a, b)
		return a.chi_path < b.chi_path
	end)

	pickers
		.new({}, {
			prompt_title = "Forge Routes",
			finder = finders.new_table({
				results = items,
				entry_maker = function(item)
					return {
						value = item,
						display = item.display,
						ordinal = item.display,
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, map)
				-- <CR> open in browser
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local sel = action_state.get_selected_entry()
					if not sel then
						return
					end
					local path = sel.value.chi_path
					if has_path_params(path) then
						path = fill_path_params(path)
						if not path then
							return
						end
					end
					local r = send_cmd("navigate-full " .. BASE_URL .. path)
					if r then
						vim.notify("[" .. sel.value.func .. "] " .. r)
					end
				end)

				-- <C-o> open file
				map("n", "<C-o>", function()
					actions.close(prompt_bufnr)
					local sel = action_state.get_selected_entry()
					if not sel or not sel.value.output then
						return
					end
					local root = nav._project_root or vim.fn.getcwd()
					local full = root .. "/" .. sel.value.output
					if vim.fn.filereadable(full) == 1 then
						vim.cmd("edit " .. vim.fn.fnameescape(full))
					else
						vim.notify("forge_browser: file not found: " .. full, vim.log.levels.WARN)
					end
				end)

				return true
			end,
		})
		:find()
end, { desc = "Forge: browse all routes (open in browser)" })
