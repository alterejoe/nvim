-- /home/altjoe/.config/nvim/lua/opencode-manage/journalview.lua FINAL
-- opencode-manage.journalview — journal review panel (console adapter).
-- Top = journal entries. Below: TWO side-by-side preview windows —
-- CURRENT (left, the real file) vs AFTER RESTORE (right, snapshot/_old
-- content) — syntax highlighted, scroll-locked together.
--   j/k move · gg/G jump · [/] scroll both previews · <CR> restore this
--   entry (confirm — the pair already shows what it will become) ·
--   dd delete this entry (confirmed — removes snapshot, unrecoverable) ·
--   gr revert the whole group this entry belongs to · r refresh · Q kill.
-- Row colors: green=create · blue=replace/edit · red=delete/move ·
-- yellow=manual · magenta=restore · dim strike=not restorable
-- The engine (opencode-manage.console) owns windows/keymaps/state; this
-- file owns the journal-specific rendering and actions.
-- PERF: per-row classification (filereadable checks) runs ONCE per refresh
-- in rows(); render_list reads the cache only.

local journal = require("opencode-manage.journal")
local console = require("opencode-manage.console")

local M = {}

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

--- Rows: one per entry; the ONLY place filereadable runs per refresh.
--- @param items table[]
--- @return table[]
local function rows(items)
	local out = {}
	for i, e in ipairs(items) do
		local op = op_label(e.op)
		local target = journal.describe_target(e)
		local rest = restorable(e)
		local when = os.date("%H:%M:%S", math.floor((e.ts or 0) / 1000))
		out[i] = {
			item = e,
			text = string.format(
				"%s  [%-20s] %-30s %-9s %s  → %s",
				when,
				short_group(e.group),
				e.path,
				op,
				(e.reason or ""):sub(1, 20),
				target
			),
			hl = rest and hl_for_op(e.op) or "ManageDead",
		}
	end
	return out
end

--- CURRENT (left) and AFTER RESTORE (right) side by side.
--- @param e table
--- @return table
local function preview(e)
	local pl = journal.preview_lines(e)
	local cur_lines = #pl.current > 0 and pl.current or { "<file does not exist>" }
	local warn = pl.restorable and "" or "  ⚠ no restorable state"
	return {
		left = {
			lines = cur_lines,
			name = "CURRENT: " .. pl.path,
			ft = vim.filetype.match({ filename = pl.path }) or "",
			modifiable = false,
			winbar = string.format("CURRENT %s  [%s]", pl.path, op_label(e.op)),
		},
		right = {
			lines = pl.after,
			name = "AFTER RESTORE: " .. pl.path,
			ft = vim.filetype.match({ filename = pl.path }) or "",
			modifiable = false,
			winbar = "AFTER RESTORE — " .. pl.what .. warn,
		},
		focus = { left = 1, right = 1 },
	}
end

--- <CR>: restore this entry (skip_peek — the side-by-side pair IS the preview).
--- @param e table
--- @param h table  console handle
local function restore_current(e, h)
	if not e then
		return
	end
	journal.restore(e, true)
	h.refresh()
end

--- dd: delete this entry (confirmed — removes snapshot, unrecoverable).
--- @param e table
--- @param h table  console handle
local function delete_current(e, h)
	if not e then
		return
	end
	journal.delete(e)
	h.refresh()
end

--- gr: revert the whole group this entry belongs to.
--- @param e table
--- @param h table  console handle
local function group_revert_current(e, h)
	if not e then
		return
	end
	journal.restore_group(e.group)
	h.refresh()
end

function M.open()
	console.open({
		name = "Journal",
		layout = "pair",
		list = function()
			return journal.list()
		end,
		rows = rows,
		preview = preview,
		actions = {
			primary = restore_current,
			primary_desc = "restore",
		},
		keys = {
			{
				key = "dd",
				desc = "delete entry",
				fn = function(h)
					delete_current(h.state.items[h.state.idx], h)
				end,
			},
			{
				key = "gr",
				desc = "group revert",
				fn = function(h)
					group_revert_current(h.state.items[h.state.idx], h)
				end,
			},
		},
		legend = "j/k move · gg/G jump · [/] scroll previews · <CR> restore · dd delete entry · gr group revert · r refresh · Q kill",
		swatches = "%#ManageNew#██%*create  %#ManageEdit#██%*replace/edit  %#ManageDelete#██%*delete/move  "
			.. "%#ManageManual#██%*manual  %#ManageRestore#██%*restore  %#ManageDead#██%*not restorable",
		empty_msg = "Journal is empty",
	})
end

return M
