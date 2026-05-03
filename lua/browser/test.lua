-- browser/test.lua
--
-- Two-pane HTTP test editor for devproxy routes.
-- Left: editable labeled fields. Right: rendered HTTP preview + response.

local M = {}

local _state = {}

local function send_cmd(cmd)
	return require("browser.session").send_cmd(cmd)
end

local function get_active_base()
	local raw = send_cmd("active-server")
	if raw then
		local port = raw:match("port (%d+)")
		if port then
			return "http://localhost:" .. port
		end
	end
	return "http://localhost:3333"
end

local function tests_dir()
	return require("browser.session").TESTS_DIR
end

local function path_to_slug(chi_path)
	return (chi_path or "unknown"):gsub("/$", ""):gsub("^/", ""):gsub("/", "-"):gsub("{", ""):gsub("}", "")
end

local function parse_fields(lines)
	local req = { method = "GET", path = "", query = "", headers = {}, body = {} }
	for _, line in ipairs(lines) do
		local label, val = line:match("^([%w%.%-_]+):%s*(.*)")
		if label and val then
			val = vim.trim(val)
			local low = label:lower()
			if low == "method" then
				req.method = val:upper()
			elseif low == "path" then
				req.path = val
			elseif low == "query" then
				req.query = val
			else
				local hname = low:match("^header%.(.+)$")
				if hname then
					local orig = label:match("^[Hh]eader%.(.+)$") or hname
					req.headers[orig] = val
				end
				local bname = label:match("^[Bb]ody%.(.+)$")
				if bname then
					req.body[bname] = val
				end
			end
		end
	end
	return req
end

local function render_preview(req, base_url)
	local lines = {}
	local u = base_url .. req.path
	if req.query ~= "" then
		u = u .. "?" .. req.query
	end
	table.insert(lines, req.method .. " " .. u .. " HTTP/1.1")
	local host = base_url:match("//([^/]+)") or "localhost"
	table.insert(lines, "Host: " .. host)
	local hkeys = vim.tbl_keys(req.headers)
	table.sort(hkeys)
	for _, k in ipairs(hkeys) do
		table.insert(lines, k .. ": " .. req.headers[k])
	end
	if next(req.body) then
		local parts = {}
		for k, v in pairs(req.body) do
			table.insert(parts, k .. "=" .. v)
		end
		local body_str = table.concat(parts, "&")
		table.insert(lines, "Content-Type: application/x-www-form-urlencoded")
		table.insert(lines, "Content-Length: " .. #body_str)
		table.insert(lines, "")
		table.insert(lines, body_str)
	end
	return lines
end

local function update_preview()
	if not (_state.left_buf and vim.api.nvim_buf_is_valid(_state.left_buf)) then
		return
	end
	if not (_state.right_buf and vim.api.nvim_buf_is_valid(_state.right_buf)) then
		return
	end
	local lines = vim.api.nvim_buf_get_lines(_state.left_buf, 0, -1, false)
	local req = parse_fields(lines)
	local preview = render_preview(req, _state.base_url or get_active_base())
	vim.bo[_state.right_buf].modifiable = true
	local end_line = _state.sep_line and (_state.sep_line - 1) or -1
	vim.api.nvim_buf_set_lines(_state.right_buf, 0, end_line, false, preview)
	if not _state.sep_line then
		_state.req_end = #preview
	end
	vim.bo[_state.right_buf].modifiable = false
end

local function append_response(status_line)
	if not (_state.right_buf and vim.api.nvim_buf_is_valid(_state.right_buf)) then
		return
	end
	vim.bo[_state.right_buf].modifiable = true
	local count = vim.api.nvim_buf_line_count(_state.right_buf)
	vim.api.nvim_buf_set_lines(_state.right_buf, count, -1, false, { "", "--- " .. status_line })
	_state.sep_line = count + 1
	vim.bo[_state.right_buf].modifiable = false
	if _state.right_win and vim.api.nvim_win_is_valid(_state.right_win) then
		local new_count = vim.api.nvim_buf_line_count(_state.right_buf)
		vim.api.nvim_win_set_cursor(_state.right_win, { new_count, 0 })
	end
end

local function do_send()
	if not (_state.left_buf and vim.api.nvim_buf_is_valid(_state.left_buf)) then
		return
	end
	local lines = vim.api.nvim_buf_get_lines(_state.left_buf, 0, -1, false)
	local req = parse_fields(lines)
	local base = _state.base_url or get_active_base()
	local url = base .. req.path
	if req.query ~= "" then
		url = url .. "?" .. req.query
	end
	_state.sep_line = nil
	update_preview()
	if req.method == "GET" then
		local htmx = req.headers["HX-Request"] == "true"
		local cmd = htmx and "navigate" or "navigate-full"
		local result = send_cmd(cmd .. " " .. url)
		append_response(result or "ok")
		return
	end
	local payload = vim.json.encode({
		method = req.method,
		url = url,
		headers = req.headers,
		body = req.body,
	})
	local result = send_cmd("test-request " .. payload)
	if not result then
		append_response("Error: no response")
		return
	end
	if result:sub(1, 1) == "{" then
		local ok, data = pcall(vim.json.decode, result)
		if ok and data.status then
			append_response(
				string.format(
					"Response: %d  %s (%dms) - see browser",
					data.status,
					data.content_type or "?",
					data.elapsed_ms or 0
				)
			)
		else
			append_response(result)
		end
	else
		append_response(result)
	end
end

local function do_save()
	if not (_state.left_buf and vim.api.nvim_buf_is_valid(_state.left_buf)) then
		return
	end
	local dir = tests_dir()
	vim.fn.mkdir(dir, "p")
	local slug = path_to_slug(_state.chi_path)
	local path = dir .. "/" .. slug .. ".http"
	local lines = vim.api.nvim_buf_get_lines(_state.left_buf, 0, -1, false)
	local f = io.open(path, "w")
	if not f then
		vim.notify("browser.test: cannot write " .. path, vim.log.levels.ERROR)
		return
	end
	f:write("# devproxy-test\n")
	f:write("# chi_path: " .. (_state.chi_path or "") .. "\n")
	f:write("# base: " .. (_state.base_url or "") .. "\n")
	f:write("\n")
	for _, line in ipairs(lines) do
		f:write(line .. "\n")
	end
	f:close()
	vim.notify("browser.test: saved  " .. path)
end

local function load_file(path)
	local f = io.open(path, "r")
	if not f then
		return nil, nil
	end
	local lines, meta = {}, {}
	for line in f:lines() do
		if line:match("^# chi_path: ") then
			meta.chi_path = line:match("^# chi_path: (.+)$")
		elseif line:match("^# base: ") then
			meta.base_url = line:match("^# base: (.+)$")
		elseif not line:match("^#") then
			table.insert(lines, line)
		end
	end
	f:close()
	while #lines > 0 and vim.trim(lines[1]) == "" do
		table.remove(lines, 1)
	end
	return lines, meta
end

function M.load_pick()
	local dir = tests_dir()
	if vim.fn.isdirectory(dir) == 0 then
		vim.notify("browser.test: no tests at " .. dir, vim.log.levels.WARN)
		return
	end
	local files = vim.fn.glob(dir .. "/*.http", false, true)
	if #files == 0 then
		vim.notify("browser.test: no saved tests", vim.log.levels.WARN)
		return
	end
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	pickers
		.new({}, {
			prompt_title = "Load Test  [CR=open]",
			finder = finders.new_table({
				results = files,
				entry_maker = function(fp)
					local name = vim.fn.fnamemodify(fp, ":t:r")
					return { value = fp, display = name, ordinal = name }
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					local sel = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if not sel then
						return
					end
					local lines, meta = load_file(sel.value)
					if lines then
						M.open(nil, lines, meta)
					end
				end)
				return true
			end,
		})
		:find()
end

function M.open(nav, preload_lines, preload_meta)
	local base_url = get_active_base()
	local chi_path, initial_lines
	if preload_lines and preload_meta then
		initial_lines = preload_lines
		chi_path = preload_meta.chi_path
		base_url = preload_meta.base_url or base_url
	elseif nav then
		chi_path = nav.chi_path
		local slug = path_to_slug(chi_path or "")
		local test_path = tests_dir() .. "/" .. slug .. ".http"
		if vim.fn.filereadable(test_path) == 1 then
			local saved_lines, saved_meta = load_file(test_path)
			if saved_lines then
				initial_lines = saved_lines
				base_url = (saved_meta and saved_meta.base_url) or base_url
			end
		end
		if not initial_lines then
			local query = (nav.qp or ""):gsub("^%?", "")
			initial_lines = {
				"Method:  GET",
				"Path:    " .. (nav.resolved or ""),
				"Query:   " .. query,
			}
			if nav.htmx then
				table.insert(initial_lines, "Header.HX-Request:  true")
			end
		end
	else
		vim.notify("browser.test: no navigation recorded", vim.log.levels.WARN)
		return
	end
	if _state.left_buf and vim.api.nvim_buf_is_valid(_state.left_buf) then
		vim.api.nvim_buf_delete(_state.left_buf, { force = true })
	end
	if _state.right_buf and vim.api.nvim_buf_is_valid(_state.right_buf) then
		vim.api.nvim_buf_delete(_state.right_buf, { force = true })
	end
	_state = { chi_path = chi_path, base_url = base_url }
	local right_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[right_buf].buftype = "nofile"
	vim.bo[right_buf].bufhidden = "wipe"
	vim.bo[right_buf].swapfile = false
	vim.bo[right_buf].filetype = "http"
	vim.bo[right_buf].modifiable = true
	vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, {
		"-- W=send+save  CR=send  R=reset  M=method  o=body  H=header  L=load  q=close --",
		"",
	})
	vim.bo[right_buf].modifiable = false
	vim.api.nvim_buf_set_name(right_buf, "devproxy://test-preview")
	local left_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[left_buf].buftype = "nofile"
	vim.bo[left_buf].bufhidden = "wipe"
	vim.bo[left_buf].swapfile = false
	vim.bo[left_buf].filetype = "conf"
	vim.api.nvim_buf_set_name(left_buf, "devproxy://test-params")
	vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, initial_lines)
	_state.left_buf = left_buf
	_state.right_buf = right_buf
	vim.api.nvim_set_current_buf(left_buf)
	local left_win = vim.api.nvim_get_current_win()
	vim.cmd("vsplit")
	local right_win = vim.api.nvim_get_current_win()
	vim.api.nvim_set_current_buf(right_buf)
	vim.wo[right_win].number = false
	vim.wo[right_win].wrap = true
	vim.wo[right_win].cursorline = false
	vim.api.nvim_set_current_win(left_win)
	vim.wo[left_win].number = true
	vim.wo[left_win].cursorline = true
	_state.left_win = left_win
	_state.right_win = right_win

	local aug = vim.api.nvim_create_augroup("devproxy_test", { clear = true })
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = left_buf,
		group = aug,
		callback = update_preview,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = left_buf,
		group = aug,
		once = true,
		callback = function()
			if _state.right_buf and vim.api.nvim_buf_is_valid(_state.right_buf) then
				vim.api.nvim_buf_delete(_state.right_buf, { force = true })
			end
			_state = {}
		end,
	})
	local function map(lhs, rhs, desc)
		vim.keymap.set("n", lhs, rhs, { buffer = left_buf, nowait = true, noremap = true, desc = desc })
	end
	map("<CR>", do_send, "Send request")
	map("W", function()
		do_send()
		do_save()
	end, "Send and save")
	map("R", function()
		local views = require("browser.views")
		local last = views._last_nav
		if not last then
			vim.notify("browser.test: no navigation to reset to", vim.log.levels.WARN)
			return
		end
		local query = (last.qp or ""):gsub("^%?", "")
		local reset_lines = {
			"Method:  GET",
			"Path:    " .. (last.resolved or ""),
			"Query:   " .. query,
		}
		if last.htmx then
			table.insert(reset_lines, "Header.HX-Request:  true")
		end
		vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, reset_lines)
		vim.notify("browser.test: reset to nav defaults")
	end, "Reset to nav defaults")
	map("L", M.load_pick, "Load saved test")
	map("q", function()
		if vim.api.nvim_buf_is_valid(left_buf) then
			vim.api.nvim_buf_delete(left_buf, { force = true })
		end
	end, "Close")
	map("o", function()
		local lnum = vim.api.nvim_win_get_cursor(left_win)[1]
		vim.api.nvim_buf_set_lines(left_buf, lnum, lnum, false, { "Body.field:  " })
		vim.api.nvim_win_set_cursor(left_win, { lnum + 1, 0 })
		vim.cmd("startinsert!")
	end, "Add body field")
	map("H", function()
		local lnum = vim.api.nvim_win_get_cursor(left_win)[1]
		vim.api.nvim_buf_set_lines(left_buf, lnum, lnum, false, { "Header.Name:  " })
		vim.api.nvim_win_set_cursor(left_win, { lnum + 1, 0 })
		vim.cmd("startinsert!")
	end, "Add header field")
	map("M", function()
		local methods = { "GET", "POST", "PUT", "PATCH", "DELETE" }
		local lines = vim.api.nvim_buf_get_lines(left_buf, 0, -1, false)
		for i, line in ipairs(lines) do
			if line:match("^Method:") then
				local cur = line:match("^Method:%s+(%u+)") or "GET"
				local idx = 1
				for j, m in ipairs(methods) do
					if m == cur then
						idx = j
						break
					end
				end
				local next_method = methods[(idx % #methods) + 1]
				lines[i] = "Method:  " .. next_method
				vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, lines)
				break
			end
		end
	end, "Cycle method")
end

return M
