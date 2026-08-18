-- opencode-manage.journal — the safety net.
-- Snapshots every accepted change to .ai-journal/ BEFORE it lands, and
-- records the transition in journal.jsonl. Restore = copy the .orig back
-- (or delete, for created files; or move back, for _old moves).
-- No git. Plain copies + JSONL.
--
-- M1g: entries carry a `group`; restore_group reverts a whole change.
-- Revert-is-an-event: a restore snapshots the CURRENT state first and
-- records op="restore", so reverting the revert works.
-- Restore is never blind: preview_lines builds CURRENT vs AFTER-RESTORE
-- content, shown in the journal viewer (or peek_and_confirm for the
-- one-shot picker path).
-- CWD-proof: finds EVERY .ai-journal dir — walking up AND globbing down.

local M = {}

--- Find all .ai-journal directories: walk up from cwd (nearest first)
--- AND glob down two levels. Deduplicated.
--- @return string[]
local function journal_dirs()
	local dirs = {}
	local seen = {}

	local function add(d)
		if d and not seen[d] then
			seen[d] = true
			table.insert(dirs, d)
		end
	end

	local dir = vim.fn.getcwd()
	for _ = 1, 12 do
		local candidate = dir .. "/.ai-journal"
		if vim.fn.isdirectory(candidate) == 1 then
			add(candidate)
		end
		local parent = vim.fn.fnamemodify(dir, ":h")
		if parent == dir then
			break
		end
		dir = parent
	end

	for _, d in ipairs(vim.fn.glob(vim.fn.getcwd() .. "/.ai-journal", false, true)) do
		add(d)
	end
	for _, d in ipairs(vim.fn.glob(vim.fn.getcwd() .. "/*/.ai-journal", false, true)) do
		add(d)
	end
	for _, d in ipairs(vim.fn.glob(vim.fn.getcwd() .. "/*/*/.ai-journal", false, true)) do
		add(d)
	end

	return dirs
end

--- Prefer the nearest (first found) journal dir; fall back to cwd.
--- @return string
local function journal_dir()
	local dirs = journal_dirs()
	return dirs[1] or (vim.fn.getcwd() .. "/.ai-journal")
end

--- @return string
local function journal_file()
	return journal_dir() .. "/journal.jsonl"
end

--- Snapshot a file. No-op if the file doesn't exist.
--- @param path string  absolute path
--- @return string|nil  snapshot path, or nil if nothing to snapshot
function M.snapshot(path)
	if vim.fn.filereadable(path) ~= 1 then
		return nil
	end
	local ts = tostring(os.time() * 1000)
	local snap = journal_dir() .. "/" .. path:gsub("^/", "") .. ".snap/" .. ts .. ".orig"
	vim.fn.mkdir(vim.fn.fnamemodify(snap, ":h"), "p")
	local ok, err = vim.loop.fs_copyfile(path, snap)
	if not ok then
		vim.notify("❌ Snapshot failed: " .. tostring(err), vim.log.levels.ERROR)
		return nil
	end
	return snap
end

--- Append a journal entry.
--- @param entry table  { ts, path, group, op, snapshot, existed, parent_ts, reason, sessionID }
function M.record(entry)
	local file = journal_file()
	vim.fn.mkdir(journal_dir(), "p")
	local line = vim.json.encode(entry)
	local fd = vim.loop.fs_open(file, "a", 420)
	if fd then
		vim.loop.fs_write(fd, line .. "\n", -1)
		vim.loop.fs_close(fd)
	end
end

--- Read the full journal timeline (oldest first), from every journal dir.
--- @return table[]
function M.list()
	local out = {}
	for _, dir in ipairs(journal_dirs()) do
		local file = dir .. "/journal.jsonl"
		if vim.fn.filereadable(file) == 1 then
			local lines = vim.fn.readfile(file)
			for _, line in ipairs(lines) do
				if line ~= "" then
					local ok, entry = pcall(vim.json.decode, line)
					if ok and type(entry) == "table" then
						table.insert(out, entry)
					end
				end
			end
		end
	end
	return out
end

--- Distinct groups present in the journal (non-nil).
--- @return string[]
function M.groups()
	local seen = {}
	local out = {}
	for _, e in ipairs(M.list()) do
		if e.group and not seen[e.group] then
			seen[e.group] = true
			table.insert(out, e.group)
		end
	end
	return out
end

--- What will the file become if this entry is restored?
--- Returns a short one-line description of the target state.
--- @param entry table
--- @return string
function M.describe_target(entry)
	if not entry then
		return "?"
	end
	if entry.op == "move" and entry.moved_to then
		if vim.fn.filereadable(entry.moved_to) == 1 then
			return "moves back from _old/ (file restored)"
		end
		return "file already gone from _old/"
	end
	if entry.snapshot and vim.fn.filereadable(entry.snapshot) == 1 then
		return "restores snapshot (" .. tostring(entry.ts) .. ")"
	end
	if entry.existed == false then
		return "deletes the created file"
	end
	return "no restorable state"
end

--- The source file a restore will apply from (snapshot or _old file).
--- @param entry table
--- @return string|nil
local function restore_source(entry)
	if entry.op == "move" and entry.moved_to and vim.fn.filereadable(entry.moved_to) == 1 then
		return entry.moved_to
	end
	if entry.snapshot and vim.fn.filereadable(entry.snapshot) == 1 then
		return entry.snapshot
	end
	return nil
end

--- Build CURRENT vs AFTER-RESTORE content for an entry — the live journal
--- viewer renders this in its preview pane.
--- @param entry table
--- @return table  { path, what, current = string[], after = string[], restorable = boolean }
function M.preview_lines(entry)
	local out = {
		path = entry.path or "?",
		what = M.describe_target(entry),
		current = {},
		after = {},
		restorable = false,
	}
	local src = restore_source(entry)
	if entry.path and vim.fn.filereadable(entry.path) == 1 then
		out.current = vim.fn.readfile(entry.path)
	end
	if src then
		out.after = vim.fn.readfile(src)
		out.restorable = true
	elseif entry.existed == false then
		out.after = { "<file does not exist>" }
		out.restorable = true
	end
	return out
end

--- Peek at what a restore will do: show the target content (snapshot or
--- the _old file) so the revert is never blind. Confirm before applying.
--- @param entry table
--- @return boolean  true if the user confirmed
function M.peek_and_confirm(entry)
	if not entry or not entry.path then
		vim.notify("❌ Invalid journal entry", vim.log.levels.WARN)
		return false
	end

	local src = restore_source(entry)
	local what = M.describe_target(entry)
	if src then
		local cur = vim.fn.filereadable(entry.path) == 1 and vim.fn.readfile(entry.path) or {}
		local nxt = vim.fn.readfile(src)
		local buf = vim.api.nvim_create_buf(false, true)
		local lines = {}
		table.insert(lines, "RESTORE: " .. entry.path)
		table.insert(lines, "→ " .. what)
		table.insert(lines, "───────────────────────────")
		table.insert(lines, "CURRENT:")
		for _, l in ipairs(cur) do
			table.insert(lines, "  " .. l)
		end
		table.insert(lines, "───────────────────────────")
		table.insert(lines, "AFTER RESTORE:")
		for _, l in ipairs(nxt) do
			table.insert(lines, "  " .. l)
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = false
		vim.bo[buf].bufhidden = "wipe"
		vim.cmd("vsplit")
		vim.api.nvim_win_set_buf(0, buf)
		vim.wo[0].winbar = "RESTORE PREVIEW — q to close, then re-run restore to apply"
		vim.keymap.set("n", "q", function()
			vim.cmd("close!")
		end, { buffer = buf, nowait = true, noremap = true, silent = true })
		return false -- preview only; the user re-runs restore after reviewing
	end

	-- No content to peek (create-deletes): confirm directly
	if entry.existed == false then
		local choice = vim.fn.confirm("Restore will DELETE the created file:\n  " .. entry.path, "&Yes\n&No", 2)
		return choice == 1
	end
	vim.notify("❌ No restorable state for this entry", vim.log.levels.WARN)
	return false
end

--- Undo ONE transition on a file, depending on the entry's op.
--- Returns true if the file state changed.
--- @param entry table
--- @return boolean
local function undo_entry(entry)
	if entry.op == "move" and entry.moved_to then
		if vim.fn.filereadable(entry.moved_to) == 1 then
			vim.fn.mkdir(vim.fn.fnamemodify(entry.path, ":h"), "p")
			return vim.loop.fs_rename(entry.moved_to, entry.path) == true
		end
		return false
	end
	if entry.snapshot and vim.fn.filereadable(entry.snapshot) == 1 then
		return vim.loop.fs_copyfile(entry.snapshot, entry.path) == true
	end
	if entry.existed == false then
		if vim.fn.filereadable(entry.path) == 1 then
			vim.fn.delete(entry.path)
			return true
		end
	end
	return false
end

--- Restore a single entry. With skip_peek (the journal viewer already shows
--- the current-vs-after pane), a simple confirm is used instead of the
--- one-shot vsplit preview. The restore is itself a journal event.
--- @param entry table
--- @param skip_peek boolean|nil  true when the viewer pane already previews
function M.restore(entry, skip_peek)
	if not entry or not entry.path then
		vim.notify("❌ Invalid journal entry", vim.log.levels.WARN)
		return
	end

	if skip_peek then
		local choice = vim.fn.confirm(
			"Restore this entry?\n  " .. entry.path .. "\n  → " .. M.describe_target(entry),
			"&Yes\n&No",
			2
		)
		if choice ~= 1 then
			return
		end
	elseif not M.peek_and_confirm(entry) then
		return -- preview shown or cancelled; nothing applied
	end

	local current_snap = M.snapshot(entry.path)
	local restored = undo_entry(entry)
	if not restored then
		vim.notify("❌ Nothing to restore for this entry", vim.log.levels.WARN)
		return
	end

	M.record({
		ts = os.time() * 1000,
		path = entry.path,
		group = entry.group,
		op = "restore",
		snapshot = current_snap,
		existed = current_snap ~= nil,
		parent_ts = entry.ts,
		reason = "restored from " .. (entry.op or "?") .. " (" .. tostring(entry.ts) .. ")",
		sessionID = entry.sessionID,
	})
	vim.notify("↩️ Restored " .. entry.path .. " — revert recorded in journal", vim.log.levels.INFO)
end

--- Revert a whole change: undo every accepted entry in the group.
--- @param group string
function M.restore_group(group)
	if not group or group == "" then
		vim.notify("❌ No group given", vim.log.levels.WARN)
		return
	end
	local entries = M.list()
	local hits = {}
	for _, e in ipairs(entries) do
		if e.group == group then
			table.insert(hits, e)
		end
	end
	if #hits == 0 then
		vim.notify("ℹ️ No journal entries for group: " .. group, vim.log.levels.INFO)
		return
	end
	local ok_count = 0
	for _, e in ipairs(hits) do
		local current_snap = M.snapshot(e.path)
		if undo_entry(e) then
			ok_count = ok_count + 1
			M.record({
				ts = os.time() * 1000,
				path = e.path,
				group = e.group,
				op = "restore",
				snapshot = current_snap,
				existed = current_snap ~= nil,
				parent_ts = e.ts,
				reason = "group revert of " .. group,
				sessionID = e.sessionID,
			})
		end
	end
	vim.notify(string.format("↩️ Group reverted: %s (%d/%d files)", group, ok_count, #hits), vim.log.levels.INFO)
end

--- Remove an entry from the journal by its ts (rewrites the JSONL).
--- Also removes its snapshot file, if any. CONFIRMS first.
--- @param entry table
function M.delete(entry)
	if not entry or not entry.ts then
		vim.notify("❌ Invalid journal entry", vim.log.levels.WARN)
		return
	end
	local choice = vim.fn.confirm(
		"Delete journal entry?\n  "
			.. (entry.path or "?")
			.. " ("
			.. (entry.op or "?")
			.. ", "
			.. tostring(entry.ts)
			.. ")\n\n"
			.. "Removes the entry AND its snapshot — unrecoverable.",
		"&Yes\n&No",
		2 -- default to No
	)
	if choice ~= 1 then
		vim.notify("Entry kept", vim.log.levels.INFO)
		return
	end
	local file = journal_file()
	if vim.fn.filereadable(file) ~= 1 then
		return
	end
	local lines = vim.fn.readfile(file)
	local kept = {}
	local removed = false
	for _, line in ipairs(lines) do
		if line ~= "" then
			local ok, e = pcall(vim.json.decode, line)
			if ok and type(e) == "table" and e.ts == entry.ts then
				removed = true
			else
				table.insert(kept, line)
			end
		end
	end
	if removed then
		vim.fn.writefile(kept, file)
		if entry.snapshot and vim.fn.filereadable(entry.snapshot) == 1 then
			vim.fn.delete(entry.snapshot)
		end
		vim.notify("🗑️ Journal entry removed: " .. (entry.path or "?"), vim.log.levels.INFO)
	else
		vim.notify("ℹ️ Entry not found (already removed?)", vim.log.levels.INFO)
	end
end

return M
