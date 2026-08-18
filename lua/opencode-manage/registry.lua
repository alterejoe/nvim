-- opencode-manage.registry — the registry data layer (M1r).
-- Reads .opencode/manage.registry.pending.jsonl (written by the opencode
-- manage plugin's registry_propose tool), accepts (merge into
-- manage.registry.json + journal entry + summary regen + status flip) and
-- rejects (status flip only).
-- The registry JSON is ground truth; the pending queue is the review queue.
-- The merge is a USER-initiated action from nvim, never the AI.
-- The registry file is a hand-reviewed artifact: written back as pretty
-- JSON (2-space), never single-line.
-- Discovery scopes (mirrors proposals.lua): walk-up + glob-down from cwd
-- plus SCAN_ROOTS, so foreign projects' queues are reviewable too.
--
-- NULL GOTCHA: the plugin writes "constraints":null / "suggested_target":null
-- for unset fields. vim.json.decode maps JSON null to cjson's null sentinel
-- (a USERDATA, truthy) — concatenating it crashes. All decodes pass
-- { luanil = { object = true, array = true } } so null becomes nil and the
-- `if field then` guards behave. set_status deliberately decodes WITHOUT the
-- option: cjson round-trips its own null sentinel, so the queue line stays
-- byte-stable on status flips.
--
-- nvim 0.11+ deprecations avoided: vim.islist (not vim.tbl_islist) and
-- vim.list_contains (not vim.tbl_contains).

local journal = require("opencode-manage.journal")

local M = {}

local SCAN_ROOTS = {
	vim.env.HOME .. "/projects",
	vim.env.HOME .. "/docs",
}

-- The registry sections, in canonical order.
local SECTIONS = { "shared", "canonical", "modularize", "consolidations" }

--- .opencode dirs reachable from cwd: walk up 12 levels + glob down 2.
--- @return table<string, boolean> dir -> true
local function opencode_dirs()
	local dirs = {}
	local dir = vim.fn.getcwd()
	for _ = 1, 12 do
		local candidate = dir .. "/.opencode"
		if vim.fn.isdirectory(candidate) == 1 then
			dirs[candidate] = true
		end
		local parent = vim.fn.fnamemodify(dir, ":h")
		if parent == dir then
			break
		end
		dir = parent
	end
	for _, d in ipairs(vim.fn.glob(vim.fn.getcwd() .. "/.opencode", false, true)) do
		dirs[d] = true
	end
	for _, d in ipairs(vim.fn.glob(vim.fn.getcwd() .. "/*/.opencode", false, true)) do
		dirs[d] = true
	end
	for _, d in ipairs(vim.fn.glob(vim.fn.getcwd() .. "/*/*/.opencode", false, true)) do
		dirs[d] = true
	end
	for _, root in ipairs(SCAN_ROOTS) do
		for _, d in ipairs(vim.fn.glob(root .. "/*/.opencode", false, true)) do
			dirs[d] = false
		end
	end
	return dirs
end

--- Every .opencode dir that actually has a registry pending queue.
--- @return table<string, boolean>
local function pending_dirs()
	local out = {}
	for d in pairs(opencode_dirs()) do
		if vim.fn.filereadable(d .. "/manage.registry.pending.jsonl") == 1 then
			out[d] = true
		end
	end
	return out
end

--- Read every pending entry from every queue. Each carries _file, _line,
--- _project, _rel so accept/reject can update in place. Lines that decode
--- to a table without a `kind` are skipped (malformed), never fatal.
--- @return table[]
function M.list_all()
	local out = {}
	local dir_list = {}
	for d in pairs(pending_dirs()) do
		dir_list[#dir_list + 1] = d
	end
	table.sort(dir_list)
	for _, dir in ipairs(dir_list) do
		local project_root = vim.fn.fnamemodify(dir, ":h")
		local f = dir .. "/manage.registry.pending.jsonl"
		local lines = vim.fn.readfile(f)
		for li, line in ipairs(lines) do
			if line ~= "" then
				local ok, e = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
				if ok and type(e) == "table" and type(e.kind) == "string" then
					e._file = f
					e._line = li
					e._project = vim.fn.fnamemodify(project_root, ":t")
					e._rel = e.path or table.concat(e.paths or {}, " + ")
					table.insert(out, e)
				end
			end
		end
	end
	return out
end

--- Visible entries: pending + merged (merged stay in the viewer marked
--- [merged], so the review history is never a mystery).
--- @return table[]
function M.list_visible()
	local out = {}
	for _, e in ipairs(M.list_all()) do
		local st = e.status or "pending"
		if st == "pending" or st == "merged" then
			table.insert(out, e)
		end
	end
	return out
end

--- Update an entry's status field in its queue (in place).
--- Deliberately decodes WITHOUT luanil: cjson round-trips its own null
--- sentinel on encode, so the line keeps its exact shape (nulls intact).
--- @param entry table
--- @param status string  "merged" | "rejected"
function M.set_status(entry, status)
	if not entry._file then
		return
	end
	local lines = vim.fn.readfile(entry._file)
	local ok, obj = pcall(vim.json.decode, lines[entry._line] or "")
	if ok and type(obj) == "table" then
		obj.status = status
		lines[entry._line] = vim.json.encode(obj)
		vim.fn.writefile(lines, entry._file)
	end
end

--- Minimal JSON pretty-printer (2-space indent). The registry is a
--- hand-reviewed artifact — never write it single-line.
--- @param val any
--- @param indent number
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

--- The registry file for a project's .opencode dir.
--- @param opencode_dir string
--- @return string
local function registry_file(opencode_dir)
	return opencode_dir .. "/manage.registry.json"
end

--- Read the registry JSON (fail-open: missing/unreadable file = empty).
--- @param opencode_dir string
--- @return table
local function read_registry(opencode_dir)
	local f = registry_file(opencode_dir)
	if vim.fn.filereadable(f) ~= 1 then
		return {}
	end
	local ok, reg = pcall(vim.json.decode, table.concat(vim.fn.readfile(f), "\n"), {
		luanil = { object = true, array = true },
	})
	if not ok or type(reg) ~= "table" then
		return {}
	end
	return reg
end

--- Convert a pending entry into the shape stored in the registry JSON
--- (runtime fields stripped: ts/sessionID/group/status).
--- @param e table
--- @return table
local function to_registry_entry(e)
	local out = {}
	if e.kind == "shared" then
		out.path = e.path
		out.symbols = e.symbols or {}
		if e.fragile then
			out.fragile = true
		end
		if e.constraints then
			out.constraints = e.constraints
		end
	elseif e.kind == "canonical" then
		out.concept = e.concept
		out.path = e.path
		out.symbols = e.symbols or {}
	elseif e.kind == "modularize" then
		out.path = e.path
		out.symbols = e.symbols or {}
	elseif e.kind == "consolidations" then
		out.paths = e.paths or {}
		if e.suggested_target then
			out.suggested_target = e.suggested_target
		end
	end
	if e.rationale then
		out.rationale = e.rationale
	end
	if e.refs and #e.refs > 0 then
		out.refs = e.refs
	end
	return out
end

--- The exact JSON block a merge appends — shown in the viewer's right pane
--- so da is never blind.
--- @param e table
--- @return string
function M.preview_block(e)
	return pretty_json(to_registry_entry(e))
end

--- Render the human-readable registry summary MD from the registry JSON.
--- @param opencode_dir string
--- @param reg table
--- @return string
function M.render_summary(opencode_dir, reg)
	local summary_path = opencode_dir .. "/registry-summary.md"
	local project = vim.fn.fnamemodify(vim.fn.fnamemodify(opencode_dir, ":h"), ":t")
	local L = {}
	L[#L + 1] = "# " .. summary_path .. " FINAL"
	L[#L + 1] = "# Registry Summary — " .. project
	L[#L + 1] = ""
	L[#L + 1] = "Generated from `.opencode/manage.registry.json`. LSP-verified refs"
	L[#L + 1] = "land via `registry_propose` as entries merge. Files under `_old/`"
	L[#L + 1] = "are archived by the snapshot system — treat as dead consumers."

	local function add_section(title, entries, renderer)
		if not entries or #entries == 0 then
			return
		end
		L[#L + 1] = ""
		L[#L + 1] = "## " .. title
		for _, e in ipairs(entries) do
			L[#L + 1] = ""
			renderer(e)
		end
	end

	add_section("shared", reg.shared, function(s)
		local frag = s.fragile and " [FRAGILE]" or ""
		L[#L + 1] = "### " .. (s.path or "?") .. frag
		L[#L + 1] = "- Symbols: " .. table.concat(s.symbols or {}, ", ")
		L[#L + 1] = "- Why: " .. (s.rationale or s.constraints or "(none recorded — add via registry_propose)")
		if s.refs and #s.refs > 0 then
			local paths = {}
			for _, r in ipairs(s.refs) do
				paths[#paths + 1] = r.path
			end
			L[#L + 1] = "- Used by: " .. table.concat(paths, ", ")
		end
	end)
	add_section("canonical", reg.canonical, function(c)
		L[#L + 1] = "### " .. (c.concept or "?")
		local reuse = "- Reuse: " .. (c.path or "?")
		if c.symbols and #c.symbols > 0 then
			reuse = reuse .. " — " .. table.concat(c.symbols, ", ")
		end
		L[#L + 1] = reuse
		if c.constraints then
			L[#L + 1] = "- Constraint: " .. c.constraints
		end
		if c.refs and #c.refs > 0 then
			local paths = {}
			for _, r in ipairs(c.refs) do
				paths[#paths + 1] = r.path
			end
			L[#L + 1] = "- Used by: " .. table.concat(paths, ", ")
		end
	end)
	add_section("modularize", reg.modularize, function(m)
		L[#L + 1] = "### " .. (m.path or "?")
		L[#L + 1] = "- Symbols: " .. table.concat(m.symbols or {}, ", ")
		L[#L + 1] = "- Why: " .. (m.rationale or "(none recorded — add via registry_propose)")
	end)
	add_section("consolidations", reg.consolidations, function(c)
		L[#L + 1] = "### " .. table.concat(c.paths or {}, ", ")
		if c.rationale then
			L[#L + 1] = "- Why: " .. c.rationale
		end
		if c.suggested_target then
			L[#L + 1] = "- Suggested target: " .. c.suggested_target
		end
	end)

	return table.concat(L, "\n") .. "\n"
end

--- Write the summary MD next to the registry.
--- @param opencode_dir string
--- @param reg table|nil  registry JSON; re-read when omitted
function M.write_summary(opencode_dir, reg)
	local content = M.render_summary(opencode_dir, reg or read_registry(opencode_dir))
	local f = opencode_dir .. "/registry-summary.md"
	local lines = vim.split(content, "\n", { plain = true })
	if lines[#lines] == "" then
		table.remove(lines)
	end
	vim.fn.writefile(lines, f)
end

--- Merge a pending entry into the project's registry: snapshot → append to
--- its section → write (pretty JSON) → journal → summary regen → status.
--- The write is a USER-initiated action from nvim, never the AI.
--- @param e table
function M.accept(e)
	if not e._file then
		vim.notify("❌ Entry has no queue file", vim.log.levels.WARN)
		return
	end
	if not vim.list_contains(SECTIONS, e.kind) then
		vim.notify("❌ Unknown registry kind: " .. tostring(e.kind), vim.log.levels.WARN)
		return
	end
	local opencode_dir = vim.fn.fnamemodify(e._file, ":h")
	local f = registry_file(opencode_dir)
	local snap = journal.snapshot(f)

	local reg = read_registry(opencode_dir)
	for _, section in ipairs(SECTIONS) do
		if type(reg[section]) ~= "table" then
			reg[section] = {}
		end
	end
	table.insert(reg[e.kind], to_registry_entry(e))

	vim.fn.mkdir(opencode_dir, "p")
	local out_lines = vim.split(pretty_json(reg), "\n", { plain = true })
	if out_lines[#out_lines] == "" then
		table.remove(out_lines)
	end
	vim.fn.writefile(out_lines, f)

	journal.record({
		ts = os.time() * 1000,
		path = f,
		group = e.group,
		op = "registry-merge",
		snapshot = snap,
		existed = snap ~= nil,
		reason = (e.kind or "?") .. ": " .. (e.rationale or ""),
		sessionID = e.sessionID,
	})

	M.write_summary(opencode_dir, reg)

	M.set_status(e, "merged")
	vim.notify(
		"✅ Registry merged (" .. e.kind .. "): " .. (e.path or table.concat(e.paths or {}, " + ")),
		vim.log.levels.INFO
	)
end

--- Reject an entry: status flip only. Nothing written.
--- @param e table
function M.reject(e)
	M.set_status(e, "rejected")
	vim.notify("❌ Registry entry rejected (" .. tostring(e.kind) .. ")", vim.log.levels.INFO)
end

return M
