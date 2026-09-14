-- opencode-manage.sessionview — OpenCode session health and reset panel.
-- Persistent two-pane viewer: session rows (right/top) + selected session
-- detail (below). `STALLED` means a live tmux OpenCode session has a latest
-- assistant message with no completion/error and no update for the threshold.
--   j/k move · <CR> open conversation · R reset selected session · r refresh · Q close

local db = require("opencode-ext.db")
local runtime = require("opencode-ext.sessions")

local M = {}
local STALL_AFTER_SECONDS = 45

local HEALTH_HL = {
	STALLED = "ManageDelete",
	ERROR = "ManageRejected",
	RUNNING = "ManageEdit",
	IDLE = "ManageApplied",
	STOPPED = "ManageGroup",
	UNKNOWN = "ManageMismatch",
}

local state = {
	items = {},
	idx = 1,
	list_buf = nil,
	detail_buf = nil,
	list_win = nil,
	detail_win = nil,
	outer_win = nil,
	origin_win = nil,
	autocmd = nil,
}

local function define_hls()
	local hl = vim.api.nvim_set_hl
	hl(0, "ManageDelete", { fg = "#f44747", bold = true })
	hl(0, "ManageRejected", { fg = "#808080", strikethrough = true })
	hl(0, "ManageEdit", { fg = "#569cd6" })
	hl(0, "ManageApplied", { fg = "#6a9955" })
	hl(0, "ManageGroup", { fg = "#808080", italic = true })
	hl(0, "ManageMismatch", { fg = "#dcdcaa", bold = true })
end

local function seconds(value)
	local n = tonumber(value) or 0
	if n > 100000000000 then
		return n / 1000
	end
	return n
end

local function age_label(value)
	local age = math.max(0, os.time() - seconds(value))
	if age < 60 then
		return "now"
	elseif age < 3600 then
		return math.floor(age / 60) .. "m"
	elseif age < 86400 then
		return math.floor(age / 3600) .. "h"
	end
	return math.floor(age / 86400) .. "d"
end

local function health(s)
	if not s or not s.project or s.project == "" then
		return "UNKNOWN"
	end
	if not runtime.is_running_for_directory(s.project) then
		return "STOPPED"
	end
	if s.last_error and s.last_error ~= vim.NIL and s.last_error ~= "" then
		return "ERROR"
	end
	if s.last_role == "assistant" and (s.last_completed == nil or s.last_completed == vim.NIL) then
		local last_activity = math.max(seconds(s.time_updated), seconds(s.last_message_created))
		if os.time() - last_activity >= STALL_AFTER_SECONDS then
			return "STALLED"
		end
		return "RUNNING"
	end
	return "IDLE"
end

local function load_items()
	local items, err = db.fetch_sessions()
	if not items then
		state.items = {}
		vim.notify("Manage sessions: " .. tostring(err or "could not read OpenCode DB"), vim.log.levels.WARN)
		return
	end
	state.items = items
	state.idx = math.max(1, math.min(state.idx, #items))
end

local function render_list()
	if not state.list_buf or not vim.api.nvim_buf_is_valid(state.list_buf) then
		return
	end
	local lines = {}
	local row_hl = {}
	for i, s in ipairs(state.items) do
		local status = health(s)
		local marker = i == state.idx and ">" or " "
		local title = (s.title or "untitled"):gsub("\n", " "):sub(1, 42)
		local project = (s.project or "?"):gsub("^" .. vim.pesc(vim.env.HOME or ""), "~")
		lines[#lines + 1] = string.format(
			"%s %-8s %-9s %-42s %s  %2d msgs  %s",
			marker,
			status,
			age_label(s.time_updated),
			title,
			project,
			s.msg_count or 0,
			s.id or "?"
		)
		row_hl[#lines] = status
	end
	if #lines == 0 then
		lines[1] = "— no OpenCode sessions —"
	end
	vim.bo[state.list_buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.list_buf, 0, -1, false, lines)
	vim.bo[state.list_buf].modifiable = false

	local ns = vim.api.nvim_create_namespace("manage-session-health")
	vim.api.nvim_buf_clear_namespace(state.list_buf, ns, 0, -1)
	for line, status in pairs(row_hl) do
		local group = HEALTH_HL[status]
		if group then
			vim.api.nvim_buf_add_highlight(state.list_buf, ns, group, line - 1, 0, -1)
		end
	end
	if state.list_win and vim.api.nvim_win_is_valid(state.list_win) then
		local line = math.max(1, math.min(state.idx, vim.api.nvim_buf_line_count(state.list_buf)))
		pcall(vim.api.nvim_win_set_cursor, state.list_win, { line, 0 })
	end
end

local function render_detail()
	if not state.detail_buf or not vim.api.nvim_buf_is_valid(state.detail_buf) then
		return
	end
	local s = state.items[state.idx]
	local lines
	if not s then
		lines = { "— nothing selected —" }
	else
		local status = health(s)
		lines = {
			"health:   " .. status,
			"title:    " .. ((s.title or "untitled"):gsub("\n", " ")),
			"project:  " .. (s.project or "?"),
			"session:  " .. (s.id or "?"),
			"messages: " .. tostring(s.msg_count or 0),
			"updated:  " .. age_label(s.time_updated) .. " ago",
			"last role: " .. (s.last_role or "?"),
			"error:    " .. ((s.last_error and s.last_error ~= vim.NIL and s.last_error) or "—"),
			"",
			"R resets the tmux OpenCode session and preserves its database history.",
		}
	end
	vim.bo[state.detail_buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.detail_buf, 0, -1, false, lines)
	vim.bo[state.detail_buf].modifiable = false
	vim.api.nvim_buf_set_name(state.detail_buf, "MANAGE SESSION DETAIL")
end

local function refresh()
	load_items()
	render_list()
	render_detail()
	if state.list_win and vim.api.nvim_win_is_valid(state.list_win) then
		vim.wo[state.list_win].winbar = string.format(
			"MANAGE SESSIONS · %d rows · threshold=%ds · j/k <CR> open R reset r refresh Q close",
			#state.items,
			STALL_AFTER_SECONDS
		)
	end
end

local function move(delta)
	if #state.items == 0 then
		return
	end
	state.idx = math.max(1, math.min(#state.items, state.idx + delta))
	render_list()
	render_detail()
end

local function kill_viewer()
	if state.autocmd then
		pcall(vim.api.nvim_del_autocmd, state.autocmd)
		state.autocmd = nil
	end
	local seen = {}
	for _, win in ipairs({ state.list_win, state.detail_win, state.outer_win }) do
		if win and not seen[win] then
			seen[win] = true
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
		end
	end
	state.items = {}
	state.list_buf = nil
	state.detail_buf = nil
	state.list_win = nil
	state.detail_win = nil
	state.outer_win = nil
	state.origin_win = nil
end

local function reset_current()
	local s = state.items[state.idx]
	if not s or not s.project or s.project == "" then
		vim.notify("Manage sessions: selected row has no project directory", vim.log.levels.WARN)
		return
	end
	local status = health(s)
	local answer = vim.fn.confirm(
		string.format("Reset %s session?\n  %s\n\nConversation data is preserved.", status, s.project),
		"&Reset\n&Cancel",
		status == "STALLED" and 1 or 2
	)
	if answer ~= 1 then
		return
	end
	local ok, err = runtime.restart_for_directory(s.project)
	if not ok then
		vim.notify("Manage sessions: reset failed: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	vim.notify("Manage sessions: reset " .. (s.project or "?"), vim.log.levels.INFO)
	refresh()
end

local function open_current()
	local s = state.items[state.idx]
	if not s or not s.id then
		return
	end
	local ok = require("opencode-ext.viewer").open_by_id(s.id, s.project)
	if ok then
		kill_viewer()
	end
end

local function make_window(buf, split, ref_win)
	local opts = { relative = "", split = split }
	if ref_win then
		opts.win = ref_win
	end
	return vim.api.nvim_open_win(buf, false, opts)
end

local function map_keys(buf)
	local opts = { buffer = buf, nowait = true, noremap = true, silent = true }
	vim.keymap.set("n", "j", function()
		move(1)
	end, opts)
	vim.keymap.set("n", "k", function()
		move(-1)
	end, opts)
	vim.keymap.set("n", "<CR>", open_current, opts)
	vim.keymap.set("n", "R", reset_current, opts)
	vim.keymap.set("n", "r", refresh, opts)
	vim.keymap.set("n", "Q", kill_viewer, opts)
end

function M.open()
	if state.outer_win and vim.api.nvim_win_is_valid(state.outer_win) then
		kill_viewer()
	end
	define_hls()
	load_items()
	if #state.items == 0 then
		vim.notify("Manage sessions: no OpenCode sessions found", vim.log.levels.INFO)
		return
	end
	state.origin_win = vim.api.nvim_get_current_win()
	state.idx = 1

	state.list_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[state.list_buf].bufhidden = "wipe"
	vim.bo[state.list_buf].filetype = "managesessions"
	state.outer_win = make_window(state.list_buf, "right")
	state.list_win = state.outer_win

	state.detail_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[state.detail_buf].bufhidden = "wipe"
	vim.bo[state.detail_buf].modifiable = false
	state.detail_win = make_window(state.detail_buf, "below", state.list_win)

	vim.api.nvim_set_current_win(state.list_win)
	map_keys(state.list_buf)
	map_keys(state.detail_buf)
	state.autocmd = vim.api.nvim_create_autocmd("WinEnter", {
		callback = function()
			local current = vim.api.nvim_get_current_win()
			if state.list_win and vim.api.nvim_win_is_valid(state.list_win)
				and (current == state.list_win or current == state.detail_win) then
				vim.schedule(function()
					if state.list_win and vim.api.nvim_win_is_valid(state.list_win) then
						vim.api.nvim_set_current_win(state.list_win)
					end
				end)
			end
		end,
	})
	refresh()
end

return M
