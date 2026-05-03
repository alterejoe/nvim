-- after/plugin/browser.lua

local s = require("browser.session")
local v = require("browser.views")
local b = require("browser.cdp")
local g = require("browser.groups")

-- ------------------------------------------------------------
-- session
-- ------------------------------------------------------------
vim.keymap.set("n", "<leader>wb", s.start, { desc = "Browser: start" })
vim.keymap.set("n", "<leader>wq", s.stop, { desc = "Browser: stop all" })
vim.keymap.set("n", "<leader>wk", s.kill, { desc = "Browser: kill all (force)" })
vim.keymap.set("n", "<leader>wo", s.toggle_log, { desc = "Browser: toggle devproxy log" })
vim.keymap.set("n", "<leader>wR", s.restart, { desc = "Browser: restart devproxy" })
vim.keymap.set("n", "<leader>wB", function()
	local r = s.send_cmd("open-defaults")
	if r then
		vim.notify(r)
	end
end, { desc = "Browser: open default tabs" })

-- ------------------------------------------------------------
-- dashboard  (primary interface)
-- ------------------------------------------------------------
vim.keymap.set("n", "<leader>bb", function()
	require("browser.dashboard").open()
end, { desc = "Browser: dashboard" })

-- ------------------------------------------------------------
-- server / context
-- ------------------------------------------------------------
vim.keymap.set("n", "<leader>bS", v.server_pick, { desc = "Browser: switch server" })
vim.keymap.set("n", "<leader>bX", v.context_show, { desc = "Browser: show active context params" })

-- ------------------------------------------------------------
-- context cycling  (quick without opening dashboard)
-- ------------------------------------------------------------
vim.keymap.set("n", "<leader>b[", function()
	v.cycle_context(-1)
end, { desc = "Browser: previous context" })
vim.keymap.set("n", "<leader>b]", function()
	v.cycle_context(1)
end, { desc = "Browser: next context" })

-- ------------------------------------------------------------
-- group cycling  (navigate active group tabs without dashboard)
-- ------------------------------------------------------------
vim.keymap.set("n", "<leader>b}", function()
	g.cycle_next()
end, { desc = "Browser: next tab in active group" })
vim.keymap.set("n", "<leader>b{", function()
	g.cycle_prev()
end, { desc = "Browser: prev tab in active group" })
vim.keymap.set("n", "<leader>bQ", function()
	g.close_active()
end, { desc = "Browser: close active group tabs" })

-- ------------------------------------------------------------
-- refresh
-- ------------------------------------------------------------
vim.keymap.set("n", "<leader>bR", s.hard_refresh, { desc = "Browser: hard refresh (clear cache)" })
vim.keymap.set("n", "<leader>bA", s.auto_refresh, { desc = "Browser: auto-refresh toggle" })

-- ------------------------------------------------------------
-- viewport
-- ------------------------------------------------------------
vim.keymap.set("n", "<leader>bm", s.mobile_partial, { desc = "Browser: mobile partial" })
vim.keymap.set("n", "<leader>bM", s.mobile_full, { desc = "Browser: mobile full page" })
vim.keymap.set("n", "<leader>bd", s.desktop, { desc = "Browser: restore desktop" })

-- ------------------------------------------------------------
-- cdp / inspection
-- ------------------------------------------------------------
local function with_tab(fn)
	return function()
		s.pick_tab_then(function(id)
			fn(id)
		end)
	end
end

vim.keymap.set("n", "<leader>bc", with_tab(b.pick_console), { desc = "Browser: console picker (tab)" })
vim.keymap.set("n", "<leader>bq", with_tab(b.pick_network), { desc = "Browser: network picker (tab)" })
vim.keymap.set("n", "<leader>bn", with_tab(b.show_network_log), { desc = "Browser: network log (tab)" })
vim.keymap.set("n", "<leader>bl", with_tab(b.show_console_log), { desc = "Browser: console log (tab)" })
vim.keymap.set("n", "<leader>bi", with_tab(s.inject_css), { desc = "Browser: re-inject CSS (tab)" })
vim.keymap.set("n", "<leader>bN", b.clear_network, { desc = "Browser: clear network log" })
vim.keymap.set("n", "<leader>bC", b.clear_console, { desc = "Browser: clear console log" })
vim.keymap.set("n", "<leader>bP", function()
	local r = s.send_cmd("signin")
	if r then
		vim.notify(r)
	end
end, { desc = "Browser: sign in (.signin)" })

-- ------------------------------------------------------------
-- views.yaml management  (no dashboard equivalent)
-- ------------------------------------------------------------
vim.keymap.set("n", "<leader>bV", v.reload, { desc = "Browser: reload views config" })
vim.keymap.set("n", "<leader>ve", v.edit, { desc = "Browser: edit views.yaml" })
vim.keymap.set("n", "<leader>va", v.quick_add, { desc = "Browser: quick-add view" })

-- ------------------------------------------------------------
-- layout
-- ------------------------------------------------------------
vim.keymap.set("n", "<leader>bH", function()
	require("browser.layout").open(v._last_nav)
end, { desc = "Browser: layout editor" })
vim.keymap.set("n", "<leader>bI", function()
	s.send_cmd("clear-layout")
	vim.notify("browser: layout cleared")
end, { desc = "Browser: clear layout" })

-- ------------------------------------------------------------
-- html pattern search  (patterns defined in H view with 'a')
-- applies to any buffer - useful for tracking UUIDs, ids, etc.
-- ------------------------------------------------------------
vim.keymap.set("n", "<leader>ha", function()
	local patterns = require("browser.dashboard").get_patterns()
	if #patterns == 0 then
		vim.notify("browser: no html patterns - open H view and use 'a' to add one", vim.log.levels.WARN)
		return
	end
	vim.ui.select(
		vim.tbl_map(function(p)
			return p.name
		end, patterns),
		{ prompt = "Search pattern:" },
		function(choice)
			if not choice then
				return
			end
			for _, p in ipairs(patterns) do
				if p.name == choice then
					vim.fn.setreg("/", p.pattern)
					vim.opt.hlsearch = true
					vim.cmd("normal! n")
					vim.notify("browser: searching for '" .. p.name .. "'")
					break
				end
			end
		end
	)
end, { desc = "Browser: search for html pattern in current buffer" })
