-- /home/altjoe/.config/nvim/lua/opencode-manage/foldersview.lua FINAL
-- opencode-manage.foldersview — permissions viewer (doc 23, PM1, simplified).
-- ONE float, two views inside it:
--   · saved list (default)
--   · `a` → oil opens IN THE SAME WINDOW at the tmux pane cwd (fallback:
--     nvim cwd) — navigate like oil; `A` (or `o`) saves the directory you
--     are viewing (scope prompt); `q`/Esc returns to the list; `Q` closes
--     the float from either view.
-- No second pane: verify output lands as footer lines.
--   j/k move · a browse+save · x avoid · d remove · o open ·
--   s sync · v verify · Q close
-- Approve writes state.db memory; `s` merges approved rows into
-- opencode.json external_directory (journaled, additive-only); `v` reports
-- drift both ways.

local folders = require("opencode-manage.folders")

local M = {}

local state = {
	rows = {},
	idx = 1,
	buf = nil,
	win = nil,
	origin_win = nil,
	origin_buf = nil,
	report = nil, -- last verify report
}

local function define_hls()
	local hl = vim.api.nvim_set_hl
	hl(0, "ManageFolderOk", { fg = "#4ec9b0" }) -- approved + in config
	hl(0, "ManageFolderAvoid", { fg = "#f44747" }) -- avoid
	hl(0, "ManageFolderDrift", { fg = "#e5c07b" }) -- approved but not in config
	hl(0, "ManageFolderHint", { link = "Comment" }) -- footer lines
end

local function short(path)
	return vim.fn.fnamemodify(path, ":~")
end

local function secs(v)
	local n = tonumber(v) or 0
	if n > 100000000000 then
		return n / 1000
	end
	return n
end

local function fmt_when(ts)
	local n = tonumber(ts)
	if not n or n == 0 then
		return "?"
	end
	return os.date("%m-%d %H:%M", math.floor(secs(n)))
end

--- The tmux pane cwd (where you actually are), fallback nvim cwd.
--- @return string
local function browse_root()
	local out = vim.fn.system({ "tmux", "display-message", "-p", "#{pane_current_path}" })
	if vim.v.shell_error == 0 and type(out) == "string" then
		local dir = vim.trim(out)
		if dir ~= "" and vim.fn.isdirectory(dir) == 1 then
			return dir
		end
	end
	return vim.fn.getcwd()
end

local function load_rows()
	local cfg_global = folders.config_entries("global")
	local cfg_project = folders.config_entries("project")
	local rows = folders.list()
	for _, r in ipairs(rows) do
		local cfg = r.scope == "project" and cfg_project or cfg_global
		r.in_config = cfg[folders.entry_for(r.path)] ~= nil
	end
	state.rows = rows
	state.idx = math.max(1, math.min(state.idx, #rows))
end

local function render()
	if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
		vim.notify("folders: list buffer is gone — reopen with <leader>aa", vim.log.levels.WARN)
		return
	end
	local lines = { "📁 FOLDERS — " .. #state.rows .. " saved" }
	local hl = {}
	local sel = 1
	for i, r in ipairs(state.rows) do
		local marker = i == state.idx and ">" or " "
		local tag = r.status == "avoid" and "x " or "ok"
		local drift = (r.status ~= "avoid" and not r.in_config) and " !" or ""
		lines[#lines + 1] = string.format(
			"%s [%s] %-44s %-7s u=%-3s %s%s",
			marker,
			tag,
			short(r.path),
			tostring(r.scope),
			tostring(r.uses or 0),
			fmt_when(r.last_seen),
			drift
		)
		hl[#lines] = (r.status == "avoid" and "ManageFolderAvoid")
			or (not r.in_config and "ManageFolderDrift")
			or "ManageFolderOk"
		if i == state.idx then
			sel = #lines
		end
	end
	if #state.rows == 0 then
		lines[#lines + 1] = "  — none saved — press a to browse (oil) and save a folder —"
		hl[#lines] = "ManageFolderHint"
	end
	if state.report then
		lines[#lines + 1] = "  ── verify ──"
		hl[#lines] = "ManageFolderHint"
		if #state.report.missing == 0 and #state.report.extra == 0 then
			lines[#lines + 1] = "  in sync"
			hl[#lines] = "ManageFolderOk"
		else
			for _, m in ipairs(state.report.missing) do
				lines[#lines + 1] = "  missing from config: " .. m
				hl[#lines] = "ManageFolderDrift"
			end
			for _, e in ipairs(state.report.extra) do
				lines[#lines + 1] = "  in config, not in memory: " .. e
				hl[#lines] = "ManageFolderHint"
			end
		end
	end
	lines[#lines + 1] =
		"  a browse (oil: a row · A folder) · x avoid · d remove · o open · s sync · v verify · Q close"
	hl[#lines] = "ManageFolderHint"
	vim.bo[state.buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
	vim.bo[state.buf].modifiable = false
	local ns = vim.api.nvim_create_namespace("manage-folders")
	vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
	for ln, h in pairs(hl) do
		vim.api.nvim_buf_add_highlight(state.buf, ns, h, ln - 1, 0, -1)
	end
	pcall(vim.api.nvim_win_set_cursor, state.win, { sel, 0 })
end

local function refresh()
	load_rows()
	render()
end

local function current()
	return state.rows[state.idx]
end

local function set_title(text)
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		pcall(vim.api.nvim_win_set_config, state.win, { title = text, title_pos = "center" })
	end
end

local function kill()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		pcall(vim.api.nvim_win_close, state.win, true)
	end
	if state.origin_win and vim.api.nvim_win_is_valid(state.origin_win) then
		pcall(vim.api.nvim_set_current_win, state.origin_win)
	end
end

--- Scope is automatic (no prompt): a folder inside the current project is
--- "project" (this repo's config); anywhere else is "common" (global).
local function auto_scope(dir)
	local root = folders.project_root()
	if root and (dir == root or dir:sub(1, #root + 1) == root .. "/") then
		return "project"
	end
	return "common"
end

--- Save a directory with the automatic scope; the row shows it afterwards.
--- PM3/CV1: a successful save also indexes the folder into refs — the
--- project store for "project", the GLOBAL vault store for "common", so
--- approved folders land in refs by default.
local function save_dir(dir)
	if type(dir) ~= "string" or dir == "" or vim.fn.isdirectory(dir) ~= 1 then
		vim.notify("folders: not a directory: " .. tostring(dir), vim.log.levels.WARN)
		return
	end
	local scope = auto_scope(dir)
	if folders.approve(dir, scope) then
		vim.notify(("folders: saved %s (%s)"):format(short(dir), scope), vim.log.levels.INFO)
		local ok, refs = pcall(require, "opencode-manage.refs")
		if ok then
			pcall(refs.index, dir, { global = scope == "common" })
		end
		refresh()
	end
end

--- Back from oil to the saved list, same window.
local function return_to_list()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		vim.api.nvim_win_set_buf(state.win, state.buf)
		set_title(" FOLDERS ")
		refresh()
	end
end

--- `a` (in oil): save the HIGHLIGHTED row when it is a directory.
local function save_row()
	local ok, oil = pcall(require, "oil")
	if not ok or type(oil.get_cursor_entry) ~= "function" then
		vim.notify("folders: oil API unavailable — A saves the containing folder", vim.log.levels.WARN)
		return
	end
	local entry = oil.get_cursor_entry()
	if type(entry) ~= "table" or type(entry.name) ~= "string" then
		vim.notify("folders: nothing under the cursor", vim.log.levels.WARN)
		return
	end
	local dir = nil
	if type(oil.get_current_dir) == "function" then
		dir = oil.get_current_dir(vim.api.nvim_get_current_buf())
	end
	dir = dir or state.browse_dir
		local target = dir:gsub("/+$", "") .. "/" .. entry.name
	if entry.type ~= "directory" then
		vim.notify(
			"folders: " .. short(target) .. " is not a folder (a = highlighted row, A = containing folder)",
			vim.log.levels.WARN
		)
		return
	end
	vim.notify("folders: saving " .. short(target) .. " …", vim.log.levels.INFO)
	save_dir(target)
end

--- `A` (in oil): save the CONTAINING folder (the one you are inside).
local function save_here()
	local d = nil
	local ok, oil = pcall(require, "oil")
	if ok and type(oil.get_current_dir) == "function" then
		d = oil.get_current_dir(vim.api.nvim_get_current_buf())
	end
	d = d or state.browse_dir
	vim.notify("folders: saving containing folder " .. short(d) .. " …", vim.log.levels.INFO)
	save_dir(d)
end

--- Bind our keys on the oil buffer actually shown in OUR float. Called on
--- FileType/BufEnter/OilEnter — late enough that oil's own setup cannot win.
local function bind_oil(buf)
	local function map(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, {
			buffer = buf,
			nowait = true,
			silent = true,
			desc = desc,
		})
	end
	map("a", save_row, "folders: save highlighted row")
	map("A", save_here, "folders: save containing folder")
	map("q", return_to_list, "folders: back to list")
	map("<Esc>", return_to_list, "folders: back to list")
	map("Q", kill, "folders: close")
end

local function browse()
	local dir = browse_root()
	state.browse_dir = dir
	local ok, oil = pcall(require, "oil")
	if not ok or type(oil.open) ~= "function" then
		vim.notify("folders: oil not available for browsing", vim.log.levels.WARN)
		return
	end
	local opened = pcall(oil.open, dir)
	if not opened then
		vim.notify("folders: oil could not open " .. short(dir), vim.log.levels.WARN)
		return
	end
	set_title(" FOLDERS · browse — a row · A folder · q back · Q close ")
	local group = vim.api.nvim_create_augroup("manage_folders_oil", { clear = true })
	local function maybe_bind(ev)
		if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
			return
		end
		local shown = vim.api.nvim_win_get_buf(state.win)
		if shown ~= ev.buf and shown ~= vim.api.nvim_get_current_buf() then
			return
		end
		bind_oil(shown)
	end
	vim.api.nvim_create_autocmd({ "FileType", "BufEnter" }, {
		group = group,
		pattern = "oil",
		callback = maybe_bind,
	})
	-- Oil's own "entered" event: the most reliable late point.
	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = "OilEnter",
		callback = maybe_bind,
	})
	if vim.bo[vim.api.nvim_get_current_buf()].filetype == "oil" then
		bind_oil(vim.api.nvim_get_current_buf())
	end
	vim.notify("folders: a saves the highlighted row · A saves the containing folder · q back", vim.log.levels.INFO)
end

local function do_avoid()
	local it = current()
	if not it then
		return
	end
	if folders.avoid(it.path) then
		refresh()
	end
end

local function do_remove()
	local it = current()
	if not it then
		return
	end
	local choice = vim.fn.confirm(
		"Remove the memory row for " .. short(it.path) .. "?\n(config entries stay; sync never deletes)",
		"&Remove\n&Cancel",
		2
	)
	if choice ~= 1 then
		return
	end
	if folders.remove(it.id) then
		refresh()
	end
end

local function do_open()
	local it = current()
	if not it then
		return
	end
	if vim.fn.isdirectory(it.path) ~= 1 then
		vim.notify("folders: not a directory: " .. it.path, vim.log.levels.WARN)
		return
	end
	if state.origin_win and vim.api.nvim_win_is_valid(state.origin_win) then
		pcall(vim.api.nvim_set_current_win, state.origin_win)
	end
	pcall(vim.cmd, "edit " .. vim.fn.fnameescape(it.path))
end

local function do_sync()
	folders.sync()
	refresh()
end

local function do_verify()
	state.report = folders.verify()
	render()
end

local function map_keys()
	local function nmap(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = state.buf, nowait = true, desc = desc })
	end
	nmap("j", function()
		state.idx = math.min(state.idx + 1, #state.rows)
		render()
	end, "folders: next")
	nmap("k", function()
		state.idx = math.max(state.idx - 1, 1)
		render()
	end, "folders: prev")
	nmap("a", browse, "folders: browse (oil) + save")
	nmap("x", do_avoid, "folders: avoid")
	nmap("d", do_remove, "folders: remove row")
	nmap("o", do_open, "folders: open folder")
	nmap("s", do_sync, "folders: sync config")
	nmap("v", do_verify, "folders: verify drift")
	nmap("r", refresh, "folders: refresh")
	nmap("Q", kill, "folders: close")
	nmap("q", kill, "folders: close")
	nmap("<Esc>", kill, "folders: close")
end

function M.open()
	define_hls()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		refresh()
		vim.api.nvim_set_current_win(state.win)
		return
	end
	state.origin_win = vim.api.nvim_get_current_win()
	state.buf = vim.api.nvim_create_buf(false, true)
	vim.bo[state.buf].buftype = "nofile"
	vim.bo[state.buf].bufhidden = "hide" -- oil takes this window; the list must survive being hidden
	vim.bo[state.buf].swapfile = false
	-- Big panel: ~3x the old area, 80% of the editor in both dimensions.
	load_rows()
	local w = math.floor(vim.o.columns * 0.8)
	local h = math.floor(vim.o.lines * 0.8)
	state.win = vim.api.nvim_open_win(state.buf, true, {
		relative = "editor",
		width = w,
		height = h,
		row = math.floor((vim.o.lines - h) / 2),
		col = math.floor((vim.o.columns - w) / 2),
		style = "minimal",
		border = "rounded",
		title = " FOLDERS ",
		title_pos = "center",
	})
	vim.wo[state.win].cursorline = true
	vim.wo[state.win].winhighlight = "CursorLine:Visual"
	map_keys()
	refresh()
end

return M
