-- opencode-manage.journalview — the persistent journal viewer.
-- Top = journal entries. Below: TWO side-by-side preview windows —
-- CURRENT (left, the real file) vs AFTER RESTORE (right, snapshot/_old
-- content) — syntax highlighted, scroll-locked together.
-- One column beside your buffer (mirrors reviewview).
--   j/k      move selection in the list (preview pair follows)
--   [ / ]    scroll BOTH preview windows together (diff-style)
--   <CR>     restore this entry (confirm — the pair already shows what
--            it will become)
--   dd       delete this entry (confirmed — removes snapshot, unrecoverable)
--   gr       revert the whole group this entry belongs to
--   Q        kill the viewer (buffer-local; your global Q untouched)
-- The LIST window's winbar is a permanent legend: color swatches (same
-- highlight groups as the rows) + every keybind.
-- Row colors: green=create · blue=replace/edit · red=delete/move ·
-- yellow=manual · magenta=restore · dim strike=not restorable
-- Returning to the viewer defaults to the PICKER, position preserved.
--
-- PERF: per-row classification (filereadable checks) runs ONCE per refresh
-- into state.row_info; render_list reads the cache only.

local journal = require("opencode-manage.journal")

local M = {}

local state = {
	items = {},
	idx = 1,
	row_info = {}, -- item index -> { op = string, target = string, restorable = bool }
	list_buf = nil,
	cur_buf = nil,
	after_buf = nil,
	list_win = nil,
	cur_win = nil,
	after_win = nil,
	outer_win = nil,
	origin_win = nil,
	origin_buf = nil,
	autocmd = nil,
}

local function op_label(op)
	local labels = {
		create = "create",
		replace = "replace",
		edit_range = "edit",
		delete = "delete",
		move = "move-old",
		manual = "manual-y",
		restore = "restore",
	}
	return labels[op] or (op or "?")
end

local function short_group(g)
	return (g or "-"):sub(1, 20)
end

--- Define the row highlight groups once (same names/values as reviewview,
--- so both viewers agree visually).
local function define_hls()
	local hl = vim.api.nvim_set_hl
	hl(0, "ManageNew", { fg = "#4ec9b0", bold = true }) -- green: create
	hl(0, "ManageEdit", { fg = "#569cd6" }) -- blue: replace / edit_range
	hl(0, "ManageDelete", { fg = "#f44747" }) -- red: delete / move
	hl(0, "ManageManual", { fg = "#dcdcaa" }) -- yellow: manual-y
	hl(0, "ManageRestore", { fg = "#c586c0" }) -- magenta: restore (revert)
	hl(0, "ManageDead", { fg = "#808080", strikethrough = true }) -- dim: not restorable
	hl(0, "ManageGroup", { fg = "#808080", italic = true }) -- group headers
end

--- Permanent legend in the LIST window's winbar: color swatches (rendered
--- with the same highlight groups the rows use) + every keybind.
--- Multi-line winbar requires nvim 0.10+.
local function set_legend()
	if not state.list_win or not vim.api.nvim_win_is_valid(state.list_win) then
		return
	end
	vim.wo[state.list_win].winbar = table.concat({
		"%#ManageNew#██%*create  %#ManageEdit#██%*replace/edit  %#ManageDelete#██%*delete/move  "
			.. "%#ManageManual#██%*manual  %#ManageRestore#██%*restore  %#ManageDead#██%*not restorable",
		"j/k move · gg/G jump · [/] scroll previews · <CR> restore · dd delete entry · gr group revert · Q kill",
	}, "\n")
end

--- Is this entry restorable? Mirrors preview_lines: a move needs its _old
--- file, a snapshot-backed op needs the snapshot, a created file is always
--- restorable (restore = delete it).
--- @param e table
--- @return boolean
local function restorable(e)
	if e.op == "move" and e.moved_to then
		return vim.fn.filereadable(e.moved_to) == 1
	end
	if e.snapshot then
		return vim.fn.filereadable(e.snapshot) == 1
	end
	return e.existed == false
end

--- Highlight group for an entry's op.
--- @param op string
--- @return string
local function hl_for_op(op)
	if op == "create" then
		return "ManageNew"
	elseif op == "replace" or op == "edit_range" then
		return "ManageEdit"
	elseif op == "delete" or op == "move" then
		return "ManageDelete"
	elseif op == "manual" then
		return "ManageManual"
	elseif op == "restore" then
		return "ManageRestore"
	end
	return nil
end

--- Precompute per-row display info. Called once per refresh — the ONLY
--- place filereadable runs. Rendering reads state.row_info.
local function compute_row_info()
	state.row_info = {}
	for i, e in ipairs(state.items) do
		state.row_info[i] = {
			op = op_label(e.op),
			target = journal.describe_target(e),
			restorable = restorable(e),
		}
	end
end

--- Render CURRENT (left) and AFTER RESTORE (right) side by side.
local function render_previews()
	local e = state.items[state.idx]
	if not e then
		return
	end
	local pl = journal.preview_lines(e)

	-- LEFT: the real file (if it exists) — syntax highlighting + scrolling
	-- for free. Otherwise an empty scratch with the right filetype.
	if vim.bo[state.cur_buf].modifiable == false then
		vim.bo[state.cur_buf].modifiable = true
	end
	local cur_lines
	if #pl.current > 0 then
		cur_lines = pl.current
	else
		cur_lines = { "<file does not exist>" }
	end
	vim.api.nvim_buf_set_lines(state.cur_buf, 0, -1, false, cur_lines)
	vim.bo[state.cur_buf].bufhidden = "wipe"
	vim.bo[state.cur_buf].filetype = vim.filetype.match({ filename = pl.path }) or ""
	vim.api.nvim_buf_set_name(state.cur_buf, "CURRENT: " .. pl.path)
	vim.bo[state.cur_buf].modifiable = false

	-- RIGHT: the snapshot/_old content — same filetype for highlighting.
	if vim.bo[state.after_buf].modifiable == false then
		vim.bo[state.after_buf].modifiable = true
	end
	vim.api.nvim_buf_set_lines(state.after_buf, 0, -1, false, pl.after)
	vim.bo[state.after_buf].bufhidden = "wipe"
	vim.bo[state.after_buf].filetype = vim.filetype.match({ filename = pl.path }) or ""
	vim.api.nvim_buf_set_name(state.after_buf, "AFTER RESTORE: " .. pl.path)
	vim.bo[state.after_buf].modifiable = false

	-- Winbars: what each side is, and what restoring does
	if state.cur_win and vim.api.nvim_win_is_valid(state.cur_win) then
		vim.wo[state.cur_win].winbar = string.format("CURRENT %s  [%s]", pl.path, op_label(e.op))
	end
	if state.after_win and vim.api.nvim_win_is_valid(state.after_win) then
		local warn = pl.restorable and "" or "  ⚠ no restorable state"
		vim.wo[state.after_win].winbar = "AFTER RESTORE — " .. pl.what .. warn
	end

	-- Reset both views to the top and keep them scroll-locked
	for _, w in ipairs({ state.cur_win, state.after_win }) do
		if w and vim.api.nvim_win_is_valid(w) then
			vim.api.nvim_win_set_cursor(w, { 1, 0 })
		end
	end
end

--- Scroll BOTH preview windows together (diff-style).
--- @param delta number  lines to scroll (negative = up)
local function scroll_previews(delta)
	local amount = delta * 8
	for _, w in ipairs({ state.cur_win, state.after_win }) do
		if w and vim.api.nvim_win_is_valid(w) then
			local topline = vim.api.nvim_win_call(w, function()
				return vim.fn.line("w0")
			end)
			vim.api.nvim_win_set_cursor(w, { math.max(1, topline + amount), 0 })
		end
	end
end

local function render_list()
	if not state.list_buf or not vim.api.nvim_buf_is_valid(state.list_buf) then
		return
	end
	local lines = {}
	local row_of = {} -- display line -> highlight group name
	for i, e in ipairs(state.items) do
		local marker = (i == state.idx) and ">" or " "
		local when = os.date("%H:%M:%S", math.floor((e.ts or 0) / 1000))
		local info = state.row_info[i] or {}
		lines[i] = string.format(
			"%s %s  [%-20s] %-30s %-9s %s  → %s",
			marker,
			when,
			short_group(e.group),
			e.path,
			info.op or op_label(e.op),
			(e.reason or ""):sub(1, 20),
			info.target or journal.describe_target(e)
		)
		if info.restorable == false then
			row_of[i] = "ManageDead"
		else
			row_of[i] = hl_for_op(e.op)
		end
	end
	if vim.bo[state.list_buf].modifiable == false then
		vim.bo[state.list_buf].modifiable = true
	end
	vim.api.nvim_buf_set_lines(state.list_buf, 0, -1, false, lines)
	vim.bo[state.list_buf].modifiable = false

	-- Color each row by its op (or dim+strike when not restorable)
	local ns = vim.api.nvim_create_namespace("manage-journal-rows")
	vim.api.nvim_buf_clear_namespace(state.list_buf, ns, 0, -1)
	for ln, hl in pairs(row_of) do
		if hl then
			vim.api.nvim_buf_add_highlight(state.list_buf, ns, hl, ln - 1, 2, -1)
		end
	end

	if state.list_win and vim.api.nvim_win_is_valid(state.list_win) then
		pcall(vim.api.nvim_win_set_cursor, state.list_win, { state.idx, 0 })
	end
end

local function move(delta)
	local n = #state.items
	if n == 0 then
		return
	end
	state.idx = math.max(1, math.min(n, state.idx + delta))
	render_list()
	render_previews()
end

local function restore_current()
	local e = state.items[state.idx]
	if not e then
		return
	end
	journal.restore(e, true) -- skip_peek: the side-by-side pair IS the preview
	refresh_items()
end

local function delete_current()
	local e = state.items[state.idx]
	if not e then
		return
	end
	journal.delete(e)
	refresh_items()
end

local function group_revert_current()
	local e = state.items[state.idx]
	if not e then
		return
	end
	journal.restore_group(e.group)
	refresh_items()
end

local function refresh_items()
	local items = journal.list()
	state.items = items
	compute_row_info()
	if #items == 0 then
		vim.notify("Journal is empty — viewer closing", vim.log.levels.INFO)
		kill_viewer()
		return
	end
	state.idx = math.max(1, math.min(state.idx, #items))
	render_list()
	render_previews()
end

local function kill_viewer()
	for _, b in ipairs({ state.list_buf, state.cur_buf, state.after_buf, state.origin_buf }) do
		if b and vim.api.nvim_buf_is_valid(b) then
			pcall(vim.keymap.del, "n", "Q", { buffer = b })
		end
	end
	if state.autocmd then
		pcall(vim.api.nvim_del_autocmd, state.autocmd)
		state.autocmd = nil
	end
	local seen = {}
	for _, w in ipairs({ state.list_win, state.cur_win, state.after_win, state.outer_win }) do
		if w and not seen[w] then
			seen[w] = true
			if vim.api.nvim_win_is_valid(w) then
				vim.api.nvim_win_close(w, true)
			end
		end
	end
	state.items = {}
	state.row_info = {}
	state.list_buf = nil
	state.cur_buf = nil
	state.after_buf = nil
	state.list_win = nil
	state.cur_win = nil
	state.after_win = nil
	state.outer_win = nil
	state.origin_win = nil
	state.origin_buf = nil
	vim.notify("🗑️ Journal viewer closed", vim.log.levels.INFO)
end

local function set_q_kill(buf)
	vim.keymap.set("n", "Q", kill_viewer, { buffer = buf, nowait = true, noremap = true, silent = true })
end

local function make_window(buf, split, ref_win)
	local opts = {
		relative = "",
		split = split,
	}
	if ref_win then
		opts.win = ref_win
	end
	return vim.api.nvim_open_win(buf, false, opts)
end

function M.open()
	local items = journal.list()
	if #items == 0 then
		vim.notify("Journal is empty", vim.log.levels.INFO)
		return
	end
	-- Re-entry guard: replace an existing viewer instead of stacking
	if state.outer_win and vim.api.nvim_win_is_valid(state.outer_win) then
		kill_viewer()
	end
	define_hls()
	state.items = items
	compute_row_info()
	state.idx = 1
	state.origin_win = vim.api.nvim_get_current_win()
	state.origin_buf = vim.api.nvim_get_current_buf()

	-- List buffer: new column to the RIGHT of the origin buffer
	state.list_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[state.list_buf].bufhidden = "wipe"
	vim.bo[state.list_buf].filetype = "managelist"
	state.outer_win = make_window(state.list_buf, "right")
	state.list_win = state.outer_win
	set_legend()

	-- CURRENT preview: below the list (left side of the lower pair)
	state.cur_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[state.cur_buf].bufhidden = "wipe"
	vim.bo[state.cur_buf].modifiable = false
	state.cur_win = make_window(state.cur_buf, "below", state.list_win)

	-- AFTER RESTORE preview: to the RIGHT of CURRENT (side by side)
	state.after_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[state.after_buf].bufhidden = "wipe"
	vim.bo[state.after_buf].modifiable = false
	state.after_win = make_window(state.after_buf, "right", state.cur_win)

	vim.api.nvim_set_current_win(state.list_win)

	set_q_kill(state.list_buf)
	set_q_kill(state.cur_buf)
	set_q_kill(state.after_buf)
	set_q_kill(state.origin_buf)

	state.autocmd = vim.api.nvim_create_autocmd("WinEnter", {
		callback = function()
			local cur = vim.api.nvim_get_current_win()
			if
				state.list_win
				and vim.api.nvim_win_is_valid(state.list_win)
				and (cur == state.cur_win or cur == state.after_win or cur == state.list_win)
			then
				vim.api.nvim_set_current_win(state.list_win)
			end
		end,
	})

	local opts = { buffer = state.list_buf, nowait = true, noremap = true, silent = true }
	vim.keymap.set("n", "j", function()
		move(1)
	end, opts)
	vim.keymap.set("n", "k", function()
		move(-1)
	end, opts)
	vim.keymap.set("n", "<C-n>", function()
		move(1)
	end, opts)
	vim.keymap.set("n", "<C-p>", function()
		move(-1)
	end, opts)
	vim.keymap.set("n", "gg", function()
		state.idx = 1
		render_list()
		render_previews()
	end, opts)
	vim.keymap.set("n", "G", function()
		state.idx = #state.items
		render_list()
		render_previews()
	end, opts)
	vim.keymap.set("n", "]", function()
		scroll_previews(1)
	end, opts)
	vim.keymap.set("n", "[", function()
		scroll_previews(-1)
	end, opts)
	vim.keymap.set("n", "<CR>", restore_current, opts)
	vim.keymap.set("n", "dd", delete_current, opts)
	vim.keymap.set("n", "gr", group_revert_current, opts)

	render_list()
	render_previews()
end

return M
