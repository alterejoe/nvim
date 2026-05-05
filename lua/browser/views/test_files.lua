-- browser/views/test_files.lua
--
-- .http test file read/write + query string assembly.
--
-- Test file format:
--   htmx: true|false
--   query:
--     - keyname
--     - keyname
--
-- The query: block is a list of key NAMES only. Values for those
-- keys live in config.yaml under contexts.<ctx>.query.<chi>.<key>
-- so values are context-swappable while the key list is per-route.
--
-- Public API:
--   test_file_path(chi_path, ctx_name)  -> path on disk
--   parse_test_file(fpath)               -> { htmx, query_keys }  (private helper exposed for write_test_file callers)
--   load_test_for_path(chi_path)         -> { htmx, query_keys, query_string }
--   write_test_file(chi_path, ctx, opts) -> bool   -- merge-write
--   save_htmx_for_path(chi_path, htmx)   -> ()     -- thin wrapper
--   query_for_route(ctx, chi, filter_keys?) -> map
--   build_query_string(map)              -> "?k=v&..."
--   build_query_template(map)            -> "?k={k}&..."
--
-- Depends on config.lua (for ensure_context_loaded, get_config,
-- get_active_context) and routes.lua (for normalize_chi_path).

local M = {}

local config = require("browser.views.config")
local routes = require("browser.views.routes")

-- ============================================================
-- test_file_path
-- Slug rule: drop leading/trailing /, replace / with -, drop {}.
-- Files for the default context live at TESTS_DIR/<slug>.http.
-- Files for named contexts live at TESTS_DIR/<ctx>/<slug>.http.
-- ============================================================
function M.test_file_path(chi_path, ctx_name)
	chi_path = routes.normalize_chi_path(chi_path)
	local session = require("browser.session")
	local slug = (chi_path or "unknown"):gsub("/$", ""):gsub("^/", ""):gsub("/", "-"):gsub("{", ""):gsub("}", "")
	if ctx_name and ctx_name ~= "default" and ctx_name ~= "" then
		return session.TESTS_DIR .. "/" .. ctx_name .. "/" .. slug .. ".http"
	else
		return session.TESTS_DIR .. "/" .. slug .. ".http"
	end
end

-- ============================================================
-- parse_test_file
-- Reads a single .http file into { htmx, query_keys }. Used by
-- load_test_for_path AND write_test_file (the writer needs to read
-- existing values to preserve fields the caller didn't pass).
-- ============================================================
function M.parse_test_file(fpath)
	local result = { htmx = nil, query_keys = {} }
	local f = io.open(fpath, "r")
	if not f then
		return result
	end
	local in_query = false
	for line in f:lines() do
		-- Indented "- name" under query:
		local q_item = line:match("^%s%s+%-%s*(.+)%s*$")
		if in_query and q_item then
			local key = vim.trim(q_item)
			if key ~= "" then
				table.insert(result.query_keys, key)
			end
		else
			local label, val = line:match("^([%w%.%-_]+):%s*(.*)")
			if label then
				local low = label:lower()
				if low == "htmx" then
					result.htmx = vim.trim(val) == "true"
					in_query = false
				elseif low == "query" then
					in_query = true
				else
					in_query = false
				end
			end
		end
	end
	f:close()
	return result
end

-- ============================================================
-- query_for_route
-- Returns map of query params for a chi_path under a named context.
-- filter_keys (optional list): when provided, only keys in this list
-- are returned. Missing keys default to "" so callers can render the
-- key alongside an empty value. Returns {} when none configured and
-- no filter is given.
-- ============================================================
function M.query_for_route(ctx_name, chi_path, filter_keys)
	if not chi_path or chi_path == "" then
		return {}
	end
	local cfg = config.get_config()
	local ctx = cfg.contexts[ctx_name]
	local route_q = nil
	if type(ctx) == "table" then
		local q = ctx.query
		if type(q) == "table" and q ~= vim.NIL then
			local rq = q[chi_path]
			if type(rq) == "table" and rq ~= vim.NIL then
				route_q = rq
			end
		end
	end

	if filter_keys and #filter_keys > 0 then
		-- Filter mode: return one entry per filter key, defaulting to "".
		local out = {}
		for _, k in ipairs(filter_keys) do
			local v = route_q and route_q[k]
			if v ~= nil and v ~= vim.NIL then
				out[tostring(k)] = tostring(v)
			else
				out[tostring(k)] = ""
			end
		end
		return out
	end

	-- Unfiltered mode: return everything in config for this route.
	local out = {}
	if route_q then
		for k, v in pairs(route_q) do
			if v ~= nil and v ~= vim.NIL then
				out[tostring(k)] = tostring(v)
			end
		end
	end
	return out
end

-- ============================================================
-- build_query_string
-- "?k=v&k=v" form. Keys sorted for stability. Values not URL-encoded
-- (matches existing behavior of saved.qp).
-- ============================================================
function M.build_query_string(params)
	if type(params) ~= "table" then
		return ""
	end
	local keys = {}
	for k in pairs(params) do
		table.insert(keys, k)
	end
	if #keys == 0 then
		return ""
	end
	table.sort(keys)
	local parts = {}
	for _, k in ipairs(keys) do
		local v = params[k]
		if v ~= nil and v ~= "" then
			table.insert(parts, k .. "=" .. tostring(v))
		end
	end
	if #parts == 0 then
		return ""
	end
	return "?" .. table.concat(parts, "&")
end

-- ============================================================
-- build_query_template
-- "?k={k}&k={k}" form for templated-mode display.
-- ============================================================
function M.build_query_template(params)
	if type(params) ~= "table" then
		return ""
	end
	local keys = {}
	for k in pairs(params) do
		table.insert(keys, k)
	end
	if #keys == 0 then
		return ""
	end
	table.sort(keys)
	local parts = {}
	for _, k in ipairs(keys) do
		table.insert(parts, k .. "={" .. k .. "}")
	end
	return "?" .. table.concat(parts, "&")
end

-- ============================================================
-- load_test_for_path
-- Returns { htmx, query_keys, query_string }. query_string is the
-- rendered "k=v&k=v" form (no leading "?") assembled from config.yaml
-- values filtered to query_keys. Empty when no keys or no values.
-- ============================================================
function M.load_test_for_path(chi_path)
	config.ensure_context_loaded()
	chi_path = routes.normalize_chi_path(chi_path)
	local fpath = M.test_file_path(chi_path, config.get_active_context())
	local parsed = M.parse_test_file(fpath)

	local q_map = {}
	if #parsed.query_keys > 0 then
		q_map = M.query_for_route(config.get_active_context(), chi_path, parsed.query_keys)
	end
	local qstr = M.build_query_string(q_map):gsub("^%?", "")

	return {
		htmx = parsed.htmx,
		query_keys = parsed.query_keys,
		query_string = qstr,
	}
end

-- ============================================================
-- write_test_file
-- Canonical writer. Reads the existing file, merges the provided
-- fields with what's already there, writes back. Pass nil for any
-- field to leave it unchanged.
--
-- Use this instead of writing test files inline in callers, so we
-- never accidentally clobber a sibling field (htmx, query_keys).
-- ============================================================
function M.write_test_file(chi_path, ctx_name, opts)
	opts = opts or {}
	chi_path = routes.normalize_chi_path(chi_path)
	local fpath = M.test_file_path(chi_path, ctx_name)
	local existing = M.parse_test_file(fpath)

	local htmx = opts.htmx
	if htmx == nil then
		htmx = existing.htmx
	end

	local query_keys = opts.query_keys
	if query_keys == nil then
		query_keys = existing.query_keys
	end

	local lines = {}
	if htmx ~= nil then
		table.insert(lines, "htmx: " .. tostring(htmx))
	end
	if query_keys and #query_keys > 0 then
		-- Stable order: write keys in the order provided.
		table.insert(lines, "query:")
		for _, k in ipairs(query_keys) do
			table.insert(lines, "  - " .. k)
		end
	end

	vim.fn.mkdir(vim.fn.fnamemodify(fpath, ":h"), "p")
	local wf = io.open(fpath, "w")
	if not wf then
		return false
	end
	for _, l in ipairs(lines) do
		wf:write(l .. "\n")
	end
	wf:close()
	return true
end

-- ============================================================
-- save_htmx_for_path
-- Thin wrapper over write_test_file. Preserves existing query_keys
-- when toggling htmx alone.
-- ============================================================
function M.save_htmx_for_path(chi_path, htmx)
	config.ensure_context_loaded()
	M.write_test_file(chi_path, config.get_active_context(), { htmx = htmx })
end

return M
