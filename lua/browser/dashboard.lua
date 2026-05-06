-- browser/dashboard.lua

local M = {}

local util = require("browser.dashboard.util")
local tabops = require("browser.dashboard.tabops")
local httpops = require("browser.dashboard.httpops")
local logops = require("browser.dashboard.logops")
local assetops = require("browser.dashboard.assetops")
local htmxops = require("browser.dashboard.htmxops")
local keymaps = require("browser.dashboard.keymaps")

local _html_patterns = {}
local _saved_state = { tab_cursor = 1 }

local HELP_FOR_VIEW = {
	tabs = {
		"CR navigate  t partial  T full  \\ chi/resolved",
		"dd+W close   :  routes   gz groups  + +group",
		"e http  H html  c console  n net  , assets  M htmx  S split",
	},
	groups = {
		"CR open      W  save     :  routes",
		"# group  ## heading  ### tag",
		"gz back  <leader>u history",
	},
	http = {
		"W save   :  +param   <leader>w curl",
		"e/r back",
	},
	html = {
		"b body/head   U uuid   P partial  T trigger",
		"Y target  S swap  B boost",
		"A +pattern    ?  patterns       H/r back",
	},
	console = {
		"r refresh   C clear   c/r back",
	},
	network = {
		"r refresh   N clear   R req/res   n/r back",
	},
	assets = {
		"W reevaluate  b src   m miss  l loaded  x extra",
		"A all   R +html   r refresh   a/r back",
	},
	htmx = {
		"CR expand  e errors  A all  b src",
		"N clear   r refresh   M/r back",
	},
}

local function build_help_lines(state)
	if not (state and state.primary_win) then
		return HELP_FOR_VIEW.tabs
	end
	local cur_win = vim.api.nvim_get_current_win()
	local view
	if state.split_win and vim.api.nvim_win_is_valid(state.split_win) and cur_win == state.split_win then
		view = state.split_view or "tabs"
	else
		view = state.view_mode or "tabs"
	end
	return HELP_FOR_VIEW[view] or HELP_FOR_VIEW.tabs
end

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

function M.open()
	local session = require("browser.session")
	if vim.fn.filereadable(session.SOCKET) == 0 then
		vim.notify("browser: devproxy not running", vim.log.levels.WARN)
		return
	end

	local state = {
		tab_htmx = {},
		tab_metadata = {},
		tab_counts = {},
		preview_tab_id = nil,
		layout = nil,
		primary_buf = nil,
		primary_win = nil,
		view_mode = "tabs",
		show_chi_path = true,
		http_section_paths = {},
		http_tab_meta = nil,
		http_chi_path = nil,
		html_body_lines = nil,
		html_full_lines = nil,
		html_show_full = false,
		html_source_meta = nil,
		net_entries = {},
		net_show_response = false,
		assets_referenced = {},
		assets_loaded = {},
		assets_missing = {},
		assets_extra = {},
		assets_filter = "all",
		assets_src_only = false,
		assets_show_html = false,
		htmx_groups = {},
		htmx_filter = "all",
		htmx_src_only = false,
		htmx_expanded = {},
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
		split_assets_referenced = {},
		split_assets_loaded = {},
		split_assets_missing = {},
		split_assets_extra = {},
		split_assets_filter = "all",
		split_assets_src_only = false,
		split_assets_show_html = false,
		split_htmx_groups = {},
		split_htmx_filter = "all",
		split_htmx_src_only = false,
		split_htmx_expanded = {},
		registered_keymaps = {},
		html_patterns = _html_patterns,
		saved_state = _saved_state,
		_help_last_view = nil,
	}

	local function update_help_pane()
		if not state.layout then
			return
		end
		local cur_win = vim.api.nvim_get_current_win()
		local view
		if state.split_win and vim.api.nvim_win_is_valid(state.split_win) and cur_win == state.split_win then
			view = state.split_view or "tabs"
		else
			view = state.view_mode or "tabs"
		end
		local key = "primary:"
			.. (state.view_mode or "?")
			.. "|split:"
			.. (state.split_view or "?")
			.. "|focus:"
			.. view
		if state._help_last_view == key then
			return
		end
		state._help_last_view = key
		state.layout.set(util.HELP_TITLE, HELP_FOR_VIEW[view] or HELP_FOR_VIEW.tabs)
	end

	state._update_help_pane = update_help_pane

	local function update_server_title()
		if not (state.primary_win and vim.api.nvim_win_is_valid(state.primary_win)) then
			return
		end
		local raw = send_cmd("active-server")
		local name = raw and raw:match("ok: (%S+)") or "?"
		pcall(vim.api.nvim_win_set_config, state.primary_win, {
			title = " " .. util.TITLE .. " [" .. name .. "] ",
			title_pos = "center",
		})
	end
	state.update_server_title = update_server_title
	local tabs = tabops.fetch_tabs(state.tab_htmx)
	if #tabs == 0 then
		vim.notify("browser: no open tabs", vim.log.levels.WARN)
		return
	end

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

	local active_line
	for _, t in ipairs(tabs) do
		if t.active then
			active_line = "GET " .. tabops.make_content(t, state.show_chi_path)
			break
		end
	end

	local function restore_tabs(buf)
		local fresh_tabs = tabops.fetch_tabs(state.tab_htmx)
		local fresh_lines, fresh_meta, fresh_counts = tabops.build_tab_lines(fresh_tabs, state.show_chi_path)
		update_metadata(fresh_meta, fresh_counts)
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, fresh_lines)
		vim.bo[buf].filetype = "scratchbuf"
		vim.bo[buf].modified = false
		state.view_mode = "tabs"
		update_help_pane()
	end

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

	require("scratchbuf").open({
		title = util.TITLE,
		lines = tab_lines,
		prefixes = util.PREFIXES,
		metadata = state.tab_metadata,
		current = active_line,
		filetype = "scratchbuf",
		close_on_open = false,

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

		on_save = function(_changes)
			vim.notify(
				string.format(
					"on_save: view_mode=%s split_view=%s",
					tostring(state.view_mode),
					tostring(state.split_view)
				)
			)
			if state.view_mode == "assets" then
				if state.primary_buf and vim.api.nvim_buf_is_valid(state.primary_buf) then
					assetops.reevaluate(state.primary_buf, state)
				end
				return true
			end
			if state.view_mode == "htmx" then
				return true
			end
			if state.view_mode == "groups" then
				if not (state.primary_buf and vim.api.nvim_buf_is_valid(state.primary_buf)) then
					return true
				end
				local all_lines = vim.api.nvim_buf_get_lines(state.primary_buf, 0, -1, false)
				local groups, tags, headings, server_tags, group_order, tag_order, server_tag_order =
					util.parse_group_buf(all_lines)
				require("browser.groups").save_groups(groups, group_order)
				tabops.save_tags(tags, tag_order)
				tabops.save_headings(headings)
				tabops.save_server_tags(server_tags, server_tag_order)
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
			if not (state.primary_buf and vim.api.nvim_buf_is_valid(state.primary_buf)) then
				return true
			end
			return tabops.on_save_tabs(state)
		end,

		on_cursor = function(_line, parsed, _layout)
			if not state.layout then
				return
			end
			update_help_pane()
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
					local pmeta
					for _, m in pairs(state.tab_metadata) do
						if m.tab_id == state.preview_tab_id then
							pmeta = m
							break
						end
					end
					local psrv = (pmeta and pmeta.server and pmeta.server ~= "") and (" --server=" .. pmeta.server)
						or ""
					local cmd = htmx and "navigate" or "navigate-full"
					send_cmd("switch " .. state.preview_tab_id)
					send_cmd(cmd .. " --tab=" .. state.preview_tab_id .. psrv .. " " .. get_base_url() .. path_query)
					state.tab_htmx[state.preview_tab_id] = htmx
					vim.notify("browser: " .. (htmx and "[partial]" or "[full]") .. " " .. path_query)
					return true
				end,
			},

			{
				title = util.HELP_TITLE,
				role = "readonly",
				lines = HELP_FOR_VIEW.tabs,
			},
		},

		on_ready = function(buf, win, layout)
			state.layout = layout
			state.primary_buf = buf
			state.primary_win = win
			util.browser_highlights(win)

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

			if _saved_state.tab_cursor > 1 then
				local total = vim.api.nvim_buf_line_count(buf)
				pcall(vim.api.nvim_win_set_cursor, win, { math.min(_saved_state.tab_cursor, total), 0 })
			end

			vim.api.nvim_create_autocmd("CursorMoved", {
				buffer = buf,
				callback = function()
					if vim.api.nvim_get_current_win() == win then
						_saved_state.tab_cursor = vim.api.nvim_win_get_cursor(win)[1]
					end
				end,
			})

			vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
				callback = function()
					if not (state.layout and state.primary_buf and vim.api.nvim_buf_is_valid(state.primary_buf)) then
						return
					end
					local cur_buf = vim.api.nvim_get_current_buf()
					local in_dashboard = cur_buf == state.primary_buf
						or (state.split_buf and cur_buf == state.split_buf)
					if in_dashboard then
						update_help_pane()
					end
				end,
			})

			update_help_pane()

			keymaps.register(buf, win, layout, state, {
				restore_tabs_fn = restore_tabs,
				do_buf_refresh_fn = do_buf_refresh,
			})
			update_server_title()
		end,
	})
end

function M.get_patterns()
	return _html_patterns
end

return M
