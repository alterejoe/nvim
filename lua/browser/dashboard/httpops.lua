-- browser/dashboard/httpops.lua
--
-- Orchestrator. Re-exports the public API from the submodules under
-- dashboard/httpops/ so external callers (keymaps/views.lua,
-- keymaps/core.lua, dashboard.lua) can keep using:
--   httpops = require("browser.dashboard.httpops")
--   httpops.open_http_panel(meta, buf, state)
--   httpops.on_save_http(state)
--   httpops.curl_preview(state)
--
-- without touching their require sites.
--
-- Submodule responsibilities:
--   panel.lua  - open_http_panel + find_http_file. The renderer for
--                the e-view.
--   parse.lua  - parse_buffer. Splits the buffer into per-context
--                sections; shared by save and curl. The natural seam
--                where future format extensions (headers, body, form)
--                land first.
--   save.lua   - on_save_http. Persists path/query params and htmx,
--                re-navigates the current tab and any tabs that share
--                the changed path params.
--   curl.lua   - curl_preview. Background curl into the preview pane.
--   picker.lua - the ":" param picker keymap, installed by panel.lua
--                when the e-view opens.

local panel = require("browser.dashboard.httpops.panel")
local save = require("browser.dashboard.httpops.save")
local curl = require("browser.dashboard.httpops.curl")

local M = {}

M.open_http_panel = panel.open_http_panel
M.on_save_http = save.on_save_http
M.curl_preview = curl.curl_preview

return M
