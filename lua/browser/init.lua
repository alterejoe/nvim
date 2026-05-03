-- browser/init.lua
-- Single require point for the browser plugin.
-- Consumers: require("browser").session, .views, .groups, .cdp, .test, .layout, .dashboard
local M = {}

M.session = require("browser.session")
M.views = require("browser.views")
M.groups = require("browser.groups")
M.cdp = require("browser.cdp")
M.test = require("browser.test")
M.layout = require("browser.layout")
M.dashboard = require("browser.dashboard")

return M
