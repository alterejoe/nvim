-- opencode-manage.proposals — the review data.
-- Reads .ai-proposals/*.jsonl (written by the opencode manage plugin),
-- accepts (snapshot → write → record → status), rejects, and "deletes"
-- (snapshot → MOVE to <dir>/_old/ → record → status) proposals.
-- No files are ever permanently deleted — they go to _old/ next to them,
-- which is reversible and auditable.
-- The JSONL is ground truth: schema-valid tool-call args, never parsed prose.
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

--- Resolve a proposal path to absolute. Absolute paths stay; relative paths
--- resolve against the .ai-proposals dir's project root (best effort).
--- @param proposal table
--- @return string
local function resolve_path(proposal)
	if proposal.path:sub(1, 1) == "/" then
		return proposal.path
	end
	if proposal._file then
		return vim.fn.fnamemodify(proposal._file, ":h:h") .. "/" .. proposal.path
	end
	return vim.fn.getcwd() .. "/" .. proposal.path
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

--- Accept a proposal: snapshot → write → journal → status flip.
--- The write is a USER-initiated action from nvim, never the AI.
--- @param proposal table
--- @param content_override string|nil  use this instead of proposal.content
---   (the user may have edited the proposed content before accepting)
function M.accept(proposal, content_override)
	local path = resolve_path(proposal)
	local snap = journal.snapshot(path)

	-- mkdir parents for create / new paths
	local parent = vim.fn.fnamemodify(path, ":h")
	if vim.fn.isdirectory(parent) ~= 1 then
		vim.fn.mkdir(parent, "p")
	end

	local content = content_override or proposal.content or ""
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
	M.set_status(proposal, "accepted")
	vim.notify("✅ Accepted: " .. path, vim.log.levels.INFO)
end

--- Snapshot a file WITHOUT writing — the manual `y` path. Records a journal
--- entry so even copy-paste changes are revertible (the airlock covers
--- every way a file changes, not just `da`).
--- @param proposal table
--- @return string|nil  snapshot path
function M.snapshot_only(proposal)
	local path = resolve_path(proposal)
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
--- @param proposal table
--- @return string|nil  the _old destination path, or nil if nothing moved
function M.move_to_old(proposal)
	local path = resolve_path(proposal)
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
	M.set_status(proposal, "accepted")
	vim.notify("📦 Moved to _old: " .. path .. " → " .. dest, vim.log.levels.INFO)
	return dest
end

--- Reject a proposal: status flip only. Nothing written.
--- @param proposal table
function M.reject(proposal)
	M.set_status(proposal, "rejected")
	vim.notify("❌ Rejected: " .. proposal.path, vim.log.levels.INFO)
end

return M
