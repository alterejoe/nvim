-- browser/dashboard/httpops.lua
-- HTTP panel (e view): open, on_save, curl preview, and key picker.
--
-- Format per context section:
--   --- context: <name> ---
--   path: <resolved>      (display only; not persisted)
--   htmx: true|false
--   params:
--     key: value
--     key: value
--
-- Storage:
--   path params -> contexts.<ctx>.<key>           (config.yaml)
--   query params -> contexts.<ctx>.query.<chi_path>.<key>  (config.yaml)
--   htmx        -> .devproxy/tests/<...>.http
--
-- The `:` keymap (in the http buffer) opens a fuzzy picker over all keys
-- in defaults and active context (path-param keys), inserting the selected
-- key as a new "  <key>: " line under the nearest params: block.

local M = {}

local util = require("browser.dashboard.util")

local function send_cmd(cmd)
	return require("browser.session").send_cmd(cmd)
end

-- ============================================================
-- find_http_file (private)
-- Resolves the .http test file path for a chi_path and context.
-- Falls back to structurally equivalent routes (same static segments
-- and param positions, any param names).
-- ============================================================
local function find_http_file(chi_path, ctx)
	local session = require("browser.session")
	local function make_path(cp)
		local slug = cp:gsub("/$", ""):gsub("^/", ""):gsub("/", "-"):gsub("{", ""):gsub("}", "")
		if ctx and ctx ~= "default" and ctx ~= "" then
			return session.TESTS_DIR .. "/" .. ctx .. "/" .. slug .. ".http"
		end
		return session.TESTS_DIR .. "/" .. slug .. ".http"
	end
	local p = make_path(chi_path)
	if vim.fn.filereadable(p) == 1 then
		return p
	end

	local routes = require("browser.views").get_routes()
	local cp_segs = util.segs(chi_path)
	for _, r in ipairs(routes) do
		if r.chi_path ~= chi_path then
			local r_segs = util.segs(r.chi_path)
			if #r_segs == #cp_segs then
				local same = true
				for i, cs in ipairs(cp_segs) do
					local rs = r_segs[i]
					local c_p = cs:sub(1, 1) == "{"
					local r_p = rs:sub(1, 1) == "{"
					if c_p ~= r_p or (not c_p and cs ~= rs) then
						same = false
						break
					end
				end
				if same then
					local alt = make_path(r.chi_path)
					if vim.fn.filereadable(alt) == 1 then
						return alt
					end
				end
			end
		end
	end
	return p
end

-- ============================================================
-- yq helpers
-- ============================================================
local function yq_quote_path(s)
	-- yaml path components for chi_paths contain slashes and braces; quote
	-- with double quotes inside the yq path expression.
	return '"' .. s:gsub('"', '\\"') .. '"'
end

local function yq_set_string(yaml_path, dotted_path, value)
	-- value may contain double quotes; escape them.
	local v = tostring(value):gsub('"', '\\"')
	vim.fn.system(string.format("yq -i '%s = \"%s\"' %s 2>/dev/null", dotted_path, v, vim.fn.shellescape(yaml_path)))
	return vim.v.shell_error == 0
end

local function yq_delete(yaml_path, dotted_path)
	vim.fn.system(string.format("yq -i 'del(%s)' %s 2>/dev/null", dotted_path, vim.fn.shellescape(yaml_path)))
	return vim.v.shell_error == 0
end

-- ============================================================
-- open_http_panel
-- Opens the e-panel for the given tab meta in buf.
-- Populates state.http_tab_meta, state.http_chi_path,
-- state.http_section_paths.
-- ============================================================
function M.open_http_panel(meta, buf, state)
	local views = require("browser.views")
	local routes = views.get_routes()

	-- Resolve to the canonical chi_path from plan.json
	local chi_path = meta.chi_path or meta.path
	for _, r in ipairs(routes) do
		if util.path_matches_chi(meta.path, r.chi_path) then
			chi_path = r.chi_path
			break
		end
	end

	local contexts = views.get_contexts()
	state.http_section_paths = {}
	state.http_tab_meta = meta
	state.http_chi_path = chi_path

	-- Read test files for each context (htmx only)
	local sections = {}
	for _, ctx in ipairs(contexts) do
		local fpath = find_http_file(chi_path, ctx)
		state.http_section_paths[ctx] = fpath
		local htmx_val = nil
		local f = io.open(fpath, "r")
		if f then
			for line in f:lines() do
				local label, val = line:match("^([%w%.%-_]+):%s*(.*)")
				if label and label:lower() == "htmx" then
					htmx_val = vim.trim(val) == "true"
				end
			end
			f:close()
		end
		table.insert(sections, { context = ctx, htmx = htmx_val })
	end

	-- Build buffer: one section per context
	local new_lines = { "# " .. chi_path, "" }
	for i, sec in ipairs(sections) do
		table.insert(new_lines, "--- context: " .. sec.context .. " ---")
		local injected = views.resolve_path_for_context(chi_path, sec.context)
		table.insert(new_lines, "path: " .. injected)
		if sec.htmx ~= nil then
			table.insert(new_lines, "htmx: " .. tostring(sec.htmx))
		else
			table.insert(new_lines, "htmx: false")
		end
		table.insert(new_lines, "params:")
		local q = views.query_for_route(sec.context, chi_path)
		local keys = {}
		for k in pairs(q) do
			table.insert(keys, k)
		end
		table.sort(keys)
		for _, k in ipairs(keys) do
			table.insert(new_lines, "  " .. k .. ": " .. q[k])
		end
		if i < #sections then
			table.insert(new_lines, "")
		end
	end

	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
	vim.bo[buf].filetype = "http"
	vim.bo[buf].modified = false
	state.view_mode = "http"

	-- Register the `:` picker keymap on this buffer.
	M._install_param_picker_keymap(buf, state)

	vim.notify("browser: http editor - W=save  :=add param  <leader>w=curl  e/r=back")
end

-- ============================================================
-- parse_buffer (private)
-- Splits the http panel buffer into sections.
-- Each section: { ctx, path, htmx, params = { {key, val}, ... } }
-- params keeps insertion order so re-render is stable per save.
-- ============================================================
local function parse_buffer(all_lines)
	local sections, cur = {}, nil
	local in_params = false
	for _, l in ipairs(all_lines) do
		local ctx_name = l:match("^%-%-%- context: (.+) %-%-%-%s*$")
		if ctx_name then
			if cur then
				table.insert(sections, cur)
			end
			cur = { ctx = ctx_name, path = nil, htmx = nil, params = {} }
			in_params = false
		elseif cur then
			-- Detect indented "key: value" under params:
			local indent_key, indent_val = l:match("^%s%s+([%w%.%-_]+):%s*(.*)$")
			if in_params and indent_key then
				table.insert(cur.params, { key = indent_key, val = vim.trim(indent_val) })
			else
				local label, val = l:match("^([%w%.%-_]+):%s*(.*)")
				if label then
					local low = label:lower()
					if low == "path" then
						cur.path = vim.trim(val)
						in_params = false
					elseif low == "htmx" then
						cur.htmx = vim.trim(val) == "true"
						in_params = false
					elseif low == "params" then
						in_params = true
					else
						in_params = false
					end
				end
			end
		end
	end
	if cur then
		table.insert(sections, cur)
	end
	return sections
end

-- ============================================================
-- on_save_http
-- Writes path params (from injected path), htmx (test file),
-- and query params (config.yaml), then re-navigates.
-- ============================================================
function M.on_save_http(state)
	local buf = state.primary_buf
	local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local views = require("browser.views")
	local session = require("browser.session")
	local yaml_path = session.DEVPROXY_DIR .. "/config.yaml"
	local active_ctx = views.get_active_context()
	local active_ctx_key = active_ctx == "" and "default" or active_ctx
	local chi_path = state.http_chi_path

	if not chi_path then
		vim.notify("browser: no active http context", vim.log.levels.WARN)
		return true
	end

	local sections = parse_buffer(all_lines)
	local active_path_params_changed = {}
	local active_query_params = {}
	local yaml_ok = vim.fn.filereadable(yaml_path) == 1
	if not yaml_ok then
		vim.notify("browser: config.yaml not found - params not saved", vim.log.levels.WARN)
	end

	for _, sec in ipairs(sections) do
		local sec_ctx_key = sec.ctx == "" and "default" or sec.ctx

		-- Extract path params from the displayed (injected) path.
		local sec_path_params = {}
		if sec.path and sec.path ~= "" then
			local chi_s = util.segs(chi_path)
			local res_s = util.segs(sec.path)
			if #chi_s == #res_s then
				for i, c in ipairs(chi_s) do
					if c:sub(1, 1) == "{" then
						local pname = c:match("{(.+)}")
						local val = res_s[i]
						if pname and val and val ~= "" and not val:find("{") and not val:match("%%7[Bb]") then
							sec_path_params[pname] = val
						end
					end
				end
			end
		end

		-- Write path params to contexts.<ctx>.<key>
		if yaml_ok and next(sec_path_params) then
			for k, v in pairs(sec_path_params) do
				if not yq_set_string(yaml_path, "." .. ".contexts." .. sec_ctx_key .. "." .. k, v) then
					vim.notify("browser: yq write failed for " .. k, vim.log.levels.WARN)
				end
			end
		end

		-- Write query params to contexts.<ctx>.query.<chi_path>.<key>
		-- First wipe the existing route block, then write each entry.
		-- This way removing a line in the editor actually deletes it.
		if yaml_ok then
			local route_path = string.format(".contexts.%s.query[%s]", sec_ctx_key, yq_quote_path(chi_path))
			yq_delete(yaml_path, route_path)
			local q_map = {}
			for _, kv in ipairs(sec.params) do
				if kv.key ~= "" then
					q_map[kv.key] = kv.val
				end
			end
			for k, v in pairs(q_map) do
				local dotted = string.format(".contexts.%s.query[%s].%s", sec_ctx_key, yq_quote_path(chi_path), k)
				if not yq_set_string(yaml_path, dotted, v) then
					vim.notify("browser: yq query write failed for " .. k, vim.log.levels.WARN)
				end
			end
			if sec_ctx_key == active_ctx_key then
				active_query_params = q_map
			end
		end

		-- Write htmx to test file. Only htmx lives in the test file now.
		local fpath = views.test_file_path(chi_path, sec.ctx)
		vim.fn.mkdir(vim.fn.fnamemodify(fpath, ":h"), "p")
		local wf = io.open(fpath, "w")
		if wf then
			if sec.htmx ~= nil then
				wf:write("htmx: " .. tostring(sec.htmx) .. "\n")
			end
			wf:close()
		else
			vim.notify("browser: could not write test file " .. fpath, vim.log.levels.WARN)
		end

		if sec_ctx_key == active_ctx_key then
			active_path_params_changed = sec_path_params
		end
	end

	views.reload_config_silent()

	-- Resolve a chi_path using the freshly-edited params, falling back to
	-- the stored context for any param the user did not edit here.
	local function resolve_direct(cp, new_params)
		local existing = views.params_for_context(views.get_active_context())
		local result = cp
		for param in cp:gmatch("{([^}]+)}") do
			local v = new_params[param]
			if not v or v == "" or v:find("{") or v:match("%%7[Bb]") then
				v = existing[param] or ""
			end
			if v ~= "" and not v:find("{") and not v:match("%%7[Bb]") then
				result = result:gsub("{" .. vim.pesc(param) .. "}", v, 1)
			end
		end
		return result
	end

	-- Navigate the current tab.
	if state.http_tab_meta and chi_path then
		local nav_path = resolve_direct(chi_path, active_path_params_changed)
		if not nav_path:find("{") then
			local qp = views.build_query_string(active_query_params)
			local base = views.get_active_base()
			-- Use the htmx the user just saved for the active context, falling
			-- back to the tab's existing htmx state if not provided.
			local htmx = state.http_tab_meta.htmx or false
			for _, sec in ipairs(sections) do
				local k = sec.ctx == "" and "default" or sec.ctx
				if k == active_ctx_key and sec.htmx ~= nil then
					htmx = sec.htmx
					break
				end
			end
			send_cmd("switch " .. state.http_tab_meta.tab_id)
			send_cmd((htmx and "navigate" or "navigate-full") .. " " .. base .. nav_path .. qp)
			vim.notify(string.format("browser: %s%s%s", nav_path, qp, htmx and " [partial]" or " [full]"))
		else
			vim.notify("browser: unresolved params in " .. chi_path, vim.log.levels.WARN)
		end
	end

	-- Re-navigate other open tabs that share any of the updated path params.
	-- Query params are per-route, so they don't trigger fan-out re-nav.
	if next(active_path_params_changed) then
		local routes = views.get_routes()
		vim.schedule(function()
			for _, m in pairs(state.tab_metadata) do
				if m.tab_id == (state.http_tab_meta and state.http_tab_meta.tab_id) then
					goto next_tab
				end
				local chi = m.chi_path
				if not chi then
					for _, r in ipairs(routes) do
						if util.path_matches_chi(m.path, r.chi_path) then
							chi = r.chi_path
							break
						end
					end
				end
				if not chi then
					goto next_tab
				end
				local should_nav = false
				for param in chi:gmatch("{([^}]+)}") do
					if active_path_params_changed[param] then
						should_nav = true
						break
					end
				end
				if should_nav then
					local nav = resolve_direct(chi, active_path_params_changed)
					if not nav:find("{") then
						local q = views.build_query_string(views.query_for_route(active_ctx_key, chi))
						send_cmd("switch " .. m.tab_id)
						local cmd = (m.htmx or false) and "navigate" or "navigate-full"
						send_cmd(cmd .. " " .. views.get_active_base() .. nav .. q)
					end
				end
				::next_tab::
			end
		end)
		vim.notify(
			string.format(
				"browser: saved - updated %d path param(s) in [%s], re-navigating affected tabs",
				vim.tbl_count(active_path_params_changed),
				active_ctx_key
			)
		)
	else
		vim.notify("browser: saved")
	end

	return true
end

-- ============================================================
-- curl_preview
-- Fires curl -siL against the path/params in the active section.
-- ============================================================
function M.curl_preview(state)
	local buf = state.primary_buf
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	if not (state.http_tab_meta and state.http_chi_path) then
		vim.notify("browser: no active http context", vim.log.levels.WARN)
		return
	end

	local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local sections = parse_buffer(all_lines)
	local first = sections[1]
	if not first then
		vim.notify("browser: no context section", vim.log.levels.WARN)
		return
	end

	local views = require("browser.views")
	local base = views.get_active_base()
	local resolved = (first.path and first.path ~= "") and first.path or views.resolve_path(state.http_chi_path)

	local q_map = {}
	for _, kv in ipairs(first.params) do
		if kv.key ~= "" then
			q_map[kv.key] = kv.val
		end
	end
	local qp = views.build_query_string(q_map)
	local full_url = base .. resolved .. qp

	local hx_flag = state.http_tab_meta.htmx and (" -H 'HX-Request: true' -H 'HX-Current-URL: " .. full_url .. "'")
		or ""

	local cookie_file = require("browser.session").DEVPROXY_DIR .. "/cookies.txt"
	local cookie_flag = vim.fn.filereadable(cookie_file) == 1 and (" -b " .. vim.fn.shellescape(cookie_file)) or ""

	vim.notify("browser: GET " .. resolved .. qp)

	vim.fn.jobstart("curl -siL" .. hx_flag .. cookie_flag .. " " .. vim.fn.shellescape(full_url), {
		stdout_buffered = true,
		on_stdout = function(_, data)
			if not data then
				return
			end
			local all = {}
			for _, l in ipairs(data) do
				if l ~= nil then
					table.insert(all, (tostring(l):gsub("\r", "")))
				end
			end
			if #all == 0 then
				return
			end

			local blocks, current = {}, {}
			for _, l in ipairs(all) do
				if l:match("^HTTP/") and #current > 0 then
					table.insert(blocks, current)
					current = {}
				end
				table.insert(current, l)
			end
			if #current > 0 then
				table.insert(blocks, current)
			end

			local out = {}
			for i = #blocks, 1, -1 do
				local block = blocks[i]
				local in_body = false
				for _, l in ipairs(block) do
					if in_body then
						-- HTML body content is dropped
					elseif l == "" then
						in_body = true
						table.insert(out, l)
					else
						table.insert(out, l)
					end
				end
				if i > 1 then
					table.insert(out, "")
				end
			end

			vim.schedule(function()
				if state.layout then
					state.layout.set(require("browser.dashboard.util").PREVIEW_TITLE, out)
				end
			end)
		end,
	})
end

-- ============================================================
-- `:` picker
-- Opens a fuzzy floating-window picker over candidate keys to
-- insert under the nearest params: block.
-- Candidates: defaults + active context's path-param keys + any
-- keys already present in this section's params block.
-- ============================================================
local function in_params_section(buf, lnum)
	-- Walk backwards from lnum looking for the section's structural start.
	-- Returns true if the most recent label (path:/htmx:/params:) is params:.
	local lines = vim.api.nvim_buf_get_lines(buf, 0, lnum, false)
	for i = #lines, 1, -1 do
		local l = lines[i]
		local label = l:match("^([%w%.%-_]+):")
		if label then
			return label:lower() == "params"
		end
		if l:match("^%-%-%- context:") then
			return false
		end
	end
	return false
end

local function find_params_anchor(buf, lnum)
	-- Find the line number of the nearest preceding "params:" line.
	local lines = vim.api.nvim_buf_get_lines(buf, 0, lnum, false)
	for i = #lines, 1, -1 do
		if lines[i]:match("^params:%s*$") then
			return i
		end
		if lines[i]:match("^%-%-%- context:") then
			return nil
		end
	end
	return nil
end

local function existing_params_keys(buf, params_lnum)
	-- Read indented "  key:" lines below params_lnum until next non-indented
	-- line or end of buffer. Returns set of keys.
	local total = vim.api.nvim_buf_line_count(buf)
	local keys = {}
	for i = params_lnum + 1, total do
		local l = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
		if l == "" then
			break
		end
		local ik = l:match("^%s%s+([%w%.%-_]+):")
		if ik then
			keys[ik] = true
		else
			-- non-indented line ends the params block
			if not l:match("^%s") then
				break
			end
		end
	end
	return keys
end

-- Tiny fuzzy picker (substring filter, modeled on scratchbuf.fuzzy_filter).
local function fuzzy_pick(items, on_select)
	if #items == 0 then
		vim.notify("browser: no candidates", vim.log.levels.WARN)
		return
	end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = true

	local width = math.min(60, vim.o.columns - 4)
	local height = math.min(20, vim.o.lines - 6)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " params ",
		title_pos = "center",
	})

	local query = ""
	local filtered = {}
	local function render()
		filtered = {}
		local q = query:lower()
		for _, it in ipairs(items) do
			if q == "" or it:lower():find(q, 1, true) then
				table.insert(filtered, it)
			end
		end
		if #filtered == 0 then
			filtered = items
		end
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, filtered)
		vim.bo[buf].modifiable = false
		pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
		vim.api.nvim_win_set_config(win, {
			relative = "editor",
			row = math.floor((vim.o.lines - height) / 2),
			col = math.floor((vim.o.columns - width) / 2),
			width = width,
			height = height,
			title = " params  /" .. query .. " ",
			title_pos = "center",
		})
		vim.cmd("redraw")
	end
	render()

	local function close()
		pcall(vim.api.nvim_win_close, win, true)
	end

	while true do
		local ok, ch = pcall(vim.fn.getcharstr)
		if not ok then
			close()
			return
		end
		if ch == "\27" then
			close()
			return
		elseif ch == "\r" then
			local row = vim.api.nvim_win_get_cursor(win)[1]
			local sel = filtered[row]
			close()
			if sel then
				on_select(sel)
			end
			return
		elseif ch == "\14" or ch == "j" then
			if vim.api.nvim_get_mode().mode == "n" then
				local row = vim.api.nvim_win_get_cursor(win)[1]
				if row < #filtered then
					vim.api.nvim_win_set_cursor(win, { row + 1, 0 })
					vim.cmd("redraw")
				end
			else
				query = query .. ch
				render()
			end
		elseif ch == "\16" or ch == "k" then
			if vim.api.nvim_get_mode().mode == "n" then
				local row = vim.api.nvim_win_get_cursor(win)[1]
				if row > 1 then
					vim.api.nvim_win_set_cursor(win, { row - 1, 0 })
					vim.cmd("redraw")
				end
			else
				query = query .. ch
				render()
			end
		elseif ch == "\8" or ch == "\127" then
			if #query > 0 then
				query = query:sub(1, -2)
				render()
			end
		elseif #ch == 1 and ch:byte() >= 32 then
			query = query .. ch
			render()
		end
	end
end

function M._install_param_picker_keymap(buf, state)
	vim.keymap.set("n", ":", function()
		-- Only trigger inside an http panel.
		if state.view_mode ~= "http" then
			-- Pass through to default ":" behavior.
			vim.api.nvim_feedkeys(":", "n", false)
			return
		end
		local row = vim.api.nvim_win_get_cursor(0)[1]
		if not in_params_section(buf, row) then
			vim.api.nvim_feedkeys(":", "n", false)
			return
		end

		local views = require("browser.views")
		local cfg = views.get_config()
		local seen = {}
		local items = {}

		local function add(k)
			if k and k ~= "" and not seen[k] then
				seen[k] = true
				table.insert(items, k)
			end
		end

		-- defaults
		for k, _ in pairs(cfg.defaults or {}) do
			add(k)
		end
		-- active context (path params only - skip "query")
		local active = views.get_active_context()
		local ctx = (cfg.contexts or {})[active] or {}
		for k, _ in pairs(ctx) do
			if k ~= "query" then
				add(k)
			end
		end
		-- already-present keys in this section's params block
		local anchor = find_params_anchor(buf, row)
		if anchor then
			for k, _ in pairs(existing_params_keys(buf, anchor)) do
				add(k)
			end
		end

		table.sort(items)

		fuzzy_pick(items, function(key)
			-- Insert "  <key>: " on a new line just after the cursor's line,
			-- or right under the params: anchor if cursor is the anchor itself.
			local ins_row = row
			local cur_line = vim.api.nvim_buf_get_lines(buf, ins_row - 1, ins_row, false)[1] or ""
			if cur_line:match("^params:%s*$") then
				ins_row = row -- insert at row+1 (below the params: line)
			end
			vim.bo[buf].modifiable = true
			vim.api.nvim_buf_set_lines(buf, ins_row, ins_row, false, { "  " .. key .. ": " })
			vim.bo[buf].modified = true
			-- Move cursor onto the new line, after the colon+space.
			local new_row = ins_row + 1
			local new_col = #("  " .. key .. ": ")
			pcall(vim.api.nvim_win_set_cursor, 0, { new_row, new_col })
			vim.cmd("startinsert!")
		end)
	end, { buffer = buf, nowait = true, silent = true, desc = "browser: pick param key" })
end

return M
