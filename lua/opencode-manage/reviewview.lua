-- /home/altjoe/.config/nvim/lua/opencode-manage/reviewview.lua FINAL-2
-- opencode-manage.reviewview — proposals review panel (console adapter).
-- The richest adapter: editable AFTER pane, revision ordering, scope filter,
-- hunk navigation, group apply, copy+open, rerun.
--   j/k move · gg/G jump · [/] hunks · f scope filter (all / session /
--   files / neither) · r refresh · o/CR open in origin · da accept
--   (snapshot + write the RIGHT pane) · dr reject (status only) ·
--   rr rerun (open for re-eval) · ga GROUP-APPLY (the newest row per
--   target in the current group; older revisions are skipped
--   automatically — revision ordering is internal, never your job) ·
--   y yank row state · c CLEAN (purge accepted/rejected rows from the
--   journals — verdicts stay in state.db) · Q kill.
-- ACCEPTED ROWS STAY: the list shows pending + accepted rows; accepted
-- ones render dim-green [applied] and older revisions render dim-struck
-- [superseded], so the review history is explicit.
-- Partial (edit_range) rows: LEFT pane = the unified diff itself
-- (@@ header, context, - removed red / + added green); RIGHT pane = the
-- full file with the range applied (editable — da writes it verbatim, so
-- a partial can never truncate a file). create/replace rows: LEFT = the
-- unified diff (disk vs proposed), RIGHT = proposed content. Panes open
-- positioned at the first change; [ / ] jumps between hunks.
-- Row colors: green=NEW · blue=EDIT · magenta=RERUN · red=DELETE ·
-- dim=APPLIED · strike=REJECTED · strike-italic=SUPERSEDED · yellow=MISMATCH.
-- The cursor stays on the selected PROPOSAL across refreshes (identity-
-- based restore), and row ordering is fully deterministic.
-- The engine (opencode-manage.console) owns windows/keymaps/state; this
-- file owns the proposals-specific logic: row classification (row_state),
-- CURRENT/AFTER previews (diff building), and the actions.

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

local adapter = { filter = "all", show_all_applied = false }

--- Current session id: the newest .ai-proposals/ses_*.jsonl journal across
--- the SAME directories proposals are read from (proposals.all_dirs — cwd-
--- reachable + SCAN_ROOTS). The plugin writes one journal per opencode
--- session, project-locally (<project>/.ai-proposals/), so scanning the
--- nvim config dir alone misses it and hides the current session's accepted
--- rows as "foreign history".
--- @return string|nil
local function current_session()
	local best, best_mtime = nil, 0
	for d in pairs(proposals.all_dirs()) do
		for _, f in ipairs(vim.fn.glob(d .. "/ses_*.jsonl", false, true)) do
			local mtime = vim.fn.getftime(f)
			if mtime > best_mtime then
				best_mtime = mtime
				best = f
			end
		end
	end
	if not best then
		return nil
	end
	return best:match("ses_[%w-]+")
end

--- Coerce a proposal field to a number. The journal may store range fields
--- as strings (or other types); math.floor/string %d need real numbers.
--- @param v any
--- @param fallback number
--- @return number
local function num(v, fallback)
	local n = tonumber(v)
	if n == nil then
		return fallback
	end
	return n
end

--- Resolve a proposal path to absolute. Absolute paths pass through;
--- relative paths return "" — a sentinel every consumer treats as
--- unresolvable (filereadable("") is 0; the write path refuses it).
--- Joining a relative path to any root is how web/web copies were born.
--- @param p table
--- @return string  absolute path, or "" when the proposal path is relative
local function resolve_path(p)
	if p.path and p.path:sub(1, 1) == "/" then
		return p.path
	end
	return ""
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

--- Classify a proposal's state by comparing the proposal against the ACTUAL
--- file on disk: content first (bytes are truth), then mtime (context
--- staleness), then existence/op structure.
--- @param p table
--- @return string  "new" | "edit" | "rerun" | "delete" | "applied" | "rejected" | "superseded" | "mismatch"
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

	-- Superseded: an older revision of a target a newer row owns. Also a
	-- persisted status value, for any future explicit marking.
	if st == "superseded" then
		return "superseded"
	end

	local path = resolve_path(p)
	if path == "" then
		return "mismatch" -- legacy relative path: unresolvable, fail closed
	end
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

--- Newest revision candidate per (group + path): pending and accepted rows.
--- Several pending rows for one target in one group are revisions of a single
--- change — only the newest is actionable. Accepted rows count so a pending
--- row older than an APPLIED revision is obsolete too. Keyed WITHOUT the
--- session id: a re-emission from a fresh session (a "fresh pending set")
--- supersedes the old set on purpose.
--- @param items table[]
--- @return table<string, table>  key -> newest candidate
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

--- Is this pending row an older revision of its target? Derived, not
--- persisted: nothing is written when a row is skipped; if the newest row is
--- rejected, the older one becomes actionable again on the next refresh.
--- @param p table
--- @param newest table<string, table>
--- @return boolean
local function is_stale(p, newest)
	if (p.status or "pending") ~= "pending" then
		return false
	end
	local top = newest[(p.group or "misc") .. "\0" .. (p.path or "")]
	return top ~= nil and (top.ts or 0) > (p.ts or 0)
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
		superseded = "superseded",
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

--- @param sid string|nil
--- @return string
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

--- Display-order indices: groups ordered by their NEWEST proposal's time
--- (descending), proposals within a group newest-first — so the actionable
--- (newest) revision of a target always sits ABOVE its superseded siblings.
--- The comparator is TOTAL (path tiebreaker) — table.sort is unstable, and
--- equal timestamps would otherwise reorder rows between refreshes, moving
--- the cursor.
--- @param items table[]
--- @return number[]
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

--- Rows in DISPLAY order with group separators. Revision ordering is
--- derived here: a pending row with a newer pending or accepted sibling for
--- the same (group + path) renders as [superseded] and can never be applied.
--- The revision map is computed over ALL visible rows (one extra manifest
--- scan, cheap at this size) so a scope filter can never hide the newer row
--- and let the older one through.
--- @param items table[]
--- @return table[]
local function rows(items)
	local newest = newest_revisions(proposals.list_visible("all"))
	local order = display_order(items)
	local out = {}
	local last_group = nil
	for _, si in ipairs(order) do
		local p = items[si]
		local g = p.group or "misc"
		if g ~= last_group then
			last_group = g
			out[#out + 1] = { sep = g }
		end
		local st = row_state(p)
		if is_stale(p, newest) then
			st = "superseded"
		end
		-- Active rows color the marker too; applied/rejected/superseded
		-- keep the "> " visible (dim rows start at column 2).
		local col = 2
		if st ~= "applied" and st ~= "rejected" and st ~= "superseded" then
			col = 0
		end
		out[#out + 1] = {
			item = p,
			text = string.format(
				"%-12s %-9s [%-8s] %s  (s:%s · %s)",
				p._project or "?",
				p.operation,
				state_tag(st),
				p._rel or p.path,
				short_sid(p.sessionID),
				fmt_when(p.ts)
			),
			hl = hl_for(st),
			state = st,
			col = col,
		}
	end
	return out
end

--- CURRENT (left) vs AFTER (right) for the selected proposal.
--- For edit_range: LEFT = unified diff (- removed / + added, red/green),
--- RIGHT = the full file with the range applied (editable — da writes it).
--- For create/replace: LEFT = unified diff (disk vs proposed), RIGHT =
--- proposed content. Panes open at the first change; [ / ] jumps hunks.
--- @param p table
--- @return table
local function preview(p)
	local path = resolve_path(p)
	local is_delete = p.operation == "delete"
	local is_range = p.operation == "edit_range" and p.start_line ~= nil

	local cur_lines, after_lines
	local after_span -- 1-based inclusive line span of the added block
	local first_change -- diff line of the first change (create/replace rows)
	local first_added -- proposed-content line of the first added line

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
			local s = math.max(1, math.floor(num(p.start_line, 1)))
			local e = math.max(s, math.floor(num(p.end_line, s)))
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
			-- removed lines (-, red) and added lines (+, green).
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
			-- create/replace: LEFT = unified diff (disk vs proposed),
			-- RIGHT = proposed content. The change is visible at a glance
			-- and [ / ] jumps between hunks.
			after_lines = vim.split(p.content or "", "\n", { plain = true })
			if after_lines[#after_lines] == "" then
				table.remove(after_lines)
			end
			if #disk == 0 then
				cur_lines = {}
				for _, l in ipairs(after_lines) do
					cur_lines[#cur_lines + 1] = "+" .. l
				end
				first_change = 1
				first_added = 1
			else
				cur_lines, first_change, first_added = diff.build_diff(disk, after_lines)
			end
		end
	end

	-- Diff highlights: red = being deleted, green = being added.
	local left_hl, right_hl = {}, {}
	if is_range or first_change then
		for ln, l in ipairs(cur_lines or {}) do
			local prefix = l:sub(1, 1)
			if prefix == "-" then
				left_hl[ln] = "ManageRemove"
			elseif prefix == "+" then
				left_hl[ln] = "ManageAdd"
			end
		end
	end
	if after_span then
		for ln = after_span[1], after_span[2] do
			right_hl[ln] = "ManageAdd"
		end
	end

	local opdesc = p.operation
	if is_range then
		opdesc = string.format(
			"%s %d-%d",
			p.operation,
			num(p.start_line, 0),
			num(p.end_line, num(p.start_line, 0))
		)
	end
	local what = "proposal content"
	if is_delete then
		what = "moved to _old"
	elseif is_range then
		what = "range applied"
	end

	-- Position: open both panes at the first change (diff rows) or the
	-- added block (range rows); everything else starts at the top.
	-- The AFTER pane focuses the PROPOSED-content line (first_added), not
	-- the diff line — the two buffers have different line numbers.
	local left_focus = 1
	local right_focus = 1
	if is_range then
		right_focus = after_span and after_span[1] or 1
	elseif first_change then
		left_focus = first_change
		right_focus = first_added or first_change
	end

	return {
		left = {
			lines = cur_lines or { "" },
			name = "CURRENT: " .. p.path,
			ft = vim.filetype.match({ filename = p.path }) or "",
			modifiable = false,
			winbar = string.format("CURRENT %s  [%s]", p._rel or p.path, opdesc),
			hl = left_hl,
		},
		right = {
			lines = after_lines or { "" },
			name = "AFTER: " .. p.path,
			ft = vim.filetype.match({ filename = p.path }) or "",
			modifiable = true,
			winbar = string.format("AFTER — %s · da writes this  %s", what, p._rel or p.path),
			hl = right_hl,
		},
		focus = { left = left_focus, right = right_focus },
	}
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

--- @param target string
--- @return boolean
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
--- @param p table
--- @param h table  console handle
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

--- rr: re-evaluation path — the proposal predates file changes, so open the
--- file in origin and let the user re-ask the AI against current state.
--- Status unchanged; this is a context flag, not a verdict.
--- @param p table
--- @param h table  console handle
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

--- da: accept the selected proposal. Writes the RIGHT pane verbatim —
--- for edit_range that pane is the full file with the range applied, so
--- partials are safe. Rerun guard confirms before clobbering newer work.
--- Older revisions of a target are refused automatically (revision
--- ordering is an internal function — never the user's job to order rows).
--- @param p table
--- @param h table  console handle
local function accept_current(p, h)
	if not p then
		return
	end
	local st = h.state.row_info[h.state.idx] and h.state.row_info[h.state.idx].state
	if st == "applied" then
		vim.notify("ℹ️ Already applied: " .. p.path, vim.log.levels.INFO)
		return
	end
	if st == "superseded" then
		-- Derived, not persisted: nothing is written for the skip. Rejecting
		-- the newest row makes this one actionable again on the next refresh.
		vim.notify(
			string.format(
				"⏭ Skipped: %s is an older revision — the newest row for this " ..
					"target is the one that counts (ordering is automatic).",
				p._rel or p.path
			),
			vim.log.levels.WARN
		)
		return
	end
	if p.operation == "delete" then
		handle_delete(p)
	else
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
		local current = vim.api.nvim_buf_get_lines(h.state.after_buf, 0, -1, false)
		-- Baseline for the verdict: for edit_range it is the full after-content
		-- (never the replacement fragment); other ops keep proposal.content.
		local baseline = nil
		if p.operation == "edit_range" then
			baseline = after_content(p, resolve_path(p))
		end
		proposals.accept(p, table.concat(current, "\n"), baseline)
	end
	h.refresh()
end

--- dr: reject the selected proposal (status + verdict only).
--- @param p table
--- @param h table  console handle
local function reject_current(p, h)
	if not p then
		return
	end
	proposals.reject(p)
	h.refresh()
end

--- ga: apply the current group. Revision ordering is INTERNAL: per target
--- (group + path) only the NEWEST pending row applies; older pending
--- siblings are skipped as [superseded] (a derived state — nothing is
--- written for a skip; reject the newest and the older row becomes live
--- again). Staleness is computed from ALL visible rows, not the filtered
--- list, so a filtered view can never apply an older revision. Delete rows
--- still prompt; each row is computed against the file state at apply time.
--- @param p table
--- @param h table  console handle
local function apply_group(p, h)
	if not p then
		return
	end
	local group = p.group or "misc"
	local newest = newest_revisions(proposals.list_visible("all"))
	local applied, skipped, superseded = 0, 0, 0
	for _, it in ipairs(h.state.items) do
		if (it.group or "misc") == group then
			if row_state(it) == "applied" then
				skipped = skipped + 1
			elseif is_stale(it, newest) then
				superseded = superseded + 1
			elseif it.operation == "delete" then
				handle_delete(it)
			else
				local path = resolve_path(it)
				local content = after_content(it, path)
				-- Group-apply never edits: baseline == applied.
				proposals.accept(it, content, content)
				applied = applied + 1
			end
		end
	end
	h.refresh()
	vim.notify(
		string.format(
			"✅ Group %s: %d applied, %d already applied, %d superseded (older revisions skipped)",
			group,
			applied,
			skipped,
			superseded
		),
		vim.log.levels.INFO
	)
end

--- y: yank the proposal's state + content — paste into a session to ask
--- about it. Replaces the old copy+open (the open half is o's job).
--- @param p table
--- @param h table  console handle
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

--- c: CLEAN — purge accepted/rejected rows from the journals. Explicit
--- user action only; the verdicts already live in state.db, so the audit
--- trail survives the purge. Pending rows are never touched.
--- @param h table  console handle
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

--- f: cycle the scope filter ALL → SESSION → FILES → NEITHER → ALL.
--- Every press reports all four counts so the effect is visible even when
--- two scopes coincide (e.g. only one project has manifests).
--- @param h table  console handle
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

function M.open()
	console.open({
		name = "Review",
		layout = "pair",
		list = function()
			local out = {}
			local cur = current_session()
			for _, p in ipairs(proposals.list_visible(adapter.filter)) do
				if not bookmarks.is_bookmark(p) then
					-- Accepted rows from OTHER sessions are history, not review
					-- material — hidden by default (x shows the full history).
					if
						adapter.show_all_applied
						or p.status ~= "accepted"
						or not cur
						or not p.sessionID
						or p.sessionID == cur
					then
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
			accept = accept_current,
			reject = reject_current,
			group_apply = apply_group,
			open = open_in_origin,
			yank = yank_proposal,
			rerun = rerun_open,
		},
		keys = {
			{ key = "f", desc = "filter", fn = toggle_filter },
			{
				key = "x",
				desc = "show all applied",
				fn = function(h)
					adapter.show_all_applied = not adapter.show_all_applied
					h.refresh()
					vim.notify(
						"proposals: "
							.. (adapter.show_all_applied and "showing ALL applied history" or "hiding applied rows from other sessions"),
						vim.log.levels.INFO
					)
				end,
			},
			{ key = "c", desc = "clean resolved rows", fn = clean_resolved },
		},
		legend = function(h)
			local c = scope_counts()
			return string.format(
				"%s · %d rows · f: all=%d session=%d files=%d neither=%d · j/k gg/G [/] f r o/CR da dr rr ga y c x Q",
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
			return p.path .. "\0" .. (p._file or "") .. "\0" .. tostring(p.ts)
		end,
		scroll = "hunks",
		hunk_jump = function(delta, h)
			diff.jump_hunk(h.state, delta)
		end,
		right_editable = true,
	})
end

return M
