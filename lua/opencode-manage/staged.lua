-- /home/altjoe/.config/nvim/lua/opencode-manage/staged.lua FINAL-1
-- opencode-manage.staged — staged workflow store reader (doc 18, S1).
-- Reads the same five tables the plugin's lib/staged.ts writes into
-- <project>/.opencode/state.db. Read-only in S1; console approvals (S2) add
-- the user-authority writes. Schema creation is additive (CREATE IF NOT
-- EXISTS) and never touches the verdicts table.
-- kkharji API — sqlite:open + db:execute + db:eval. Fail-open with a loud
-- ERROR notify: a broken store surfaces, it never silently no-ops.

local M = {}

-- sqlite is required on first use, not at module load (lazy.nvim has
-- install.missing=false — plugins are installed manually via :Lazy install).
local sqlite = nil

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS staged_state (
  session_id TEXT PRIMARY KEY,
  project TEXT,
  goal TEXT,
  stage TEXT NOT NULL DEFAULT 'context',
  group_name TEXT,
  plan_json TEXT,
  ts INTEGER NOT NULL,
  updated_ts INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS staged_slice (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL,
  name TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'planned',
  digest TEXT,
  ts_verified INTEGER
);
CREATE TABLE IF NOT EXISTS staged_check (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  slice_id INTEGER NOT NULL,
  name TEXT NOT NULL,
  kind TEXT,
  command TEXT,
  result TEXT,
  evidence TEXT,
  ts INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS staged_event (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL,
  ts INTEGER NOT NULL,
  actor TEXT NOT NULL,
  action TEXT NOT NULL,
  detail TEXT
);
CREATE TABLE IF NOT EXISTS staged_handoff (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL,
  ts INTEGER NOT NULL,
  next_slice TEXT,
  scope_json TEXT,
  stop TEXT,
  open_q TEXT
);
CREATE INDEX IF NOT EXISTS idx_staged_slice_session ON staged_slice(session_id);
CREATE INDEX IF NOT EXISTS idx_staged_event_session ON staged_event(session_id, ts);
CREATE INDEX IF NOT EXISTS idx_staged_check_slice ON staged_check(slice_id);
]]

--- Project .opencode dir: first dir with .opencode (walk up to the .git root)
--- and CREATE .opencode there if missing.
--- @return string
local function project_dir()
	local dir = vim.fn.getcwd()
	for _ = 1, 12 do
		local candidate = dir .. "/.opencode"
		if vim.fn.isdirectory(candidate) == 1 then
			return candidate
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
	local root = vim.fn.isdirectory(dir .. "/.git") == 1 and dir or vim.fn.getcwd()
	vim.fn.mkdir(root .. "/.opencode", "p")
	return root .. "/.opencode"
end

--- Open (creating if needed) the project store, ensure the staged schema.
--- @param dir string
--- @return table|nil
local function open_db(dir)
	vim.fn.mkdir(dir, "p")
	local ok, db_or_err = pcall(function()
		if not sqlite then
			sqlite = require("sqlite")
		end
		return sqlite:open(dir .. "/state.db")
	end)
	if not ok then
		vim.notify("⚠️ staged: sqlite open failed: " .. tostring(db_or_err), vim.log.levels.ERROR)
		return nil
	end
	local db = db_or_err
	if type(db) ~= "table" then
		vim.notify("⚠️ staged: sqlite.open returned no db for " .. dir, vim.log.levels.ERROR)
		return nil
	end
	local ok2, schema_err = pcall(function()
		db:execute(SCHEMA)
	end)
	if not ok2 then
		vim.notify("⚠️ staged: schema failed: " .. tostring(schema_err), vim.log.levels.ERROR)
		pcall(function()
			db:close()
		end)
		return nil
	end
	return db
end

--- Latest staged state row (project-wide), or nil.
--- @return table|nil
function M.state()
	local db = open_db(project_dir())
	if not db then
		return nil
	end
	local ok, rows = pcall(function()
		return db:eval(
			"SELECT session_id, project, goal, stage, group_name, plan_json, ts, updated_ts FROM staged_state ORDER BY updated_ts DESC LIMIT 1"
		)
	end)
	pcall(function()
		db:close()
	end)
	if not ok or type(rows) ~= "table" then
		return nil
	end
	return rows[1] or nil
end

--- Slices for a session, oldest first.
--- @param session_id string
--- @return table[]
function M.slices(session_id)
	local db = open_db(project_dir())
	if not db then
		return {}
	end
	local ok, rows = pcall(function()
		return db:eval(
			"SELECT id, session_id, name, status, digest, ts_verified FROM staged_slice WHERE session_id = :sid ORDER BY id",
			{ sid = session_id }
		)
	end)
	pcall(function()
		db:close()
	end)
	if not ok or type(rows) ~= "table" then
		return {}
	end
	return rows
end

--- Recent events for a session, newest first.
--- @param session_id string
--- @param limit number|nil
--- @return table[]
function M.events(session_id, limit)
	local db = open_db(project_dir())
	if not db then
		return {}
	end
	local n = math.max(1, math.floor(tonumber(limit) or 20))
	local ok, rows = pcall(function()
		return db:eval(
			"SELECT id, session_id, ts, actor, action, detail FROM staged_event WHERE session_id = :sid ORDER BY ts DESC LIMIT " .. n,
			{ sid = session_id }
		)
	end)
	pcall(function()
		db:close()
	end)
	if not ok or type(rows) ~= "table" then
		return {}
	end
	return rows
end

return M
