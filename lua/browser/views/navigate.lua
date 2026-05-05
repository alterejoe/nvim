-- browser/views/navigate.lua
--
-- Navigation actions originating from the views layer.
--
-- _last_nav and _nav_history live on the orchestrator (browser.views)
-- so external callers (groups.lua, layout.lua, etc.) can keep reading
-- via require("browser.views")._last_nav unchanged. We mutate them
-- through that orchestrator handle.

local M = {}

local config = require("browser.views.config")
local routes = require("browser.views.routes")
local test_files = require("browser.views.test_files")

local function send_cmd(cmd)
	return require("browser.session").send_cmd(cmd)
end

-- ============================================================
-- do_navigate
-- Resolves chi_path against the active context, looks up the test
-- file's query keys, assembles the query string from config values
-- filtered to those keys, and fires navigate / navigate-full.
-- Updates the orchestrator's _last_nav and _nav_history.
-- ============================================================
function M.do_navigate(chi_path, htmx)
	chi_path = routes.normalize_chi_path(chi_path)
	local path = routes.resolve_path(chi_path)
	if not path or path:find("{") then
		vim.notify("browser: unresolved params in " .. chi_path, vim.log.levels.WARN)
		return
	end
	config.ensure_context_loaded()
	local saved = test_files.load_test_for_path(chi_path)
	local q_map = test_files.query_for_route(config.get_active_context(), chi_path, saved.query_keys)
	local qp = test_files.build_query_string(q_map)

	local orch = require("browser.views")
	orch._last_nav = {
		chi_path = chi_path,
		resolved = path,
		qp = qp,
		htmx = htmx,
		params_used = config.active_params(),
		skip = {},
	}
	-- Also push to history (cap at 50 most recent).
	orch._nav_history = orch._nav_history or {}
	table.insert(orch._nav_history, 1, orch._last_nav)
	while #orch._nav_history > 50 do
		table.remove(orch._nav_history)
	end

	local base = config.get_active_base()
	local cmd = htmx and "navigate" or "navigate-full"
	-- Phase 1 strict: navigate requires --tab=<id>. do_navigate's
	-- intent is "navigate the active tab" so we look up the active
	-- id once and pass it explicitly. If devproxy doesn't know the
	-- active tab (e.g. no tabs), we fall through with no id and
	-- devproxy will return an error - we surface it as a notify.
	local session = require("browser.session")
	local id = session.active_tab_id()
	if not id then
		vim.notify("browser: no active tab to navigate", vim.log.levels.WARN)
		return
	end
	local resp = send_cmd(cmd .. " --tab=" .. id .. " " .. base .. path .. qp)
	if resp and vim.startswith(resp, "err:") then
		vim.notify("browser: " .. resp, vim.log.levels.WARN)
		return
	end
	local hx_label = htmx and " [partial]" or " [full]"
	vim.notify(string.format("browser: %s%s%s", path, qp, hx_label))
end

-- ============================================================
-- toggle_mode
-- Re-fires the last navigation with htmx flipped.
-- ============================================================
function M.toggle_mode()
	local orch = require("browser.views")
	local nav = orch._last_nav
	if not nav then
		vim.notify("browser: no navigation recorded", vim.log.levels.WARN)
		return
	end
	M.do_navigate(nav.chi_path, not nav.htmx)
end

-- ============================================================
-- open_in_tab
-- Opens a new tab to chi_path resolved against the active context.
-- Honors the test file's htmx preference for the follow-up navigate
-- (since "open" is always full-page, a partial test routes through
-- a deferred navigate after the tab settles).
-- ============================================================
function M.open_in_tab(chi_path)
	chi_path = routes.normalize_chi_path(chi_path)
	local path = routes.resolve_path(chi_path)
	if not path then
		return nil
	end
	config.ensure_context_loaded()
	local saved = test_files.load_test_for_path(chi_path)
	local qp = test_files.build_query_string(
		test_files.query_for_route(config.get_active_context(), chi_path, saved.query_keys)
	)
	local port = (send_cmd("active-server") or ""):match("port (%d+)") or "3333"
	local url = "http://localhost:" .. port .. path .. qp
	-- The `open` response is "ok: opened tab <id> -> <url>". We parse
	-- the new tab id out so the deferred follow-up navigate can target
	-- it explicitly via --tab= (phase 1 strict).
	local open_resp = send_cmd("open " .. url) or ""
	local new_id = open_resp:match("opened tab (%S+)")
	local htmx = saved and saved.htmx
	if htmx and new_id then
		vim.defer_fn(function()
			send_cmd("navigate --tab=" .. new_id .. " " .. url)
		end, 800)
	end
	return url
end

return M
