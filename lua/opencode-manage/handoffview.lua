-- /home/altjoe/.config/nvim/lua/opencode-manage/handoffview.lua FINAL
-- opencode-manage.handoffview — the handoff catalogue viewer.
-- Single-pane viewer over the latest handoff catalogue (.ai-proposals/handoff.md)
-- plus the pending proposal list from the journal:
--   r refresh · o open handoff file · Q kill
-- The handoff is CONTEXT ONLY: previous goals, accomplishments, state,
-- pending, and deferred items — so the user can define the new session's
-- goal. It never names the next task.

local proposals = require("opencode-manage.proposals")

local M = {}

local state = {
	buf = nil,
	win = nil,
	origin_win = nil,
	autocmd = nil,
}

local function handoff_path()
	return vim.fn.getcwd() .. "/.ai-proposals/handoff.md"
end

local function short(path)
	if not path or path == "" then
		return ""
	end
	return (path:gsub("^" .. vim.pesc(vim.env.HOME or ""), "~"))
end

local function render()
	if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
		return
	end
	local lines = {}
	local path = handoff_path()
	if vim.fn.filereadable(path) == 1 then
		lines[#lines + 1] = "HANDOFF CATALOGUE  (" .. short(path) .. ")"
		lines[#lines + 1] = string.rep("─", 60)
		for _, l in ipairs(vim.fn.readfile(path)) do
			lines[#lines + 1] = l
		end
	else
		lines[#lines + 1] = "HANDOFF CATALOGUE"
		lines[#lines + 1] = string.rep("─", 60)
		lines[#lines + 1] = "— no handoff catalogue on disk —"
		lines[#lines + 1] = "  (the handoff skill writes .ai-proposals/handoff.md at session close)"
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "PENDING PROPOSALS"
	lines[#lines + 1] = string.rep("─", 60)
	local pending = proposals.list_pending()
	if #pending == 0 then
		lines[#lines + 1] = "— no pending proposals —"
	else
		table.sort(pending, function(a, b)
			local ga, gb = a.group or "misc", b.group or "misc"
			if ga ~= gb then
				return ga < gb
			end
			return (a.ts or 0) < (b.ts or 0)
		end)
		for _, p in ipairs(pending) do
			lines[#lines + 1] = string.format(
				"[%s] %-10s %s",
				p.group or "misc",
				p.operation or "?",
				p.path
			)
		end
	end
	if vim.bo[state.buf].modifiable == false then
		vim.bo[state.buf].modifiable = true
	end
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
	vim.bo[state.buf].modifiable = false
	vim.api.nvim_buf_set_name(state.buf, "HANDOFF")
end

local function refresh()
	render()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		vim.wo[state.win].winbar = string.format(
			"HANDOFF · catalogue + %d pending · r refresh o open Q close",
			#proposals.list_pending()
		)
	end
end

local function open_in_origin()
	local path = handoff_path()
	if vim.fn.filereadable(path) ~= 1 then
		vim.notify("❌ handoff: no catalogue on disk at " .. path, vim.log.levels.WARN)
		return
	end
	local origin = state.origin_win
	if origin and vim.api.nvim_win_is_valid(origin) then
		local cur = vim.api.nvim_get_current_win()
		vim.api.nvim_set_current_win(origin)
		vim.cmd("edit " .. vim.fn.fnameescape(path))
		vim.api.nvim_set_current_win(cur)
		vim.notify("📍 Opened " .. short(path), vim.log.levels.INFO)
	end
end

local function kill_viewer()
	if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
		pcall(vim.keymap.del, "n", "Q", { buffer = state.buf })
	end
	if state.autocmd then
		pcall(vim.api.nvim_del_autocmd, state.autocmd)
		state.autocmd = nil
	end
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		vim.api.nvim_win_close(state.win, true)
	end
	state.buf = nil
	state.win = nil
	state.origin_win = nil
	vim.notify("🗑️ Handoff viewer closed", vim.log.levels.INFO)
end

function M.open()
	state.origin_win = vim.api.nvim_get_current_win()
	state.buf = vim.api.nvim_create_buf(false, true)
	vim.bo[state.buf].bufhidden = "wipe"
	state.win = vim.api.nvim_open_win(state.buf, false, { relative = "", split = "right" })
	local opts = { buffer = state.buf, nowait = true, noremap = true, silent = true }
	vim.keymap.set("n", "r", refresh, opts)
	vim.keymap.set("n", "o", open_in_origin, opts)
	vim.keymap.set("n", "Q", kill_viewer, opts)
	refresh()
end

return M
