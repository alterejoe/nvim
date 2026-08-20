-- opencode-manage.reviewview — the persistent review viewer.
-- List (top) + CURRENT/AFTER preview panes (below, side by side).
--   j/k move · gg/G jump · [/] scroll panes · f scope filter (all /
--   session / files / neither) · r refresh · o/CR open in origin ·
--   da accept (snapshot + write the RIGHT pane) · dr reject (status
--   only) · rr rerun (open for re-eval) · ga GROUP-APPLY (every pending
--   row in the current group, each against the freshly-written file) ·
--   y copy+open · Q kill.
-- ALL keys are mapped on every buffer — nothing is dead by focus.
-- ACCEPTED ROWS STAY: the list shows pending + accepted rows; accepted
-- ones render dim-green [applied] so the review history is explicit.
-- Partial (edit_range) rows: LEFT pane = the unified diff itself
-- (@@ header, context, - removed red / + added green); RIGHT pane = the
-- full file with the range applied (editable — da writes it verbatim, so
-- a partial can never truncate a file). Panes open positioned at the
-- change. create/replace rows: current file vs proposed content.
-- Row colors: green=NEW · blue=EDIT · magenta=RERUN · red=DELETE ·
-- dim=APPLIED · strike=REJECTED · yellow=MISMATCH.
-- The cursor stays on the selected PROPOSAL across refreshes (identity-
-- based restore), and row ordering is fully deterministic.
-- Perf: row_state() (filereadable/readfile/fs_stat) runs once per refresh
-- into state.row_states; rendering reads the cache only.

local proposals = require("opencode-manage.proposals")

local M = {}

local FILTER_CYCLE = { "all", "session", "files", "neither" }

local FILTER_LABELS = {
	all = "🌐 ALL",
	session = "🗂 SESSION (in cwd)",
	files = "📄 FILES (in cwd)",
	neither = "🚫 NEITHER (foreign session+files)",
}

local state = {
	items = {},
	idx = 1,
	filter = "all", -- "all" | "session" | "files" | "neither"
	row_states = {}, -- item index -> derived state, computed at refresh
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

--- Resolve a proposal path to absolute.
--- @param p table
--- @return string
local function resolve_path(p)
	if p.path:sub(1, 1) == "/" then
		return p.path
	end
	if p._file then
		return vim.fn.fnamemodify(p._file, ":h:h") .. "/" .. p.path
	end
	return vim.fn.getcwd() .. "/" .. p.path
end

--- Does the file on disk already contain exactly what the proposal wants?
--- Trailing-newline-insensitive. Only meaningful for create/replace
--- (full-content ops); edit_range blocks can't be compared this way.
--- @param p table
--- @param path string
--- @return boolean
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

--- Was the target file modified AFTER the proposal was created?
--- Content equality is checked BEFORE this (see row_state), so a manual
--- apply with exact proposal content never flags rerun. Second-granularity:
--- ext4 mtime resolution is 1s; equal-second is ambiguous and treated as
--- not-modified (conservative).
--- @param p table
--- @param path string
--- @return boolean
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

--- Define the row highlight groups once.
local function define_hls()
	local hl = vim.api.nvim_set_hl
	hl(0, "ManageNew", { fg = "#4ec9b0", bold = true }) -- green: new file
	hl(0, "ManageEdit", { fg = "#569cd6" }) -- blue: edit needed
	hl(0, "ManageRerun", { fg = "#c586c0" }) -- magenta: context stale
	hl(0, "ManageDelete", { fg = "#f44747" }) -- red: delete/move
	hl(0, "ManageApplied", { fg = "#6a9955" }) -- dim green: already applied
	hl(0, "ManageRejected", { fg = "#808080", strikethrough = true }) -- dim: rejected
	hl(0, "ManageMismatch", { fg = "#dcdcaa", bold = true }) -- yellow: mismatch
	hl(0, "ManageGroup", { fg = "#808080", italic = true }) -- group headers
	-- Diff-pane backgrounds: what a partial deletes (left) / adds (right).
	hl(0, "ManageAdd", { bg = "#1e3b2a" })
	hl(0, "ManageRemove", { bg = "#3b1f1f" })
end

--- Counts per scope from a single scan — cheap, one read of the manifests.
--- Counts VISIBLE rows (pending + accepted) to match what the list shows.
--- @return table<string, number>
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

--- Permanent legend in the LIST window's winbar: scope + the four counts +
--- color swatches (rendered with the same highlight groups the rows use)
--- + every keybind. Multi-line winbar requires nvim 0.10+.
local function set_legend()
	if not state.list_win or not vim.api.nvim_win_is_valid(state.list_win) then
		return
	end
	local c = scope_counts()
	local line2 = string.format(
		"%s · %d rows · f: all=%d session=%d files=%d neither=%d · j/k gg/G [/] f r o/CR da dr rr ga y Q",
		FILTER_LABELS[state.filter],
		#state.items,
		c.all,
		c.session,
		c.files,
		c.neither
	)
	vim.wo[state.list_win].winbar = table.concat({
		"%#ManageNew#██%*new  %#ManageEdit#██%*edit  %#ManageRerun#██%*rerun  %#ManageDelete#██%*delete  "
			.. "%#ManageApplied#██%*applied  %#ManageRejected#██%*rejected  %#ManageMismatch#██%*mismatch",
		line2,
	}, "\n")
end

--- Classify a proposal's state by comparing the proposal against the ACTUAL
--- file on disk: content first (bytes are truth), then mtime (context
--- staleness), then existence/op structure.
--- @param p table
--- @return string  "new" | "edit" | "rerun" | "delete" | "applied" | "rejected" | "mismatch"
local function row_state(p)
	local st = p.status or "pending"

	-- Explicitly rejected is final, regardless of disk
	if st == "rejected" then
		return "rejected"
	end

	-- Accepted is done — the disk state no longer matters for the label.
	if st == "accepted" then
		return "applied"
	end

	local path = resolve_path(p)
	local exists = vim.fn.filereadable(path) == 1

	-- delete/move: applied once the file is gone (moved to _old/)
	if p.operation == "delete" then
		if exists then
			return "delete"
		end
		return "applied" -- already moved / gone
	end

	-- create/replace: content equality is the ground truth
	if p.operation == "create" or p.operation == "replace" then
		if exists and content_matches(p, path) then
			return "applied" -- the file already IS the proposal
		end
		if exists then
			if p.operation == "create" then
				return "mismatch" -- create on an existing file that differs
			end
			-- replace: file exists and differs — context staleness decides
			if file_modified_since(p, path) then
				return "rerun" -- file changed after the proposal was authored
			end
			return "edit"
		end
		if p.operation == "create" then
			return "new"
		end
		return "mismatch" -- replace on a missing file
	end

	-- edit_range: can't content-compare a partial block; existence + mtime.
	-- The mtime gate matters MORE here — it's the only staleness signal.
	if exists then
		if file_modified_since(p, path) then
			return "rerun"
		end
		return "edit"
	end
	return "mismatch"
end

--- Precompute the derived state for every item. Called once per refresh —
--- the ONLY place row_state runs. Rendering reads state.row_states.
local function compute_row_states()
	state.row_states = {}
	for i, p in ipairs(state.items) do
		state.row_states[i] = row_state(p)
	end
end

--- Human-readable tag for a derived state (shown in the row's [tag]).
--- @param st string
--- @return string
local function state_tag(st)
	local tags = {
		applied = "applied",
		edit = "edit",
		rerun = "rerun",
		new = "new",
		delete = "delete",
		rejected = "rejected",
		mismatch = "mismatch",
	}
	return tags[st] or st
end

--- The highlight group for a row state.
--- @param st string
--- @return string
local function hl_for(st)
	return "Manage" .. st:sub(1, 1):upper() .. st:sub(2)
end

local function short_sid(sid)
	if not sid then
		return "?"
	end
	return sid:sub(-8)
end

--- Compact "when" stamp for a proposal's epoch-millis ts.
--- @param ts number|nil
--- @return string
local function fmt_when(ts)
	if not ts or ts == 0 then
		return "?"
	end
	return os.date("%m-%d %H:%M", math.floor(ts / 1000))
end

--- Highlight a 1-based inclusive line span with an extmark background.
--- @param buf number
--- @param ns number
--- @param hl string
--- @param from number
--- @param to number
local function hl_span(buf, ns, hl, from, to)
	if not from or not to or to < from then
		return
	end
	for ln = from, to do
		vim.api.nvim_buf_add_highlight(buf, ns, hl, ln - 1, 0, -1)
	end
end

--- The exact content a proposal would write to disk, computed against the
--- CURRENT file at call time (range-apply for edit_range, full content for
--- create/replace). nil for delete rows (they move, not write).
--- @param p table
--- @param path string
--- @return string|nil
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
		local s = math.max(1, math.floor(p.start_line or 1))
		local e = math.max(s, math.floor(p.end_line or s))
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

--- Render CURRENT (left) vs AFTER (right) for the selected proposal.
--- For edit_range: LEFT = unified diff (- removed / + added, red/green),
--- RIGHT = the full file with the range applied (editable — da writes it).
--- The right pane opens at the first added line; the left at the diff.
local function render_previews()
	if not state.cur_buf or not vim.api.nvim_buf_is_valid(state.cur_buf) then
		return
	end
	local p = state.items[state.idx]
	if not p then
		return
	end
	local path = resolve_path(p)
	local is_delete = p.operation == "delete"
	local is_range = p.operation == "edit_range" and p.start_line ~= nil

	local cur_lines, after_lines
	local after_span -- 1-based inclusive line span of the added block

	if is_delete and vim.fn.filereadable(path) == 1 then
		cur_lines = vim.fn.readfile(path)
		after_lines = { "<moved to _old> — da prompts the move" }
	else
		local disk = {}
		if vim.fn.filereadable(path) == 1 then
			disk = vim.fn.readfile(path)
		end
		if is_range then
			-- AFTER = full file with the range replaced; the preview IS the
			-- file da writes, so a partial can never truncate anything.
			local block = vim.split(p.content or "", "\n", { plain = true })
			if block[#block] == "" then
				table.remove(block)
			end
			local s = math.max(1, math.floor(p.start_line or 1))
			local e = math.max(s, math.floor(p.end_line or s))
			local head, tail = {}, {}
			for i = 1, math.min(s - 1, #disk) do
				head[i] = disk[i]
			end
			for i = e + 1, #disk do
				tail[#tail + 1] = disk[i]
			end
			after_lines = {}
			for _, l in ipairs(head) do
				after_lines[#after_lines + 1] = l
			end
			for _, l in ipairs(block) do
				after_lines[#after_lines + 1] = l
			end
			for _, l in ipairs(tail) do
				after_lines[#after_lines + 1] = l
			end
			if #block > 0 then
				after_span = { s, math.min(s + #block - 1, #after_lines) }
			end

			-- LEFT pane = the DIFF ITSELF: hunk header, a little context,
			-- removed lines (-, red) and added lines (+, green). The change
			-- is visible at a glance; the right pane is the write-truth.
			local ctx = 2
			local diff_lines = {}
			table.insert(
				diff_lines,
				string.format("@@ -%d,%d +%d,%d @@", s, math.max(0, math.min(e, #disk) - s + 1), s, #block)
			)
			local cs = math.max(1, s - ctx)
			for i = cs, s - 1 do
				table.insert(diff_lines, " " .. (disk[i] or ""))
			end
			for i = s, math.min(e, #disk) do
				table.insert(diff_lines, "-" .. (disk[i] or ""))
			end
			for i = 1, #block do
				table.insert(diff_lines, "+" .. block[i])
			end
			for i = e + 1, math.min(e + ctx, #disk) do
				table.insert(diff_lines, " " .. (disk[i] or ""))
			end
			cur_lines = diff_lines
		else
			-- create/replace: current file vs proposed content.
			if #disk == 0 then
				cur_lines = { "<file does not exist>" }
			else
				cur_lines = disk
			end
			after_lines = vim.split(p.content or "", "\n", { plain = true })
			if after_lines[#after_lines] == "" then
				table.remove(after_lines)
			end
		end
	end

	-- LEFT pane: current state / diff (reference, read-only).
	if vim.bo[state.cur_buf].modifiable == false then
		vim.bo[state.cur_buf].modifiable = true
	end
	vim.api.nvim_buf_set_lines(state.cur_buf, 0, -1, false, cur_lines or { "" })
	vim.bo[state.cur_buf].bufhidden = "wipe"
	vim.bo[state.cur_buf].filetype = vim.filetype.match({ filename = p.path }) or ""
	vim.api.nvim_buf_set_name(state.cur_buf, "CURRENT: " .. p.path)
	vim.bo[state.cur_buf].modifiable = false

	-- RIGHT pane: the proposal's result — EDITABLE, da writes this.
	if vim.bo[state.after_buf].modifiable == false then
		vim.bo[state.after_buf].modifiable = true
	end
	vim.api.nvim_buf_set_lines(state.after_buf, 0, -1, false, after_lines or { "" })
	vim.bo[state.after_buf].bufhidden = "wipe"
	vim.bo[state.after_buf].filetype = vim.filetype.match({ filename = p.path }) or ""
	vim.api.nvim_buf_set_name(state.after_buf, "AFTER: " .. p.path)
	vim.bo[state.after_buf].modifiable = true

	-- Diff highlights: red = being deleted, green = being added. Range rows
	-- show a unified diff on the LEFT, so color by line prefix there.
	local ns = vim.api.nvim_create_namespace("manage-diff")
	vim.api.nvim_buf_clear_namespace(state.cur_buf, ns, 0, -1)
	vim.api.nvim_buf_clear_namespace(state.after_buf, ns, 0, -1)
	if is_range then
		for ln, l in ipairs(cur_lines or {}) do
			local prefix = l:sub(1, 1)
			if prefix == "-" then
				vim.api.nvim_buf_add_highlight(state.cur_buf, ns, "ManageRemove", ln - 1, 0, -1)
			elseif prefix == "+" then
				vim.api.nvim_buf_add_highlight(state.cur_buf, ns, "ManageAdd", ln - 1, 0, -1)
			end
		end
	end
	hl_span(state.after_buf, ns, "ManageAdd", after_span and after_span[1], after_span and after_span[2])

	-- Winbars: what each side is, and that da writes the right one.
	local opdesc = p.operation
	if is_range then
		opdesc = string.format("%s %d-%d", p.operation, p.start_line, p.end_line or p.start_line)
	end
	if state.cur_win and vim.api.nvim_win_is_valid(state.cur_win) then
		vim.wo[state.cur_win].winbar = string.format("CURRENT %s  [%s]", p._rel or p.path, opdesc)
	end
	if state.after_win and vim.api.nvim_win_is_valid(state.after_win) then
		local what = "proposal content"
		if is_delete then
			what = "moved to _old"
		elseif is_range then
			what = "range applied"
		end
		vim.wo[state.after_win].winbar = string.format("AFTER — %s · da writes this  %s", what, p._rel or p.path)
	end

	-- Position: range rows open the LEFT pane at the diff (top) and the
	-- RIGHT pane at the first added line; everything else starts at the
	-- top. [/] then scroll both together.
	local left_focus = 1
	local right_focus = 1
	if is_range then
		right_focus = after_span and after_span[1] or 1
	end
	for _, spec in ipairs({ { state.cur_win, left_focus }, { state.after_win, right_focus } }) do
		local w, ln = spec[1], spec[2]
		if w and vim.api.nvim_win_is_valid(w) then
			vim.api.nvim_win_call(w, function()
				vim.api.nvim_win_set_cursor(w, { math.max(1, ln), 0 })
				vim.cmd("normal! zt") -- change line lands at the top of the pane
			end)
		end
	end
end

--- Scroll BOTH preview panes together (diff-style). Uses zt so the viewport
--- ACTUALLY moves: set_cursor alone only scrolls when the target is outside
--- the view, which made ']' (down) a silent no-op. Notifies at boundaries.
--- @param delta number  lines to scroll (negative = up)
local function scroll_previews(delta)
	local amount = delta * 8
	for _, w in ipairs({ state.cur_win, state.after_win }) do
		if w and vim.api.nvim_win_is_valid(w) then
			vim.api.nvim_win_call(w, function()
				local topline = vim.fn.line("w0")
				local nlines = vim.api.nvim_buf_line_count(0)
				local max_top = math.max(1, nlines - vim.api.nvim_win_get_height(0) + 1)
				local target = math.max(1, math.min(max_top, topline + amount))
				vim.api.nvim_win_set_cursor(0, { target, 0 })
				vim.cmd("normal! zt")
				if target == topline then
					vim.notify(delta > 0 and "— bottom —" or "— top —", vim.log.levels.INFO)
				end
			end)
		end
	end
end

--- Display-order indices: groups ordered by their NEWEST proposal's time
--- (descending), proposals within a group newest-first. The comparator is
--- TOTAL (path tiebreaker) — table.sort is unstable, and equal timestamps
--- would otherwise reorder rows between refreshes, moving the cursor.
--- @return number[]
local function display_order()
	local order = {}
	local group_newest = {}
	for i, p in ipairs(state.items) do
		order[i] = i
		local g = p.group or "misc"
		group_newest[g] = math.max(group_newest[g] or 0, p.ts or 0)
	end
	table.sort(order, function(a, b)
		local ia, ib = state.items[a], state.items[b]
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

--- Item index at display position `pos` (1-based), clamped.
--- @param order number[]
--- @param pos number
--- @return number item index
local function item_at(order, pos)
	local n = #order
	if n == 0 then
		return nil
	end
	pos = math.max(1, math.min(n, pos))
	return order[pos]
end

local function render_list()
	if not state.list_buf or not vim.api.nvim_buf_is_valid(state.list_buf) then
		return
	end
	local order = display_order()
	local lines = {}
	local row_of = {} -- display line -> state string
	local last_group = nil
	local cursor_line = 1
	for _, si in ipairs(order) do
		local p = state.items[si]
		local g = p.group or "misc"
		if g ~= last_group then
			last_group = g
			table.insert(lines, "── " .. g .. " ─────────────────────")
		end
		local marker = (si == state.idx) and ">" or " "
		local st = state.row_states[si] or row_state(p)
		local tag = state_tag(st)
		table.insert(
			lines,
			string.format(
				"%s %-12s %-9s [%-8s] %s  (s:%s · %s)",
				marker,
				p._project or "?",
				p.operation,
				tag,
				p._rel or p.path,
				short_sid(p.sessionID),
				fmt_when(p.ts)
			)
		)
		row_of[#lines] = st
		if si == state.idx then
			cursor_line = #lines
		end
	end
	if #lines == 0 then
		table.insert(lines, "— nothing here —")
	end
	if vim.bo[state.list_buf].modifiable == false then
		vim.bo[state.list_buf].modifiable = true
	end
	vim.api.nvim_buf_set_lines(state.list_buf, 0, -1, false, lines)
	vim.bo[state.list_buf].modifiable = false

	-- Color each row by its cached state
	local ns = vim.api.nvim_create_namespace("manage-rows")
	vim.api.nvim_buf_clear_namespace(state.list_buf, ns, 0, -1)
	for ln, st in pairs(row_of) do
		local hl = hl_for(st)
		if hl ~= "ManageApplied" and hl ~= "ManageRejected" then
			vim.api.nvim_buf_add_highlight(state.list_buf, ns, hl, ln - 1, 0, -1)
		else
			vim.api.nvim_buf_add_highlight(state.list_buf, ns, hl, ln - 1, 2, -1)
		end
	end

	if state.list_win and vim.api.nvim_win_is_valid(state.list_win) then
		local total = vim.api.nvim_buf_line_count(state.list_buf)
		local target = math.max(1, math.min(cursor_line, total))
		pcall(vim.api.nvim_win_set_cursor, state.list_win, { target, 0 })
	end
end

--- Move selection by `delta` DISPLAY positions.
--- @param delta number  -1 or 1
local function move(delta)
	local order = display_order()
	if #order == 0 then
		return
	end
	local pos = 1
	for i, si in ipairs(order) do
		if si == state.idx then
			pos = i
			break
		end
	end
	local next_item = item_at(order, pos + delta)
	if next_item then
		state.idx = next_item
		render_list()
		render_previews()
	end
end

--- Jump to the first (top) or last (bottom) DISPLAY row.
--- @param to_last boolean
local function jump(to_last)
	local order = display_order()
	if #order == 0 then
		return
	end
	state.idx = item_at(order, to_last and #order or 1)
	render_list()
	render_previews()
end

--- Re-read VISIBLE proposals (pending + accepted) for the current scope.
--- Preserves the selected proposal BY IDENTITY (path + manifest + ts), so
--- the cursor stays on the same row through da/ga even though the list is
--- rebuilt. Defined BEFORE accept/reject/toggle (its callers) — a later
--- local would resolve to a nil global inside their closures.
local function refresh_items()
	local items = proposals.list_visible(state.filter)
	local prev = state.items[state.idx]
	state.items = items
	compute_row_states()
	if prev then
		local found = false
		for i, p in ipairs(items) do
			if p.path == prev.path and p._file == prev._file and p.ts == prev.ts then
				state.idx = i
				found = true
				break
			end
		end
		if not found then
			state.idx = math.max(1, math.min(state.idx, #items))
		end
	else
		state.idx = math.max(1, math.min(state.idx, #items))
	end
	render_list()
	render_previews()
end

local function ensure_dirs(target)
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

--- Shared delete handling: confirm Move to _old? then route.
--- @param p table
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

--- o / <CR>: open target in the origin window WITHOUT moving the cursor.
local function open_in_origin()
	local p = state.items[state.idx]
	if not p then
		return
	end
	local target = resolve_path(p)
	if not ensure_dirs(target) then
		return
	end
	local origin = state.origin_win
	if origin and vim.api.nvim_win_is_valid(origin) then
		local cur = vim.api.nvim_get_current_win()
		vim.api.nvim_set_current_win(origin)
		vim.cmd("edit " .. vim.fn.fnameescape(target))
		vim.api.nvim_set_current_win(cur)
		vim.notify("📍 Opened " .. target .. " in your buffer (picker stays focused)", vim.log.levels.INFO)
	end
end

--- rr: re-evaluation path — the proposal predates file changes, so open the
--- file in origin and let the user re-ask the AI against current state.
--- Status unchanged; this is a context flag, not a verdict.
local function rerun_open()
	local p = state.items[state.idx]
	if not p then
		return
	end
	vim.notify(
		string.format("🔄 %s — proposal predates file changes; re-ask the AI against current state", p.path),
		vim.log.levels.WARN
	)
	open_in_origin()
end

local function accept_current()
	local p = state.items[state.idx]
	if not p then
		return
	end
	if state.row_states[state.idx] == "applied" then
		vim.notify("ℹ️ Already applied: " .. p.path, vim.log.levels.INFO)
		return
	end
	if p.operation == "delete" then
		handle_delete(p)
	else
		-- rerun guard: accepting overwrites work the user did after the
		-- proposal was authored — confirm before clobbering it
		if state.row_states[state.idx] == "rerun" then
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
		-- da writes the RIGHT pane verbatim — for edit_range that pane is
		-- the full file with the range applied, so partials are safe.
		local current = vim.api.nvim_buf_get_lines(state.after_buf, 0, -1, false)
		proposals.accept(p, table.concat(current, "\n"))
	end
	refresh_items()
end

local function reject_current()
	local p = state.items[state.idx]
	if not p then
		return
	end
	proposals.reject(p)
	refresh_items()
end

--- ga: apply EVERY pending row in the current group, in display order.
--- Each row is computed against the file state at apply time (fresh read),
--- so a multi-file group applies cleanly in one pass. Delete rows prompt.
local function apply_group()
	local p = state.items[state.idx]
	if not p then
		return
	end
	local group = p.group or "misc"
	local applied, skipped = 0, 0
	for _, it in ipairs(state.items) do
		if (it.group or "misc") == group then
			if row_state(it) == "applied" then
				skipped = skipped + 1
			elseif it.operation == "delete" then
				handle_delete(it)
			else
				local path = resolve_path(it)
				local content = after_content(it, path)
				proposals.accept(it, content)
				applied = applied + 1
			end
		end
	end
	refresh_items()
	vim.notify(
		string.format("✅ Group %s: %d applied, %d already applied", group, applied, skipped),
		vim.log.levels.INFO
	)
end

--- f: cycle the scope filter ALL → SESSION → FILES → NEITHER → ALL.
--- Every press reports all four counts so the effect is visible even when
--- two scopes coincide (e.g. only one project has manifests).
local function toggle_filter()
	local c = scope_counts()
	local cur = 1
	for i, f in ipairs(FILTER_CYCLE) do
		if f == state.filter then
			cur = i
			break
		end
	end
	state.filter = FILTER_CYCLE[(cur % #FILTER_CYCLE) + 1]
	state.idx = 1
	refresh_items()
	set_legend()
	vim.notify(
		string.format(
			"f: all=%d session=%d files=%d neither=%d — now showing %s",
			c.all,
			c.session,
			c.files,
			c.neither,
			FILTER_LABELS[state.filter]
		),
		vim.log.levels.INFO
	)
end

--- y: on DELETE rows, prompt Move to _old? like da. Otherwise SNAPSHOT the
--- current file (journaled — manual pastes are revertible), copy content,
--- and open the target in origin.
local function copy_and_open()
	local p = state.items[state.idx]
	if not p then
		return
	end
	if p.operation == "delete" then
		handle_delete(p)
		refresh_items()
		return
	end
	local content = p.content or ""
	vim.fn.setreg("+", content)
	vim.fn.setreg('"', content)

	-- Snapshot the CURRENT file BEFORE the user pastes — the manual path
	-- is now journaled and revertible, same as da.
	proposals.snapshot_only(p)

	vim.notify(string.format("📋 Copied %d chars (%s) to clipboard", #content, p.path), vim.log.levels.INFO)
	local target = resolve_path(p)
	if not ensure_dirs(target) then
		return
	end
	local origin = state.origin_win
	if origin and vim.api.nvim_win_is_valid(origin) then
		vim.api.nvim_set_current_win(origin)
		vim.cmd("edit " .. vim.fn.fnameescape(target))
	end
	vim.notify(
		string.format("📍 Opened %s — clipboard has the new content. Paste + :w to apply.", target),
		vim.log.levels.INFO
	)
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
	state.row_states = {}
	state.list_buf = nil
	state.cur_buf = nil
	state.after_buf = nil
	state.list_win = nil
	state.cur_win = nil
	state.after_win = nil
	state.outer_win = nil
	state.origin_win = nil
	state.origin_buf = nil
	vim.notify("🗑️ Review viewer closed", vim.log.levels.INFO)
end

local function set_q_kill(buf)
	vim.keymap.set("n", "Q", kill_viewer, { buffer = buf, nowait = true, noremap = true, silent = true })
end

--- Create a deterministic split window.
--- @param buf number
--- @param split string  "right" | "below"
--- @param ref_win number  window to split (defaults to current)
--- @return number win
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

--- Map the full key set on one buffer.
--- @param buf number
local function map_keys(buf)
	local opts = { buffer = buf, nowait = true, noremap = true, silent = true }
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
		jump(false)
	end, opts)
	vim.keymap.set("n", "G", function()
		jump(true)
	end, opts)
	vim.keymap.set("n", "[", function()
		scroll_previews(-1)
	end, opts)
	vim.keymap.set("n", "]", function()
		scroll_previews(1)
	end, opts)
	vim.keymap.set("n", "f", toggle_filter, opts)
	vim.keymap.set("n", "r", refresh_items, opts)
	vim.keymap.set("n", "o", open_in_origin, opts)
	vim.keymap.set("n", "<CR>", open_in_origin, opts)
	vim.keymap.set("n", "da", accept_current, opts)
	vim.keymap.set("n", "dr", reject_current, opts)
	vim.keymap.set("n", "rr", rerun_open, opts)
	vim.keymap.set("n", "ga", apply_group, opts)
	vim.keymap.set("n", "y", copy_and_open, opts)
	set_q_kill(buf)
end

function M.open()
	local items = proposals.list_visible(state.filter)
	if #items == 0 then
		vim.notify("No proposals yet", vim.log.levels.INFO)
		return
	end
	-- Re-entry guard: replace an existing viewer instead of stacking
	if state.outer_win and vim.api.nvim_win_is_valid(state.outer_win) then
		kill_viewer()
	end
	define_hls()
	state.items = items
	compute_row_states()

	-- Cursor: the NEWEST row (first display position — newest-first).
	state.idx = item_at(display_order(), 1)

	state.origin_win = vim.api.nvim_get_current_win()
	state.origin_buf = vim.api.nvim_get_current_buf()

	-- List buffer: new column to the RIGHT of the origin buffer
	state.list_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[state.list_buf].bufhidden = "wipe"
	vim.bo[state.list_buf].filetype = "managelist"
	state.outer_win = make_window(state.list_buf, "right")
	state.list_win = state.outer_win
	set_legend()

	-- CURRENT pane: below the list (left of the lower pair) — read-only.
	state.cur_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[state.cur_buf].bufhidden = "wipe"
	vim.bo[state.cur_buf].modifiable = false
	state.cur_win = make_window(state.cur_buf, "below", state.list_win)

	-- AFTER pane: to the RIGHT of CURRENT — EDITABLE, da writes this.
	state.after_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[state.after_buf].bufhidden = "wipe"
	vim.bo[state.after_buf].modifiable = true
	state.after_win = make_window(state.after_buf, "right", state.cur_win)

	vim.api.nvim_set_current_win(state.list_win)

	-- Full key set on ALL buffers so nothing is a dead key by focus.
	map_keys(state.list_buf)
	map_keys(state.cur_buf)
	map_keys(state.after_buf)

	state.autocmd = vim.api.nvim_create_autocmd("WinEnter", {
		callback = function()
			local cur = vim.api.nvim_get_current_win()
			if
				state.list_win
				and vim.api.nvim_win_is_valid(state.list_win)
				and (cur == state.cur_win or cur == state.after_win or cur == state.list_win)
			then
				-- Deferred: never switch windows synchronously inside a
				-- nvim_win_call (disallowed) or mid-render — the focus
				-- return lands on the next tick.
				vim.schedule(function()
					if state.list_win and vim.api.nvim_win_is_valid(state.list_win) then
						vim.api.nvim_set_current_win(state.list_win)
					end
				end)
			end
		end,
	})

	render_list()
	render_previews()
end

return M
