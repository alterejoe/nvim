-- /home/jmeyer/.config/nvim/lua/opencode-manage/refs.lua FINAL
-- opencode-manage.refs — the reference index (doc 20, R1a).
-- Live pointers to the user's own working code + frozen blocks from
-- corrections. Nvim builds the index (the filesystem is the user's); the
-- plugin reads it for focus routing and ref_lookup.
-- Commands:
--   :ManageIndex [root]          scan and index files under root
--   :ManageRef [path]            pin the current buffer (or a path)
--   :ManageRefs                  list references
--   :ManageRefPrune <id> <why>   prune with a recorded reason
-- Focus: BufEnter writes the active file so the plugin can surface refs.
-- Writer commands CREATE the store (dir + file + refs schema) — indexing a
-- project must never require a pre-existing state.db.
-- COLON FIX: sqlite:open(path) — the dot form silently opens in-memory.
-- Live refs/focus inside HOME are stored as ~/ paths and resolved on read.
-- Foreign absolute paths and frozen corrections are never remapped.

local M = {}

local sqlite = nil
local last_focus = nil

local INDEX_EXTS = {
	"go",
	"lua",
	"ts",
	"tsx",
	"js",
	"templ",
	"sql",
	"md",
	"yaml",
	"yml",
	"sh",
	"py",
	"toml",
}

local SKIP_PATTERNS = { "/node_modules/", "/.git/", "/_old/", "/vendor/", "/.cache/" }

local REFS_SCHEMA = [[
CREATE TABLE IF NOT EXISTS refs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts INTEGER NOT NULL,
  source TEXT NOT NULL,
  kind TEXT NOT NULL,
  path TEXT,
  symbol TEXT,
  subject TEXT,
  scope TEXT NOT NULL DEFAULT 'project',
  content TEXT,
  uses INTEGER NOT NULL DEFAULT 0,
  last_used INTEGER,
  pruned_ts INTEGER,
  prune_reason TEXT
);
CREATE INDEX IF NOT EXISTS idx_refs_subject ON refs(subject);
CREATE INDEX IF NOT EXISTS idx_refs_path ON refs(path);

CREATE TABLE IF NOT EXISTS focus (
  id INTEGER PRIMARY KEY,
  ts INTEGER NOT NULL,
  path TEXT NOT NULL,
  dir TEXT
);
]]

local function home_dir()
	local home = vim.env.HOME or ""
	return home == "/" and home or home:gsub("/+$", "")
end

local function resolve_path(path)
	local home = home_dir()
	if home == "" then
		return path
	end
	if path == "~" then
		return home
	end
	if path:sub(1, 2) == "~/" then
		return home:gsub("/$", "") .. path:sub(2)
	end
	return path
end

local function portable_path(path)
	local home = home_dir()
	if home == "" or home == "/" then
		return path
	end
	if path == home then
		return "~"
	end
	if path:sub(1, #home + 1) == home .. "/" then
		return "~" .. path:sub(#home + 1)
	end
	return path
end

local function resolve_rows(rows)
	for _, row in ipairs(rows) do
		if (row.source == "index" or row.source == "pin") and type(row.path) == "string" then
			row.path = resolve_path(row.path)
		end
	end
	return rows
end

--- Nearest state.db: walk up from cwd looking for .opencode; stop at the
--- project root (first dir with .git). Never creates directories.
--- @return string
local function store_path()
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

--- Read-only open: existing store or nil.
--- @return table|nil
local function open()
	local path = store_path()
	if vim.fn.filereadable(path) ~= 1 then
		return nil
	end
	local ok, db = pcall(function()
		if not sqlite then
			sqlite = require("sqlite")
		end
		return sqlite:open(path)
	end)
	if not ok or type(db) ~= "table" then
		return nil
	end
	pcall(function()
		db:execute(REFS_SCHEMA)
	end)
	return db
end

--- Writer open: creates the .opencode dir, the DB file, and the refs schema.
--- @return table|nil
local function open_writable()
	local path = store_path()
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local ok, db = pcall(function()
		if not sqlite then
			sqlite = require("sqlite")
		end
		return sqlite:open(path)
	end)
	if not ok or type(db) ~= "table" then
		vim.notify("❌ refs: could not open/create store at " .. path, vim.log.levels.ERROR)
		return nil
	end
	pcall(function()
		db:execute(REFS_SCHEMA)
	end)
	return db
end

--- Writer open for the GLOBAL store (the vault): ~/.config/opencode/state.db.
--- Global refs are shared by every project — indexed once, not per project
--- (CV1, doc 20).
--- @return table|nil
local function open_global_writable()
	if home_dir() == "" then
		vim.notify("❌ refs: HOME is unavailable; cannot open the global store", vim.log.levels.ERROR)
		return nil
	end
	local path = resolve_path("~/.config/opencode/state.db")
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local ok, db = pcall(function()
		if not sqlite then
			sqlite = require("sqlite")
		end
		return sqlite:open(path)
	end)
	if not ok or type(db) ~= "table" then
		vim.notify("❌ refs: could not open/create the global store at " .. path, vim.log.levels.ERROR)
		return nil
	end
	pcall(function()
		db:execute(REFS_SCHEMA)
	end)
	return db
end

--- Subject from a path: parent dir + extension (same rule as the plugin).
--- @param path string
--- @return string
function M.subject(path)
	local dir = vim.fn.fnamemodify(path, ":h:t")
	local ext = vim.fn.fnamemodify(path, ":e"):lower()
	return table.concat(vim.tbl_filter(function(s)
		return s ~= ""
	end, { dir, ext }), " ")
end

--- Index files under a root. Live pointers only; pruned entries are not
--- resurrected. Matching local absolute live refs are converted in place,
--- keeping IDs, usage and pruning metadata; foreign paths are not guessed.
--- opts.global = true writes the GLOBAL store with scope 'global' (the
--- vault); default stays the project store.
--- @param root string
--- @param opts table|nil  { global = boolean }
--- @return number  inserted count
function M.index(root, opts)
	opts = opts or {}
	root = vim.fn.fnamemodify(resolve_path(root), ":p")
	local db
	if opts.global then
		db = open_global_writable()
	else
		db = open_writable()
	end
	if not db then
		return 0
	end
	local scope = opts.global and "global" or "project"

	local files = {}
	for _, ext in ipairs(INDEX_EXTS) do
		for _, f in ipairs(vim.fn.globpath(root, "**/*." .. ext, false, true)) do
			local skip = false
			for _, pat in ipairs(SKIP_PATTERNS) do
				if f:find(pat, 1, true) then
					skip = true
					break
				end
			end
			if not skip then
				files[#files + 1] = vim.fn.fnamemodify(f, ":p")
			end
			if #files >= 800 then
				break
			end
		end
		if #files >= 800 then
			break
		end
	end

	local inserted = 0
	local portable = 0
	local converted = 0
	local now = os.time() * 1000
	local ok, err = pcall(function()
		assert(db:execute("BEGIN") ~= false, "could not begin indexing transaction")
		for _, f in ipairs(files) do
			local stored = portable_path(f)
			local rows = db:eval(
				"SELECT id, source, path FROM refs WHERE path = :portable OR path = :absolute",
				{ portable = stored, absolute = f }
			)
			assert(rows ~= false, "could not look up existing reference")
			if type(rows) == "table" and rows[1] then
				for _, row in ipairs(rows) do
					if stored ~= f and row.path == f and (row.source == "index" or row.source == "pin") then
						assert(
							db:eval("UPDATE refs SET path = ? WHERE id = ?", { stored, row.id }) ~= false,
							"could not convert local reference path"
						)
						converted = converted + 1
					end
				end
			else
				local res = db:eval(
					"INSERT INTO refs (ts, source, kind, path, subject, scope) "
						.. "VALUES (?, 'index', 'file', ?, ?, ?)",
					{ now, stored, M.subject(f), scope }
				)
				assert(res ~= false, "could not insert reference")
				inserted = inserted + 1
				if stored ~= f then
					portable = portable + 1
				end
			end
		end
		assert(db:execute("COMMIT") ~= false, "could not commit indexing transaction")
	end)
	if not ok then
		pcall(function()
			db:execute("ROLLBACK")
		end)
	end
	pcall(function()
		db:close()
	end)
	if not ok then
		vim.notify("❌ refs: indexing failed under " .. root .. ": " .. tostring(err), vim.log.levels.ERROR)
		return 0
	end
	vim.notify(
		string.format(
			"📚 refs: indexed %d new file(s) under %s (%s; %d home-relative new, %d converted)",
			inserted,
			root,
			scope,
			portable,
			converted
		),
		vim.log.levels.INFO
	)
	return inserted
end

--- Pin a file as a canonical reference. Creates the store.
--- @param path string
--- @return boolean
function M.pin(path)
	path = vim.fn.fnamemodify(resolve_path(path), ":p")
	local stored = portable_path(path)
	local db = open_writable()
	if not db then
		return false
	end
	local ok, err = pcall(function()
		assert(
			db:eval(
				"INSERT INTO refs (ts, source, kind, path, subject, scope) "
					.. "VALUES (?, 'pin', 'file', ?, ?, 'project')",
				{ os.time() * 1000, stored, M.subject(path) }
			) ~= false,
			"could not insert pinned reference"
		)
	end)
	pcall(function()
		db:close()
	end)
	if ok then
		vim.notify("📌 ref pinned: " .. path .. " (stored as " .. stored .. ")", vim.log.levels.INFO)
	else
		vim.notify("❌ refs: pin failed for " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
	end
	return ok
end

--- Record the file the user is working on (BufEnter; deduplicated).
--- Skips silently when the project has no store yet.
--- @param path string
function M.request_focus(path)
	if not path or path == "" then
		return
	end
	if path:find("^%w+://") or path:find("term://", 1, true) then
		return
	end
	path = vim.fn.fnamemodify(resolve_path(path), ":p")
	if path == last_focus then
		return
	end
	local db = open()
	if not db then
		return
	end
	local ok, err = pcall(function()
		assert(
			db:eval(
				"INSERT INTO focus (id, ts, path, dir) VALUES (1, ?, ?, ?) "
					.. "ON CONFLICT(id) DO UPDATE SET ts=excluded.ts, path=excluded.path, dir=excluded.dir",
				{ os.time() * 1000, portable_path(path), portable_path(vim.fn.fnamemodify(path, ":h")) }
			) ~= false,
			"could not record focus"
		)
	end)
	pcall(function()
		db:close()
	end)
	if ok then
		last_focus = path
	else
		vim.notify("❌ refs: focus update failed for " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
	end
end

--- References list (unpruned first, most used first), with local live paths.
--- @return table[]
function M.list()
	local db = open()
	if not db then
		return {}
	end
	local rows = {}
	pcall(function()
		local res = db:eval(
			"SELECT id, source, kind, subject, path, symbol, uses, last_used, pruned_ts, prune_reason "
				.. "FROM refs ORDER BY (pruned_ts IS NOT NULL), uses DESC, ts DESC LIMIT 200"
		)
		if type(res) == "table" then
			rows = res
		end
	end)
	pcall(function()
		db:close()
	end)
	return resolve_rows(rows)
end

--- Read-only open of the global vault store (nil when absent/unusable).
--- @return table|nil
local function open_global()
	if home_dir() == "" then
		return nil
	end
	local path = resolve_path("~/.config/opencode/state.db")
	if vim.fn.filereadable(path) ~= 1 then
		return nil
	end
	local ok, db = pcall(function()
		if not sqlite then
			sqlite = require("sqlite")
		end
		return sqlite:open(path)
	end)
	if not ok or type(db) ~= "table" then
		return nil
	end
	pcall(function()
		db:execute(REFS_SCHEMA)
	end)
	return db
end

--- Global vault list (unpruned first, most used first), with local live paths.
--- @return table[]
function M.list_global()
	local db = open_global()
	if not db then
		return {}
	end
	local rows = {}
	pcall(function()
		local res = db:eval(
			"SELECT id, source, kind, subject, path, symbol, uses, last_used, pruned_ts, prune_reason "
				.. "FROM refs ORDER BY (pruned_ts IS NOT NULL), uses DESC, ts DESC LIMIT 300"
		)
		if type(res) == "table" then
			rows = res
		end
	end)
	pcall(function()
		db:close()
	end)
	return resolve_rows(rows)
end

--- Prune a GLOBAL vault ref (reason kept; the vault viewer's `d`).
--- @param id number
--- @param reason string
--- @return boolean
function M.prune_global(id, reason)
	local db = open_global_writable()
	if not db then
		return false
	end
	local ok = pcall(function()
		db:eval("UPDATE refs SET pruned_ts = ?, prune_reason = ? WHERE id = ?", {
			os.time() * 1000,
			reason,
			tonumber(id),
		})
	end)
	pcall(function()
		db:close()
	end)
	if ok then
		vim.notify("🗑 vault ref pruned: #" .. tostring(id), vim.log.levels.INFO)
	end
	return ok
end

--- Print the list (stable verification command).
function M.summary()
	local rows = M.list()
	local lines = { string.format("refs: %d entries", #rows) }
	for _, r in ipairs(rows) do
		local state = r.pruned_ts and ("pruned: " .. tostring(r.prune_reason or "?")) or ""
		lines[#lines + 1] = string.format(
			"  #%s %-10s %-4s uses=%-3s %-20s %s %s",
			tostring(r.id),
			tostring(r.source or "?"),
			tostring(r.kind or "?"),
			tostring(r.uses or 0),
			tostring(r.subject or ""),
			tostring(r.path or r.symbol or ""),
			state
		)
	end
	if #rows == 0 then
		lines[#lines + 1] = "  — none yet — :ManageIndex <root> to scan your projects"
	end
	for _, l in ipairs(lines) do
		print(l)
	end
	return lines
end

--- Prune a reference, keeping the reason as context. Creates the store if
--- needed (pruning an empty store is a no-op).
--- @param id number
--- @param reason string
--- @return boolean
function M.prune(id, reason)
	local db = open_writable()
	if not db then
		return false
	end
	local ok = pcall(function()
		db:eval("UPDATE refs SET pruned_ts = ?, prune_reason = ? WHERE id = ?", {
			os.time() * 1000,
			reason or "no reason recorded",
			tonumber(id),
		})
	end)
	pcall(function()
		db:close()
	end)
	if ok then
		vim.notify(string.format("🗑️ ref #%s pruned (%s)", tostring(id), reason or "no reason"), vim.log.levels.INFO)
	end
	return ok
end

return M
