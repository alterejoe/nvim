-- browser/dashboard/tabops/yaml_io.lua
--
-- YAML read/write for the three editable files driven by the gz buffer:
--   tags.yaml      - tab annotations (chi_path -> tag names)
--   headings.yaml  - panel section headers (glob patterns)
--
-- Plus the matches_glob helper used by render.lua to decide which tabs
-- belong under which heading.
--
-- groups.yaml is owned by browser/groups.lua, not here, because groups
-- have richer behavior (open_group, cycle_next, M.pick, etc).
--
-- Save sites snapshot the existing file via groups_history before write
-- so accidental overwrites can be recovered. Save honors an optional
-- `order` parameter; see yaml_order.lua for the resolve_order rules.

local M = {}

local function devproxy_dir()
	return require("browser.session").DEVPROXY_DIR
end

-- ============================================================
-- tags.yaml
-- ============================================================

local function tags_path()
	return devproxy_dir() .. "/tags.yaml"
end

function M.tags_path()
	return tags_path()
end

function M.load_tags()
	local path = tags_path()
	if vim.fn.filereadable(path) == 0 then
		return {}
	end
	local raw = vim.fn.system("yq -o=json . " .. vim.fn.shellescape(path) .. " 2>/dev/null")
	local ok, data = pcall(vim.json.decode, raw)
	if not ok or not data or not data.tags or type(data.tags) ~= "table" then
		return {}
	end
	local result = {}
	for name, paths in pairs(data.tags) do
		result[name] = type(paths) == "table" and paths or {}
	end
	return result
end

function M.save_tags(tags, order)
	local path = tags_path()
	require("browser.groups_history").snapshot(path)

	local yaml_order = require("browser.yaml_order")
	local existing = yaml_order.read_top_level_order(path, "tags")
	local final_order = yaml_order.resolve_order(order, tags, existing)

	local lines = { "tags:" }
	for _, name in ipairs(final_order) do
		table.insert(lines, "  " .. name .. ":")
		for _, p in ipairs(tags[name] or {}) do
			table.insert(lines, "    - " .. p)
		end
	end
	local f = io.open(path, "w")
	if f then
		f:write(table.concat(lines, "\n") .. "\n")
		f:close()
	end
end

-- ============================================================
-- headings.yaml
-- ============================================================

local function headings_path()
	return devproxy_dir() .. "/headings.yaml"
end

function M.headings_path()
	return headings_path()
end

function M.load_headings()
	-- Returns { order=[names], patterns={name=[globs]} }
	local path = headings_path()
	if vim.fn.filereadable(path) == 0 then
		return { order = {}, patterns = {} }
	end
	local raw = vim.fn.system("yq -o=json . " .. vim.fn.shellescape(path) .. " 2>/dev/null")
	local ok, data = pcall(vim.json.decode, raw)
	if not ok or not data or type(data.headings) ~= "table" then
		return { order = {}, patterns = {} }
	end
	local result = { order = {}, patterns = {} }
	for _, entry in ipairs(data.headings) do
		if type(entry) == "table" and type(entry.name) == "string" then
			table.insert(result.order, entry.name)
			result.patterns[entry.name] = type(entry.patterns) == "table" and entry.patterns or {}
		end
	end
	return result
end

function M.save_headings(headings)
	-- headings: { order=[names], patterns={name=[globs]} }
	-- Headings always use the explicit order from headings.order; no
	-- "preserve file order" logic needed because parse_group_buf already
	-- captures buffer order into headings.order during the line walk.
	local path = headings_path()
	require("browser.groups_history").snapshot(path)
	local lines = { "headings:" }
	for _, name in ipairs(headings.order) do
		table.insert(lines, "  - name: " .. name)
		local pats = headings.patterns[name] or {}
		if #pats > 0 then
			table.insert(lines, "    patterns:")
			for _, p in ipairs(pats) do
				table.insert(lines, "      - " .. p)
			end
		end
	end
	local f = io.open(path, "w")
	if f then
		f:write(table.concat(lines, "\n") .. "\n")
		f:close()
	end
end

-- ============================================================
-- glob matching for headings
-- Supports:
--   /admin/*     trailing * matches any single suffix (no slashes)
--   /admin/**    trailing ** matches any suffix including slashes
--   /**/edit/*   ** in the middle matches any path segments
--   /exact/path  exact match
-- ============================================================
function M.matches_glob(path, pattern)
	path = (path:match("^([^?#]+)") or path):gsub("%%7B", "{"):gsub("%%7D", "}")
	-- Convert glob to a Lua pattern: escape magic chars except *, then
	-- handle ** (any chars including /) before * (any non-slash chars).
	local lua_pat = pattern
		:gsub("([%.%+%-%^%$%(%)%[%]%%])", "%%%1")
		:gsub("%*%*", "DOUBLESTAR")
		:gsub("%*", "[^/]*")
		:gsub("DOUBLESTAR", ".*")
	lua_pat = "^" .. lua_pat .. "$"
	return path:match(lua_pat) ~= nil
end

function M.tab_matches_heading(tab_path, patterns)
	for _, pat in ipairs(patterns) do
		if M.matches_glob(tab_path, pat) then
			return true
		end
	end
	return false
end

return M
