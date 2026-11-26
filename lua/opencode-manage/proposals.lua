-- /home/jmeyer/.config/nvim/lua/opencode-manage/proposals.lua FINAL-3
-- opencode-manage.proposals — the review data.
-- Reads .ai-proposals/*.jsonl (written by the opencode manage plugin),
-- accepts (snapshot → write → record → status), rejects, and "deletes"
-- (snapshot → MOVE to <dir>/_old/ → record → status) proposals.
-- No files are ever permanently deleted — they go to _old/ next to them,
-- which is reversible and auditable.
-- The JSONL is ground truth: schema-valid tool-call args, never parsed prose.
-- T2 (10-verdict-capture.md): every accept/reject/move writes a verdict to
-- the shared SQLite store automatically — accepted | corrected (edited
-- before da) | rejected | moved_old. The correction diff is recoverable
-- from proposed_content vs applied_content.
-- PATH VALIDATION (doc 21): the apply side FAILS CLOSED. Only absolute
-- proposal paths apply; update ops (replace/edit_range/delete) require a
-- readable target and are refused otherwise. Only create may create a
-- missing parent chain, and only after an explicit y/n (default No) — the
-- emit side records the chain as `mkdirs`, and the apply side recomputes it
-- when absent so legacy rows are covered too. Directories are never created
-- silently.
-- A relative path is refused with a loud message — joining it to any root
-- is how web/web copies were born. The emit side enforces the same rules
-- (lib/proposals.ts validateProposalTarget).
-- DELIMITER GUARD: edit_range accepts on .ts/.tsx/.js/.lua files with grossly
-- unbalanced braces/parens warn with a confirm gate — an unbalanced apply can
-- break a file (or a plugin) at load. Heuristic: strings and comments can
-- false-positive, so it asks, never silently refuses (default is No).
-- Two per-proposal cwd predicates drive the viewer's 4-state filter:
--   _cwd       = the proposal's manifest dir is reachable from cwd
--                ("session in the cwd" — walk-up + glob-down discovery)
--   _cwd_file  = the AFFECTED FILE's absolute path is inside the cwd
-- Discovery scopes:
--   ALL      = cwd-reachable .ai-proposals + SCAN_ROOTS (project roots)
--   SESSION  = _cwd
--   FILES    = _cwd_file
--   NEITHER  = not _cwd and not _cwd_file (foreign session AND foreign file)
-- VISIBLE = pending + accepted (accepted rows stay in the viewer marked
-- [applied], so the review history is never a mystery).
-- Resolved rows are purged ONLY by explicit user action (M.purge_resolved,
-- `c` in the review console) — never automatically.
-- All iteration is DETERMINISTIC (sorted dirs) — the item order never
-- reshuffles between refreshes.
-- Each proposal also carries _file/_line (in-place status updates) and
-- _project/_rel (display metadata).
-- MALFORMED-LINE GUARD: a jsonl line that decodes to a table without a
-- `path` field is SKIPPED (warned once per file), not fatal — one bad
-- line must never take the whole viewer down.

local journal = require("opencode-manage.journal")
local verdicts = require("opencode-manage.verdicts")

local M = {}

-- Roots scanned for the "all sessions" view. Each is globbed for
-- */.ai-proposals — one level deep, cheap at viewer open.
local SCAN_ROOTS = {
	vim.env.HOME .. "/projects",
	vim.env.HOME .. "/docs",
}

--- .ai-proposals dirs reachable from cwd: walk up 12 levels + glob down 2.
--- @return table<string, boolean> dir -> true
local function cwd_dirs()
	local dirs = {}
	local dir = vim.fn.getcwd()
	for _ = 1, 12 do
		local candidate = dir .. "/.ai-proposals"
		if vim.fn.isdirectory(candidate) == 1 then
			dirs[candidate] = true
		end
		local parent = vim.fn.fnamemodify(dir, ":h")
		if parent == dir then
			break
		end
		dir = parent
	end
	for _, d in ipairs(vim.fn.glob(vim.fn.getcwd() .. "/.ai-proposals", false, true)) do
		dirs[d] = true
	end
	for _, d in ipairs(vim.fn.glob(vim.fn.getcwd() .. "/*/.ai-proposals", false, true)) do
		dirs[d] = true
	end
	for _, d in ipairs(vim.fn.glob(vim.fn.getcwd() .. "/*/*/.ai-proposals", false, true)) do
		dirs[d] = true
	end
	return dirs
end

--- Every .ai-proposals dir: cwd-reachable plus SCAN_ROOTS. Value = whether
--- the dir is cwd-reachable (the SESSION predicate).
--- @return table<string, boolean>
local session = require("opencode-manage.session")

--- Legacy queues: cwd-reachable plus SCAN_ROOTS. Their only remaining job is the
--- fallback session scan; the reader still lists them during the migration.
local function legacy_dirs()
	local dirs = cwd_dirs()
	for _, root in ipairs(SCAN_ROOTS) do
		for _, d in ipairs(vim.fn.glob(root .. "/*/.ai-proposals", false, true)) do
			dirs[d] = dirs[d] or false
		end
	end
	return dirs
end

M.current_session = function()
	return session.current_session(legacy_dirs)
end

M.session_store_dir = function()
	local id = M.current_session()
	if not id then
		return nil
	end
	return session.store_root() .. "/" .. id
end

--- The dirs the console reads: the stores of the sessions this tmux session is
--- running — and, when no pointer resolves yet, every session store on the
--- machine.
---
--- The pointer is written on the first tool call, so a cold nvim has none. The
--- console must not render empty because of that: a session store is still the
--- truth, and a directory guess never is. Legacy queues remain the last resort.
--- @return table<string, boolean>
local function all_dirs()
	local dirs = {}
	for _, id in ipairs(session.session_ids(legacy_dirs)) do
		dirs[session.store_root() .. "/" .. id] = true
	end
	if next(dirs) then
		return dirs
	end

	for _, d in ipairs(vim.fn.glob(session.store_root() .. "/*", false, true)) do
		if vim.fn.isdirectory(d) == 1 then
			dirs[d] = true
		end
	end
	if next(dirs) then
		return dirs
	end

	return legacy_dirs()
end

--- Exported for consumers that need the same discovery (e.g. the review
--- console's current_session): every .ai-proposals dir, cwd-reachable or
--- under SCAN_ROOTS.
M.all_dirs = all_dirs

--- Read every proposal from every jsonl in every .ai-proposals dir.
--- Each proposal carries _file and _line so accept/reject can update in
--- place, plus filter/display metadata: _cwd, _cwd_file, _project, _rel.
--- Dirs are iterated SORTED — pairs() on a hash table is unspecified and
--- could reorder rows between refreshes (moving the viewer cursor).
--- Lines that decode to a table WITHOUT a usable `path` are skipped and
--- warned once per file — they are partial/corrupt emissions and must not
--- crash the viewer.
--- @return table[]
function M.list_all()
	local out = {}
	local cwd = vim.fn.getcwd()
	local dirs = all_dirs()
	local dir_list = {}
	for d in pairs(dirs) do
		dir_list[#dir_list + 1] = d
	end
	table.sort(dir_list)
	local warned = {}
	for _, dir in ipairs(dir_list) do
		local cwd_reachable = dirs[dir]
		local project_root = vim.fn.fnamemodify(dir, ":h")
		for _, f in ipairs(vim.fn.glob(dir .. "/*.jsonl", false, true)) do
			local lines = vim.fn.readfile(f)
			for li, line in ipairs(lines) do
				if line ~= "" then
					local ok, p = pcall(vim.json.decode, line)
					if ok and type(p) == "table" then
						if type(p.path) ~= "string" or p.path == "" then
							-- Malformed/partial line: warn once per file, skip
							if not warned[f] then
								warned[f] = true
								vim.notify(
									string.format("⚠️ Skipping malformed proposal line %d in %s (no path)", li, f),
									vim.log.levels.WARN
								)
							end
						else
							p._file = f
							p._line = li
							p._cwd = cwd_reachable
							p._project = vim.fn.fnamemodify(project_root, ":t")
							local abs = p.path
							if abs:sub(1, 1) ~= "/" then
								abs = project_root .. "/" .. abs
							end
							p._rel = abs:gsub("^" .. vim.pesc(project_root .. "/"), "")
							p._cwd_file = abs == cwd or abs:sub(1, #cwd + 1) == cwd .. "/"
							table.insert(out, p)
						end
					end
				end
			end
		end
	end
	return out
end

--- Apply a scope filter to a decoded proposal.
--- @param p table
--- @param mode string|nil  "all" | "session" | "files" | "neither"
--- @return boolean
local function in_scope(p, mode)
	if mode == "session" then
		return p._cwd
	elseif mode == "files" then
		return p._cwd_file
	elseif mode == "neither" then
		return not p._cwd and not p._cwd_file
	end
	return true
end

--- Proposals still waiting for a decision, in one of the four scopes.
--- @param mode string|nil  "all" | "session" | "files" | "neither" (nil = all)
--- @return table[]
function M.list_pending(mode)
	local out = {}
	for _, p in ipairs(M.list_all()) do
		if p.status == "pending" and in_scope(p, mode) then
			table.insert(out, p)
		end
	end
	return out
end

--- Visible proposals: pending + accepted (accepted stay in the viewer so
--- the review history is explicit — marked [applied] by row_state).
--- @param mode string|nil  scope filter (see in_scope)
--- @return table[]
function M.list_visible(mode)
	local out = {}
	for _, p in ipairs(M.list_all()) do
		local st = p.status or "pending"
		if (st == "pending" or st == "accepted") and in_scope(p, mode) then
			table.insert(out, p)
		end
	end
	return out
end

--- Purge resolved rows (accepted/rejected) from the journal files, in
--- place. Verdicts already live in state.db (T2 capture), so the audit
--- trail survives even though the journal rows are removed. Pending rows
--- are never touched. Line numbers are collected per file and removed
--- descending so earlier removals never shift later ones.
--- @return number  rows removed
function M.purge_resolved()
	local by_file = {}
	for _, p in ipairs(M.list_all()) do
		local st = p.status or "pending"
		if (st == "accepted" or st == "rejected") and p._file and p._line then
			by_file[p._file] = by_file[p._file] or {}
			table.insert(by_file[p._file], p._line)
		end
	end
	local removed = 0
	for f, lines in pairs(by_file) do
		table.sort(lines, function(a, b)
			return a > b
		end)
		local content = vim.fn.readfile(f)
		for _, ln in ipairs(lines) do
			table.remove(content, ln)
		end
		vim.fn.writefile(content, f)
		removed = removed + #lines
	end
	return removed
end

--- Resolve a proposal path to absolute, FAIL CLOSED (doc 21): only absolute
--- paths resolve. Relative paths return nil and every write path refuses
--- them with a visible message — joining it to any root is how the
--- web/web copies were born.
--- @param proposal table
--- @return string|nil
local function resolve_path(proposal)
	if type(proposal.path) == "string" and proposal.path:sub(1, 1) == "/" then
		return proposal.path
	end
	return nil
end

--- Refuse helper: visible, loud, never writes.
--- @param proposal table
--- @param action string
--- @return boolean  always false
local function refuse(proposal, action)
	vim.notify(
		string.format(
			"❌ Refused to %s: non-absolute proposal path (legacy entry):\n  %s\n  Re-emit with an absolute path.",
			action,
			tostring(proposal.path)
		),
		vim.log.levels.ERROR
	)
	return false
end

--- Update a proposal's status field in its jsonl (in place).
--- @param proposal table
--- @param status string  "accepted" | "rejected"
function M.set_status(proposal, status)
	if not proposal._file then
		return
	end
	local lines = vim.fn.readfile(proposal._file)
	local ok, obj = pcall(vim.json.decode, lines[proposal._line] or "")
	if ok and type(obj) == "table" then
		obj.status = status
		lines[proposal._line] = vim.json.encode(obj)
		vim.fn.writefile(lines, proposal._file)
	end
end

--- Accept a proposal: snapshot → write → journal → verdict → status flip.
--- The write is a USER-initiated action from nvim, never the AI.
--- Fail closed (doc 21): absolute path required; update ops require a
--- readable target; create may create a missing parent chain only after the
--- y/n prompt (default No).
--- T2: editing the buffer before accepting makes the verdict `corrected` —
--- the diff between INTENDED and applied content is the structural fact.
--- @param proposal table
--- @param content_override string|nil  use this instead of proposal.content
---   (the user may have edited the proposed content before accepting)
--- @param baseline_override string|nil  the full content the proposal intended
---   to produce. For edit_range this is the after-content, NOT the replacement
---   fragment — fragment-vs-file comparisons flagged every accept as corrected.
--- @return boolean  true when written
function M.accept(proposal, content_override, baseline_override)
	-- A group marked do-not-apply cannot be applied.
	if proposal.operation ~= "mark-proposals" and proposal.operation ~= "reject-proposals" then
		for _, mp in ipairs(M.list_all()) do
			if (mp.status or "pending") ~= "rejected" and mp.operation == "mark-proposals" then
				local ok, spec = pcall(vim.json.decode, mp.content or "")
				if ok and type(spec) == "table" and spec.mark == "do-not-apply"
					and (mp.group or "misc") == (proposal.group or "misc") then
					vim.notify("⛔ Refused: group marked do-not-apply — " .. tostring(mp.reason), vim.log.levels.ERROR)
					return false
				end
			end
		end
	end
	-- Directory move: one row, one rename. Never expanded into per-file
	-- creates/deletes, and never routed through _old — the content is
	-- preserved exactly, only its location changes.
	-- Rename: one row, one in-place change. The body and zettel id are
	-- identity; only the title, slug, and path move. The daemon has already
	-- updated referrer links; the row carries a human-readable reason.
	if proposal.operation == "rename" then
		local src = resolve_path(proposal)
		if not src then
			return refuse(proposal, "rename")
		end
		local okjson, spec = pcall(vim.json.decode, proposal.content or "")
		if not okjson or type(spec) ~= "table" then
			vim.notify("❌ Refused: rename content is not valid JSON", vim.log.levels.ERROR)
			return false
		end
		local dst = tostring(spec.target or "")
		if dst:sub(1, 1) ~= "/" then
			vim.notify("❌ Refused: rename target must be absolute: " .. dst, vim.log.levels.ERROR)
			return false
		end
		if vim.fn.filereadable(src) ~= 1 then
			vim.notify("❌ Refused: rename source is not readable: " .. src, vim.log.levels.ERROR)
			return false
		end
		if vim.fn.filereadable(dst) == 1 or vim.fn.isdirectory(dst) == 1 then
			vim.notify("❌ Refused: rename target already exists: " .. dst, vim.log.levels.ERROR)
			return false
		end
		local snap = journal.snapshot(src)
		local lines = vim.split(tostring(spec.content or ""), "\n", { plain = true })
		if lines[#lines] == "" then
			table.remove(lines)
		end
		vim.fn.mkdir(vim.fn.fnamemodify(dst, ":h"), "p")
		vim.fn.writefile(lines, dst)
		vim.loop.fs_unlink(src)
		journal.record({
			ts = proposal.ts,
			path = src,
			group = proposal.group,
			op = "rename",
			snapshot = snap,
			moved_to = dst,
			existed = true,
			reason = proposal.reason,
			sessionID = proposal.sessionID,
		})
		verdicts.record({
			ts = os.time() * 1000,
			session_id = proposal.sessionID,
			proposal_id = proposal.ts,
			group_name = proposal.group,
			path = src,
			operation = proposal.operation,
			verdict = "accepted",
			reason = proposal.reason,
			proposed_content = dst,
			applied_content = dst,
		})
		M.set_status(proposal, "accepted")
		vim.notify("✏️ Renamed: " .. src .. " → " .. dst, vim.log.levels.INFO)
		return true
	end

	-- Directory move: one row, one rename. Never expanded into per-file
	if proposal.operation == "move" then
		local src = resolve_path(proposal)
		if not src then
			return refuse(proposal, "move")
		end
		local dst = tostring(proposal.content or "")
		if dst:sub(1, 1) ~= "/" then
			vim.notify("❌ Refused: move destination must be absolute: " .. dst, vim.log.levels.ERROR)
			return false
		end
		if vim.fn.isdirectory(src) ~= 1 then
			vim.notify("❌ Refused: move source is not a directory: " .. src, vim.log.levels.ERROR)
			return false
		end
		if vim.fn.isdirectory(dst) == 1 or vim.fn.filereadable(dst) == 1 then
			vim.notify("❌ Refused: move target already exists: " .. dst, vim.log.levels.ERROR)
			return false
		end
		vim.fn.mkdir(vim.fn.fnamemodify(dst, ":h"), "p")
		local ok, err = vim.loop.fs_rename(src, dst)
		if not ok then
			vim.notify("❌ Move failed: " .. tostring(err), vim.log.levels.ERROR)
			return false
		end
		journal.record({
			ts = proposal.ts,
			path = src,
			group = proposal.group,
			op = "move",
			snapshot = nil,
			moved_to = dst,
			existed = true,
			reason = proposal.reason,
			sessionID = proposal.sessionID,
		})
		verdicts.record({
			ts = os.time() * 1000,
			session_id = proposal.sessionID,
			proposal_id = proposal.ts,
			group_name = proposal.group,
			path = src,
			operation = proposal.operation,
			verdict = "accepted",
			reason = proposal.reason,
			proposed_content = dst,
			applied_content = dst,
		})
		M.set_status(proposal, "accepted")
		vim.notify("📦 Moved: " .. src .. " → " .. dst, vim.log.levels.INFO)
		return true
	end

	-- Folder-approval proposals are not file changes: accepting them
	-- approves the folder in state.db (folders table) and flips status.
	if proposal.operation == "folder-approve" then
		local folders = require("opencode-manage.folders")
		local ok = folders.approve(proposal.path, "project", proposal.reason)
		if not ok then
			vim.notify("folder-approve failed: " .. (proposal.path or "?"), vim.log.levels.ERROR)
			return false
		end
		verdicts.record({
			ts = os.time() * 1000,
			session_id = proposal.sessionID,
			proposal_id = proposal.ts,
			group_name = proposal.group,
			path = proposal.path,
			operation = proposal.operation,
			verdict = "accepted",
			reason = proposal.reason,
			proposed_content = proposal.content,
			applied_content = nil,
		})
		M.set_status(proposal, "accepted")
		vim.notify("🔐 folder approved: " .. proposal.path, vim.log.levels.INFO)
		return true
	end

	-- Goal suggestions are not file changes: accepting them applies the
	-- suggestion through the goals adapter (daemon apply endpoint).
	if proposal.operation == "goal-suggest" then
		local goals = require("opencode-manage.goals")
		local id = tonumber(proposal.path)
		if not id then
			vim.notify("goal-suggest: missing suggestion id in path", vim.log.levels.ERROR)
			return false
		end
		local ok, err = goals.accept_suggestion(id)
		if not ok then
			vim.notify("goal-suggest apply failed: " .. tostring(err), vim.log.levels.ERROR)
			return false
		end
		verdicts.record({
			ts = os.time() * 1000,
			session_id = proposal.sessionID,
			proposal_id = proposal.ts,
			group_name = proposal.group,
			path = proposal.path,
			operation = proposal.operation,
			verdict = "accepted",
			reason = proposal.reason,
			proposed_content = proposal.content,
			applied_content = nil,
		})
		M.set_status(proposal, "accepted")
		vim.notify("🎯 goal suggestion accepted: #" .. tostring(id), vim.log.levels.INFO)
		return true
	end
	-- Rejection proposals are not file changes: applying one marks the
	-- selected pending proposals rejected (a verdict per row) and flips
	-- this row accepted. Dismissing it leaves everything untouched.
	if proposal.operation == "reject-proposals" then
		local ok, sel = pcall(vim.json.decode, proposal.content or "")
		if not ok or type(sel) ~= "table" then
			vim.notify("reject-proposals: content is not valid JSON", vim.log.levels.ERROR)
			return false
		end
		local group = sel.group or ""
		local paths = {}
		for _, tp in ipairs(sel.paths or {}) do
			paths[tp] = true
		end
		local n = 0
		for _, t in ipairs(M.list_all()) do
			if
				(t.status or "pending") == "pending"
				and ((group ~= "" and (t.group or "misc") == group) or paths[t.path])
			then
				M.set_status(t, "rejected")
				verdicts.record({
					ts = os.time() * 1000,
					session_id = t.sessionID,
					proposal_id = t.ts,
					group_name = t.group,
					path = resolve_path(t),
					operation = t.operation,
					verdict = "rejected",
					reason = proposal.reason,
					proposed_content = t.content,
					applied_content = nil,
				})
				n = n + 1
			end
		end
		M.set_status(proposal, "accepted")
		vim.notify(
			string.format("🤖 Rejection applied: %d proposal(s) — %s", n, proposal.reason or ""),
			vim.log.levels.INFO
		)
		return true
	end

	-- Mark rows are metadata only: never a file write.
	if proposal.operation == "mark-proposals" then
		M.set_status(proposal, "accepted")
		vim.notify("🏷 Marked: " .. tostring(proposal.reason), vim.log.levels.INFO)
		return true
	end

	local path = resolve_path(proposal)
	if not path then
		return refuse(proposal, "accept")
	end
	local op = proposal.operation or "replace"
	local exists = vim.fn.filereadable(path) == 1
	if op == "create" then
		if exists then
			vim.notify(
				"❌ Refused: create target already exists:\n  " .. path .. "\n  Use replace/edit_range instead.",
				vim.log.levels.ERROR
			)
			return false
		end
		local parent = vim.fn.fnamemodify(path, ":h")
		if vim.fn.isdirectory(parent) ~= 1 then
			-- New directories need explicit consent: list `mkdirs` (recorded
			-- by the emit side) or recompute for legacy rows, then ask y/n.
			-- Default No — nothing is created or written without a Yes.
			local dirs = type(proposal.mkdirs) == "table" and proposal.mkdirs or {}
			if #dirs == 0 then
				local d = parent
				while vim.fn.isdirectory(d) ~= 1 do
					table.insert(dirs, 1, d)
					local up = vim.fn.fnamemodify(d, ":h")
					if up == d then
						break
					end
					d = up
				end
			end
			local choice = vim.fn.confirm(
				"New directories needed by this create:\n  "
					.. table.concat(dirs, "\n  ")
					.. "\n\nCreate them and write the file?",
				"&No\n&Yes",
				1
			)
			if choice ~= 2 then
				vim.notify("❌ Cancelled — no directory created, nothing written", vim.log.levels.WARN)
				return false
			end
			vim.fn.mkdir(parent, "p")
		end
	else
		if not exists then
			vim.notify(
				"❌ Refused: "
					.. op
					.. " target is not readable:\n  "
					.. path
					.. "\n  Update ops never create files — re-emit as 'create' if that was intended.",
				vim.log.levels.ERROR
			)
			return false
		end
	end

	local snap = journal.snapshot(path)

	local content = content_override or proposal.content or ""
	-- Delimiter balance guard (doc 21 follow-up): an edit_range that leaves
	-- braces/parens unbalanced can kill a plugin at load — that is not
	-- hypothetical, it happened. Strings and comments can false-positive
	-- here, so this warns with a confirm gate instead of hard-blocking.
	if op == "edit_range" then
		local ext = vim.fn.fnamemodify(path, ":e"):lower()
		if ext == "ts" or ext == "tsx" or ext == "js" or ext == "lua" then
			local depth = 0
			for ch in content:gmatch("[%{%(}%)]") do
				if ch == "\123" or ch == "\40" then
					depth = depth + 1
				else
					depth = depth - 1
				end
			end
			if depth ~= 0 then
				local choice = vim.fn.confirm(
					string.format(
						"⚠️ Delimiter balance is off (%+d) after this edit:\n  %s\n\nAn unbalanced apply can kill the plugin at load. Apply anyway?",
						depth,
						path
					),
					"&No\n&Yes",
					1
				)
				if choice ~= 2 then
					vim.notify("❌ Refused: unbalanced edit — review the range and re-emit", vim.log.levels.WARN)
					return false
				end
			end
		end
	end
	local lines = vim.split(content, "\n", { plain = true })
	if lines[#lines] == "" then
		table.remove(lines) -- writefile adds the trailing newline itself
	end
	vim.fn.writefile(lines, path)

	journal.record({
		ts = proposal.ts,
		path = path,
		group = proposal.group,
		op = proposal.operation,
		snapshot = snap,
		existed = snap ~= nil,
		reason = proposal.reason,
		sessionID = proposal.sessionID,
	})

	-- T2 verdict capture
	local verdict = "accepted"
	-- Trailing whitespace/newlines are not corrections, and edit_range
	-- baselines are full files — compare applied content against the intended
	-- baseline, normalized.
	local function norm_content(s)
		return (s or ""):gsub("%s+$", "")
	end
	local baseline = baseline_override or proposal.content
	if content_override and norm_content(content_override) ~= norm_content(baseline) then
		verdict = "corrected"
	end
	verdicts.record({
		ts = os.time() * 1000,
		session_id = proposal.sessionID,
		proposal_id = proposal.ts,
		group_name = proposal.group,
		path = path,
		operation = proposal.operation,
		verdict = verdict,
		reason = proposal.reason,
		proposed_content = baseline,
		applied_content = content,
	})
	verdicts.promote_if_cross_project(path, verdict)

	M.set_status(proposal, "accepted")
	vim.notify("✅ Accepted: " .. path, vim.log.levels.INFO)
	return true
end

--- Snapshot a file WITHOUT writing — the manual `y` path. Records a journal
--- entry so even copy-paste changes are revertible (the airlock covers
--- every way a file changes, not just `da`). Fails closed on relative paths.
--- @param proposal table
--- @return string|nil  snapshot path
function M.snapshot_only(proposal)
	local path = resolve_path(proposal)
	if not path then
		refuse(proposal, "snapshot")
		return nil
	end
	local snap = journal.snapshot(path)
	journal.record({
		ts = proposal.ts,
		path = path,
		group = proposal.group,
		op = "manual",
		snapshot = snap,
		existed = snap ~= nil,
		reason = "manual copy (y) — not yet written",
		sessionID = proposal.sessionID,
	})
	return snap
end

--- "Delete" a file: snapshot then MOVE it to <dir>/_old/<basename>.
--- Never permanently deletes — reversible and auditable.
--- The move is a USER-initiated action from nvim, never the AI.
--- Fails closed on relative paths.
--- @param proposal table
--- @return string|nil  the _old destination path, or nil if nothing moved
function M.move_to_old(proposal)
	local path = resolve_path(proposal)
	if not path then
		refuse(proposal, "move to _old")
		return nil
	end
	if vim.fn.filereadable(path) ~= 1 then
		vim.notify("ℹ️ File already gone: " .. path, vim.log.levels.INFO)
		M.set_status(proposal, "accepted")
		return nil
	end

	-- snapshot for reversibility
	local snap = journal.snapshot(path)

	-- destination: <dir>/_old/<basename>
	local parent = vim.fn.fnamemodify(path, ":h")
	local old_dir = parent .. "/_old"
	local basename = vim.fn.fnamemodify(path, ":t")
	vim.fn.mkdir(old_dir, "p")
	local dest = old_dir .. "/" .. basename
	if vim.fn.filereadable(dest) == 1 then
		-- avoid clobbering: suffix with a timestamp
		dest = old_dir .. "/" .. basename .. "." .. tostring(os.time())
	end

	local ok, err = vim.loop.fs_rename(path, dest)
	if not ok then
		vim.notify("❌ Move to _old failed: " .. tostring(err), vim.log.levels.ERROR)
		return nil
	end

	journal.record({
		ts = proposal.ts,
		path = path,
		group = proposal.group,
		op = "move",
		snapshot = snap,
		moved_to = dest,
		existed = true,
		reason = proposal.reason,
		sessionID = proposal.sessionID,
	})

	-- T2 verdict capture
	verdicts.record({
		ts = os.time() * 1000,
		session_id = proposal.sessionID,
		proposal_id = proposal.ts,
		group_name = proposal.group,
		path = path,
		operation = proposal.operation,
		verdict = "moved_old",
		reason = proposal.reason,
		proposed_content = proposal.content,
		applied_content = nil,
	})
	verdicts.promote_if_cross_project(path, "moved_old")

	M.set_status(proposal, "accepted")
	vim.notify("📦 Moved to _old: " .. path .. " → " .. dest, vim.log.levels.INFO)
	return dest
end

--- Reject a proposal: status flip + verdict. Nothing written. Rejection is
--- allowed for legacy relative rows too — it clears them from the queue.
--- @param proposal table
function M.reject(proposal, quiet)
	M.set_status(proposal, "rejected")

	-- T2 verdict capture
	local path = resolve_path(proposal) -- nil for legacy relative entries
	verdicts.record({
		ts = os.time() * 1000,
		session_id = proposal.sessionID,
		proposal_id = proposal.ts,
		group_name = proposal.group,
		path = path,
		operation = proposal.operation,
		verdict = "rejected",
		reason = proposal.reason,
		proposed_content = proposal.content,
		applied_content = nil,
	})
	if path then
		verdicts.promote_if_cross_project(path, "rejected")
	end

	if not quiet then
		vim.notify("❌ Rejected: " .. proposal.path, vim.log.levels.INFO)
	end
end

--- Reject every pending proposal in a group. Status + verdict only; nothing
--- is written. Rows already accepted/rejected are left alone.
--- @param group string
--- @param mode string|nil  scope filter (see in_scope)
--- @return number  rows rejected
function M.reject_group(group, mode)
	local n = 0
	for _, p in ipairs(M.list_all()) do
		if (p.status or "pending") == "pending" and (p.group or "misc") == group and in_scope(p, mode) then
			M.reject(p, true)
			n = n + 1
		end
	end
	return n
end

-- Ensure the daemon is accepting before a raw curl apply. The opencode tools
-- spawn it on demand; the console bypasses that, so it waits for /healthz and
-- starts bin/manage when the socket is gone (or the daemon is still starting).
local function ensure_daemon(socket)
	local function healthy()
		local r = vim.system(
			{ "curl", "-sS", "--fail", "--unix-socket", socket, "http://localhost/healthz" },
			{ text = true }
		):wait()
		return r.code == 0
	end
	local sleep = (vim.uv or vim.loop).sleep
	-- Give an in-flight start a moment before spawning a second daemon.
	for _ = 1, 10 do
		if healthy() then
			return true
		end
		sleep(100)
	end
	local bin = vim.env.MANAGE_BIN or ((vim.env.HOME or "") .. "/projects/opencode-manage/bin/manage")
	if vim.fn.filereadable(bin) == 0 then
		return false
	end
	local log = (vim.env.HOME or "") .. "/.local/share/opencode-manage/manage.log"
	vim.fn.system({
		"sh",
		"-c",
		"nohup " .. vim.fn.shellescape(bin) .. " >>" .. vim.fn.shellescape(log) .. " 2>&1 &",
	})
	for _ = 1, 30 do
		if healthy() then
			return true
		end
		sleep(100)
	end
	return false
end

--- Apply an entire proposal group atomically via the daemon endpoint
--- POST /v1/proposals/apply-group. The daemon validates all rows, snapshots
--- before-images, writes/moves files, consumes fleeting thoughts, reindexes,
--- and rolls back on any error.
function M.apply_group_atomic(group, batch, project)
	if not batch or #batch == 0 then
		return false, 0
	end
	local socket = vim.fn.expand("~/.local/share/opencode-manage/manage.sock")
	if not ensure_daemon(socket) then
		vim.notify("❌ apply-group: manage daemon is unreachable at " .. socket, vim.log.levels.ERROR)
		return false, 0
	end
	local rows = {}
	local session_id = ""
	for _, entry in ipairs(batch) do
		local it = entry.proposal
		if session_id == "" and it.sessionID then
			session_id = it.sessionID
		end
		table.insert(rows, {
			ts = it.ts,
			session_id = it.sessionID,
			group = group,
			path = entry.path,
			operation = it.operation,
			content = entry.content,
			target = it.target,
			reason = it.reason,
		})
	end
	local payload = vim.json.encode({
		group = group,
		project = project,
		session_id = session_id,
		rows = rows,
	})
	local res = vim.system({
		"curl",
		"--silent",
		"--show-error",
		"--fail-with-body",
		"--unix-socket",
		socket,
		"-X",
		"POST",
		"--header",
		"Content-Type: application/json",
		"--data-raw",
		payload,
		"http://localhost/v1/proposals/apply-group",
	}, { text = true }):wait()
	if res.code ~= 0 then
		local detail = (res.stdout ~= "" and res.stdout) or res.stderr or "apply-group failed"
		vim.notify("❌ Atomic group apply aborted: " .. detail, vim.log.levels.ERROR)
		return false, 0
	end
	for _, entry in ipairs(batch) do
		local it = entry.proposal
		M.set_status(it, "accepted")
		verdicts.record({
			ts = os.time() * 1000,
			session_id = it.sessionID,
			proposal_id = it.ts,
			group_name = it.group,
			path = entry.path,
			operation = it.operation,
			verdict = "accepted",
			reason = it.reason,
			proposed_content = entry.content,
			applied_content = entry.content,
		})
		verdicts.promote_if_cross_project(entry.path, "accepted")
	end
	return true, #batch
end

return M
