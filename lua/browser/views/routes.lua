-- browser/views/routes.lua
--
-- plan.json route discovery + chi_path resolution.
--
-- Owns:
--   find_plan_path        - locate .forge/plan.json from cwd or forge_nav
--   get_routes            - parse plan.json into { chi_path, handler, ... } list
--   normalize_chi_path    - reduce a path expression to its canonical chi_path
--                           by structural match against plan.json routes
--   resolve_path          - substitute {param} segments using active context
--   resolve_path_for_context - same but for a named context
--
-- Depends on config.lua for active_params and params_for_context.
-- Does NOT depend on test_files / navigate / pickers.

local M = {}

local config = require("browser.views.config")

-- ============================================================
-- find_plan_path
-- Prefer forge_nav's project root if it's loaded; otherwise walk up
-- from cwd looking for a .forge/plan.json.
-- ============================================================
local function find_plan_path()
	local nav = package.loaded["forge_nav"]
	if nav and nav._project_root then
		return nav._project_root .. "/.forge/plan.json"
	end
	local dir = vim.fn.getcwd()
	while dir ~= "/" do
		local p = dir .. "/.forge/plan.json"
		if vim.fn.filereadable(p) == 1 then
			return p
		end
		dir = vim.fn.fnamemodify(dir, ":h")
	end
	return nil
end

-- ============================================================
-- get_routes
-- Returns a list of GET handler routes from plan.json. Each entry:
--   { kind, name, method, chi_path, handler, output }
-- Sorted by chi_path for stable picker order.
-- ============================================================
function M.get_routes()
	local plan_path = find_plan_path()
	if not plan_path then
		return {}
	end
	local f = io.open(plan_path, "r")
	if not f then
		return {}
	end
	local raw = f:read("*a")
	f:close()
	local ok, plan = pcall(vim.json.decode, raw)
	if not ok or not plan or not plan.actions then
		return {}
	end
	local routes = {}
	for _, action in ipairs(plan.actions) do
		if action.label == "handler" and action.data then
			local method = (action.data.route_method or "get"):upper()
			if method == "GET" and action.data.chi_path then
				table.insert(routes, {
					kind = "route",
					name = action.data.chi_path,
					method = method,
					chi_path = action.data.chi_path,
					handler = action.data.handler_func,
					output = action.output,
				})
			end
		end
	end
	table.sort(routes, function(a, b)
		return (a.chi_path or "") < (b.chi_path or "")
	end)
	return routes
end

-- ============================================================
-- normalize_chi_path
-- Maps any chi_path expression (literal URL with values, or template
-- with {param}) back to its canonical plan.json template form.
-- Match strategy:
--   1. Exact match against any route's chi_path -> return as-is
--   2. Structural match: same number of segments, params in the same
--      positions, static segments equal -> return the matched route's
--      chi_path
-- Falls back to the input if nothing matches.
-- ============================================================
function M.normalize_chi_path(chi_path)
	if not chi_path then
		return chi_path
	end
	local routes = M.get_routes()
	for _, r in ipairs(routes) do
		if r.chi_path == chi_path then
			return chi_path
		end
	end
	local function segs(s)
		local t = {}
		for seg in s:gsub("?.*$", ""):gmatch("[^/]+") do
			table.insert(t, seg)
		end
		return t
	end
	local c_segs = segs(chi_path)
	for _, r in ipairs(routes) do
		local r_segs = segs(r.chi_path)
		if #r_segs == #c_segs then
			local same = true
			for i, c in ipairs(c_segs) do
				local rs = r_segs[i]
				local c_param = c:sub(1, 1) == "{"
				local r_param = rs:sub(1, 1) == "{"
				if c_param ~= r_param or (not c_param and c ~= rs) then
					same = false
					break
				end
			end
			if same then
				return r.chi_path
			end
		end
	end
	return chi_path
end

-- ============================================================
-- resolve_path
-- Substitute {param} segments using the active context's params.
-- Any {param} without a value stays as-is (caller can detect by
-- looking for "{" in the result).
-- ============================================================
function M.resolve_path(chi_path)
	local params = config.active_params()
	local result = chi_path
	for param in chi_path:gmatch("{([^}]+)}") do
		if params[param] and params[param] ~= "" then
			result = result:gsub("{" .. param .. "}", params[param], 1)
		end
	end
	return result
end

-- ============================================================
-- resolve_path_for_context
-- Same as resolve_path but for an arbitrary named context. Used by
-- the http panel to render every context's resolved path.
-- ============================================================
function M.resolve_path_for_context(chi_path, ctx_name)
	local params = config.params_for_context(ctx_name)
	local result = chi_path
	for param in chi_path:gmatch("{([^}]+)}") do
		if params[param] and params[param] ~= "" then
			result = result:gsub("{" .. param .. "}", params[param], 1)
		end
	end
	return result
end

-- get_active_base lives in config.lua but is re-exported here so
-- callers thinking in "routes" terms can stay there. Same fn,
-- just a convenience.
M.get_active_base = config.get_active_base

return M
