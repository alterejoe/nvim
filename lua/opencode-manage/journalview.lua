-- /home/altjoe/.config/nvim/lua/opencode-manage/journalview.lua FINAL-3
-- opencode-manage.journalview — journal review panel (console adapter).
-- Top = journal entries. Below: ONE pane showing the file AS IT WILL LOOK
-- AFTER RESTORE — the change shown by highlight (removed lines red, added
-- lines green), no git-style prefixes. A restore that deletes the file
-- shows the current file in red.
--   j/k move · gg/G jump · [/] first row of prev/next group · <CR> restore
--   this entry (confirm — the pane already shows what it will become) · dd
--   delete this entry (confirmed — removes snapshot, unrecoverable) · gr
--   revert the whole group this entry belongs to · r refresh · Q kill.
-- Row colors: green=create · blue=replace/edit · red=delete/move ·
-- yellow=manual · magenta=restore · dim strike=not restorable
-- The engine (opencode-manage.console) owns windows/keymaps/state; this
-- file owns the journal-specific rendering and actions.
-- PERF: per-row classification (filereadable checks) runs ONCE per refresh
-- in rows(); render_list reads the cache only.

local journal = require("opencode-manage.journal")
local diff = require("opencode-manage.reviewview.diff")
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

local function short_sid(sid)
	if not sid then
		return "?"
	end
	return sid:sub(-8)
end

local function fmt_when(ts)
	if not ts or ts == 0 then
		return "?"
	end
	return os.date("%m-%d %H:%M", math.floor(ts / 1000))
end

local function short_project(project)
	if not project or project == "" then
		return "-"
	end
	return (project:gsub("/+$", "")):match("([^/]+)$") or project
end

--- Is this entry restorable? Mirrors preview_lines: a move needs its _old
--- file, a snapshot-backed op needs the snapshot, a created file is always
--- restorable (restore = delete it).
--- @param e table
--- @return boolean
local function restorable(e)
	if e.op == "move" and e.moved_to and e.moved_to ~= "" then
		return vim.fn.filereadable(e.moved_to) == 1
	end
	if e.snapshot_id then
		return true
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

--- Rows in DISPLAY order with group separators — the same shape the
--- proposals console renders: groups ordered by their NEWEST entry
--- (descending), entries within a group newest-first. The separator shows
--- the full group name (base + emission number, e.g. read-smoke-1). The
--- console extracts `item` from each row, so separators never enter the
--- cursor/navigation set.
--- @param items table[]
--- @return table[]
local function rows(items)
	local order = {}
	local group_newest = {}
	for i, e in ipairs(items) do
		order[i] = i
		local g = e.group or "misc"
		group_newest[g] = math.max(group_newest[g] or 0, e.ts or 0)
	end
	-- Total comparator (path tiebreaker): table.sort is unstable and equal
	-- timestamps would otherwise reorder rows between refreshes, moving the cursor.
	table.sort(order, function(a, b)
		local ea, eb = items[a], items[b]
		local ga, gb = ea.group or "misc", eb.group or "misc"
		if ga ~= gb then
			return (group_newest[ga] or 0) > (group_newest[gb] or 0)
		end
		local ta, tb = ea.ts or 0, eb.ts or 0
		if ta ~= tb then
			return ta > tb
		end
		return (ea.path or "") < (eb.path or "")
	end)
	local out = {}
	local last_group = nil
	for _, si in ipairs(order) do
		local e = items[si]
		local g = e.group or "misc"
		if g ~= last_group then
			last_group = g
			out[#out + 1] = { sep = g }
		end
		local rest = restorable(e)
		local state = rest and "restorable" or "no-restore"
		out[#out + 1] = {
			item = e,
			text = string.format(
				"%-12s %-9s [%-10s] %s  (s:%s · %s)",
				short_project(e.project),
				op_label(e.op),
				state,
				e.path,
				short_sid(e.sessionID),
				fmt_when(e.ts)
			),
			hl = rest and hl_for_op(e.op) or "ManageDead",
			state = state,
			col = rest and 0 or 2,
		}
	end
	return out
end

--- The single pane: the file AS IT WILL LOOK AFTER RESTORE. The change is
--- shown by highlight only — removed lines red, added lines green. A restore
--- that deletes the file (it was created by this change) shows the current
--- file in red.
--- @param e table
--- @return table
local function preview(e)
	local pl = journal.preview_lines(e)
	local cur = pl.current or {}
	local after = pl.after or {}
	local warn = pl.restorable and "" or "  ⚠ no restorable state"

	-- Restore that removes the file (it was created by this change).
	if e.existed == false and #after == 0 then
		local hl = {}
		for i = 1, #cur do
			hl[i] = "ManageRemove"
		end
		return {
			left = {
				lines = (#cur > 0) and cur or { "<file does not exist>" },
				name = "RESTORE: " .. pl.path,
				ft = vim.filetype.match({ filename = pl.path }) or "",
				modifiable = false,
				winbar = "RESTORE — removes " .. (e.path or pl.path) .. warn,
				hl = hl,
			},
			focus = { left = 1 },
		}
	end

	-- Otherwise the pane is the restored content, changes highlighted vs
	-- the current file (removed red, added green).
	local lines, hl = after, {}
	if #cur > 0 and #after > 0 then
		local diff_lines = diff.build_diff(cur, after)
		lines, hl = {}, {}
		for _, l in ipairs(diff_lines) do
			local mark = l:sub(1, 1)
			local text = l:sub(2)
			local ln = #lines + 1
			lines[ln] = text
			if mark == "+" then
				hl[ln] = "ManageAdd"
			elseif mark == "-" then
				hl[ln] = "ManageRemove"
			end
		end
	end
	if #lines == 0 then
		lines = { "<empty>" }
	end
	return {
		left = {
			lines = lines,
			name = "AFTER RESTORE: " .. pl.path,
			ft = vim.filetype.match({ filename = pl.path }) or "",
			modifiable = false,
			winbar = "AFTER RESTORE — " .. pl.what .. warn,
			hl = hl,
		},
		focus = { left = 1 },
	}
end

--- [ / ]: jump to the FIRST ROW of the previous / next group. Groups are
--- contiguous in display order and the console drops separators from the
--- cursor set, so a group's first row is simply where the group changes.
--- Bound on every pane, so it works from the list or from inside the preview.
--- @param delta number  -1 (previous group) or 1 (next group)
--- @param h table  console handle
local function group_jump(delta, h)
	local items = h.state.items
	if not items or #items == 0 then
		return
	end
	local function group_of(i)
		return (items[i] and items[i].group) or "misc"
	end
	local starts = { 1 }
	for i = 2, #items do
		if group_of(i) ~= group_of(i - 1) then
			starts[#starts + 1] = i
		end
	end
	local cur = 1
	for k, s in ipairs(starts) do
		if s <= h.state.idx then
			cur = k
		end
	end
	local target = math.max(1, math.min(#starts, cur + delta))
	h.state.idx = starts[target]
	h.refresh()
end

--- <CR>: restore this entry (skip_peek — the pane IS the preview).
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
		layout = "detail",
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
		legend = "j/k move · gg/G jump · [/] group · <CR> restore · dd delete entry · gr group revert · r refresh · Q kill",
		swatches = "%#ManageNew#██%*create  %#ManageEdit#██%*replace/edit  %#ManageDelete#██%*delete/move  "
			.. "%#ManageManual#██%*manual  %#ManageRestore#██%*restore  %#ManageDead#██%*not restorable",
		empty_msg = "Journal is empty",
		scroll = "hunks",
		hunk_jump = group_jump,
	})
end

return M
