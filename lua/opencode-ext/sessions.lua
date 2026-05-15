-- lua/opencode-ext/sessions.lua FINAL
-- sessions.lua
-- Manages OpenCode in dedicated tmux sessions.
-- Sessions are named `opencode-<parent>-<dir>` and persist across nvim restarts.
--
-- Keymaps:
--   <leader>oo  Start/toggle OpenCode session for current project
--   <leader>or  Restart OpenCode session
--   <leader>oq  Kill OpenCode session
--   <leader>os  Pick a main session (via telescope)
--   <leader>om  Toggle main session (works from any CWD)
--   <leader>am  Open code block picker for main session

local M = {}
local OC_PREFIX = "opencode-"
local MAIN_SESSION_FILE = vim.fn.stdpath("config") .. "/.opencode-main-session"

local function in_tmux()
	return vim.env.TMUX ~= nil
end

local function tmux(cmd)
	return vim.fn.system("tmux " .. cmd)
end

local function project_key()
	local cwd = vim.fn.getcwd()
	local parts = {}
	for part in cwd:gmatch("[^/]+") do
		table.insert(parts, part)
	end
	local key
	if #parts >= 2 then
		key = parts[#parts - 1] .. "-" .. parts[#parts]
	else
		key = parts[#parts] or "unknown"
	end
	return key:gsub("[%.%:]", "_")
end

local function session_name()
	return OC_PREFIX .. project_key()
end

local function session_exists(name)
	vim.fn.system("tmux has-session -t=" .. vim.fn.shellescape(name) .. " 2>/dev/null")
	return vim.v.shell_error == 0
end

local function find_oc_buf()
	local bufname = "opencode-term-" .. project_key()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):find(bufname, 1, true) then
			return buf
		end
	end
	return nil
end

local function open_oc_buffer()
	local name = session_name()
	local bufname = "opencode-term-" .. project_key()

	vim.cmd("vsplit")
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(0, buf)
	vim.fn.termopen("tmux attach-session -t " .. vim.fn.shellescape(name), {
		on_exit = function()
			if vim.api.nvim_buf_is_valid(buf) then
				vim.api.nvim_buf_delete(buf, { force = true })
			end
		end,
	})
	vim.api.nvim_buf_set_name(buf, bufname)
	vim.bo[buf].bufhidden = "hide"
	vim.cmd("startinsert")
end

local function close_oc_buffer()
	local buf = find_oc_buf()
	if not buf then
		return false
	end
	local wins = vim.fn.win_findbuf(buf)
	local was_open = #wins > 0
	if was_open then
		for _, win in ipairs(wins) do
			vim.api.nvim_win_close(win, true)
		end
	end
	return was_open
end

--- Persisted main session ---------------------------------------------

local function get_main_session()
	local f = io.open(MAIN_SESSION_FILE, "r")
	if not f then
		return nil, nil
	end
	local name = f:read("*l")
	local path = f:read("*l")
	f:close()
	name = name and name ~= "" and name or nil
	path = path and path ~= "" and path or nil
	return name, path
end

local function set_main_session(name, path)
	local f = io.open(MAIN_SESSION_FILE, "w")
	if f then
		f:write((name or "") .. "\n")
		f:write((path or "") .. "\n")
		f:close()
	end
end

local function list_oc_sessions()
	local out = vim.fn.systemlist("tmux list-sessions -F '#S' 2>/dev/null")
	local oc = {}
	for _, s in ipairs(out or {}) do
		if s:match("^" .. OC_PREFIX) then
			oc[#oc + 1] = s
		end
	end
	return oc
end

local function session_preview_lines(name)
	local ok, windows = pcall(vim.fn.systemlist, {
		"tmux",
		"list-windows",
		"-F",
		"#W",
		"-t",
		name,
	})
	local lines = { "Session: " .. name, "Windows:", "" }
	if ok and vim.v.shell_error == 0 then
		for _, w in ipairs(windows or {}) do
			lines[#lines + 1] = "  " .. w
		end
	end
	local ok2, pane = pcall(vim.fn.system, {
		"tmux",
		"capture-pane",
		"-t",
		name .. ":1",
		"-p",
		"-S",
		"-20",
	})
	if ok2 and vim.v.shell_error == 0 and pane and pane ~= "" then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "--- Last output ---"
		for _, l in ipairs(vim.split(pane, "\n", { plain = true })) do
			lines[#lines + 1] = l
		end
	end
	return lines
end

--- <leader>oo -- start/toggle ----------------------------------------

vim.keymap.set("n", "<leader>oo", function()
	if not in_tmux() then
		vim.notify("opencode: not in tmux", vim.log.levels.WARN)
		return
	end

	local name = session_name()

	if not session_exists(name) then
		local cwd = vim.fn.shellescape(vim.fn.getcwd())
		tmux("new-session -ds " .. vim.fn.shellescape(name) .. " -c " .. cwd .. " 'opencode'")
		vim.notify("opencode: started [" .. name .. "]")
	end

	local existing_buf = find_oc_buf()
	if existing_buf and vim.api.nvim_buf_is_valid(existing_buf) then
		local wins = vim.fn.win_findbuf(existing_buf)
		if #wins > 0 then
			for _, win in ipairs(wins) do
				vim.api.nvim_win_close(win, true)
			end
		else
			vim.cmd("vsplit")
			vim.api.nvim_win_set_buf(0, existing_buf)
			vim.cmd("startinsert")
		end
	else
		open_oc_buffer()
	end
end, { desc = "OpenCode: start/toggle" })

--- <leader>or -- restart ---------------------------------------------

vim.keymap.set("n", "<leader>or", function()
	if not in_tmux() then
		return
	end

	local name = session_name()
	if not session_exists(name) then
		vim.notify("opencode: no session for this project", vim.log.levels.WARN)
		return
	end

	close_oc_buffer()
	local buf = find_oc_buf()
	if buf and vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_delete(buf, { force = true })
	end

	tmux("kill-session -t " .. vim.fn.shellescape(name))

	local cwd = vim.fn.shellescape(vim.fn.getcwd())
	tmux("new-session -ds " .. vim.fn.shellescape(name) .. " -c " .. cwd .. " 'opencode'")

	vim.notify("opencode: restarted [" .. name .. "]")

	vim.defer_fn(function()
		open_oc_buffer()
	end, 500)
end, { desc = "OpenCode: restart" })

--- <leader>oq -- kill ------------------------------------------------

vim.keymap.set("n", "<leader>oq", function()
	if not in_tmux() then
		return
	end

	local name = session_name()
	if not session_exists(name) then
		vim.notify("opencode: no session for this project", vim.log.levels.WARN)
		return
	end

	close_oc_buffer()
	local buf = find_oc_buf()
	if buf and vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_delete(buf, { force = true })
	end

	tmux("kill-session -t " .. vim.fn.shellescape(name))
	vim.notify("opencode: killed [" .. name .. "]")
end, { desc = "OpenCode: kill" })

--- <leader>os -- pick main session -----------------------------------

vim.keymap.set("n", "<leader>os", function()
	if not in_tmux() then
		vim.notify("opencode: not in tmux", vim.log.levels.WARN)
		return
	end

	local sessions = list_oc_sessions()
	if #sessions == 0 then
		vim.notify("opencode: no sessions found", vim.log.levels.WARN)
		return
	end

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local previewers = require("telescope.previewers")

	local items = {}
	for _, s in ipairs(sessions) do
		local project = s:gsub("^opencode%-", ""):gsub("%-", "/")
		items[#items + 1] = {
			name = s,
			display = s .. "  (" .. project .. ")",
			ordinal = s,
		}
	end

	pickers
		.new({}, {
			prompt_title = "Set main opencode session",
			finder = finders.new_table({
				results = items,
				entry_maker = function(item)
					return {
						value = item,
						display = item.display,
						ordinal = item.ordinal,
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = previewers.new_buffer_previewer({
				define_preview = function(self, entry)
					local lines = session_preview_lines(entry.value.name)
					pcall(vim.api.nvim_buf_set_lines, self.state.bufnr, 0, -1, false, lines)
				end,
			}),
			attach_mappings = function(prompt_bufnr, _)
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if selection then
						local name = selection.value.name
						-- Resolve directory from tmux
						local dir_result = vim.fn.systemlist({
							"tmux",
							"list-windows",
							"-F",
							"#{pane_current_path}",
							"-t",
							name,
						})
						local dir = nil
						if vim.v.shell_error == 0 and #dir_result > 0 then
							dir = dir_result[1]
						end
						set_main_session(name, dir)
						vim.notify("opencode: main -> [" .. name .. "]", vim.log.levels.INFO)
					end
				end)
				return true
			end,
		})
		:find()
end, { desc = "OpenCode: set main session" })

--- <leader>om -- toggle main session ----------------------------------

vim.keymap.set("n", "<leader>om", function()
	if not in_tmux() then
		vim.notify("opencode: not in tmux", vim.log.levels.WARN)
		return
	end

	local name = get_main_session()
	if not name then
		vim.notify("opencode: no main session set (<leader>os to pick)", vim.log.levels.WARN)
		return
	end

	if not session_exists(name) then
		vim.notify("opencode: main session '" .. name .. "' no longer exists", vim.log.levels.WARN)
		return
	end

	local bufname = "opencode-main-term"
	local existing_buf = nil
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):find(bufname, 1, true) then
			existing_buf = buf
			break
		end
	end

	if existing_buf and vim.api.nvim_buf_is_valid(existing_buf) then
		local wins = vim.fn.win_findbuf(existing_buf)
		if #wins > 0 then
			for _, win in ipairs(wins) do
				vim.api.nvim_win_close(win, true)
			end
		else
			vim.cmd("vsplit")
			vim.api.nvim_win_set_buf(0, existing_buf)
			vim.cmd("startinsert")
		end
	else
		vim.cmd("vsplit")
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_win_set_buf(0, buf)
		vim.fn.termopen("tmux attach-session -t " .. vim.fn.shellescape(name), {
			on_exit = function()
				if vim.api.nvim_buf_is_valid(buf) then
					vim.api.nvim_buf_delete(buf, { force = true })
				end
			end,
		})
		vim.api.nvim_buf_set_name(buf, bufname)
		vim.bo[buf].bufhidden = "hide"
		vim.cmd("startinsert")
		vim.notify("opencode: attached [" .. name .. "]", vim.log.levels.INFO)
	end
end, { desc = "OpenCode: toggle main session" })

--- <leader>am -- open code block picker for main session -------------

vim.keymap.set("n", "<leader>am", function()
	if not in_tmux() then
		vim.notify("opencode: not in tmux", vim.log.levels.WARN)
		return
	end

	local name, dir = get_main_session()
	if not dir then
		vim.notify("opencode: no main session directory (<leader>os to pick)", vim.log.levels.WARN)
		return
	end

	require("opencode-ext.viewer").toggle_for_dir(dir)
end, { desc = "OpenCode: main session picker" })

return M
