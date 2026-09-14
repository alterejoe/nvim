-- /home/altjoe/.config/nvim/lua/opencode-manage/metrics.lua FINAL
-- opencode-manage.metrics — the metrics store reader + prune requester
-- (doc 19, C1 + C2 + O1). Reads turn_metrics / context_events / event_tags
-- from the shared state.db written by the opencode manage plugin.
-- Stable commands:
--   :ManageMetrics            read-only summary
--   :ManagePrune [note]       request a shaped context prune
-- Data helpers for the viewer: turns() / events() / objects() / object_events().
--
-- No surprises: the reader never creates the store, never writes; query
-- errors are surfaced. The prune requester writes ONE event row and the
-- plugin consumes it on the next message.
--
-- COLON FIX: the driver must be called as `sqlite:open(path)`. The dot form
-- passes no self — sqlite.lua then silently falls back to in-memory.

local M = {}

local sqlite = nil

--- Nearest state.db: walk up from cwd looking for .opencode; stop at the
--- project root (first dir with .git). Never creates anything.
--- @return string
local function metrics_store()
	local dir = vim.fn.getcwd()
	for _ = 1, 12 do
		local candidate = dir .. "/.opencode"
		if vim.fn.isdirectory(candidate) == 1 then
			return candidate .. "/state.db"
		end
		if vim.fn.isdirectory(dir .. "/.git") == 1 then
			break
		end
		local parent = vim.fn.fnamemodify(dir, ":h")
		if parent == dir then
			break
		end
		dir = parent
	end
	return vim.fn.getcwd() .. "/.opencode/state.db"
end

--- Open the store. Only called after filereadable() confirmed it exists.
--- @param path string
--- @return table|nil
local function open(path)
	local ok, db = pcall(function()
		if not sqlite then
			sqlite = require("sqlite")
		end
		return sqlite:open(path)
	end)
	if not ok or type(db) ~= "table" then
		return nil
	end
	return db
end

--- pcall'd eval: a missing table raises in sqlite.lua — never crash here.
--- @param db table
--- @param sql string
--- @param params table|nil
--- @return table[]|nil, string|nil
local function q(db, sql, params)
	local ok, rows = pcall(function()
		return db:eval(sql, params)
	end)
	if not ok then
		return nil, tostring(rows)
	end
	if type(rows) ~= "table" then
		return {}, nil
	end
	return rows, nil
end

--- Run a read query against the store if it exists.
--- @param sql string
--- @param params table|nil  named binds (e.g. { tag = "..." })
--- @return table[]
local function read(sql, params)
	local path = metrics_store()
	if vim.fn.filereadable(path) ~= 1 then
		return {}
	end
	local db = open(path)
	if not db then
		return {}
	end
	local rows = q(db, sql, params)
	pcall(function()
		db:close()
	end)
	return rows or {}
end

--- Recent turns, newest first — the viewer list.
--- @param limit number
--- @return table[]
function M.turns(limit)
	limit = limit or 200
	return read(
		"SELECT ts, message_id, tokens_input, tokens_output, tokens_reasoning, "
			.. "cache_read, cache_write, model, agent FROM turn_metrics "
			.. "ORDER BY ts DESC LIMIT " .. tostring(math.floor(limit))
	)
end

--- Recent context events, newest first — the viewer detail.
--- @param limit number
--- @return table[]
function M.events(limit)
	limit = limit or 500
	return read(
		"SELECT ts, session_id, kind, detail FROM context_events "
			.. "ORDER BY ts DESC LIMIT " .. tostring(math.floor(limit))
	)
end

--- O1: named objects, most touched first.
--- @param limit number
--- @return table[]
function M.objects(limit)
	limit = limit or 300
	return read(
		"SELECT tag, kind, COUNT(*) AS n, MAX(event_ts) AS last FROM event_tags "
			.. "GROUP BY tag, kind ORDER BY n DESC, tag ASC LIMIT " .. tostring(math.floor(limit))
	)
end

--- O1: recent events carrying one object tag.
--- @param tag string
--- @param kind string
--- @param limit number
--- @return table[]
function M.object_events(tag, kind, limit)
	limit = limit or 80
	return read(
		"SELECT e.ts, e.kind, e.detail FROM context_events e "
			.. "JOIN event_tags t ON t.event_ts = e.ts "
			.. "WHERE t.tag = :tag AND t.kind = :kind "
			.. "ORDER BY e.ts DESC LIMIT " .. tostring(math.floor(limit)),
		{ tag = tag, kind = kind }
	)
end

--- O1: verdict outcomes recorded for a path (file tags carry absolute paths
--- from tool args; verdicts store the resolved absolute path).
--- @param path string
--- @return table[]
function M.object_verdicts(path)
	return read(
		"SELECT verdict, COUNT(*) AS n FROM verdicts WHERE path = :path "
			.. "GROUP BY verdict ORDER BY n DESC",
		{ path = path }
	)
end

--- Collected metrics facts.
--- @return table
function M.stats()
	local path = metrics_store()
	local out = {
		path = path,
		exists = vim.fn.filereadable(path) == 1,
		tables = {},
		tables_err = nil,
		turns = nil,
		events = nil,
		newest = nil,
	}
	if not out.exists then
		return out
	end
	local db = open(path)
	if not db then
		out.error = "sqlite.lua could not open the store"
		return out
	end

	local tables, tables_err = q(db, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
	if tables then
		for _, r in ipairs(tables) do
			out.tables[#out.tables + 1] = r.name
		end
	else
		out.tables_err = tables_err
	end
	local has = {}
	for _, t in ipairs(out.tables) do
		has[t] = true
	end

	if has.turn_metrics then
		local rows = q(
			db,
			"SELECT COUNT(*) AS n, COALESCE(SUM(tokens_input),0) AS input, "
				.. "COALESCE(SUM(tokens_output),0) AS output FROM turn_metrics"
		)
		if rows and rows[1] then
			out.turns = {
				n = tonumber(rows[1].n) or 0,
				input = tonumber(rows[1].input) or 0,
				output = tonumber(rows[1].output) or 0,
			}
		end
		local newest = q(
			db,
			"SELECT ts, message_id, tokens_input, tokens_output, cache_read "
				.. "FROM turn_metrics ORDER BY ts DESC LIMIT 1"
		)
		if newest and newest[1] then
			out.newest = newest[1]
		end
	end

	if has.context_events then
		local rows = q(db, "SELECT kind, COUNT(*) AS n FROM context_events GROUP BY kind ORDER BY n DESC")
		out.events = {}
		if rows then
			for _, r in ipairs(rows) do
				out.events[#out.events + 1] = { kind = r.kind, n = tonumber(r.n) or 0 }
			end
		end
		local pending = q(
			db,
			"SELECT ts FROM context_events WHERE kind = 'prune_request' ORDER BY ts DESC LIMIT 1"
		)
		local consumed = q(
			db,
			"SELECT ts FROM context_events WHERE kind = 'prune_consumed' ORDER BY ts DESC LIMIT 1"
		)
		local req = pending and pending[1] and tonumber(pending[1].ts) or nil
		local con = consumed and consumed[1] and tonumber(consumed[1].ts) or nil
		out.prune_pending = req ~= nil and (con == nil or req > con)
	end

	if has.event_tags then
		local rows = q(db, "SELECT COUNT(DISTINCT tag || '|' || kind) AS n FROM event_tags")
		if rows and rows[1] then
			out.objects = tonumber(rows[1].n) or 0
		end
	end

	pcall(function()
		db:close()
	end)
	return out
end

--- Human-readable summary; prints each line and returns them.
--- @return string[]
function M.summary()
	local s = M.stats()
	local lines = {}
	lines[#lines + 1] = "metrics store: " .. s.path
	if not s.exists then
		lines[#lines + 1] = "  not created yet — it appears after the first assistant turn or tool call"
		lines[#lines + 1] = "  (if it stays absent, check :messages for [manage] metrics errors)"
	else
		lines[#lines + 1] = "  tables: " .. (#s.tables > 0 and table.concat(s.tables, ", ") or "(none)")
		if s.tables_err then
			lines[#lines + 1] = "  sqlite_master error: " .. s.tables_err
		end
		if s.turns then
			lines[#lines + 1] = string.format(
				"  turns: %d · input %d · output %d",
				s.turns.n,
				s.turns.input,
				s.turns.output
			)
			if s.newest then
				local when = os.date("%H:%M:%S", math.floor((tonumber(s.newest.ts) or 0) / 1000))
				lines[#lines + 1] = string.format(
					"  newest: %s · in %s · out %s · cache %s",
					when,
					tostring(s.newest.tokens_input),
					tostring(s.newest.tokens_output),
					tostring(s.newest.cache_read)
				)
			end
		elseif #s.tables > 0 then
			lines[#lines + 1] = "  metrics tables absent — the plugin has not written yet"
		end
		if s.events then
			local parts = {}
			for _, e in ipairs(s.events) do
				parts[#parts + 1] = string.format("%s=%d", e.kind, e.n)
			end
			lines[#lines + 1] = "  events: " .. (#parts > 0 and table.concat(parts, " · ") or "(none)")
		end
		if s.objects then
			lines[#lines + 1] = string.format("  objects: %d tracked", s.objects)
		end
		if s.prune_pending then
			lines[#lines + 1] = "  prune: requested — applies on your next opencode message"
		end
		if s.error then
			lines[#lines + 1] = "  error: " .. s.error
		end
	end
	for _, l in ipairs(lines) do
		print(l)
	end
	return lines
end

--- C2: write a prune request the plugin consumes on the next message.
--- Shaped compaction keeps verified state and drops exploration / superseded
--- content; effectiveness is measurable via the token columns.
--- @param note string|nil
--- @return boolean
function M.request_prune(note)
	local path = metrics_store()
	if vim.fn.filereadable(path) ~= 1 then
		vim.notify("❌ prune: no store yet at " .. path, vim.log.levels.WARN)
		return false
	end
	local ok, err = pcall(function()
		if not sqlite then
			sqlite = require("sqlite")
		end
		local db = sqlite:open(path)
		local res = db:eval(
			"INSERT INTO context_events (session_id, ts, kind, detail, subject) "
				.. "VALUES (NULL, ?, 'prune_request', ?, NULL)",
			{ os.time() * 1000, note or "user-requested prune" }
		)
		if res == false then
			error("insert returned false")
		end
		pcall(function()
			db:close()
		end)
	end)
	if not ok then
		vim.notify("❌ prune request failed: " .. tostring(err), vim.log.levels.ERROR)
		return false
	end
	vim.notify("✂️ Prune requested — applies on your next message in opencode", vim.log.levels.INFO)
	return true
end

return M
