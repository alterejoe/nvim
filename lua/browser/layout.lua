-- browser/layout.lua
-- Layout scaffold editor for devproxy partials.
-- Scans DOM for hx-target values, generates stub HTML, two-pane editor.
-- W = save + inject, R = regenerate from DOM, q = close

local M = {}
local _state = {}

local function send_cmd(cmd)
	return require("browser.session").send_cmd(cmd)
end

local function layouts_dir()
	return require("browser.session").LAYOUTS_DIR
end

local function path_to_slug(chi_path)
	return (chi_path or "unknown"):gsub("/$", ""):gsub("^/", ""):gsub("/", "-"):gsub("{", ""):gsub("}", "")
end

local function scan_targets_from_dom()
	local html = send_cmd("dom-dump")
	if not html or html:sub(1, 4) == "err:" then
		return {}
	end
	local targets = {}
	local seen = {}
	for target in html:gmatch('hx%-target="([^"]+)"') do
		if target:match("^#") and not seen[target] then
			seen[target] = true
			local id = target:sub(2)
			table.insert(targets, id)
		end
	end
	return targets
end

local function generate_stub_html(targets)
	if #targets == 0 then
		return "<!-- no hx-target IDs found in partial -->\n"
	end
	local lines = { "<!-- devproxy layout scaffold -->" }
	for _, id in ipairs(targets) do
		table.insert(
			lines,
			string.format(
				'<div id="%s" style="border:1px dashed #666;padding:8px;margin:4px;min-height:40px;"><!-- #%s --></div>',
				id,
				id
			)
		)
	end
	return table.concat(lines, "\n")
end

local function load_layout(slug)
	local path = layouts_dir() .. "/" .. slug .. ".html"
	if vim.fn.filereadable(path) == 0 then
		return nil
	end
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	return content
end

local function save_layout(slug, content)
	local dir = layouts_dir()
	vim.fn.mkdir(dir, "p")
	local path = dir .. "/" .. slug .. ".html"
	local f = io.open(path, "w")
	if not f then
		vim.notify("browser.layout: cannot write " .. path, vim.log.levels.ERROR)
		return false
	end
	f:write(content)
	f:close()
	return true
end

local function update_preview(left_buf, right_buf)
	if not (left_buf and vim.api.nvim_buf_is_valid(left_buf)) then
		return
	end
	if not (right_buf and vim.api.nvim_buf_is_valid(right_buf)) then
		return
	end
	local lines = vim.api.nvim_buf_get_lines(left_buf, 0, -1, false)
	vim.bo[right_buf].modifiable = true
	vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, lines)
	vim.bo[right_buf].modifiable = false
end

function M.open(nav)
	if not nav then
		vim.notify("browser.layout: no navigation recorded", vim.log.levels.WARN)
		return
	end
	local chi_path = nav.chi_path
	local slug = path_to_slug(chi_path)
	local content = load_layout(slug)
	if not content then
		local targets = scan_targets_from_dom()
		content = generate_stub_html(targets)
	end
	local initial_lines = vim.split(content, "\n")
	if _state.left_buf and vim.api.nvim_buf_is_valid(_state.left_buf) then
		vim.api.nvim_buf_delete(_state.left_buf, { force = true })
	end
	if _state.right_buf and vim.api.nvim_buf_is_valid(_state.right_buf) then
		vim.api.nvim_buf_delete(_state.right_buf, { force = true })
	end
	_state = { slug = slug, chi_path = chi_path }
	local right_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[right_buf].buftype = "nofile"
	vim.bo[right_buf].bufhidden = "wipe"
	vim.bo[right_buf].swapfile = false
	vim.bo[right_buf].filetype = "html"
	vim.bo[right_buf].modifiable = true
	vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, {
		"-- W=save+inject  R=regen from DOM  q=close --",
		"",
	})
	vim.bo[right_buf].modifiable = false
	vim.api.nvim_buf_set_name(right_buf, "devproxy://layout-preview")
	local left_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[left_buf].buftype = "nofile"
	vim.bo[left_buf].bufhidden = "wipe"
	vim.bo[left_buf].swapfile = false
	vim.bo[left_buf].filetype = "html"
	vim.api.nvim_buf_set_name(left_buf, "devproxy://layout-editor")
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
	update_preview(left_buf, right_buf)
	local aug = vim.api.nvim_create_augroup("devproxy_layout", { clear = true })
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = left_buf,
		group = aug,
		callback = function()
			update_preview(left_buf, right_buf)
		end,
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
	map("W", function()
		local lines = vim.api.nvim_buf_get_lines(left_buf, 0, -1, false)
		local content = table.concat(lines, "\n")
		if save_layout(_state.slug, content) then
			local result = send_cmd("inject-layout " .. _state.slug)
			vim.notify("browser.layout: saved + injected  " .. (result or "?"))
		end
	end, "Save and inject layout")
	map("R", function()
		local targets = scan_targets_from_dom()
		local new_content = generate_stub_html(targets)
		vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, vim.split(new_content, "\n"))
		vim.notify("browser.layout: regenerated from DOM (" .. #targets .. " targets found)")
	end, "Regenerate from DOM")
	map("q", function()
		if vim.api.nvim_buf_is_valid(left_buf) then
			vim.api.nvim_buf_delete(left_buf, { force = true })
		end
	end, "Close")
end

return M
