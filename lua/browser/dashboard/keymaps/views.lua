-- browser/dashboard/keymaps/views.lua
--
-- Per-panel action keymaps. Each of these dispatches based on view_mode
-- (or split_view when the cursor is in the split). All of them are
-- split-aware: pressing the key with the cursor in the split affects
-- the split; with the cursor in primary affects primary.
--
--   e   - HTTP context editor (open / return)
--   H   - HTML source viewer  (open / return)
--   b   - HTML body / full toggle
--   U   - jump to next UUID in HTML
--   P   - jump to next htmx partial (hx-get/hx-post/etc) in HTML
--   T   - jump to next hx-trigger in HTML
--   Y   - jump to next hx-target in HTML
--   S   - jump to next hx-swap in HTML
--   B   - jump to next hx-boost in HTML
--   A   - add a named html search pattern
--   ?   - HTML pattern picker
--   c   - console log         (open / return)
--   C   - clear console
--   n   - network log         (open / return)
--   N   - clear network log
--   R   - toggle req/res in network preview

local M = {}

local util = require("browser.dashboard.util")
local httpops = require("browser.dashboard.httpops")
local logops = require("browser.dashboard.logops")
local htmlops = require("browser.dashboard.htmlops")

local function send_cmd(cmd)
	return require("browser.session").send_cmd(cmd)
end

function M.register(ctx)
	local buf = ctx.buf
	local win = ctx.win
	local state = ctx.state
	local map = ctx.map
	local restore_tabs = ctx.restore_tabs
	local current_meta = ctx.current_meta
	local is_in_split = ctx.is_in_split
	local split_selected_meta = ctx.split_selected_meta
	local split_set = ctx.split_set
	local split_restore_tabs = ctx.split_restore_tabs

	-- ----------------------------------------------------------------
	-- html_motion: shared dispatcher for all htmx motion keymaps.
	-- Picks primary or split buf/win based on focus, then forwards to
	-- the right htmlops function. Returns true if it handled the press,
	-- false otherwise (caller falls through to other behaviors).
	-- ----------------------------------------------------------------
	local function html_motion(jump_fn)
		if is_in_split() and state.split_view == "html" then
			jump_fn(state.split_buf, state.split_win)
			return true
		end
		if state.view_mode == "html" then
			jump_fn(buf, win)
			return true
		end
		return false
	end

	-- ----------------------------------------------------------------
	-- e: HTTP context editor (split-aware)
	-- In primary: opens the full http panel via httpops.open_http_panel.
	-- In split: renders a lightweight per-context summary (path, query)
	-- without entering the http_panel state machine.
	-- ----------------------------------------------------------------
	map("e", function()
		if is_in_split() then
			if state.split_view == "http" then
				split_restore_tabs()
				return
			end
			local meta = split_selected_meta()
			if not meta then
				vim.notify("browser: no tab selected", vim.log.levels.WARN)
				return
			end
			local views = require("browser.views")
			local chi_path = meta.chi_path or meta.path
			local routes = views.get_routes()
			for _, r in ipairs(routes) do
				if util.path_matches_chi(meta.path, r.chi_path) then
					chi_path = r.chi_path
					break
				end
			end
			local contexts = views.get_contexts()
			local lines = { "# " .. chi_path, "" }
			for _, ctx_name in ipairs(contexts) do
				table.insert(lines, "--- context: " .. ctx_name .. " ---")
				local injected = views.resolve_path_for_context(chi_path, ctx_name)
				table.insert(lines, "path: " .. injected)
				local saved = views.load_test_for_path(chi_path)
				table.insert(lines, "query: " .. (saved and saved.query_string or ""))
			end
			split_set(lines, "http", false)
			state.split_view = "http"
			vim.notify("browser: split http - e/r=back")
			return
		end
		if state.view_mode == "http" then
			restore_tabs(buf)
			return
		end
		local meta = current_meta()
		if not meta then
			for _, m in pairs(state.tab_metadata) do
				if m.tab_id == state.preview_tab_id then
					meta = m
					break
				end
			end
		end
		if not meta then
			vim.notify("browser: no tab selected", vim.log.levels.WARN)
			return
		end
		httpops.open_http_panel(meta, buf, state)
	end, "HTTP context editor")

	-- ----------------------------------------------------------------
	-- H: HTML source viewer (split-aware)
	-- ----------------------------------------------------------------
	map("H", function()
		if is_in_split() then
			if state.split_view == "html" then
				split_restore_tabs()
				return
			end
			local meta = split_selected_meta()
			if not meta then
				vim.notify("browser: no tab selected", vim.log.levels.WARN)
				return
			end
			local body = send_cmd("page-source-body " .. meta.tab_id)
			if not body or vim.startswith(body, "err:") then
				vim.notify("browser: " .. (body or "no response"), vim.log.levels.WARN)
				return
			end
			state.split_html_body = vim.split(util.format_html(body), "\n", { plain = true })
			state.split_html_full = nil
			state.split_html_show_full = false
			state.split_html_meta = meta
			split_set(state.split_html_body, "html", true)
			state.split_view = "html"
			vim.notify("browser: split html - b=head U=uuid P=partial T=trigger Y=target S=swap B=boost  H/r=back")
			return
		end
		if state.view_mode == "html" then
			restore_tabs(buf)
			return
		end
		local meta = current_meta()
		if not meta then
			for _, m in pairs(state.tab_metadata) do
				if m.tab_id == state.preview_tab_id then
					meta = m
					break
				end
			end
		end
		if not meta then
			vim.notify("browser: no tab selected", vim.log.levels.WARN)
			return
		end
		htmlops.open_html(meta, buf, state)
	end, "HTML source viewer")

	-- ----------------------------------------------------------------
	-- b: body/head toggle (html view, split-aware)
	-- In split, lazily fetches full source on first switch into "head".
	-- ----------------------------------------------------------------
	map("b", function()
		if is_in_split() then
			if state.split_view ~= "html" then
				return
			end
			local lines
			if state.split_html_show_full then
				state.split_html_show_full = false
				lines = state.split_html_body or { "-- no body --" }
			else
				if not state.split_html_full and state.split_html_meta then
					local full = send_cmd("page-source " .. state.split_html_meta.tab_id)
					if full and not vim.startswith(full, "err:") then
						state.split_html_full = vim.split(util.format_html(full), "\n", { plain = true })
					end
				end
				state.split_html_show_full = true
				lines = state.split_html_full or { "-- no full html --" }
			end
			split_set(lines, "html", true)
			return
		end
		if state.view_mode ~= "html" then
			return
		end
		htmlops.toggle_body_head(buf, state)
	end, "Toggle body / full HTML")

	-- ----------------------------------------------------------------
	-- HTMX motion keymaps. All scoped to HTML view (primary or split)
	-- via html_motion(). When not in HTML view, the keymap is a no-op.
	--
	-- U / P / T / Y / S / B all share the same shape - dispatch to
	-- the corresponding htmlops.next_* function with the focused
	-- buf/win. Cursor lands inside the quoted attribute value so
	-- yi" yanks the value cleanly.
	-- ----------------------------------------------------------------
	map("U", function()
		html_motion(htmlops.next_uuid)
	end, "Next UUID")

	map("P", function()
		html_motion(htmlops.next_partial)
	end, "Next htmx partial")

	-- T: handled in keymaps/core.lua because the same key is also used
	-- in tabs view (force-full nav). vim.keymap.set overwrites previous
	-- registrations per buffer, so one callback dispatches both.

	map("Y", function()
		html_motion(htmlops.next_target)
	end, "Next hx-target")

	-- S: handled in keymaps/split.lua because the same key is also used
	-- to open/close the split. Same dispatch pattern as T.

	map("B", function()
		html_motion(htmlops.next_boost)
	end, "Next hx-boost")

	-- ----------------------------------------------------------------
	-- A: add named html search pattern (primary html view only).
	-- Two prompts: name then regex. Pattern stored on state.html_patterns.
	-- ----------------------------------------------------------------
	map("A", function()
		if state.view_mode ~= "html" then
			return
		end
		vim.ui.input({ prompt = "Pattern name: " }, function(name)
			if not name or name == "" then
				return
			end
			vim.ui.input({ prompt = "Vim regex: " }, function(pat)
				if not pat or pat == "" then
					return
				end
				table.insert(state.html_patterns, { name = name, pattern = pat })
				vim.notify("browser: pattern '" .. name .. "' added - ? to search")
			end)
		end)
	end, "Add html search pattern")

	-- ----------------------------------------------------------------
	-- ?: pick a stored html search pattern and run it (primary html only).
	-- ----------------------------------------------------------------
	map("?", function()
		if state.view_mode ~= "html" then
			return
		end
		if #state.html_patterns == 0 then
			vim.notify("browser: no patterns - use A to add one", vim.log.levels.WARN)
			return
		end
		local items = {}
		for _, p in ipairs(state.html_patterns) do
			table.insert(items, p.name .. "  " .. p.pattern)
		end
		util.path_picker(items, function(sel, _)
			for _, p in ipairs(state.html_patterns) do
				if (p.name .. "  " .. p.pattern) == sel then
					vim.fn.search(p.pattern)
					break
				end
			end
		end)
	end, "Pattern picker")

	-- ----------------------------------------------------------------
	-- c: console log (split-aware)
	-- In split: switch to console view; second press returns to tabs.
	-- In primary: open the console panel.
	-- ----------------------------------------------------------------
	map("c", function()
		if is_in_split() then
			if state.split_view == "console" then
				split_restore_tabs()
				return
			end
			local meta = split_selected_meta()
			local tab_arg = meta and (" " .. meta.tab_id) or ""
			local raw = send_cmd("consolelog" .. tab_arg)
			if not raw or vim.startswith(raw, "err:") then
				vim.notify("browser: " .. (raw or "no response"), vim.log.levels.WARN)
				return
			end
			split_set(logops.build_console_lines(raw), "text", true)
			state.split_view = "console"
			vim.notify("browser: split console - C=clear  r=refresh  c/r=back")
			return
		end
		if state.view_mode == "console" then
			restore_tabs(buf)
			return
		end
		logops.open_console(buf, state)
	end, "Console log")

	-- ----------------------------------------------------------------
	-- C: clear console (split-aware).
	-- Works from tabs or console views; sends consoleclear over socket.
	-- ----------------------------------------------------------------
	map("C", function()
		if is_in_split() then
			if state.split_view ~= "tabs" and state.split_view ~= "console" then
				return
			end
			send_cmd("consoleclear")
			vim.notify("browser: split console cleared")
			if state.split_view == "console" then
				split_set({ "-- console cleared --" }, "text", true)
			end
			return
		end
		if state.view_mode ~= "tabs" and state.view_mode ~= "console" then
			return
		end
		logops.clear_console(buf, state)
	end, "Clear console log")

	-- ----------------------------------------------------------------
	-- n: network log (split-aware). Same shape as c.
	-- ----------------------------------------------------------------
	map("n", function()
		if is_in_split() then
			if state.split_view == "network" then
				split_restore_tabs()
				return
			end
			local meta = split_selected_meta()
			local tab_arg = meta and (" " .. meta.tab_id) or ""
			local raw = send_cmd("netlog" .. tab_arg)
			if not raw or vim.startswith(raw, "err:") then
				vim.notify("browser: " .. (raw or "no response"), vim.log.levels.WARN)
				return
			end
			state.net_show_response = false
			split_set(logops.build_net_lines(raw, state), "text", true)
			state.split_view = "network"
			vim.notify("browser: split network - R=req/res  N=clear  r=refresh  n/r=back")
			return
		end
		if state.view_mode == "network" then
			restore_tabs(buf)
			return
		end
		logops.open_network(buf, state)
	end, "Network log")

	-- ----------------------------------------------------------------
	-- N: clear network log (split-aware). Same shape as C.
	-- ----------------------------------------------------------------
	map("N", function()
		if is_in_split() then
			if state.split_view ~= "tabs" and state.split_view ~= "network" then
				return
			end
			send_cmd("netclear")
			vim.notify("browser: split network cleared")
			if state.split_view == "network" then
				state.net_entries = {}
				split_set({ "-- network log cleared --" }, "text", true)
			end
			return
		end
		if state.view_mode ~= "tabs" and state.view_mode ~= "network" then
			return
		end
		logops.clear_network(buf, state)
	end, "Clear network log")

	-- ----------------------------------------------------------------
	-- R: toggle request/response display in network preview pane.
	-- ----------------------------------------------------------------
	map("R", function()
		logops.toggle_net_response(state)
	end, "Toggle request/response preview")
end

return M
