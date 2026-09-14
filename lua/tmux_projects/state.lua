-- lua/tmux_projects/state.lua FINAL
local M = {}

local directory_cache = nil

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
	local ordered = {}
	local file = io.open(order_file, "r")
	if file then
		for line in file:lines() do
			local value = vim.trim(line)
			if value ~= "" then
				table.insert(ordered, value)
			end
		end
		file:close()
	end

	local live_set = {}
	for _, session in ipairs(live) do
		live_set[session] = true
	end
	local result, seen = {}, {}
	for _, session in ipairs(ordered) do
		if live_set[session] and (show_hidden or not session:find("^opencode%-")) then
			table.insert(result, session)
			seen[session] = true
		end
	end
	local unseen = {}
	for _, session in ipairs(live) do
		if
			not seen[session]
			and not session:find("^browser%-")
			and not session:find("^devproxy%-")
			and (show_hidden or (not session:find("^opencode%-") and not session:find("^air%-")))
		then
			table.insert(unseen, session)
		end
	end
	table.sort(unseen)
	vim.list_extend(result, unseen)
	return result
end

function M.switch_to_first_available(exclude)
	for _, session in ipairs(vim.fn.systemlist("tmux list-sessions -F '#S' 2>/dev/null")) do
		if session ~= exclude then
			M.tmux("switch-client -t " .. vim.fn.shellescape(session))
			return
		end
	end
end

function M.get_session_path(session_name)
	for _, line in ipairs(vim.fn.systemlist("tmux list-panes -a -F '#{session_name}|#{pane_current_path}' 2>/dev/null")) do
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

local function scan_directories()
	local scan = require("plenary.scandir")
	local roots = {
		vim.fn.getcwd(),
		vim.fn.expand("~/projects"),
		vim.fn.expand("~/tools"),
	}
	local dirs, seen = {}, {}
	local function add(path)
		if path ~= "" and not seen[path] then
			seen[path] = true
			table.insert(dirs, path)
		end
	end
	for _, root in ipairs(roots) do
		if vim.fn.isdirectory(root) == 1 then
			add(root)
			for _, path in ipairs(scan.scan_dir(root, { depth = 1, only_dirs = true, silent = true })) do
				add(path)
			end
		end
	end
	table.sort(dirs)
	return dirs
end

function M.refresh_directory_cache()
	directory_cache = scan_directories()
	return directory_cache
end

function M.pick_directory(callback)
	local dirs = directory_cache or M.refresh_directory_cache()
	local actions = require("telescope.actions")
	local state = require("telescope.actions.state")
	local picker = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values

	picker
		.new({}, {
			prompt_title = "Session path (type any path) . . .",
			finder = finders.new_table({
				results = dirs,
				entry_maker = function(entry)
					return { value = entry, display = vim.fn.fnamemodify(entry, ":~"), ordinal = entry }
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					local selected = state.get_selected_entry()
					actions.close(prompt_bufnr)
					if selected then
						callback(selected.value)
					else
						local typed = vim.trim(vim.fn.getcmdline())
						if typed ~= "" then
							callback(typed)
						end
					end
				end)
				return true
			end,
		})
		:find()
end

return M
