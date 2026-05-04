-- browser/dashboard/keymaps.lua
-- Registers all on_ready keymaps for the browser dashboard.
-- Delegates panel operations to tabops, httpops, logops, and htmlops.
-- Split pane management lives here because it is tightly coupled to
-- window geometry and keymap copying.

local M = {}

local util = require("browser.dashboard.util")
local tabops = require("browser.dashboard.tabops")
local httpops = require("browser.dashboard.httpops")
local logops = require("browser.dashboard.logops")
local htmlops = require("browser.dashboard.htmlops")

local function send_cmd(cmd)
	return require("browser.session").send_cmd(cmd)
end

-- ============================================================
-- register
-- Entry point called from on_ready. Sets up every keymap on buf.
--
-- state:   per-open shared state table
-- opts:    { restore_tabs_fn, do_buf_refresh_fn }
-- ============================================================
function M.register(buf, win, layout, state, opts)
	local restore_tabs = opts.restore_tabs_fn
	local do_buf_refresh = opts.do_buf_refresh_fn

	-- map: registers on primary buf and records for split copy
	local function map(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, noremap = true, desc = desc })
		table.insert(state.registered_keymaps, { lhs = lhs, fn = fn, desc = desc })
	end

	-- current_meta: meta for the tab line under the cursor
	local function current_meta()
		return state.tab_metadata[util.strip_prefix(vim.api.nvim_get_current_line())]
	end

	-- --------------------------------------------------------
	-- Split pane helpers
	-- --------------------------------------------------------
	local function is_in_split()
		return state.split_win
			and vim.api.nvim_win_is_valid(state.split_win)
			and vim.api.nvim_get_current_win() == state.split_win
	end

	local function split_selected_meta()
		if not state.split_selected_tab_id then
			return nil
		end
		for _, m in pairs(state.split_meta) do
			if m.tab_id == state.split_selected_tab_id then
				return m
			end
		end
		return nil
	end

	local function split_set(lines, ft, readonly)
		if not vim.api.nvim_buf_is_valid(state.split_buf or -1) then
			return
		end
		vim.bo[state.split_buf].modifiable = true
		vim.api.nvim_buf_set_lines(state.split_buf, 0, -1, false, lines)
		vim.bo[state.split_buf].filetype = ft or "scratchbuf"
		vim.bo[state.split_buf].modifiable = not readonly
		vim.bo[state.split_buf].modified = false
	end

	local function split_restore_tabs()
		local tabs = tabops.fetch_tabs(state.tab_htmx)
		local lines, meta = tabops.build_tab_lines(tabs, state.show_chi_path)
		state.split_meta = meta
		state.split_selected_tab_id = nil
		split_set(lines, "scratchbuf", false)
		state.split_view = "tabs"
	end

	local function close_split()
		if state.split_win and vim.api.nvim_win_is_valid(state.split_win) then
			vim.api.nvim_win_close(state.split_win, true)
		end
		if state.split_buf and vim.api.nvim_buf_is_valid(state.split_buf) then
			vim.api.nvim_buf_delete(state.split_buf, { force = true })
		end
		state.split_win = nil
		state.split_buf = nil
		state.split_meta = {}
		state.split_view = "tabs"
		state.split_html_body = nil
		state.split_html_full = nil
		state.split_html_show_full = false
		state.split_selected_tab_id = nil
		if state.primary_w and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_set_width(win, state.primary_w)
		end
		state.primary_w = nil
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_set_current_win(win)
		end
	end

	-- --------------------------------------------------------
	-- CR: context-aware open
	-- --------------------------------------------------------
	map("<CR>", function()
		if state.view_mode == "groups" then
			local line = vim.api.nvim_get_current_line()
			local tag_name = line:match("^###%s*(.+)")
			local grp_name = not tag_name and line:match("^##?%s*(.+)")
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
			elseif grp_name then
				grp_name = vim.trim(grp_name)
				local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
				local gs, _ = util.parse_group_buf(all_lines)
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
			local meta = current_meta()
			if not meta then
				return
			end
			-- Read htmx from the test file as the authoritative source.
			-- meta.htmx may not reflect the saved preference on first load
			-- since tab_htmx starts empty each session.
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

	-- --------------------------------------------------------
	-- <leader>w: curl preview (http view only)
	-- --------------------------------------------------------
	map("<leader>w", function()
		if state.view_mode ~= "http" then
			return
		end
		httpops.curl_preview(state)
	end, "Curl preview in HTTP Preview pane")

	-- --------------------------------------------------------
	-- q: return to tab list
	-- --------------------------------------------------------
	map("q", function()
		restore_tabs(buf)
	end, "Return to tab list")

	-- --------------------------------------------------------
	-- r: refresh or return (context-aware)
	-- --------------------------------------------------------
	map("r", function()
		if is_in_split() then
			if state.split_view == "console" then
				local raw = send_cmd("consolelog")
				if raw and not vim.startswith(raw, "err:") then
					split_set(logops.build_console_lines(raw), "text", true)
				end
				vim.notify("browser: split console refreshed")
			elseif state.split_view == "network" then
				local raw = send_cmd("netlog")
				if raw and not vim.startswith(raw, "err:") then
					split_set(logops.build_net_lines(raw, state), "text", true)
				end
				vim.notify("browser: split network refreshed")
			else
				split_restore_tabs()
			end
			return
		end
		if state.view_mode == "console" then
			logops.refresh_console(buf)
		elseif state.view_mode == "network" then
			logops.refresh_network(buf, state)
		else
			restore_tabs(buf)
		end
	end, "Refresh / return to tab list")

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

	-- --------------------------------------------------------
	-- \: toggle chi_path / resolved path display
	-- --------------------------------------------------------
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

	-- --------------------------------------------------------
	-- s: switch focus between primary and split
	-- --------------------------------------------------------
	map("s", function()
		if not (state.split_win and vim.api.nvim_win_is_valid(state.split_win)) then
			return
		end
		local cur = vim.api.nvim_get_current_win()
		if cur == state.split_win then
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_set_current_win(win)
			end
		else
			vim.api.nvim_set_current_win(state.split_win)
		end
	end, "Switch between primary and split pane")

	-- --------------------------------------------------------
	-- S: open/close split pane
	-- --------------------------------------------------------
	map("S", function()
		if state.split_win and vim.api.nvim_win_is_valid(state.split_win) then
			close_split()
			return
		end
		if not vim.api.nvim_win_is_valid(win) then
			return
		end

		local pos = vim.api.nvim_win_get_position(win)
		local w = vim.api.nvim_win_get_width(win)
		local h = vim.api.nvim_win_get_height(win)
		local half = math.floor(w / 2) - 1
		if half < 10 then
			vim.notify("browser: not enough space to split", vim.log.levels.WARN)
			return
		end

		state.primary_w = w
		vim.api.nvim_win_set_width(win, half)

		state.split_buf = vim.api.nvim_create_buf(false, true)
		vim.b[state.split_buf]._scratchbuf = util.TITLE
		vim.bo[state.split_buf].bufhidden = "wipe"
		vim.bo[state.split_buf].swapfile = false

		local tabs = tabops.fetch_tabs(state.tab_htmx)
		local lines, smeta = tabops.build_tab_lines(tabs, state.show_chi_path)
		state.split_meta = smeta
		state.split_view = "tabs"
		vim.api.nvim_buf_set_lines(state.split_buf, 0, -1, false, lines)
		vim.bo[state.split_buf].filetype = "scratchbuf"
		vim.bo[state.split_buf].modified = false

		state.split_win = vim.api.nvim_open_win(state.split_buf, true, {
			relative = "editor",
			row = pos[1],
			col = pos[2] + half + 2,
			width = w - half - 2,
			height = h,
			style = "minimal",
			border = "rounded",
			title = util.TITLE .. " [S]",
			title_pos = "left",
		})
		vim.wo[state.split_win].cursorline = true
		vim.wo[state.split_win].number = true
		vim.wo[state.split_win].signcolumn = "no"
		vim.wo[state.split_win].wrap = false
		vim.wo[state.split_win].winhighlight = "Visual:ScratchbufVisual,CursorLine:ScratchbufCursorLine"
		util.browser_highlights(state.split_win)

		-- Copy all registered keymaps to the split buffer
		for _, km in ipairs(state.registered_keymaps) do
			pcall(vim.keymap.set, "n", km.lhs, km.fn, {
				buffer = state.split_buf,
				nowait = true,
				noremap = true,
				desc = km.desc,
			})
		end

		-- q/Esc/S/<C-w> in the split close only the split, not the dashboard
		for _, lhs in ipairs({ "q", "<Esc>", "S", "<C-w>" }) do
			vim.keymap.set("n", lhs, close_split, { buffer = state.split_buf, nowait = true, noremap = true })
		end

		vim.api.nvim_create_autocmd("ModeChanged", {
			buffer = state.split_buf,
			callback = function()
				if not vim.api.nvim_win_is_valid(state.split_win) then
					return
				end
				local mode = vim.api.nvim_get_mode().mode
				vim.wo[state.split_win].winhighlight = (mode == "v" or mode == "\22")
						and "Visual:ScratchbufVisual,CursorLine:ScratchbufCursorLineV"
					or "Visual:ScratchbufVisual,CursorLine:ScratchbufCursorLine"
			end,
		})

		-- Track which tab is selected in the split (persists across view switches)
		vim.api.nvim_create_autocmd("CursorMoved", {
			buffer = state.split_buf,
			callback = function()
				if state.split_view ~= "tabs" then
					return
				end
				if
					not (
						vim.api.nvim_win_is_valid(state.split_win)
						and vim.api.nvim_get_current_win() == state.split_win
					)
				then
					return
				end
				local lnum = vim.api.nvim_win_get_cursor(state.split_win)[1]
				local raw = vim.api.nvim_buf_get_lines(state.split_buf, lnum - 1, lnum, false)[1] or ""
				local m = state.split_meta[util.strip_prefix(raw)]
				if m then
					state.split_selected_tab_id = m.tab_id
				end
			end,
		})

		-- Close split when the dashboard closes
		vim.api.nvim_create_autocmd("BufWipeout", {
			buffer = buf,
			once = true,
			callback = function()
				vim.schedule(function()
					if state.split_win and vim.api.nvim_win_is_valid(state.split_win) then
						vim.api.nvim_win_close(state.split_win, true)
					end
					if state.split_buf and vim.api.nvim_buf_is_valid(state.split_buf) then
						vim.api.nvim_buf_delete(state.split_buf, { force = true })
					end
					state.split_win = nil
					state.split_buf = nil
				end)
			end,
		})
	end, "Toggle split pane")

	-- --------------------------------------------------------
	-- <C-w>: close split if focused, otherwise close dashboard
	-- --------------------------------------------------------
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

	-- --------------------------------------------------------
	-- /: native vim search (overrides scratchbuf line-filter)
	-- --------------------------------------------------------
	map("/", function()
		vim.api.nvim_feedkeys("/", "n", false)
	end, "Search")

	-- --------------------------------------------------------
	-- t / T: toggle partial/full navigation
	-- --------------------------------------------------------
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

	map("T", function()
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
	end, "Navigate full page")

	-- --------------------------------------------------------
	-- gz: group editor
	-- --------------------------------------------------------
	local function open_group_editor()
		if state.view_mode == "groups" then
			restore_tabs(buf)
			return
		end
		if state.view_mode ~= "tabs" then
			return
		end
		local groups = require("browser.groups").load_groups()
		local names = {}
		for name in pairs(groups) do
			table.insert(names, name)
		end
		table.sort(names)
		local tags = tabops.load_tags()
		local tag_names = {}
		for name in pairs(tags) do
			table.insert(tag_names, name)
		end
		table.sort(tag_names)
		local new_lines = {}
		for _, name in ipairs(names) do
			table.insert(new_lines, "# " .. name)
			for _, p in ipairs(type(groups[name]) == "table" and groups[name] or {}) do
				table.insert(new_lines, p)
			end
			table.insert(new_lines, "")
		end
		for _, name in ipairs(tag_names) do
			table.insert(new_lines, "### " .. name)
			for _, p in ipairs(type(tags[name]) == "table" and tags[name] or {}) do
				table.insert(new_lines, p)
			end
			table.insert(new_lines, "")
		end
		if #names == 0 and #tag_names == 0 then
			table.insert(new_lines, "# new-group")
			table.insert(new_lines, "")
		end
		while #new_lines > 0 and new_lines[#new_lines] == "" do
			table.remove(new_lines)
		end
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
		vim.bo[buf].filetype = "scratchbuf"
		vim.bo[buf].modified = false
		state.view_mode = "groups"
		vim.notify("browser: group editor - W=save  :=add path  CR=open  gz/r=back  #=group  ###=tag")
	end
	vim.keymap.set("n", "gz", open_group_editor, { buffer = buf, nowait = true, noremap = true, desc = "Group editor" })
	table.insert(state.registered_keymaps, { lhs = "gz", fn = open_group_editor, desc = "Group editor" })

	-- --------------------------------------------------------
	-- +: add current tab to a group
	-- --------------------------------------------------------
	map("+", function()
		if state.view_mode ~= "tabs" then
			return
		end
		local meta = current_meta()
		if not meta then
			vim.notify("browser: no tab selected", vim.log.levels.WARN)
			return
		end
		local chi_path = meta.chi_path or meta.path
		local groups_mod = require("browser.groups")
		local groups = groups_mod.load_groups()
		local names = {}
		for name in pairs(groups) do
			table.insert(names, name)
		end
		table.sort(names)
		if #names == 0 then
			vim.notify("browser: no groups defined - use gz to create one", vim.log.levels.WARN)
			return
		end
		util.path_picker(names, function(name, _)
			local gs = groups_mod.load_groups()
			gs[name] = gs[name] or {}
			for _, p in ipairs(gs[name]) do
				if p == chi_path then
					vim.notify("browser: " .. chi_path .. " already in '" .. name .. "'")
					return
				end
			end
			table.insert(gs[name], chi_path)
			groups_mod.save_groups(gs)
			vim.notify("browser: added " .. chi_path .. " to '" .. name .. "'")
			do_buf_refresh(buf)
		end)
	end, "Add tab to group")

	-- --------------------------------------------------------
	-- e: HTTP context editor (split-aware)
	-- --------------------------------------------------------
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
			-- Build a lightweight display in the split (no full panel state)
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
			for _, ctx in ipairs(contexts) do
				table.insert(lines, "--- context: " .. ctx .. " ---")
				local injected = views.resolve_path_for_context(chi_path, ctx)
				table.insert(lines, "path: " .. injected)
				local saved = views.load_test_for_path(chi_path)
				table.insert(lines, "query: " .. (saved and saved.qp or ""))
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

	-- --------------------------------------------------------
	-- H: HTML source viewer (split-aware)
	-- --------------------------------------------------------
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
			vim.notify("browser: split html - b=head  U=uuid  H/r=back")
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

	-- --------------------------------------------------------
	-- b: body/head toggle (html view, split-aware)
	-- --------------------------------------------------------
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

	-- --------------------------------------------------------
	-- U: jump to next UUID (html view)
	-- --------------------------------------------------------
	map("U", function()
		local in_html = state.view_mode == "html" or (is_in_split() and state.split_view == "html")
		if not in_html then
			return
		end
		htmlops.next_uuid()
	end, "Next UUID")

	-- --------------------------------------------------------
	-- A: add named html search pattern
	-- --------------------------------------------------------
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

	-- --------------------------------------------------------
	-- ?: pattern picker (html view)
	-- --------------------------------------------------------
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

	-- --------------------------------------------------------
	-- c: console log (split-aware)
	-- --------------------------------------------------------
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

	-- --------------------------------------------------------
	-- C: clear console (split-aware)
	-- --------------------------------------------------------
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

	-- --------------------------------------------------------
	-- n: network log (split-aware)
	-- --------------------------------------------------------
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

	-- --------------------------------------------------------
	-- N: clear network log (split-aware)
	-- --------------------------------------------------------
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

	-- --------------------------------------------------------
	-- R: toggle request/response in network preview
	-- --------------------------------------------------------
	map("R", function()
		logops.toggle_net_response(state)
	end, "Toggle request/response preview")

	-- --------------------------------------------------------
	-- :: path picker / attr insert / path insert
	-- --------------------------------------------------------
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
