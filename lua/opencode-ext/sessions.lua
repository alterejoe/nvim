-- opencode-ext/sessions.lua
-- Manages OpenCode in dedicated tmux sessions.
-- Sessions are named `opencode-<parent>-<dir>` and persist across nvim restarts.
--
-- Keymaps:
--   <leader>oo  Start OpenCode session for current project
--   <leader>oo  Toggle (if already running) - attach/detach
--   <leader>or  Restart OpenCode session
--   <leader>oq  Kill OpenCode session

local M = {}
local OC_PREFIX = "opencode-"

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

return M
