-- after/plugin/browser.lua

local s = require("browser_session")
local v = require("browser_views")
local b = require("browser")

-- ÄÄ session ÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄ
vim.keymap.set("n", "<leader>wb", s.start,      { desc = "Browser: start" })
vim.keymap.set("n", "<leader>wq", s.stop,       { desc = "Browser: stop all" })
vim.keymap.set("n", "<leader>wk", s.kill,       { desc = "Browser: kill all (force)" })
vim.keymap.set("n", "<leader>wo", s.toggle_log, { desc = "Browser: toggle devproxy log" })
vim.keymap.set("n", "<leader>wR", s.restart,    { desc = "Browser: restart devproxy" })
vim.keymap.set("n", "<leader>wB", function()
    local r = s.send_cmd("open-defaults")
    if r then vim.notify(r) end
end, { desc = "Browser: open default tabs" })

-- ÄÄ picker ÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄ
vim.keymap.set("n", "<leader>bv", v.pick,        { desc = "Browser: view/route picker" })
vim.keymap.set("n", "<leader>bV", v.reload,      { desc = "Browser: reload views config" })
vim.keymap.set("n", "<leader>ve", v.edit,        { desc = "Browser: edit views.yaml" })
vim.keymap.set("n", "<leader>va", v.quick_add,   { desc = "Browser: quick-add view" })
vim.keymap.set("n", "<leader>be", v.edit_params, { desc = "Browser: edit params for last navigation" })
vim.keymap.set("n", "<leader>bS", v.server_pick, { desc = "Browser: switch server" })
vim.keymap.set("n", "<leader>bx", v.context_pick,{ desc = "Browser: switch context" })
vim.keymap.set("n", "<leader>bX", v.context_show,{ desc = "Browser: show active context params" })
vim.keymap.set("n", "<leader>br", function() v.pick_recent() end,   { desc = "Browser: recent navigations" })
vim.keymap.set("n", "<leader>bp", function() v.toggle_mode() end,   { desc = "Browser: toggle partial/full mode" })

-- ÄÄ tabs ÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄ
vim.keymap.set("n", "<leader>bt", s.tab_picker, { desc = "Browser: tab picker" })

-- ÄÄ groups ÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄ
vim.keymap.set("n", "<leader>bg", function() require("browser_groups").pick() end,         { desc = "Browser: group picker" })
vim.keymap.set("n", "<leader>bG", function() require("browser_groups").manage() end,       { desc = "Browser: manage groups for current path" })
vim.keymap.set("n", "<leader>b]", function() require("browser_groups").cycle_next() end,   { desc = "Browser: next tab in active group" })
vim.keymap.set("n", "<leader>b[", function() require("browser_groups").cycle_prev() end,   { desc = "Browser: prev tab in active group" })
vim.keymap.set("n", "<leader>bQ", function() require("browser_groups").close_active() end, { desc = "Browser: close active group tabs" })

-- ÄÄ refresh ÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄ
vim.keymap.set("n", "<leader>bR", s.hard_refresh, { desc = "Browser: hard refresh (clear cache)" })
vim.keymap.set("n", "<leader>bA", s.auto_refresh,  { desc = "Browser: auto-refresh toggle" })

-- ÄÄ viewport ÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄ
vim.keymap.set("n", "<leader>bm", s.mobile_partial, { desc = "Browser: mobile partial" })
vim.keymap.set("n", "<leader>bM", s.mobile_full,    { desc = "Browser: mobile full page" })
vim.keymap.set("n", "<leader>bd", s.desktop,        { desc = "Browser: restore desktop" })

-- ÄÄ cdp / inspection (tab-aware) ÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄ
local function with_tab(fn)
    return function()
        s.pick_tab_then(function(id)
            s.send_cmd("switch " .. id)
            fn()
        end)
    end
end

vim.keymap.set("n", "<leader>bc", with_tab(b.pick_console),     { desc = "Browser: console picker (tab)" })
vim.keymap.set("n", "<leader>bq", with_tab(b.pick_network),     { desc = "Browser: network picker (tab)" })
vim.keymap.set("n", "<leader>bn", with_tab(b.show_network_log), { desc = "Browser: network log (tab)" })
vim.keymap.set("n", "<leader>bl", with_tab(b.show_console_log), { desc = "Browser: console log (tab)" })
vim.keymap.set("n", "<leader>bD", with_tab(b.dom_dump),         { desc = "Browser: DOM dump (tab)" })
vim.keymap.set("n", "<leader>bi", with_tab(s.inject_css),       { desc = "Browser: re-inject CSS (tab)" })
vim.keymap.set("n", "<leader>bN", b.clear_network,              { desc = "Browser: clear network log" })
vim.keymap.set("n", "<leader>bC", b.clear_console,              { desc = "Browser: clear console log" })

vim.keymap.set("n", "<leader>bP", function()
    local r = s.send_cmd("signin")
    if r then vim.notify(r) end
end, { desc = "Browser: sign in (.signin)" })

-- ÄÄ test editor ÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄ
vim.keymap.set("n", "<leader>bT", function()
    require("browser_test").open(v._last_nav)
end, { desc = "Browser: test editor for last navigation" })
vim.keymap.set("n", "<leader>bL", function()
    require("browser_test").load_pick()
end, { desc = "Browser: load saved browser test" })

-- ÄÄ layout ÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄ
vim.keymap.set("n", "<leader>bH", function()
    require("browser_layout").open(v._last_nav)
end, { desc = "Browser: layout editor" })
vim.keymap.set("n", "<leader>bI", function()
    s.send_cmd("clear-layout")
    vim.notify("browser: layout cleared")
end, { desc = "Browser: clear layout" })
