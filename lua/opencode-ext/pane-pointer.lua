-- /home/jmeyer/.config/nvim/lua/opencode-ext/pane-pointer.lua FINAL
-- Publish the session this nvim pane is attached to, for the manage console.
--
-- The manage plugin writes the same pointer on the first tool call, but that
-- fires too late: after resuming a session the pointer still named the session
-- from before the resume, so the console showed the wrong queue. This is
-- written by the action that actually knows which session was chosen.
--
-- Path and slug match internal/proposals/session.go and
-- plugins/lib/session-pointer.ts: <tmp>/opencode-manage/panes/<tty>.json where
-- /dev/pts/5 -> pts-5.
local M = {}

--- @param session_id string
--- @param cwd string|nil defaults to the current working directory
function M.write(session_id, cwd)
	local pane = vim.env.TMUX_PANE
	if not pane or pane == "" or not session_id or session_id == "" then
		return
	end

	local ok, out = pcall(vim.fn.system, {
		"tmux", "display-message", "-p", "-t", pane, "#{pane_tty}",
	})
	if not ok or vim.v.shell_error ~= 0 then
		return
	end

	local tty = vim.trim(out or "")
	if tty == "" then
		return
	end

	local dir = (vim.env.TMPDIR or "/tmp") .. "/opencode-manage/panes"
	vim.fn.mkdir(dir, "p")

	local key = tty:gsub("^/dev/", ""):gsub("[/%.]", "-")
	local f = io.open(dir .. "/" .. key .. ".json", "w")
	if not f then
		return
	end

	f:write(vim.fn.json_encode({
		session_id = session_id,
		project = cwd or vim.fn.getcwd(),
		pane = pane,
		tty = tty,
		key = key,
		updated = os.date("!%Y-%m-%dT%H:%M:%SZ"),
	}))
	f:close()
end

return M
