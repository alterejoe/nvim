-- browser/dashboard/tabops.lua
--
-- Orchestrator. Re-exports the public API from the submodules under
-- dashboard/tabops/ so external callers (groups.lua, dashboard.lua,
-- keymaps/*) can keep using:
--   tabops = require("browser.dashboard.tabops")
--   tabops.fetch_tabs(...)
--   tabops.build_tab_lines(...)
--   tabops.make_content(...)
--   tabops.infer_chi_path(...)
--   tabops.load_tags() / save_tags() / load_headings() / save_headings()
--   tabops.load_server_tags() / save_server_tags()
--   tabops.tab_server_for(...)
--   tabops.navigate_tab(...) / open_path(...)
--   tabops.on_save_tabs(state)
--
-- without touching their require sites.

local yaml_io = require("browser.dashboard.tabops.yaml_io")
local fetch = require("browser.dashboard.tabops.fetch")
local render = require("browser.dashboard.tabops.render")
local navigate = require("browser.dashboard.tabops.navigate")
local save = require("browser.dashboard.tabops.save")

local M = {}

-- yaml_io
M.load_tags = yaml_io.load_tags
M.save_tags = yaml_io.save_tags
M.load_headings = yaml_io.load_headings
M.save_headings = yaml_io.save_headings
M.load_server_tags = yaml_io.load_server_tags
M.save_server_tags = yaml_io.save_server_tags
M.tab_server_for = yaml_io.tab_server_for
M.matches_glob = yaml_io.matches_glob

-- fetch
M.fetch_tabs = fetch.fetch_tabs
M.infer_chi_path = fetch.infer_chi_path
M.make_content = fetch.make_content

-- render
M.build_tab_lines = render.build_tab_lines

-- navigate
M.navigate_tab = navigate.navigate_tab
M.open_path = navigate.open_path

-- save
M.on_save_tabs = save.on_save_tabs

return M
