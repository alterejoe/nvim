-- /home/jmeyer/.config/nvim/lua/opencode-manage/reviewview.lua FINAL-5
-- opencode-manage.reviewview — proposals review panel (console adapter).
-- Group selector: one row per group; v opens the group detail tab.
--   j/k move · gg/G jump · [/] changes · f scope filter · r refresh ·
--   o/CR open in origin · da/ga apply the whole group · dr/gr reject the
--   group · rr rerun · y yank · c clean · Q kill.
-- Row colors: green=new · blue=edit · magenta=rerun · red=delete ·
-- dim=applied · strike=rejected · strike-italic=superseded · yellow=mismatch.
-- A [note]/[emit] tag distinguishes note proposals from file emissions.

local proposals = require("opencode-manage.proposals")
local diff = require("opencode-manage.reviewview.diff")
local console = require("opencode-manage.console")
local bookmarks = require("opencode-manage.bookmarks")

local M = {}

local FILTER_LABELS = {
	all = "🌐 ALL",
	session = "🗂 SESSION (in cwd)",
	files = "📄 FILES (in cwd)",
	neither = "🚫 NEITHER (foreign session+files)",
}

local FILTER_CYCLE = { "all", "session", "files", "neither" }

local adapter = { filter = "all", show_all_applied = false, show_rejected = false }

local acted = {}

local current_session = proposals.current_session

local function num(v, fallback)
	local n = tonumber(v)
	if n == nil then
		return fallback
	end
	return n
end

local function resolve_path(p)
	if p.path and p.path:sub(1, 1) == "/" then
		return p.path
	end
	return ""
end

local function content_matches(p, path)
	if not p.content then
		return false
	end
	if vim.fn.filereadable(path) ~= 1 then
		return false
	end
	local disk = table.concat(vim.fn.readfile(path), "\n"):gsub("\n+$", "")
	local proposed = p.content:gsub("\n+$", "")
	return disk == proposed
end

local function file_modified_since(p, path)
	if not p.ts or p.ts == 0 then
		return false
	end
	local stat = vim.loop.fs_stat(path)
	if not stat then
		return false
	end
	return stat.mtime.sec > math.floor(p.ts / 1000)
end

local function is_note(p)
	local path = p.path or ""
	return path:find("/docs/slipbox/", 1, true) ~= nil
		or path:find("/docs/references/", 1, true) ~= nil
		or path:find("/docs/fleeting/", 1, true) ~= nil
end

local function row_state(p)
	if p.operation == "mark-proposals" then
		return "mark"
	end
	local st = p.status or "pending"
	if st == "rejected" then
		return "rejected"
	end
	if st == "accepted" then
		return "applied"
	end
	if st == "superseded" then
		return "superseded"
	end
	if p.operation == "reject-proposals" then
		return "reject"
	end
	local path = resolve_path(p)
	if path == "" then
		return "mismatch"
	end
	local exists = vim.fn.filereadable(path) == 1
	if p.operation == "delete" then
		if exists then
			return "delete"
		end
		return "applied"
	end
	if p.operation == "create" or p.operation == "replace" then
		if exists and content_matches(p, path) then
			return "applied"
		end
		if exists then
			if p.operation == "create" then
				return "mismatch"
			end
			if file_modified_since(p, path) then
				return "rerun"
			end
			return "edit"
		end
		if p.operation == "create" then
			return "new"
		end
		return "mismatch"
	end
	if exists then
		if file_modified_since(p, path) then
			return "rerun"
		end
		return "edit"
	end
	return "mismatch"
end

local function newest_revisions(items)
	local newest = {}
	for _, p in ipairs(items) do
		local st = p.status or "pending"
		if st == "pending" or st == "accepted" then
			local key = (p.group or "misc") .. "\0" .. (p.path or "")
			local cur = newest[key]
			if not cur or (p.ts or 0) > (cur.ts or 0) then
				newest[key] = p
			end
		end
	end
	return newest
end

local function is_stale(p, newest)
	if (p.status or "pending") ~= "pending" then
		return false
	end
	local top = newest[(p.group or "misc") .. "\0" .. (p.path or "")]
	return top ~= nil and (top.ts or 0) > (p.ts or 0)
end

local function state_tag(st)
	if st == "mark" then
		return "mark"
	end
	local tags = {
		reject = "reject",
		applied = "applied",
		edit = "edit",
		rerun = "rerun",
		new = "new",
		delete = "delete",
		rejected = "rejected",
		superseded = "superseded",
		mismatch = "mismatch",
	}
	return tags[st] or st
end

local function hl_for(st)
	if st == "mark" then
		return "ManageRerun"
	end
	return "Manage" .. st:sub(1, 1):upper() .. st:sub(2)
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

local function after_content(p, path)
	if p.operation == "delete" then
		return nil
	end
	local disk = {}
	if vim.fn.filereadable(path) == 1 then
		disk = vim.fn.readfile(path)
	end
	local lines
	if p.operation == "edit_range" and p.start_line then
		local block = vim.split(p.content or "", "\n", { plain = true })
		if block[#block] == "" then
			table.remove(block)
		end
		local s = math.max(1, math.floor(num(p.start_line, 1)))
		local e = math.max(s, math.floor(num(p.end_line, s)))
		lines = {}
		for i = 1, math.min(s - 1, #disk) do
			lines[#lines + 1] = disk[i]
		end
		for _, l in ipairs(block) do
			lines[#lines + 1] = l
		end
		for i = e + 1, #disk do
			lines[#lines + 1] = disk[i]
		end
	else
		lines = vim.split(p.content or "", "\n", { plain = true })
		if lines[#lines] == "" then
			table.remove(lines)
		end
	end
	return table.concat(lines, "\n")
end

local function display_order(items)
	local order = {}
	local group_newest = {}
	for i, p in ipairs(items) do
		order[i] = i
		local g = p.group or "misc"
		group_newest[g] = math.max(group_newest[g] or 0, p.ts or 0)
	end
	table.sort(order, function(a, b)
		local ia, ib = items[a], items[b]
		local ga, gb = ia.group or "misc", ib.group or "misc"
		if ga ~= gb then
			return (group_newest[ga] or 0) > (group_newest[gb] or 0)
		end
		local ta, tb = ia.ts or 0, ib.ts or 0
		if ta ~= tb then
			return ta > tb
		end
		return (ia.path or "") < (ib.path or "")
	end)
	return order
end

local function rows(items)
	local newest = newest_revisions(proposals.list_visible("all"))
	local order = display_order(items)
	local groups = {}
	local group_order = {}
	for _, si in ipairs(order) do
		local p = items[si]
		if (p.status or "pending") ~= "superseded" and not is_stale(p, newest) then
			local g = p.group or "misc"
			if not groups[g] then
				groups[g] = {}
				group_order[#group_order + 1] = g
			end
			groups[g][#groups[g] + 1] = p
		end
	end
	local out = {}
	for _, g in ipairs(group_order) do
		local list = groups[g]
		local st, first = "applied", list[1]
		for _, p in ipairs(list) do
			local s = row_state(p)
			if is_stale(p, newest) then
				s = "superseded"
			end
			if s ~= "applied" and s ~= "rejected" and s ~= "superseded" then
				st = s
				first = p
				break
			end
		end
		local col = 2
		if st ~= "applied" and st ~= "rejected" and st ~= "superseded" then
			col = 0
		end
		local note = false
		for _, p in ipairs(list) do
			if is_note(p) then
				note = true
				break
			end
		end
		local tag = note and "[note] " or "[emit] "
		out[#out + 1] = {
			item = first,
			group = g,
			files = #list,
			text = string.format(
				"%s%-18s %2d files  [%-8s]  %s",
				tag,
				g,
				#list,
				state_tag(st),
				first._rel or first.path or "?"
			),
			hl = hl_for(st),
			tag_hl = note and "ManageNoteTag" or "ManageEmitTag",
			tag_col = 2,
			tag_end = 2 + #tag,
			state = st,
			col = col,
		}
	end
	return out
end

local function preview(p, h)
	if p.group and h and h.state then
		local lines = { "GROUP " .. p.group, "" }
		local hl = {}
		local group_files = {}
		local newest = newest_revisions(proposals.list_visible("all"))
		for _, it in ipairs(proposals.list_visible(adapter.filter)) do
			if
				(it.group or "misc") == p.group
				and (it.status or "pending") ~= "superseded"
				and not is_stale(it, newest)
			then
				group_files[#group_files + 1] = it
			end
		end
		table.sort(group_files, function(a, b)
			local an = is_note(a) and 0 or 1
			local bn = is_note(b) and 0 or 1
			if an ~= bn then
				return an < bn
			end
			return (a.path or "") < (b.path or "")
		end)
		for _, it in ipairs(group_files) do
			if (it.group or "misc") == p.group then
				lines[#lines + 1] =
					string.format("%-9s %-10s %s", it.operation, state_tag(row_state(it)), it._rel or it.path)
				hl[#lines] = hl_for(row_state(it))
			end
		end
		if h.state then
			h.state.change_lines = {}
		end
		return {
			left = {
				lines = lines,
				hl = hl,
				name = "GROUP: " .. p.group,
				ft = "markdown",
				modifiable = false,
				winbar = "GROUP " .. p.group .. "  ·  v opens the files",
			},
			focus = { left = 1 },
		}
	end

	if p.operation == "mark-proposals" then
		local lines = { "MARK PROPOSALS", "", "reason: " .. (p.reason or "") }
		local ok, sel = pcall(vim.json.decode, p.content or "")
		if ok and type(sel) == "table" then
			lines[#lines + 1] = "mark: " .. tostring(sel.mark)
			if sel.group and sel.group ~= "" then
				lines[#lines + 1] = "group: " .. sel.group
			end
			for _, tp in ipairs(sel.paths or {}) do
				lines[#lines + 1] = "  - " .. tostring(tp)
			end
		end
		if h and h.state then
			h.state.change_lines = {}
		end
		return {
			left = {
				lines = lines,
				name = "MARK: " .. tostring(p.path),
				ft = "markdown",
				modifiable = false,
				winbar = "MARK PROPOSALS  ·  da applies · dr dismisses",
			},
			focus = { left = 1 },
		}
	end

	local function set_changes(list)
		if h and h.state then
			h.state.change_lines = list or {}
		end
	end

	if p.operation == "reject-proposals" then
		local lines = { "REJECT PROPOSALS", "", "reason: " .. (p.reason or "") }
		local ok, sel = pcall(vim.json.decode, p.content or "")
		if ok and type(sel) == "table" then
			if sel.group and sel.group ~= "" then
				lines[#lines + 1] = "group: " .. sel.group
			end
			for _, tp in ipairs(sel.paths or {}) do
				lines[#lines + 1] = "  - " .. tostring(tp)
			end
		end
		set_changes({})
		return {
			left = {
				lines = lines,
				name = "REJECT: " .. tostring(p.path),
				ft = "markdown",
				modifiable = false,
				winbar = "REJECT PROPOSALS  ·  da applies · dr dismisses",
			},
			focus = { left = 1 },
		}
	end

	local path = resolve_path(p)
	local is_delete = p.operation == "delete"
	local is_range = p.operation == "edit_range" and p.start_line ~= nil

	if is_delete then
		local disk = {}
		if path ~= "" and vim.fn.filereadable(path) == 1 then
			disk = vim.fn.readfile(path)
		end
		local hl = {}
		for i = 1, #disk do
			hl[i] = "ManageRemove"
		end
		set_changes({})
		return {
			left = {
				lines = (#disk > 0) and disk or { "<file does not exist>" },
				name = "DELETE: " .. p.path,
				ft = vim.filetype.match({ filename = p.path }) or "",
				modifiable = false,
				winbar = string.format("DELETE → _old  %s", p._rel or p.path),
				hl = hl,
			},
			focus = { left = 1 },
		}
	end

	local disk = {}
	if path ~= "" and vim.fn.filereadable(path) == 1 then
		disk = vim.fn.readfile(path)
	end

	local after
	if is_range then
		local block = vim.split(p.content or "", "\n", { plain = true })
		if block[#block] == "" then
			table.remove(block)
		end
		local s = math.max(1, math.floor(num(p.start_line, 1)))
		local e = math.max(s, math.floor(num(p.end_line, s)))
		after = {}
		for i = 1, math.min(s - 1, #disk) do
			after[#after + 1] = disk[i]
		end
		for _, l in ipairs(block) do
			after[#after + 1] = l
		end
		for i = e + 1, #disk do
			after[#after + 1] = disk[i]
		end
	else
		after = vim.split(p.content or "", "\n", { plain = true })
		if after[#after] == "" then
			table.remove(after)
		end
	end

	if #disk == 0 then
		set_changes({})
		return {
			left = {
				lines = (#after > 0) and after or { "" },
				name = "NEW: " .. p.path,
				ft = vim.filetype.match({ filename = p.path }) or "",
				modifiable = false,
				winbar = string.format("NEW FILE  +%d lines  %s", #after, p._rel or p.path),
			},
			focus = { left = 1 },
		}
	end

	local diff_lines = diff.build_diff(disk, after)
	local lines, hl = {}, {}
	local added, removed = 0, 0
	local change_lines = {}
	local prev_change = false
	for _, l in ipairs(diff_lines) do
		local mark = l:sub(1, 1)
		local text = l:sub(2)
		local ln = #lines + 1
		if mark == "+" then
			lines[ln] = text
			hl[ln] = "ManageAdd"
			added = added + 1
			if not prev_change then
				change_lines[#change_lines + 1] = ln
			end
			prev_change = true
		elseif mark == "-" then
			lines[ln] = text
			hl[ln] = "ManageRemove"
			removed = removed + 1
			if not prev_change then
				change_lines[#change_lines + 1] = ln
			end
			prev_change = true
		else
			lines[ln] = text
			prev_change = false
		end
	end
	if #lines == 0 then
		lines = { "" }
	end
	set_changes(change_lines)
	local focus_line = change_lines[1] or 1
	return {
		left = {
			lines = lines,
			name = "AFTER: " .. p.path,
			ft = vim.filetype.match({ filename = p.path }) or "",
			modifiable = false,
			winbar = string.format("AFTER  +%d −%d  %s", added, removed, p._rel or p.path),
			hl = hl,
		},
		focus = { left = focus_line },
	}
end

local function hunk_jump(delta, h)
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

local function scope_counts()
	local items = proposals.list_visible("all")
	local c = { all = #items, session = 0, files = 0, neither = 0 }
	for _, p in ipairs(items) do
		if p._cwd then
			c.session = c.session + 1
		end
		if p._cwd_file then
			c.files = c.files + 1
		end
		if not p._cwd and not p._cwd_file then
			c.neither = c.neither + 1
		end
	end
	return c
end

local function ensure_dirs(target)
	if target == "" then
		vim.notify("❌ Refused: legacy relative proposal path — re-emit with an absolute path", vim.log.levels.ERROR)
		return false
	end
	local parent = vim.fn.fnamemodify(target, ":h")
	if vim.fn.isdirectory(parent) ~= 1 then
		local create = vim.fn.confirm(
			"Directory doesn't exist:\n  " .. parent .. "\n\nCreate it and open the file?",
			"&Yes\n&No",
			1
		)
		if create ~= 1 then
			vim.notify("❌ Cancelled — target not opened", vim.log.levels.INFO)
			return false
		end
		vim.fn.mkdir(parent, "p")
	end
	return true
end

local function handle_delete(p)
	local target = resolve_path(p)
	local choice = vim.fn.confirm(
		"Move to _old?\n  "
			.. target
			.. "\n\n"
			.. "File goes to: "
			.. vim.fn.fnamemodify(target, ":h")
			.. "/_old/\n\n"
			.. "Nothing is permanently deleted — reversible from the journal.",
		"&Yes\n&No",
		1
	)
	if choice == 1 then
		proposals.move_to_old(p)
	else
		proposals.reject(p)
	end
end

local function open_in_origin(p, h)
	if not p then
		return
	end
	local target = resolve_path(p)
	if not ensure_dirs(target) then
		return
	end
	local origin = h.state.origin_win
	if origin and vim.api.nvim_win_is_valid(origin) then
		local cur = vim.api.nvim_get_current_win()
		vim.api.nvim_set_current_win(origin)
		vim.cmd("edit " .. vim.fn.fnameescape(target))
		vim.api.nvim_set_current_win(cur)
		vim.notify("📍 Opened " .. target .. " in your buffer (picker stays focused)", vim.log.levels.INFO)
	end
end

local function rerun_open(p, h)
	if not p then
		return
	end
	vim.notify(
		string.format("🔄 %s — proposal predates file changes; re-ask the AI against current state", p.path),
		vim.log.levels.WARN
	)
	open_in_origin(p, h)
end

local function is_note_group(group, items)
	for _, it in ipairs(items or {}) do
		if (it.group or "misc") == group and is_note(it) then
			return true
		end
	end
	return false
end

local function accept_current(p, h)
	if not p then
		return
	end
	local group = p.group or "misc"
	if is_note(p) or is_note_group(group, h.state.items) then
		vim.notify(
			"⛔ Note groups are all-or-nothing — press ga to apply the whole group atomically, or gr to reject.",
			vim.log.levels.WARN
		)
		return
	end
	local st = h.state.row_info[h.state.idx] and h.state.row_info[h.state.idx].state
	if st == "applied" then
		vim.notify("ℹ️ Already applied: " .. p.path, vim.log.levels.INFO)
		return
	end
	if st == "superseded" then
		vim.notify(
			string.format(
				"⏭ Skipped: %s is an older revision — the newest row for this " .. "target is the one that counts.",
				p._rel or p.path
			),
			vim.log.levels.WARN
		)
		return
	end
	if p.operation == "delete" then
		handle_delete(p)
		return
	end
	if st == "rerun" then
		local choice = vim.fn.confirm(
			"⚠️ File changed since this proposal was written.\n\n"
				.. "Accepting will OVERWRITE newer work on:\n  "
				.. resolve_path(p)
				.. "\n\n"
				.. "Continue?",
			"&Yes\n&No",
			2
		)
		if choice ~= 1 then
			return
		end
	end
	local content = after_content(p, resolve_path(p))
	local baseline = nil
	if p.operation == "edit_range" then
		baseline = content
	end
	proposals.accept(p, content, baseline)
	acted[p.ts] = true
	h.refresh()
end

local function reject_group(p, h)
	if not p then
		return
	end
	local group = p.group or "misc"
	local n = proposals.reject_group(group, adapter.filter)
	h.refresh()
	vim.notify(string.format("❌ Group %s: %d rejected", group, n), vim.log.levels.INFO)
end

local function reject_current(p, h)
	if not p then
		return
	end
	local group = p.group or "misc"
	if is_note(p) or is_note_group(group, h.state.items) then
		reject_group(p, h)
		return
	end
	proposals.reject(p)
	h.refresh()
end

local function apply_group(p, h)
	if not p then
		return
	end
	local group = p.group or "misc"
	local group_rows = {}
	for _, it in ipairs(proposals.list_visible(adapter.filter)) do
		if (it.group or "misc") == group then
			group_rows[#group_rows + 1] = it
		end
	end
	for _, it in ipairs(group_rows) do
		if it.operation == "mark-proposals" and (it.status or "pending") ~= "rejected" then
			local ok, spec = pcall(vim.json.decode, it.content or "")
			if ok and type(spec) == "table" and spec.mark == "do-not-apply" then
				vim.notify(
					"⛔ Group " .. group .. " is marked do-not-apply — " .. tostring(it.reason),
					vim.log.levels.ERROR
				)
				return
			end
		end
	end
	local newest = newest_revisions(proposals.list_visible("all"))
	local skipped, superseded = 0, 0
	local batch = {}
	local meta_rows = {}
	for _, it in ipairs(group_rows) do
		if row_state(it) == "applied" then
			skipped = skipped + 1
		elseif is_stale(it, newest) then
			superseded = superseded + 1
		elseif
			it.operation == "mark-proposals"
			or it.operation == "reject-proposals"
			or it.operation == "folder-approve"
			or it.operation == "goal-suggest"
		then
			table.insert(meta_rows, it)
		else
			local path = resolve_path(it)
			local content = after_content(it, path)
			table.insert(batch, { proposal = it, path = path, content = content })
		end
	end
	local applied = 0
	for _, it in ipairs(meta_rows) do
		if proposals.accept(it, it.content, it.content) then
			acted[it.ts] = true
			applied = applied + 1
		end
	end
	if #batch > 0 then
		local journal = require("opencode-manage.journal")
		local ok, n = proposals.apply_group_atomic(group, batch, journal.project_root())
		if not ok then
			h.refresh()
			return
		end
		for _, entry in ipairs(batch) do
			acted[entry.proposal.ts] = true
		end
		applied = applied + n
	end
	h.refresh()
	vim.notify(
		string.format(
			"✅ Group %s: %d applied atomically, %d already applied, %d superseded",
			group,
			applied,
			skipped,
			superseded
		),
		vim.log.levels.INFO
	)
end

local function yank_proposal(p, h)
	if not p then
		return
	end
	local info = h.state.row_info[h.state.idx] or {}
	local lines = { info.text or "" }
	lines[#lines + 1] = string.format("path: %s", p.path)
	lines[#lines + 1] = string.format("operation: %s", p.operation)
	lines[#lines + 1] = string.format("status: %s", p.status or "pending")
	lines[#lines + 1] = string.format("group: %s", p.group or "misc")
	lines[#lines + 1] = string.format("session: %s", p.sessionID or "?")
	lines[#lines + 1] = string.format("ts: %s", p.ts or 0)
	if p.reason and p.reason ~= "" then
		lines[#lines + 1] = string.format("reason: %s", p.reason)
	end
	if p.content and p.content ~= "" then
		lines[#lines + 1] = "content:"
		lines[#lines + 1] = p.content
	end
	return table.concat(lines, "\n")
end

local function clean_resolved(h)
	local n = 0
	for _, p in ipairs(proposals.list_all()) do
		local st = p.status or "pending"
		if (st == "accepted" or st == "rejected") and not bookmarks.is_bookmark(p) then
			n = n + 1
		end
	end
	if n == 0 then
		vim.notify("Nothing to clean — no accepted/rejected rows", vim.log.levels.INFO)
		return
	end
	local choice = vim.fn.confirm(
		string.format(
			"Purge %d resolved rows (accepted/rejected) from the journals?\n\n"
				.. "Verdicts stay in state.db — this only removes the journal rows.",
			n
		),
		"&Yes\n&No",
		2
	)
	if choice ~= 1 then
		return
	end
	local removed = proposals.purge_resolved()
	h.refresh()
	vim.notify(
		string.format("🧹 Cleaned %d resolved rows — history remains in state.db verdicts", removed),
		vim.log.levels.INFO
	)
end

local function toggle_filter(h)
	local c = scope_counts()
	local cur = 1
	for i, f in ipairs(FILTER_CYCLE) do
		if f == adapter.filter then
			cur = i
			break
		end
	end
	adapter.filter = FILTER_CYCLE[(cur % #FILTER_CYCLE) + 1]
	h.state.idx = 1
	h.refresh()
	vim.notify(
		string.format(
			"f: all=%d session=%d files=%d neither=%d — now showing %s",
			c.all,
			c.session,
			c.files,
			c.neither,
			adapter.filter
		),
		vim.log.levels.INFO
	)
end

M.row_state = row_state
M.hl_for = hl_for
M.state_tag = state_tag

function M.session_id()
	return current_session() or "none"
end

function M.open()
	adapter.filter = "all"
	console.open({
		name = "Review",
		layout = "detail",
		list = function()
			local out = {}
			local cur = current_session()
			for _, p in ipairs(proposals.list_visible(adapter.filter)) do
				if not bookmarks.is_bookmark(p) then
					if
						adapter.show_all_applied
						or acted[p.ts]
						or p.status ~= "accepted"
						or not cur
						or not p.sessionID
						or p.sessionID == cur
					then
						out[#out + 1] = p
					end
				end
			end
			if adapter.show_rejected then
				for _, p in ipairs(proposals.list_all()) do
					if not bookmarks.is_bookmark(p) and p.status == "rejected" then
						out[#out + 1] = p
					end
				end
			end
			return out
		end,
		rows = rows,
		preview = preview,
		actions = {
			primary = open_in_origin,
			primary_desc = "open in origin",
			accept = function(p, h)
				if not p then
					return
				end
				local group = p.group or "misc"
				if is_note(p) or is_note_group(group, h.state.items) then
					vim.notify(
						"⛔ Note groups are all-or-nothing — press ga to apply the whole group atomically, or gr to reject.",
						vim.log.levels.WARN
					)
					return
				end
				apply_group(p, h)
			end,
			reject = reject_group,
			group_apply = apply_group,
			group_reject = reject_group,
			open = open_in_origin,
			yank = yank_proposal,
			rerun = rerun_open,
		},
		keys = {
			{ key = "f", desc = "filter", fn = toggle_filter },
			{
				key = "O",
				desc = "show rejected (deleted) rows",
				fn = function(h)
					adapter.show_rejected = not adapter.show_rejected
					vim.notify(
						adapter.show_rejected and "showing rejected rows (struck)" or "hiding rejected rows",
						vim.log.levels.INFO
					)
					h.refresh()
				end,
			},
			{
				key = "x",
				desc = "show all applied",
				fn = function(h)
					adapter.show_all_applied = not adapter.show_all_applied
					h.refresh()
					vim.notify(
						"proposals: "
							.. (
								adapter.show_all_applied and "showing ALL applied history"
								or "hiding applied rows from other sessions"
							),
						vim.log.levels.INFO
					)
				end,
			},
			{ key = "c", desc = "clean resolved rows", fn = clean_resolved },
			{
				key = "v",
				desc = "view group",
				fn = function(h)
					local p = h.state.items[h.state.idx]
					if not p then
						return
					end
					local group = p.group or "misc"
					require("opencode-manage.previewview").open(group, function()
						h.kill()
					end, function()
						require("opencode-manage.reviewview").open()
					end, p)
				end,
			},
		},
		legend = function(h)
			local c = scope_counts()
			return string.format(
				"%s · %d rows · f: all=%d session=%d files=%d neither=%d · j/k gg/G [/] f r o/CR v files da/ga group gr rr y c x Q",
				FILTER_LABELS[adapter.filter],
				#h.state.items,
				c.all,
				c.session,
				c.files,
				c.neither
			)
		end,
		swatches = "%#ManageNew#██%*new  %#ManageEdit#██%*edit  %#ManageRerun#██%*rerun  %#ManageDelete#██%*delete  "
			.. "%#ManageApplied#██%*applied  %#ManageRejected#██%*rejected  %#ManageSuperseded#██%*superseded  %#ManageMismatch#██%*mismatch",
		empty_msg = "No proposals yet",
		keep_empty = true,
		identity = function(p)
			return p.group or "misc"
		end,
		scroll = "hunks",
		hunk_jump = hunk_jump,
	})
end

return M
