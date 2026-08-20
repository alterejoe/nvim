-- /home/jmeyer/.config/nvim/lua/tmux_projects/state.lua FINAL
local M = {}

function M.in_tmux()
	return vim.env.TMUX ~= nil
end

function M.tmux(cmd)
	vim.fn.system("tmux " .. cmd)
end

function M.tmux_result(cmd)
	return vim.fn.system("tmux " .. cmd)
end

function M.session_exists(name)
	vim.fn.system("tmux has-session -t=" .. vim.fn.shellescape(name) .. " 2>/dev/null")
	return vim.v.shell_error == 0
end

function M.ordered_sessions(show_hidden)
	local live = vim.fn.systemlist("tmux list-sessions -F '#S' 2>/dev/null")
	if vim.v.shell_error ~= 0 then
		return {}
	end
	local order_file = vim.fn.stdpath("data") .. "/tmux_session_slots"

	local live_set = {}
	for _, s in ipairs(live) do
		live_set[s] = true
	end

	local function load_order()
		local f = io.open(order_file, "r")
		if not f then
			return {}
		end
		local slots = {}
		for line in f:lines() do
			local t = vim.trim(line)
			if t ~= "" then
				table.insert(slots, t)
			end
		end
		f:close()
		return slots
	end

	local result = {}
	local seen = {}
	for _, s in ipairs(load_order()) do
		if live_set[s] and (show_hidden or not s:find("^opencode%-")) then
			table.insert(result, s)
			seen[s] = true
		end
	end
	local unseen = {}
	for _, s in ipairs(live) do
		if
			not seen[s]
			and not s:find("^browser%-")
			and not s:find("^devproxy%-")
			and (show_hidden or (not s:find("^opencode%-") and not s:find("^air%-")))
		then
			table.insert(unseen, s)
		end
	end
	table.sort(unseen)
	for _, s in ipairs(unseen) do
		table.insert(result, s)
	end
	return result
end

function M.switch_to_first_available(exclude)
	local remaining = vim.fn.systemlist("tmux list-sessions -F '#S' 2>/dev/null")
	for _, s in ipairs(remaining) do
		if s ~= exclude then
			M.tmux("switch-client -t " .. vim.fn.shellescape(s))
			return
		end
	end
end

function M.get_session_path(session_name)
	local lines = vim.fn.systemlist("tmux list-panes -a -F '#{session_name}|#{pane_current_path}' 2>/dev/null")
	for _, line in ipairs(lines) do
		local name, path = line:match("^([^|]+)|(.+)$")
		if name == session_name then
			local home = vim.fn.expand("~")
			if path:sub(1, #home) == home then
				path = "~" .. path:sub(#home + 1)
			end
			return path
		end
	end
	return ""
end

function M.pick_directory(callback)
	local scan = require("plenary.scandir")
	local cwd = vim.fn.getcwd()
	local home_projects = vim.fn.expand("~/projects")
	local tools = vim.fn.expand("~/tools")
	local dirs = {}
	local seen = {}
	local function add(d)
		if not seen[d] then
			seen[d] = true
			table.insert(dirs, d)
		end
	end
	add(cwd)
	if vim.fn.isdirectory(home_projects) == 1 then
		for _, d in ipairs(scan.scan_dir(home_projects, { depth = 1, only_dirs = true, silent = true })) do
			add(d)
		end
	end
	if vim.fn.isdirectory(tools) == 1 then
		for _, d in ipairs(scan.scan_dir(tools, { depth = 1, only_dirs = true, silent = true })) do
			add(d)
		end
	end
	for _, d in ipairs(scan.scan_dir(cwd, { only_dirs = true, silent = true })) do
		add(d)
	end
	require("telescope.pickers")
		.new({}, {
			prompt_title = "Session path",
			finder = require("telescope.finders").new_table({
				results = dirs,
				entry_maker = function(entry)
					return { value = entry, display = vim.fn.fnamemodify(entry, ":~"), ordinal = entry }
				end,
			}),
			sorter = require("telescope.config").values.generic_sorter({}),
			attach_mappings = function(prompt_bufnr)
				require("telescope.actions").select_default:replace(function()
					local sel = require("telescope.actions.state").get_selected_entry()
					require("telescope.actions").close(prompt_bufnr)
					if sel then
						callback(sel.value)
					end
				end)
				return true
			end,
		})
		:find()
end

return M
