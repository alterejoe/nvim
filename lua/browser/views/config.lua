-- browser/views/config.lua
--
-- Config loading + context state for the browser plugin.
--
-- Owns:
--   _config            - parsed config.yaml (defaults, query_params, contexts, exceptions)
--   _context           - active context name (default initially)
--   _context_loaded    - lazy-load gate so we don't read disk on every call
--   _nav_history       - in-memory list of recent navigations (used by pickers)
--
-- Storage:
--   active context persisted in .devproxy/active_context (single line)
--   config.yaml lives in .devproxy/config.yaml
--
-- Other submodules require this one to read context state and params.
-- This module does NOT require navigate / pickers / test_files; those
-- depend on us, not the other way.

local M = {}

local function send_cmd(cmd)
	return require("browser.session").send_cmd(cmd)
end

local function devproxy_dir()
	return require("browser.session").DEVPROXY_DIR
end
M.devproxy_dir = devproxy_dir

-- ============================================================
-- Active server base url (port lookup over socket).
-- Lives here because it's used by both navigate and pickers; routing
-- it through here avoids each submodule re-implementing the lookup.
-- ============================================================
function M.get_active_base()
	local raw = send_cmd("active-server")
	if raw then
		local port = raw:match("port (%d+)")
		if port then
			return "http://localhost:" .. port
		end
	end
	return "http://localhost:3333"
end

-- ============================================================
-- find_project_root
-- Resolves the project root directory. Used by the file-open action
-- in pickers and by ensure_context_loaded for fallback paths.
-- ============================================================
function M.find_project_root()
	local nav = package.loaded["forge_nav"]
	if nav and nav._project_root then
		return nav._project_root
	end
	local dir = devproxy_dir()
	if dir and dir ~= "" then
		return vim.fn.fnamemodify(dir, ":h")
	end
	return vim.fn.getcwd()
end

-- ============================================================
-- Context state (private to this module)
-- ============================================================
local _config = nil
local _context = "default"
local _context_loaded = false

-- Navigation history (in-memory). pickers.pick_recent reads this;
-- navigate.do_navigate appends to it. Exposed so callers can poke it
-- through the orchestrator (e.g. M._nav_history).
M._nav_history = {}

local function persist_context(name)
	local f = io.open(devproxy_dir() .. "/active_context", "w")
	if f then
		f:write(name)
		f:close()
	end
end

local function ensure_context_loaded()
	if _context_loaded then
		return
	end
	_context_loaded = true
	local f = io.open(devproxy_dir() .. "/active_context", "r")
	if f then
		local name = vim.trim(f:read("*a"))
		f:close()
		if name and name ~= "" then
			_context = name
		end
	end
end
M.ensure_context_loaded = ensure_context_loaded

local function load_config()
	local path = devproxy_dir() .. "/config.yaml"
	if vim.fn.filereadable(path) == 0 then
		_config = { defaults = {}, query_params = {}, contexts = {}, exceptions = {} }
		return
	end
	local raw = vim.fn.system("yq -o=json . " .. vim.fn.shellescape(path) .. " 2>/dev/null")
	local ok, data = pcall(vim.json.decode, raw)
	if not ok or not data then
		_config = { defaults = {}, query_params = {}, contexts = {}, exceptions = {} }
	else
		_config = {
			defaults = data.defaults or {},
			query_params = data.query_params or {},
			contexts = data.contexts or {},
			exceptions = data.exceptions or {},
		}
	end
end

function M.get_config()
	if not _config then
		load_config()
	end
	return _config
end

function M.reload_config()
	_config = nil
	load_config()
	vim.notify("browser.views: config reloaded from " .. (devproxy_dir() or "?"))
end

function M.reload_config_silent()
	_config = nil
	load_config()
end

-- ============================================================
-- Param map cleaning + merging.
-- vim.json.decode produces vim.NIL for null. clean_param_map strips
-- those and skips the "query" sub-table since it isn't a path param.
-- ============================================================
local function clean_param_map(t)
	if type(t) ~= "table" then
		return {}
	end
	local out = {}
	for k, v in pairs(t) do
		if k ~= "query" and v ~= nil and v ~= vim.NIL then
			out[k] = tostring(v)
		end
	end
	return out
end

-- Merged params for the active context: defaults < contexts.<ctx>
function M.active_params()
	ensure_context_loaded()
	local cfg = M.get_config()
	local params = {}
	for k, v in pairs(clean_param_map(cfg.defaults)) do
		params[k] = v
	end
	local ctx = cfg.contexts[_context] or {}
	for k, v in pairs(clean_param_map(ctx)) do
		params[k] = v
	end
	return params
end

-- Merged params for a specific named context.
function M.params_for_context(ctx_name)
	local cfg = M.get_config()
	local params = {}
	for k, v in pairs(clean_param_map(cfg.defaults)) do
		params[k] = v
	end
	local ctx = cfg.contexts[ctx_name] or {}
	for k, v in pairs(clean_param_map(ctx)) do
		params[k] = v
	end
	return params
end

-- ============================================================
-- Context switching + listing.
-- ============================================================
function M.switch_context(name)
	ensure_context_loaded()
	_context = name
	persist_context(name)
end

function M.get_active_context()
	ensure_context_loaded()
	return _context
end

local function get_contexts()
	local session = require("browser.session")
	local tests = session.TESTS_DIR
	local contexts = { "default" }
	local handle = vim.loop.fs_scandir(tests)
	if handle then
		while true do
			local name, typ = vim.loop.fs_scandir_next(handle)
			if not name then
				break
			end
			if typ == "directory" then
				table.insert(contexts, name)
			end
		end
	end
	table.sort(contexts, function(a, b)
		if a == "default" then
			return true
		end
		if b == "default" then
			return false
		end
		return a < b
	end)
	return contexts
end
M.get_contexts = get_contexts

function M.cycle_context(dir)
	ensure_context_loaded()
	local contexts = get_contexts()
	if #contexts <= 1 then
		vim.notify("browser: only one context available", vim.log.levels.INFO)
		return _context
	end
	local idx = 1
	for i, name in ipairs(contexts) do
		if name == _context then
			idx = i
			break
		end
	end
	_context = contexts[((idx - 1 + dir) % #contexts) + 1]
	persist_context(_context)
	vim.notify("browser: context -> " .. _context)
	return _context
end

function M.context_show()
	ensure_context_loaded()
	local params = M.active_params()
	local lines = { "Context: " .. _context, "Project: " .. M.find_project_root(), "", "Active params:" }
	for k, v in pairs(params) do
		table.insert(lines, string.format("  %-20s = %s", k, v))
	end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"
	vim.api.nvim_buf_set_name(buf, "devproxy-context")
	vim.cmd("vsplit")
	vim.api.nvim_win_set_buf(0, buf)
end

return M
