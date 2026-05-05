-- browser/dashboard/keymaps/core.lua
--
-- Generic keymaps that don't belong to a single panel:
--   <CR>          - context-aware open (group entry, tag, path, or tab)
--   q             - return to tab list
--   r             - refresh or return (depending on view)
--   <C-o>         - return to tab list
--   <leader>e     - return to tab list (alias)
--   \             - toggle chi_path / resolved path display
--   /             - native vim search (overrides scratchbuf line-filter)
--   t             - toggle partial / full navigation on current tab
--   T             - force full navigation on current tab
--   <leader>w     - curl preview (http view only)
--   <C-w> + lhwjk - close split if focused, otherwise close dashboard
--   :             - path picker / attr insert / path insert (context-aware)

local M = {}

local util = require("browser.dashboard.util")
local tabops = require("browser.dashboard.tabops")
local httpops = require("browser.dashboard.httpops")
local logops = require("browser.dashboard.logops")
local assetops = require("browser.dashboard.assetops")

local function send_cmd(cmd)
	return require("browser.session").send_cmd(cmd)
end

function M.register(ctx)
	local buf = ctx.buf
	local win = ctx.win
	local state = ctx.state
	local map = ctx.map
	local restore_tabs = ctx.restore_tabs
	local do_buf_refresh = ctx.do_buf_refresh
	local current_meta = ctx.current_meta
	local is_in_split = ctx.is_in_split
	local split_restore_tabs = ctx.split_restore_tabs
	local close_split = ctx.close_split

	-- ----------------------------------------------------------------
	-- <CR>: context-aware open
	-- groups view -> open group / tag / path under cursor
	-- tabs view   -> navigate the highlighted tab
	-- ----------------------------------------------------------------
	map("<CR>", function()
		if state.view_mode == "groups" then
			local line = vim.api.nvim_get_current_line()
			local tag_name = line:match("^###%s*(.+)")
			local hdg_name = not tag_name and line:match("^##([^#].*)") -- ## heading (skip)
			local grp_name = not tag_name and not hdg_name and line:match("^#([^#].*)")
			if tag_name then
				-- Tag header: open all tagged endpoints
				tag_name = vim.trim(tag_name)
				local tags = tabops.load_tags()
				local paths = type(tags[tag_name]) == "table" and tags[tag_name] or {}
				if #paths == 0 then
					vim.notify("browser: tag '" .. tag_name .. "' has no paths", vim.log.levels.WARN)
					return
				end
				restore_tabs(buf)
				require("browser.groups").open_group(tag_name, paths)
			elseif hdg_name then
				-- ## heading: no action (purely visual organizer)
				return
			elseif grp_name then
				grp_name = vim.trim(grp_name)
				local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
				local gs, _, _ = util.parse_group_buf(all_lines)
				local paths = type(gs[grp_name]) == "table" and gs[grp_name] or {}
				if #paths == 0 then
					vim.notify("browser.groups: group '" .. grp_name .. "' has no paths", vim.log.levels.WARN)
					return
				end
				restore_tabs(buf)
				require("browser.groups").open_group(grp_name, paths)
			else
				-- Path line: open a new tab
				local p = vim.trim(line)
				if p ~= "" and p:sub(1, 1) == "/" then
					tabops.open_path(p, buf, state.tab_metadata, do_buf_refresh)
				end
			end
			return
		end
		if state.view_mode == "tabs" then
			-- DEBUG: trace why CR sometimes doesn't navigate.
			-- Prints the raw line, the stripped key used for metadata
			-- lookup, and whether a meta entry was found. If meta is
			-- nil here, the line content doesn't match any rendered
			-- key in state.tab_metadata.
			local raw_line = vim.api.nvim_get_current_line()
			local stripped = util.strip_prefix(raw_line)
			local meta = current_meta()
			vim.notify(
				string.format(
					"CR debug: line=%q stripped=%q meta=%s meta_count=%d",
					raw_line,
					stripped,
					meta and meta.tab_id:sub(1, 8) or "nil",
					vim.tbl_count(state.tab_metadata)
				)
			)
			if not meta then
				-- Show first 3 metadata keys so we can see what the
				-- buffer SHOULD match against.
				local i = 0
				for k, _ in pairs(state.tab_metadata) do
					i = i + 1
					vim.notify(string.format("  meta key %d: %q", i, k))
					if i >= 3 then
						break
					end
				end
				return
			end
			-- Read htmx from the test file as the authoritative source.
			-- meta.htmx may not reflect the saved preference on first
			-- load since tab_htmx starts empty each session.
			local chi = meta.chi_path or tabops.infer_chi_path(meta)
			local htmx = meta.htmx or false
			if chi then
				local saved = require("browser.views").load_test_for_path(chi)
				if saved and saved.htmx ~= nil then
					htmx = saved.htmx
				end
			end
			tabops.navigate_tab(meta, htmx, state.tab_htmx)
		end
	end, "Open entry / open group")

	-- ----------------------------------------------------------------
	-- <leader>w: curl preview (http view only)
	-- ----------------------------------------------------------------
	map("<leader>w", function()
		if state.view_mode ~= "http" then
			return
		end
		httpops.curl_preview(state)
	end, "Curl preview in HTTP Preview pane")

	-- ----------------------------------------------------------------
	-- q: return to tab list
	-- ----------------------------------------------------------------
	map("q", function()
		restore_tabs(buf)
	end, "Return to tab list")

	-- ----------------------------------------------------------------
	-- r: context-aware refresh / return.
	--   in split:  refresh console/network/assets if in those views, else return to tabs
	--   in primary console: refresh console
	--   in primary network: refresh network
	--   in primary assets:  refresh assets
	--   else: return to tabs
	-- ----------------------------------------------------------------
	map("r", function()
		if is_in_split() then
			if state.split_view == "console" then
				local raw = send_cmd("consolelog")
				if raw and not vim.startswith(raw, "err:") then
					ctx.split_set(logops.build_console_lines(raw), "text", true)
				end
				vim.notify("browser: split console refreshed")
			elseif state.split_view == "network" then
				local raw = send_cmd("netlog")
				if raw and not vim.startswith(raw, "err:") then
					ctx.split_set(logops.build_net_lines(raw, state), "text", true)
				end
				vim.notify("browser: split network refreshed")
			elseif state.split_view == "assets" then
				assetops.split_refresh(state, ctx.split_set)
			else
				split_restore_tabs()
			end
			return
		end
		if state.view_mode == "console" then
			logops.refresh_console(buf, state)
		elseif state.view_mode == "network" then
			logops.refresh_network(buf, state)
		elseif state.view_mode == "assets" then
			assetops.refresh(buf, state)
		else
			restore_tabs(buf)
		end
	end, "Refresh / return to tab list")

	-- ----------------------------------------------------------------
	-- <C-o> and <leader>e: aliases for "return to tab list".
	-- <C-o> particularly matters for muscle memory (jump back).
	-- ----------------------------------------------------------------
	map("<C-o>", function()
		if is_in_split() then
			split_restore_tabs()
			return
		end
		restore_tabs(buf)
	end, "Return to tab list")

	map("<leader>e", function()
		if is_in_split() then
			split_restore_tabs()
			return
		end
		restore_tabs(buf)
	end, "Return to tab list")

	-- ----------------------------------------------------------------
	-- \: toggle between chi_path templates and resolved paths in tabs.
	-- ----------------------------------------------------------------
	map("\\", function()
		if state.view_mode ~= "tabs" and not (is_in_split() and state.split_view == "tabs") then
			return
		end
		state.show_chi_path = not state.show_chi_path
		do_buf_refresh(buf)
		if state.split_buf and vim.api.nvim_buf_is_valid(state.split_buf) and state.split_view == "tabs" then
			split_restore_tabs()
		end
		vim.notify("browser: showing " .. (state.show_chi_path and "chi_path templates" or "resolved paths"))
	end, "Toggle chi_path / resolved path display")

	-- ----------------------------------------------------------------
	-- <C-w> family: in primary, close dashboard. In split, close split only.
	-- The base <C-w> is set with nowait=false so multi-key mappings still
	-- compose; the explicit <C-w>l/h/j/k forms get nowait=true.
	-- ----------------------------------------------------------------
	local function close_or_dashboard()
		if state.split_win and vim.api.nvim_win_is_valid(state.split_win) then
			if vim.api.nvim_get_current_win() == state.split_win then
				close_split()
				return
			end
		end
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("q", true, false, true), "m", false)
	end
	vim.keymap.set("n", "<C-w>", close_or_dashboard, { buffer = buf, nowait = false, noremap = true })
	map("<C-w>l", close_or_dashboard, "Close split or dashboard")
	map("<C-w>h", close_or_dashboard, "Close split or dashboard")
	map("<C-w>j", close_or_dashboard, "Close split or dashboard")
	map("<C-w>k", close_or_dashboard, "Close split or dashboard")

	-- ----------------------------------------------------------------
	-- /: native vim search (overrides scratchbuf's line filter on /).
	-- ----------------------------------------------------------------
	map("/", function()
		vim.api.nvim_feedkeys("/", "n", false)
	end, "Search")

	-- ----------------------------------------------------------------
	-- t: toggle partial/full navigation for the tab under cursor.
	-- Re-navigates with the new htmx setting, persists to test file.
	-- ----------------------------------------------------------------
	map("t", function()
		if state.view_mode ~= "tabs" then
			return
		end
		local meta = current_meta()
		if not meta then
			return
		end
		local new_htmx = not meta.htmx
		tabops.navigate_tab(meta, new_htmx, state.tab_htmx)
		local chi = tabops.infer_chi_path(meta) or meta.chi_path or meta.path
		if chi then
			require("browser.views").save_htmx_for_path(chi, new_htmx)
		end
		vim.defer_fn(function()
			if vim.api.nvim_buf_is_valid(buf) then
				do_buf_refresh(buf)
			end
		end, 400)
	end, "Toggle partial/full")

	-- ----------------------------------------------------------------
	-- T: dual purpose, dispatched by view_mode.
	--   tabs view -> force full (htmx=false) navigation on tab under cursor.
	--   html view -> jump to next hx-trigger attribute (cursor inside
	--                quoted value so yi" yanks it).
	-- Lives here (not in keymaps/views.lua) because vim.keymap.set
	-- overwrites previous registrations on the same buffer; one
	-- callback per key. Same pattern as S in keymaps/split.lua.
	-- ----------------------------------------------------------------
	map("T", function()
		if state.view_mode == "html" then
			require("browser.dashboard.htmlops").next_trigger(buf, win)
			return
		end
		if is_in_split() and state.split_view == "html" then
			require("browser.dashboard.htmlops").next_trigger(state.split_buf, state.split_win)
			return
		end
		if state.view_mode ~= "tabs" then
			return
		end
		local meta = current_meta()
		if not meta then
			return
		end
		tabops.navigate_tab(meta, false, state.tab_htmx)
		local chi = tabops.infer_chi_path(meta) or meta.chi_path or meta.path
		if chi then
			require("browser.views").save_htmx_for_path(chi, false)
		end
		vim.defer_fn(function()
			if vim.api.nvim_buf_is_valid(buf) then
				do_buf_refresh(buf)
			end
		end, 400)
	end, "Navigate full page / next hx-trigger")

	-- ----------------------------------------------------------------
	-- :: context-aware insert / picker.
	--   http view   -> show all insertable test file attributes
	--   groups view -> show route picker, insert chi_path on selection
	--   tabs view   -> route picker; CR opens new tab,
	--                                C-j replaces current tab nav
	-- ----------------------------------------------------------------
	map(":", function()
		-- http view: show all insertable test file attributes
		if state.view_mode == "http" then
			local tests = require("browser.session").TESTS_DIR
			local seen, attrs = {}, {}
			local function scan_dir(dir)
				local h = vim.loop.fs_scandir(dir)
				if not h then
					return
				end
				while true do
					local name, typ = vim.loop.fs_scandir_next(h)
					if not name then
						break
					end
					if typ == "file" and name:match("%.http$") then
						local f = io.open(dir .. "/" .. name, "r")
						if f then
							for line in f:lines() do
								line = vim.trim(line)
								if line ~= "" and not seen[line] then
									seen[line] = true
									table.insert(attrs, line)
									local qp = line:match("^query:%s*(.*)")
									if qp then
										for param in qp:gmatch("[^&]+") do
											param = vim.trim(param)
											if param ~= "" and not seen[param] then
												seen[param] = true
												table.insert(attrs, param)
											end
										end
									end
								end
							end
							f:close()
						end
					elseif typ == "directory" then
						scan_dir(dir .. "/" .. name)
					end
				end
			end
			scan_dir(tests)
			table.sort(attrs)
			if #attrs == 0 then
				vim.notify("browser: no test attributes found", vim.log.levels.WARN)
				return
			end
			util.path_picker(attrs, function(attr, _)
				local lnum = vim.api.nvim_win_get_cursor(win)[1]
				vim.api.nvim_buf_set_lines(buf, lnum, lnum, false, { attr })
				vim.bo[buf].modified = true
				pcall(vim.api.nvim_win_set_cursor, win, { lnum + 1, 0 })
			end)
			return
		end

		local views = require("browser.views")
		local routes = views.get_routes()
		if #routes == 0 then
			vim.notify("browser: no routes found", vim.log.levels.WARN)
			return
		end

		local items = {}
		for _, r in ipairs(routes) do
			if r.chi_path and r.chi_path ~= "" then
				local saved = views.load_test_for_path(r.chi_path)
				local ann = (saved and saved.htmx == true) and "  [partial]" or "  [full]"
				table.insert(items, r.chi_path .. ann)
			end
		end
		local function strip_ann(s)
			return s:match("^(.-)%s+%[") or s
		end

		if state.view_mode == "groups" then
			util.path_picker(items, function(sel, _)
				local chi_path = strip_ann(sel)
				local lnum = vim.api.nvim_win_get_cursor(win)[1]
				vim.api.nvim_buf_set_lines(buf, lnum, lnum, false, { chi_path })
				vim.bo[buf].modified = true
				pcall(vim.api.nvim_win_set_cursor, win, { lnum + 1, 0 })
			end)
			return
		end

		util.path_picker(items, function(sel, replace_current)
			local chi_path = strip_ann(sel)
			local session = require("browser.session")
			if vim.fn.filereadable(session.SOCKET) == 0 then
				session.start()
				vim.notify("browser: starting Brave... opening tab in ~7s")
				vim.defer_fn(function()
					tabops.open_path(chi_path, buf, state.tab_metadata, do_buf_refresh)
				end, 7000)
				return
			end
			local saved = views.load_test_for_path(chi_path)
			local use_htmx = saved and saved.htmx ~= nil and saved.htmx or false
			local meta = current_meta()
			if replace_current and meta then
				tabops.navigate_tab(meta, use_htmx, state.tab_htmx)
				views.do_navigate(chi_path, use_htmx)
				vim.defer_fn(function()
					if vim.api.nvim_buf_is_valid(buf) then
						do_buf_refresh(buf)
					end
				end, 600)
			else
				tabops.open_path(chi_path, buf, state.tab_metadata, do_buf_refresh)
			end
		end)
	end, "Path picker / insert attr / insert path")
end

return M
