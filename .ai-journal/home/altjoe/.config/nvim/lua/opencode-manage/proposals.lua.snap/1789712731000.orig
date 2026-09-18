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
-- readable target and are refused otherwise; only create may mkdir parents.
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
local function all_dirs()
	local dirs = cwd_dirs()
	for _, root in ipairs(SCAN_ROOTS) do
		for _, d in ipairs(vim.fn.glob(root .. "/*/.ai-proposals", false, true)) do
			dirs[d] = dirs[d] or false
		end
	end
	return dirs
end

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
--- readable target; only create may mkdir parents.
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
				if ch == "{" or ch == "(" then
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
function M.reject(proposal)
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

	vim.notify("❌ Rejected: " .. proposal.path, vim.log.levels.INFO)
end

return M
