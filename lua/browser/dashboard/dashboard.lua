-- browser/dashboard.lua
-- Scratchbuf-based browser management dashboard.
-- This file is the entry point only: it owns module-level state,
-- builds the initial scratchbuf config, and delegates everything else
-- to the sub-modules under browser/dashboard/.

local M = {}

local util = require("browser.dashboard.util")
local tabops = require("browser.dashboard.tabops")
local httpops = require("browser.dashboard.httpops")
local logops = require("browser.dashboard.logops")
local keymaps = require("browser.dashboard.keymaps")

-- Module-level state: persists across dashboard opens within a session.
-- html_patterns accumulates user-added patterns until Neovim restarts.
-- saved_state carries the cursor position so re-opening lands where you left off.
local _html_patterns = {}
local _saved_state = { tab_cursor = 1 }

local help_lines = {
	"CR switch   dd+W close  W save    r refresh   q back",
	":  paths    t toggle    T full    \\  name      S split",
	"gz groups   +  +group   e  http   H  html",
	"c  console  C  clr-con  n  netlog N  clr-net",
	"n: R req/res  H: b head  U uuid  A +pat  ? pats",
}

local function send_cmd(cmd)
	return require("browser.session").send_cmd(cmd)
end

local function get_base_url()
	local raw = send_cmd("active-server")
	if raw then
		local port = raw:match("port (%d+)")
		if port then
			return "http://localhost:" .. port
		end
	end
	return "http://localhost:3333"
end

-- ============================================================
-- build_context_lines
-- Renders the context pane: active context is prefixed with *.
-- ============================================================
local function build_context_lines()
	local views = require("browser.views")
	local active = views.get_active_context()
	local names = views.get_contexts()
	local result = {}
	for _, name in ipairs(names) do
		table.insert(result, (name == active and "* " or "  ") .. name)
	end
	return result
end

-- ============================================================
-- build_preview_lines
-- Renders a minimal HTTP request card for the HTTP Preview pane.
-- Shows the active context's resolved path so params are visible.
-- ============================================================
local function build_preview_lines(meta)
	if not meta then
		return { "-- move cursor to a tab --" }
	end
	local views = require("browser.views")
	local chi_path = meta.chi_path or meta.path
	local resolved = views.resolve_path(chi_path)
	local saved = views.load_test_for_path(chi_path)
	local query = (saved and saved.query_string ~= "" and ("?" .. saved.query_string)) or ""
	local base = get_base_url()
	local host = base:match("//([^/]+)") or "localhost"
	local lines = {
		"GET " .. resolved .. query .. " HTTP/1.1",
		"Host: " .. host,
	}
	if meta.htmx then
		table.insert(lines, "HX-Request: true")
	end
	return lines
end

-- ============================================================
-- M.open
-- Opens the dashboard. Bails early if devproxy is not running
-- or if there are no open tabs.
-- ============================================================
function M.open()
	local session = require("browser.session")
	if vim.fn.filereadable(session.SOCKET) == 0 then
		vim.notify("browser: devproxy not running", vim.log.levels.WARN)
		return
	end

	-- Per-open state. A new table is created each time the dashboard
	-- opens so stale state never leaks across sessions. Module-level
	-- state (_html_patterns, _saved_state) is passed in by reference
	-- so mutations persist.
	local state = {
		-- tab data
		tab_htmx = {},
		tab_metadata = {}, -- IMPORTANT: never replace this table; always mutate in-place
		-- tab_counts: tab_id -> number of display lines emitted for that tab.
		-- Mirrors tab_metadata's lifecycle but is keyed by tab_id (not content
		-- string) so it accurately tracks duplicates across multi-group display.
		-- Mutated in-place by update_metadata; on_save_tabs reads it as the
		-- authoritative "before" count when deciding whether to close tabs.
		tab_counts = {},
		preview_tab_id = nil,
		-- window handles (set in on_ready)
		layout = nil,
		primary_buf = nil,
		primary_win = nil,
		-- view mode: "tabs" | "groups" | "http" | "html" | "console" | "network"
		view_mode = "tabs",
		show_chi_path = true,
		-- http panel
		http_section_paths = {},
		http_tab_meta = nil,
		http_chi_path = nil,
		-- html panel
		html_body_lines = nil,
		html_full_lines = nil,
		html_show_full = false,
		html_source_meta = nil,
		-- network panel
		net_entries = {},
		net_show_response = false,
		-- split pane
		split_win = nil,
		primary_w = nil,
		split_buf = nil,
		split_view = "tabs",
		split_meta = {},
		split_selected_tab_id = nil,
		split_html_body = nil,
		split_html_full = nil,
		split_html_show_full = false,
		split_html_meta = nil,
		-- keymap list, populated by keymaps.register, copied to split buffer
		registered_keymaps = {},
		-- module-level references (Lua tables are passed by reference)
		html_patterns = _html_patterns,
		saved_state = _saved_state,
	}

	local tabs = tabops.fetch_tabs(state.tab_htmx)
	if #tabs == 0 then
		vim.notify("browser: no open tabs", vim.log.levels.WARN)
		return
	end

	-- update_metadata mutates state.tab_metadata IN PLACE so that scratchbuf's
	-- pane_opts.metadata reference (which points to the same table) stays live.
	--
	-- If we did `state.tab_metadata = fresh_meta` we would create a new table and
	-- scratchbuf would keep the reference to the OLD empty table. typed_diff would
	-- then find no metadata for any entry, renamed.meta would always be nil, and
	-- on_save_tabs would see every line as matching an empty key (nil lookup) so
	-- nothing would ever be detected as edited and nothing would navigate.
	--
	-- Counts are mutated in place for the same reason: on_save_tabs holds a
	-- reference to state.tab_counts and reads from it without re-fetching.
	local function update_metadata(fresh_meta, fresh_counts)
		for k in pairs(state.tab_metadata) do
			state.tab_metadata[k] = nil
		end
		for k, v in pairs(fresh_meta) do
			state.tab_metadata[k] = v
		end
		for k in pairs(state.tab_counts) do
			state.tab_counts[k] = nil
		end
		if fresh_counts then
			for k, v in pairs(fresh_counts) do
				state.tab_counts[k] = v
			end
		end
	end

	local tab_lines, meta_init, counts_init = tabops.build_tab_lines(tabs, state.show_chi_path)
	update_metadata(meta_init, counts_init)

	-- Find the active tab line so scratchbuf can position the cursor on it
	local active_line
	for _, t in ipairs(tabs) do
		if t.active then
			active_line = "GET " .. tabops.make_content(t, state.show_chi_path)
			break
		end
	end

	-- --------------------------------------------------------
	-- Shared helpers passed into keymaps.register and on_* callbacks.
	-- Both close over `state` so they always operate on current data.
	-- --------------------------------------------------------

	-- restore_tabs: re-fetches tabs and resets the primary buffer to tabs view.
	local function restore_tabs(buf)
		local fresh_tabs = tabops.fetch_tabs(state.tab_htmx)
		local fresh_lines, fresh_meta, fresh_counts = tabops.build_tab_lines(fresh_tabs, state.show_chi_path)
		update_metadata(fresh_meta, fresh_counts)
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, fresh_lines)
		vim.bo[buf].filetype = "scratchbuf"
		vim.bo[buf].modified = false
		state.view_mode = "tabs"
	end

	-- do_buf_refresh: re-fetches tabs and updates the buffer in-place.
	-- Used by keymaps that need a silent background refresh.
	local function do_buf_refresh(buf)
		if not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		local fresh_tabs = tabops.fetch_tabs(state.tab_htmx)
		local fresh_lines, fresh_meta, fresh_counts = tabops.build_tab_lines(fresh_tabs, state.show_chi_path)
		update_metadata(fresh_meta, fresh_counts)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, fresh_lines)
		vim.bo[buf].modified = false
	end

	-- --------------------------------------------------------
	-- scratchbuf.open
	-- --------------------------------------------------------
	require("scratchbuf").open({
		title = util.TITLE,
		lines = tab_lines,
		prefixes = util.PREFIXES,
		metadata = state.tab_metadata,
		current = active_line,
		filetype = "scratchbuf",
		close_on_open = false,

		-- refresh: called by scratchbuf after on_save and on its auto-refresh
		-- timer. Returns current lines unchanged when not in tabs view so the
		-- active panel (html, console, etc.) is not silently overwritten.
		-- Must use update_metadata (in-place) not reassignment.
		refresh = function()
			if state.view_mode ~= "tabs" and state.primary_buf and vim.api.nvim_buf_is_valid(state.primary_buf) then
				return vim.api.nvim_buf_get_lines(state.primary_buf, 0, -1, false)
			end
			local fresh_tabs = tabops.fetch_tabs(state.tab_htmx)
			local fresh_lines, fresh_meta, fresh_counts = tabops.build_tab_lines(fresh_tabs, state.show_chi_path)
			update_metadata(fresh_meta, fresh_counts)
			return fresh_lines
		end,

		on_open = function(_content, _parsed) end,

		-- on_save: dispatches W to the correct handler for the current view.
		on_save = function(_changes)
			if state.view_mode == "groups" then
				if not (state.primary_buf and vim.api.nvim_buf_is_valid(state.primary_buf)) then
					return true
				end
				local all_lines = vim.api.nvim_buf_get_lines(state.primary_buf, 0, -1, false)
				local groups, tags, headings, group_order, tag_order = util.parse_group_buf(all_lines)
				require("browser.groups").save_groups(groups, group_order)
				tabops.save_tags(tags, tag_order)
				tabops.save_headings(headings)
				vim.notify("browser.groups: saved")
				return true
			end
			if state.view_mode == "http" then
				return httpops.on_save_http(state)
			end
			if state.view_mode == "html" then
				return true
			end
			if state.view_mode == "console" then
				return true
			end
			if state.view_mode == "network" then
				return true
			end
			-- Default: tabs view
			if not (state.primary_buf and vim.api.nvim_buf_is_valid(state.primary_buf)) then
				return true
			end
			return tabops.on_save_tabs(state)
		end,

		-- on_cursor: updates the HTTP Preview pane as the cursor moves.
		on_cursor = function(_line, parsed, _layout)
			if not state.layout then
				return
			end
			if state.view_mode == "network" then
				local lnum = state.primary_win and vim.api.nvim_win_get_cursor(state.primary_win)[1]
				local entry = lnum and state.net_entries[lnum]
				if entry then
					state.layout.set(util.PREVIEW_TITLE, logops.build_net_preview(entry, state.net_show_response))
				end
				return
			end
			if state.view_mode ~= "tabs" then
				return
			end
			local meta = state.tab_metadata[parsed and parsed.content or ""]
			if meta then
				state.preview_tab_id = meta.tab_id
			end
			state.layout.set(util.PREVIEW_TITLE, build_preview_lines(meta))
		end,

		right_width = 0.36,
		right = {
			-- ------------------------------------------------
			-- Context pane
			-- Active context is prefixed with *. W creates/renames/deletes
			-- context directories under TESTS_DIR. CR switches active context
			-- and re-navigates the current tab.
			-- ------------------------------------------------
			{
				title = util.CTX_TITLE,
				height = 0.20,
				lines = build_context_lines(),
				close_on_open = false,
				refresh = build_context_lines,

				on_save = function(changes)
					local sess = require("browser.session")
					local tests = sess.TESTS_DIR
					for _, entry in ipairs(changes.created) do
						local name = vim.trim(entry:gsub("^[%*%s]+", ""))
						if name ~= "" and name ~= "default" then
							vim.fn.mkdir(tests .. "/" .. name, "p")
							vim.notify("browser: created context -> " .. name)
						end
					end
					for _, entry in ipairs(changes.deleted) do
						local name = vim.trim(entry:gsub("^[%*%s]+", ""))
						if name ~= "" and name ~= "default" then
							local dir = tests .. "/" .. name
							local handle = vim.loop.fs_scandir(dir)
							local empty = handle and not vim.loop.fs_scandir_next(handle)
							if empty then
								vim.loop.fs_rmdir(dir)
								vim.notify("browser: deleted context -> " .. name)
							else
								vim.notify(
									"browser: context '" .. name .. "' has files - delete manually",
									vim.log.levels.WARN
								)
							end
						end
					end
					for _, entry in ipairs(changes.renamed) do
						local old = vim.trim(entry.old:gsub("^[%*%s]+", ""))
						local new = vim.trim(entry.new:gsub("^[%*%s]+", ""))
						if old ~= "" and new ~= "" and old ~= "default" and new ~= "default" then
							vim.loop.fs_rename(tests .. "/" .. old, tests .. "/" .. new)
							local views = require("browser.views")
							if views.get_active_context() == old then
								views.switch_context(new)
							end
							vim.notify("browser: renamed context " .. old .. " -> " .. new)
						end
					end
				end,

				on_open = function(line)
					local name = vim.trim(line:gsub("^[%*%s]+", ""))
					if name == "" then
						return
					end
					local views = require("browser.views")
					views.switch_context(name)
					if state.layout then
						state.layout.set(util.CTX_TITLE, build_context_lines())
					end
					-- Re-navigate the tab under the primary cursor with the new context params
					if state.preview_tab_id then
						for _, m in pairs(state.tab_metadata) do
							if m.tab_id == state.preview_tab_id then
								local chi = m.chi_path or m.path
								if chi then
									views.do_navigate(chi, m.htmx or false)
								end
								break
							end
						end
					end
					vim.notify("browser: context -> " .. name)
				end,
			},

			-- ------------------------------------------------
			-- HTTP Preview pane
			-- Shows the current tab's resolved request as a minimal HTTP card.
			-- Editable: W fires a direct navigate without writing any test file.
			-- The e-panel and curl preview also write into this pane.
			-- ------------------------------------------------
			{
				title = util.PREVIEW_TITLE,
				height = 0.50,
				lines = { "-- move cursor to a tab --" },

				on_save = function(_changes)
					if not (state.layout and state.preview_tab_id) then
						return true
					end
					local lines = state.layout.get(util.PREVIEW_TITLE)
					if not lines or #lines == 0 then
						return true
					end
					local first = vim.trim(lines[1])
					local path_query = first:match("^%u+%s+(/[^%s]*)") or ""
					if path_query == "" then
						vim.notify("browser: could not parse request line", vim.log.levels.WARN)
						return true
					end
					local htmx = false
					for i = 2, #lines do
						if lines[i]:lower():find("hx%-request:%s*true") then
							htmx = true
							break
						end
					end
					local cmd = htmx and "navigate" or "navigate-full"
					send_cmd("switch " .. state.preview_tab_id)
					send_cmd(cmd .. " " .. get_base_url() .. path_query)
					state.tab_htmx[state.preview_tab_id] = htmx
					vim.notify("browser: " .. (htmx and "[partial]" or "[full]") .. " " .. path_query)
					return true
				end,
			},

			-- ------------------------------------------------
			-- Help pane (readonly)
			-- ------------------------------------------------
			{
				title = util.HELP_TITLE,
				role = "readonly",
				lines = help_lines,
			},
		},

		-- on_ready: called once by scratchbuf after the layout is drawn.
		-- Sets window handles on state and delegates keymap registration.
		on_ready = function(buf, win, layout)
			state.layout = layout
			state.primary_buf = buf
			state.primary_win = win
			util.browser_highlights(win)

			-- Apply preview highlights to the HTTP Preview pane window
			vim.schedule(function()
				for _, w in ipairs(vim.api.nvim_list_wins()) do
					local wbuf = vim.api.nvim_win_get_buf(w)
					local ok, conf = pcall(vim.api.nvim_win_get_config, w)
					if ok and conf.title and vim.b[wbuf] and vim.b[wbuf]._scratchbuf == util.TITLE then
						local t = type(conf.title) == "string" and conf.title
							or (type(conf.title) == "table" and conf.title[1] and conf.title[1][1])
							or ""
						if t:find(util.PREVIEW_TITLE, 1, true) then
							util.preview_highlights(w)
						end
					end
				end
			end)

			-- Restore cursor position from the previous open
			if _saved_state.tab_cursor > 1 then
				local total = vim.api.nvim_buf_line_count(buf)
				pcall(vim.api.nvim_win_set_cursor, win, { math.min(_saved_state.tab_cursor, total), 0 })
			end

			-- Track cursor position for next open
			vim.api.nvim_create_autocmd("CursorMoved", {
				buffer = buf,
				callback = function()
					if vim.api.nvim_get_current_win() == win then
						_saved_state.tab_cursor = vim.api.nvim_win_get_cursor(win)[1]
					end
				end,
			})

			keymaps.register(buf, win, layout, state, {
				restore_tabs_fn = restore_tabs,
				do_buf_refresh_fn = do_buf_refresh,
			})
		end,
	})
end

-- Expose html_patterns for any global keymaps (e.g. <leader>ha)
function M.get_patterns()
	return _html_patterns
end

return M
