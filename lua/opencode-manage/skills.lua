-- /home/altjoe/.config/nvim/lua/opencode-manage/skills.lua FINAL
-- opencode-manage.skills — skill metadata + lifecycle (doc 22, SL2).
-- Reads and WRITES the routing manifests:
--   global  : ~/.config/opencode/skills.policy.json
--   project : <project>/.opencode/skills.policy.json (nearest .opencode up
--             from cwd, stopping at the project root — same convention as
--             metrics.lua)
-- Merged view: project entries win by name.
--
-- Lifecycle is RE-TIERING first (doc 22 SL2): demote to `legacy` to retire a
-- skill, promote to `emergency` to hint it always — the skill file stays,
-- only the routing changes. Full removal (drop the manifest entry) exists as
-- the deliberate second step; SKILL.md files are NEVER deleted here. The
-- airlock rule holds: nothing is destroyed, every write is journaled.
--
-- Every write: journal snapshot + record, then the manifest is rewritten
-- pretty (2-space, sorted keys) with unknown fields preserved. A manifest
-- that exists but does not parse fails CLOSED for writes (never silently
-- overwritten) and open for reads.
--
-- PRETTY-JSON DUPLICATION: pretty_json below is a copy of registry.lua's
-- module-private helper. A shared json helper is the consolidation candidate
-- (to be recorded via registry_propose once this file is applied).

local journal = require("opencode-manage.journal")

local M = {}

M.TIERS = { "default", "conditional", "emergency", "explicit", "legacy" }

local function global_dir()
	return (vim.env.HOME or "") .. "/.config/opencode"
end

--- Pretty JSON, 2-space, sorted keys — the manifest is a hand-reviewed
--- artifact; never write it single-line. (Copy of registry.lua's helper.)
--- @param val any
--- @param indent number|nil
--- @return string
local function pretty_json(val, indent)
	indent = indent or 0
	local pad = string.rep("  ", indent)
	if type(val) == "table" then
		if vim.islist(val) then
			local parts = {}
			for _, v in ipairs(val) do
				parts[#parts + 1] = pad .. "  " .. pretty_json(v, indent + 1)
			end
			if #parts == 0 then
				return "[]"
			end
			return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
		end
		local keys = {}
		for k in pairs(val) do
			keys[#keys + 1] = k
		end
		table.sort(keys)
		local parts = {}
		for _, k in ipairs(keys) do
			parts[#parts + 1] = string.format("%s  %q: %s", pad, k, pretty_json(val[k], indent + 1))
		end
		if #parts == 0 then
			return "{}"
		end
		return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
	end
	if type(val) == "string" then
		return string.format("%q", val)
	end
	return tostring(val)
end

--- Nearest project .opencode dir: walk up from cwd; stop at the project root
--- (first dir with .git). No .opencode found -> nil (project scope absent).
--- @return string|nil
local function project_opencode()
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
	return nil
end

--- The manifests in scope, global first (project wins on merge).
--- @return table[]  { scope = "global"|"project", file = string }
local function manifests()
	local out = { { scope = "global", file = global_dir() .. "/skills.policy.json" } }
	local pod = project_opencode()
	if pod then
		out[#out + 1] = { scope = "project", file = pod .. "/skills.policy.json" }
	end
	return out
end

--- Full decoded manifest. Absent/unreadable -> nil (no error). A valid table
--- without a `skills` table gets an empty one. Malformed -> nil + error so
--- writers fail closed (never overwrite what cannot be read).
--- @param file string
--- @return table|nil, string|nil
local function read_full(file)
	if vim.fn.filereadable(file) ~= 1 then
		return nil, nil
	end
	local f = io.open(file, "r")
	if not f then
		return nil, "cannot open " .. file
	end
	local raw = f:read("*a")
	f:close()
	if not raw or vim.trim(raw) == "" then
		return nil, nil
	end
	local ok, decoded = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
	if not ok or type(decoded) ~= "table" then
		return nil, "does not parse: " .. file
	end
	if type(decoded.skills) ~= "table" then
		decoded.skills = {}
	end
	return decoded, nil
end

--- Build the viewer-facing record for one manifest entry.
--- @param name string
--- @param scope string
--- @param file string
--- @param e table
--- @return table
local function build(name, scope, file, e)
	local root
	if scope == "global" then
		root = global_dir() .. "/skills"
	else
		root = vim.fn.fnamemodify(file, ":h") .. "/skills"
	end
	local path = root .. "/" .. name .. "/SKILL.md"
	return {
		name = name,
		scope = scope,
		file = file,
		entry = e,
		tier = type(e.tier) == "string" and e.tier or "default",
		subject = type(e.subject) == "table" and e.subject or {},
		note = type(e.note) == "string" and e.note or nil,
		path = path,
		exists = vim.fn.filereadable(path) == 1,
	}
end

--- Locate one entry across scopes (project wins); carries the live manifest
--- data so updates write back to the scope that owns the entry.
--- @param name string
--- @return table|nil
local function find(name)
	local found = nil
	for _, m in ipairs(manifests()) do
		local data, err = read_full(m.file)
		if err then
			vim.notify("⚠️ skills manifest " .. err, vim.log.levels.WARN)
		end
		if data and type(data.skills[name]) == "table" then
			local rec = build(name, m.scope, m.file, data.skills[name])
			rec.data = data
			found = rec
		end
	end
	return found
end

--- Merged list: project entries win by name; sorted by name. Read-only —
--- malformed manifests are skipped with no notification (refresh-safe).
--- @return table[]
function M.list()
	local by_name = {}
	for _, m in ipairs(manifests()) do
		local data = read_full(m.file)
		if data then
			for name, e in pairs(data.skills) do
				if type(e) == "table" and type(name) == "string" then
					by_name[name] = build(name, m.scope, m.file, e)
				end
			end
		end
	end
	local out = {}
	for _, rec in pairs(by_name) do
		out[#out + 1] = rec
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out
end

--- Apply a change to one entry: mutate the live manifest in memory, snapshot,
--- pretty-write, journal. Fails closed when the entry is missing or the
--- manifest cannot be read.
--- @param name string
--- @param op_name string  journal op label
--- @param reason string
--- @param mutate fun(entry: table, data: table)
--- @return boolean
local function update(name, op_name, reason, mutate)
	local rec = find(name)
	if not rec then
		vim.notify("❌ skills: no manifest entry for '" .. tostring(name) .. "'", vim.log.levels.WARN)
		return false
	end
	local data = rec.data
	local entry = data.skills[name]
	if type(entry) ~= "table" then
		vim.notify("❌ skills: entry vanished during update", vim.log.levels.WARN)
		return false
	end
	mutate(entry, data)
	local snap = journal.snapshot(rec.file)
	local lines = vim.split(pretty_json(data), "\n", { plain = true })
	if lines[#lines] == "" then
		table.remove(lines)
	end
	vim.fn.writefile(lines, rec.file)
	journal.record({
		ts = os.time() * 1000,
		path = rec.file,
		group = "skills",
		op = op_name,
		snapshot = snap,
		existed = snap ~= nil,
		reason = reason,
		sessionID = nil,
	})
	return true
end

--- Re-tier a skill (the primary lifecycle action — demotion over deletion).
--- @param name string
--- @param tier string  one of M.TIERS
--- @param note string|nil  nil = leave the note alone; "" = clear it
--- @return boolean
function M.set_tier(name, tier, note)
	if not vim.list_contains(M.TIERS, tier) then
		vim.notify("❌ skills: unknown tier '" .. tostring(tier) .. "'", vim.log.levels.WARN)
		return false
	end
	local label = "tier -> " .. tier .. (type(note) == "string" and note ~= "" and (" · " .. note) or "")
	return update(name, "skill-tier", label, function(entry)
		entry.tier = tier
		if type(note) == "string" then
			entry.note = note ~= "" and note or nil
		end
	end)
end

--- Set or clear the note (the WHY — "demoted: duplicates verbose-logging").
--- @param name string
--- @param note string  "" clears
--- @return boolean
function M.set_note(name, note)
	if type(note) ~= "string" then
		return false
	end
	return update(name, "skill-note", note == "" and "note cleared" or ("note: " .. note), function(entry)
		entry.note = note ~= "" and note or nil
	end)
end

--- Replace the routing subjects (the refs vocabulary; >=1 required).
--- @param name string
--- @param subjects string[]
--- @return boolean
function M.set_subjects(name, subjects)
	local cleaned = {}
	if type(subjects) == "table" then
		for _, s in ipairs(subjects) do
			if type(s) == "string" and vim.trim(s) ~= "" then
				cleaned[#cleaned + 1] = vim.trim(s)
			end
		end
	end
	if #cleaned == 0 then
		vim.notify("❌ skills: at least one subject is required — routing needs it", vim.log.levels.WARN)
		return false
	end
	return update(name, "skill-subjects", "subjects: " .. table.concat(cleaned, ", "), function(entry)
		entry.subject = cleaned
	end)
end

--- Drop the manifest entry — the deliberate full prune. The SKILL.md file is
--- kept: the skill simply stops being routed/hinted. Prefer demotion
--- (`legacy`) when the history matters.
--- @param name string
--- @return boolean
function M.drop(name)
	return update(name, "skill-drop", "entry dropped (file kept)", function(_, data)
		data.skills[name] = nil
	end)
end

return M
