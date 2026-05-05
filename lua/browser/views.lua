-- browser/views.lua
--
-- Orchestrator. Re-exports the public API from the submodules under
-- browser/views/ so external callers (groups.lua, dashboard.lua, the
-- dashboard submodules, after/plugin/browser.lua, layout.lua, test.lua)
-- can keep using:
--   local views = require("browser.views")
-- and reach everything via views.foo without touching require sites.
--
-- Submodule responsibilities:
--   config.lua      - config.yaml loading, context state, params, project root
--   routes.lua      - plan.json discovery, chi_path resolution + normalization
--   test_files.lua  - .http file read/write, query helpers, save_htmx_for_path
--   navigate.lua    - do_navigate, open_in_tab, toggle_mode (mutates _last_nav and _nav_history)
--   pickers.lua     - all telescope pickers + views.yaml management
--
-- _last_nav and _nav_history live HERE on the orchestrator's M table
-- (not on navigate.lua's M) so external readers like
--   require("browser.views")._last_nav
-- and writers like
--   require("browser.views")._last_nav = ...
-- continue to work unchanged. navigate.lua mutates them through the
-- same require handle.

local config = require("browser.views.config")
local routes = require("browser.views.routes")
local test_files = require("browser.views.test_files")
local navigate = require("browser.views.navigate")
local pickers = require("browser.views.pickers")

local M = {}

-- ============================================================
-- State on the orchestrator (read/written by navigate + pickers
-- through require("browser.views")).
-- ============================================================
M._last_nav = nil
M._nav_history = config._nav_history or {}

-- ============================================================
-- config.lua re-exports
-- ============================================================
M.get_config = config.get_config
M.get_contexts = config.get_contexts
M.get_active_context = config.get_active_context
M.switch_context = config.switch_context
M.cycle_context = config.cycle_context
M.params_for_context = config.params_for_context
M.context_show = config.context_show
M.reload_config = config.reload_config
M.reload_config_silent = config.reload_config_silent
M.get_active_base = config.get_active_base

-- ============================================================
-- routes.lua re-exports
-- ============================================================
M.get_routes = routes.get_routes
M.normalize_chi_path = routes.normalize_chi_path
M.resolve_path = routes.resolve_path
M.resolve_path_for_context = routes.resolve_path_for_context

-- ============================================================
-- test_files.lua re-exports
-- ============================================================
M.test_file_path = test_files.test_file_path
M.load_test_for_path = test_files.load_test_for_path
M.write_test_file = test_files.write_test_file
M.save_htmx_for_path = test_files.save_htmx_for_path
M.query_for_route = test_files.query_for_route
M.build_query_string = test_files.build_query_string
M.build_query_template = test_files.build_query_template

-- ============================================================
-- navigate.lua re-exports
-- ============================================================
M.do_navigate = navigate.do_navigate
M.open_in_tab = navigate.open_in_tab
M.toggle_mode = navigate.toggle_mode

-- ============================================================
-- pickers.lua re-exports
-- ============================================================
M.keys = pickers.keys
M.pick = pickers.pick
M.pick_recent = pickers.pick_recent
M.context_pick = pickers.context_pick
M.server_pick = pickers.server_pick
M.reload = pickers.reload
M.edit = pickers.edit
M.quick_add = pickers.quick_add
M._append_view = pickers._append_view

return M
