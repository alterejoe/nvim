-- browser/dashboard/keymaps/views.lua
--
--   e   - HTTP context editor
--   H   - HTML source viewer
--   b   - HTML body/full toggle  OR  assets src-only toggle  OR  htmx src-only toggle
--   U/P/Y/B - htmx attribute motions in HTML view
--   T   - hx-trigger motion in HTML / force-full nav in tabs (in core.lua)
--   S   - hx-swap motion in HTML / split toggle (in split.lua)
--   A   - add html search pattern  OR  assets/htmx filter=all
--   ?   - HTML pattern picker
--   c   - console
--   C   - clear console
--   CR  - expand console object args (in console view)
--   9   - network
--   N   - clear network  OR  clear htmx
--   R   - toggle req/res in network preview  OR  assets +html
--   ,   - assets panel
--   m/l/x - assets section filters
--   M   - htmx panel
--   e (htmx) - filter errors

local M = {}

local util = require("browser.dashboard.util")
local httpops = require("browser.dashboard.httpops")
local logops = require("browser.dashboard.logops")
local htmlops = require("browser.dashboard.htmlops")
local assetops = require("browser.dashboard.assetops")
local htmxops = require("browser.dashboard.htmxops")

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

	map("e", function()
		if is_in_split() and state.split_view == "htmx" then
			htmxops.split_set_filter(state, split_set, "errors")
			return
		end
		if state.view_mode == "htmx" then
			htmxops.set_filter(buf, state, "errors")
			return
		end
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
	end, "HTTP editor / htmx errors")

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

	map("b", function()
		if is_in_split() then
			if state.split_view == "htmx" then
				htmxops.split_toggle_src_only(state, split_set)
				return
			end
			if state.split_view == "assets" then
				assetops.split_toggle_src_only(state, split_set)
				return
			end
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
		if state.view_mode == "htmx" then
			htmxops.toggle_src_only(buf, state)
			return
		end
		if state.view_mode == "assets" then
			assetops.toggle_src_only(buf, state)
			return
		end
		if state.view_mode ~= "html" then
			return
		end
		htmlops.toggle_body_head(buf, state)
	end, "Toggle body/full or assets/htmx src-only")

	map("U", function()
		html_motion(htmlops.next_uuid)
	end, "Next UUID")
	map("P", function()
		html_motion(htmlops.next_partial)
	end, "Next htmx partial")
	map("Y", function()
		html_motion(htmlops.next_target)
	end, "Next hx-target")
	map("B", function()
		html_motion(htmlops.next_boost)
	end, "Next hx-boost")

	map("A", function()
		if is_in_split() and state.split_view == "htmx" then
			htmxops.split_set_filter(state, split_set, "all")
			return
		end
		if is_in_split() and state.split_view == "assets" then
			assetops.split_set_filter(state, split_set, "all")
			return
		end
		if state.view_mode == "htmx" then
			htmxops.set_filter(buf, state, "all")
			return
		end
		if state.view_mode == "assets" then
			assetops.set_filter(buf, state, "all")
			return
		end
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
	end, "Add pattern / show ALL")

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
			split_set(logops.build_console_lines(raw, nil), "text", true)
			state.split_view = "console"
			vim.notify("browser: split console - C clear  r refresh  c/r back")
			return
		end
		if state.view_mode == "console" then
			restore_tabs(buf)
			return
		end
		state.log_tab_id = state.preview_tab_id
		logops.open_console(buf, state)
	end, "Console log")

	-- CR in console view expands object args; falls through to normal CR elsewhere
	map("<CR>", function()
		if state.view_mode == "console" then
			logops.toggle_expand_console_at_cursor(buf, state)
			return
		end
		if is_in_split() and state.split_view == "htmx" then
			htmxops.split_toggle_expand(state, split_set)
			return
		end
		if state.view_mode == "htmx" then
			htmxops.toggle_expand_at_cursor(buf, state)
			return
		end
		-- fall through to core CR handler (navigate)
		local core_cr = state._core_cr
		if core_cr then
			core_cr()
		end
	end, "Expand / navigate")

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
	end, "Clear console")

	-- Network is on 9 (n was hijacking vim's next-search-result motion)
	map("9", function()
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
			vim.notify("browser: split network - R req/res  N clear  r refresh  9/r back")
			return
		end
		if state.view_mode == "network" then
			restore_tabs(buf)
			return
		end
		state.log_tab_id = state.preview_tab_id
		logops.open_network(buf, state)
	end, "Network log")

	map("N", function()
		if is_in_split() and state.split_view == "htmx" then
			htmxops.split_clear(state, split_set)
			return
		end
		if state.view_mode == "htmx" then
			htmxops.clear(buf, state)
			return
		end
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
	end, "Clear network / htmx")

	map("R", function()
		if is_in_split() and state.split_view == "assets" then
			assetops.split_toggle_show_html(state, split_set)
			return
		end
		if state.view_mode == "assets" then
			assetops.toggle_show_html(buf, state)
			return
		end
		logops.toggle_net_response(state)
	end, "Toggle req/res or assets +html")

	map(",", function()
		if is_in_split() then
			if state.split_view == "assets" then
				split_restore_tabs()
				return
			end
			local meta = split_selected_meta()
			if not meta then
				vim.notify("browser: no tab selected", vim.log.levels.WARN)
				return
			end
			state.preview_tab_id = meta.tab_id
			assetops.split_open(state, split_set)
			return
		end
		if state.view_mode == "assets" then
			restore_tabs(buf)
			return
		end
		assetops.open(buf, state)
	end, "Assets panel")

	map("m", function()
		if is_in_split() and state.split_view == "assets" then
			assetops.split_set_filter(state, split_set, "missing")
			return
		end
		if state.view_mode == "assets" then
			assetops.set_filter(buf, state, "missing")
		end
	end, "Assets: MISSING")

	map("l", function()
		if is_in_split() and state.split_view == "assets" then
			assetops.split_set_filter(state, split_set, "loaded")
			return
		end
		if state.view_mode == "assets" then
			assetops.set_filter(buf, state, "loaded")
		end
	end, "Assets: LOADED")

	map("x", function()
		if is_in_split() and state.split_view == "assets" then
			assetops.split_set_filter(state, split_set, "extra")
			return
		end
		if state.view_mode == "assets" then
			assetops.set_filter(buf, state, "extra")
		end
	end, "Assets: EXTRA")

	map("M", function()
		if is_in_split() then
			if state.split_view == "htmx" then
				split_restore_tabs()
				return
			end
			local meta = split_selected_meta()
			if not meta then
				vim.notify("browser: no tab selected", vim.log.levels.WARN)
				return
			end
			state.preview_tab_id = meta.tab_id
			htmxops.split_open(state, split_set)
			return
		end
		if state.view_mode == "htmx" then
			restore_tabs(buf)
			return
		end
		state.log_tab_id = state.preview_tab_id
		htmxops.open(buf, state)
	end, "Htmx panel")
end

return M
