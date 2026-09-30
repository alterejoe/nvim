-- /home/jmeyer/.config/nvim/lua/opencode-manage/daemon.lua FINAL
-- Manage daemon lifecycle. The daemon (Go, ~/projects/opencode-manage) is the
-- read/write enforcement boundary; the Makefile `restart` target rebuilds it
-- and kills the stale process, and the opencode plugin's ensureDaemon() then
-- respawns the fresh binary on the next tool call. This module just shells
-- out to `make restart` and reports via vim.notify.
local M = {}

local function default_dir()
	return (vim.env.HOME or "") .. "/projects/opencode-manage"
end

--- Rebuild + restart the manage daemon. Blocks until `make restart` returns.
--- Returns true on success. Feedback is vim.notify (INFO on success, ERROR on failure).
function M.restart()
	local dir = vim.env.MANAGE_DIR or default_dir()
	if vim.fn.isdirectory(dir) ~= 1 then
		vim.notify("manage daemon: " .. dir .. " not found (set MANAGE_DIR?)", vim.log.levels.ERROR)
		return false
	end
	vim.notify("manage daemon: rebuilding + restarting…", vim.log.levels.INFO)
	local out = vim.fn.system({ "make", "-C", dir, "restart" })
	if vim.v.shell_error == 0 then
		vim.notify("manage daemon: rebuilt ✓ — next opencode read spawns the fresh binary", vim.log.levels.INFO)
		return true
	end
	vim.notify("manage daemon: restart failed:\n" .. vim.trim(out), vim.log.levels.ERROR)
	return false
end

return M
