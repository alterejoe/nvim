-- /home/altjoe/.config/nvim/lua/opencode-manage/journal.lua FINAL
-- opencode-manage.journal — daemon-backed journal client.
-- The Go daemon (internal/handlers/journal.go) owns the journal: before-image
-- BLOBs + transition rows in manage.db, plus a git-committable
-- .ai-journal/journal.jsonl mirror. nvim is the apply surface — it calls
-- begin (capture the before-image, strictly before the write), writes the
-- file, then record. Revert-is-an-event lives daemon-side now.
-- This module PRESERVES the public API every writer/viewer already calls
-- (snapshot · record · list · groups · describe_target · preview_lines ·
-- peek_and_confirm · restore · restore_group · delete), so only the internals
-- change: HTTP over the daemon socket instead of files on disk.
-- API quirk kept for compatibility: snapshot(path) returns the SNAPSHOT ID
-- (a number) or nil when the file does not exist — callers use `snap ~= nil`
-- as the `existed` flag, exactly as before.
local M = {}

local socket = vim.fn.expand("~/.local/share/opencode-manage/manage.sock")
local binary = vim.env.MANAGE_BIN or vim.fn.expand("~/projects/opencode-manage/bin/manage")
local base_url = "http://localhost"

--- Spawn the daemon if its socket is absent; wait up to 3s.
--- @return boolean
local function ensure_daemon()
	if vim.fn.filereadable(socket) == 1 then
		return true
	end
	vim.fn.jobstart({ binary }, { detach = true, stdio = "ignore" })
	vim.wait(3000, function()
		return vim.fn.filereadable(socket) == 1
	end, 20)
	return vim.fn.filereadable(socket) == 1
end

--- POST/GET JSON over the daemon unix socket.
--- @param method string
--- @param path string
--- @param body table|nil
--- @return table|nil, string|nil  decoded body, error
local function request(method, path, body)
	if not ensure_daemon() then
		return nil, "manage daemon is unavailable"
	end
	local args = {
		"curl",
		"--silent",
		"--show-error",
		"--fail-with-body",
		"--unix-socket",
		socket,
		"-X",
		method,
		base_url .. path,
	}
	if body ~= nil then
		table.insert(args, "--header")
		table.insert(args, "Content-Type: application/json")
		table.insert(args, "--data-raw")
		table.insert(args, vim.json.encode(body))
	end
	local result = vim.system(args, { text = true }):wait()
	if result.code ~= 0 then
		return nil, result.stderr ~= "" and result.stderr or "daemon request failed"
	end
	if result.stdout == "" then
		return {}, nil
	end
	local ok, decoded = pcall(vim.json.decode, result.stdout)
	if not ok then
		return nil, "daemon returned invalid JSON"
	end
	return decoded, nil
end

--- The project root owning cwd's journal: nearest ancestor with .opencode or
--- .ai-journal, else cwd. Matches the old journal_dir() walk-up discovery.
--- @return string
local function project_root()
	local dir = vim.fn.getcwd()
	for _ = 1, 12 do
		if vim.fn.isdirectory(dir .. "/.opencode") == 1 or vim.fn.isdirectory(dir .. "/.ai-journal") == 1 then
			return dir
		end
		local parent = vim.fn.fnamemodify(dir, ":h")
		if parent == dir then
			break
		end
		dir = parent
	end
	return vim.fn.getcwd()
end

M.project_root = project_root

--- Normalize a daemon row to the entry shape the viewers/writers expect.
--- parent_ts carries the parent row id (review.lua renders "from <parent>").
--- @param r table
--- @return table
local function normalize(r)
	return {
		id = r.id,
		ts = r.ts,
		sessionID = r.session_id,
		group = r.group,
		project = r.project,
		path = r.path,
		op = r.op,
		existed = r.existed,
		snapshot_id = r.snapshot_id,
		moved_to = r.moved_to,
		parent_id = r.parent_id,
		parent_ts = r.parent_id,
		reason = r.reason,
		after_hash = r.after_hash,
		stale = r.stale,
	}
end

--- Capture the before-image (strictly before the write).
--- @param path string  absolute path
--- @return number|nil  snapshot id, or nil when the file does not exist
function M.snapshot(path)
	local data, err = request("POST", "/v1/journal/begin", { path = path })
	if not data then
		vim.notify("❌ journal begin failed: " .. tostring(err), vim.log.levels.ERROR)
		return nil
	end
	return data.snapshot_id
end

--- Record a transition. API fields map to the daemon wire shape:
--- `snapshot` -> snapshot_id, `parent_ts` -> parent_id.
--- @param entry table  { ts, path, group, op, snapshot, existed, moved_to, parent_ts, reason, sessionID, project }
--- @return table|nil  the inserted row
function M.record(entry)
	local data, err = request("POST", "/v1/journal/record", {
		ts = entry.ts,
		session_id = entry.sessionID,
		group = entry.group,
		project = entry.project or project_root(),
		path = entry.path,
		op = entry.op,
		existed = entry.existed == true,
		snapshot_id = entry.snapshot,
		moved_to = entry.moved_to or "",
		parent_id = entry.parent_ts,
		reason = entry.reason or "",
	})
	if not data then
		vim.notify("❌ journal record failed: " .. tostring(err), vim.log.levels.ERROR)
	end
	return data
end

--- The full timeline, NEWEST first — matching the proposals console order.
--- @return table[]
function M.list()
	local data, err = request("POST", "/v1/journal/list", { limit = 500 })
	if not data then
		return {}
	end
	local out = {}
	for _, r in ipairs(data.entries or {}) do
		out[#out + 1] = normalize(r)
	end
	return out
end

--- Distinct groups present in the journal (non-nil).
--- @return string[]
function M.groups()
	local seen, out = {}, {}
	for _, e in ipairs(M.list()) do
		if e.group and not seen[e.group] then
			seen[e.group] = true
			table.insert(out, e.group)
		end
	end
	return out
end

--- What will the file become if this entry is restored?
--- @param entry table
--- @return string
function M.describe_target(entry)
	if not entry then
		return "?"
	end
	if entry.op == "move" and entry.moved_to and entry.moved_to ~= "" then
		if vim.fn.filereadable(entry.moved_to) == 1 then
			return "moves back from _old/ (file restored)"
		end
		return "file already gone from _old/"
	end
	if entry.snapshot_id then
		return "restores snapshot (" .. tostring(entry.ts) .. ")"
	end
	if entry.existed == false then
		return "deletes the created file"
	end
	return "no restorable state"
end

--- CURRENT vs AFTER-RESTORE content, computed daemon-side (the before-image
--- lives in the DB — nvim never reads snapshot files).
--- @param entry table
--- @return table  { path, what, current = string[], after = string[], restorable = boolean }
function M.preview_lines(entry)
	local data, err = request("POST", "/v1/journal/preview", { id = entry and entry.id })
	if not data then
		return {
			path = (entry and entry.path) or "?",
			what = "preview unavailable: " .. tostring(err),
			current = {},
			after = {},
			restorable = false,
		}
	end
	return {
		path = data.path or (entry and entry.path) or "?",
		what = data.what or "?",
		current = data.current or {},
		after = data.after or {},
		restorable = data.restorable == true,
	}
end

--- Peek at what a restore will do (vsplit CURRENT vs AFTER). Confirm before
--- applying. Returns true only for the create-delete confirm path (the
--- vsplit path is preview-only and returns false so the user re-runs).
--- @param entry table
--- @return boolean
function M.peek_and_confirm(entry)
	if not entry or not entry.path then
		vim.notify("❌ Invalid journal entry", vim.log.levels.WARN)
		return false
	end
	local pl = M.preview_lines(entry)
	if pl.restorable and #pl.after > 0 then
		local buf = vim.api.nvim_create_buf(false, true)
		local lines = {
			"RESTORE: " .. entry.path,
			"→ " .. pl.what,
			"───────────────────────────",
			"CURRENT:",
		}
		for _, l in ipairs(pl.current) do
			table.insert(lines, "  " .. l)
		end
		table.insert(lines, "───────────────────────────")
		table.insert(lines, "AFTER RESTORE:")
		for _, l in ipairs(pl.after) do
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
		return false
	end
	if entry.existed == false then
		local choice = vim.fn.confirm("Restore will DELETE the created file:\n  " .. entry.path, "&Yes\n&No", 2)
		return choice == 1
	end
	vim.notify("❌ No restorable state for this entry", vim.log.levels.WARN)
	return false
end

--- Restore a single entry. With skip_peek the viewer pane already previews.
--- The revert is itself a journal event (recorded daemon-side).
--- @param entry table
--- @param skip_peek boolean|nil
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
		return
	end
	local data, err = request("POST", "/v1/journal/restore", {
		id = entry.id,
		session_id = entry.sessionID,
	})
	if not data then
		vim.notify("❌ Restore failed: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	if (data.restored or 0) == 0 then
		vim.notify("❌ Nothing to restore for this entry", vim.log.levels.WARN)
		return
	end
	vim.notify("↩️ Restored " .. entry.path .. " — revert recorded in journal", vim.log.levels.INFO)
end

--- Revert a whole change: every entry in the group (recorded as one revert
--- each, daemon-side). Project is resolved from the group's own entries.
--- @param group string
function M.restore_group(group)
	if not group or group == "" then
		vim.notify("❌ No group given", vim.log.levels.WARN)
		return
	end
	local project
	for _, e in ipairs(M.list()) do
		if e.group == group then
			project = e.project
			break
		end
	end
	if not project then
		vim.notify("ℹ️ No journal entries for group: " .. group, vim.log.levels.INFO)
		return
	end
	local data, err = request("POST", "/v1/journal/restore", { group = group, project = project })
	if not data then
		vim.notify("❌ Group revert failed: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	vim.notify(
		string.format("↩️ Group reverted: %s (%d files)", group, data.restored or 0),
		vim.log.levels.INFO
	)
end

--- Remove an entry AND its snapshot (unrecoverable). Confirms first.
--- @param entry table
function M.delete(entry)
	if not entry or not entry.id then
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
		2
	)
	if choice ~= 1 then
		vim.notify("Entry kept", vim.log.levels.INFO)
		return
	end
	local data, err = request("POST", "/v1/journal/delete", { id = entry.id })
	if not data then
		vim.notify("❌ Delete failed: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	vim.notify("🗑️ Journal entry removed: " .. (entry.path or "?"), vim.log.levels.INFO)
end

return M
