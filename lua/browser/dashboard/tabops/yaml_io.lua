-- browser/dashboard/tabops/yaml_io.lua
--
-- YAML read/write for the editable files driven by the gz buffer:
--   tags.yaml         - tab annotations (chi_path -> tag names)
--   headings.yaml     - panel section headers (glob patterns)
--   server_tags.yaml  - per-tab server bindings (server name -> globs)
--
-- Plus the matches_glob helper used by render.lua to decide which tabs
-- belong under which heading or server tag.

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
-- server_tags.yaml
-- ============================================================

local function server_tags_path()
	return devproxy_dir() .. "/server_tags.yaml"
end

function M.server_tags_path()
	return server_tags_path()
end

function M.load_server_tags()
	local path = server_tags_path()
	if vim.fn.filereadable(path) == 0 then
		return {}
	end
	local raw = vim.fn.system("yq -o=json . " .. vim.fn.shellescape(path) .. " 2>/dev/null")
	local ok, data = pcall(vim.json.decode, raw)
	if not ok or not data or not data.server_tags or type(data.server_tags) ~= "table" then
		return {}
	end
	local result = {}
	for name, paths in pairs(data.server_tags) do
		result[name] = type(paths) == "table" and paths or {}
	end
	return result
end

function M.save_server_tags(server_tags, order)
	local path = server_tags_path()
	require("browser.groups_history").snapshot(path)

	local yaml_order = require("browser.yaml_order")
	local existing = yaml_order.read_top_level_order(path, "server_tags")
	local final_order = yaml_order.resolve_order(order, server_tags, existing)

	local lines = { "server_tags:" }
	for _, name in ipairs(final_order) do
		table.insert(lines, "  " .. name .. ":")
		for _, p in ipairs(server_tags[name] or {}) do
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
-- glob matching for headings + server tags
-- Supports:
--   /admin/*     trailing * matches any single path segment (no slashes)
--   /admin/**    trailing ** matches the prefix exactly OR any suffix
--                including slashes. /admin/** matches both /admin AND
--                /admin/foo/bar. This is the "this or everything under it"
--                semantics most glob systems use.
--   /**/edit/*  ** in the middle matches any path segments (any chars)
--   /exact/path  exact match
-- ============================================================
function M.matches_glob(path, pattern)
	path = (path:match("^([^?#]+)") or path):gsub("%%7B", "{"):gsub("%%7D", "}")

	-- Special case: if the pattern ends with "/**", also accept the
	-- prefix without the trailing slash. So "/proofing/**" matches
	-- "/proofing", "/proofing/", and "/proofing/anything/here".
	local prefix = pattern:match("^(.+)/%*%*$")
	if prefix and prefix ~= "" then
		if path == prefix then
			return true
		end
	end

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

function M.tab_server_for(tab_path, server_tags, order)
	if not server_tags then
		return nil
	end
	if order then
		for _, name in ipairs(order) do
			local pats = server_tags[name]
			if type(pats) == "table" then
				for _, pat in ipairs(pats) do
					if M.matches_glob(tab_path, pat) then
						return name
					end
				end
			end
		end
	end
	for name, pats in pairs(server_tags) do
		if type(pats) == "table" then
			for _, pat in ipairs(pats) do
				if M.matches_glob(tab_path, pat) then
					return name
				end
			end
		end
	end
	return nil
end

return M
