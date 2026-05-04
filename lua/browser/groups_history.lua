-- browser/groups_history.lua
-- Unified snapshot history for groups.yaml, headings.yaml, tags.yaml.
-- Snapshots are taken on every save (regardless of whether content changed);
-- this is intentional - storage is cheap and accidental deletions are not.
--
-- Storage layout:
--   .devproxy/.history/<basename>.<unix_ts>.yaml
--
-- The picker shows snapshots from all three files in one list, sorted by
-- timestamp newest first, each row labeled with which file it belongs to.

local M = {}

local MAX_PER_FILE = 50

-- The three files we track. Keep this list in sync with the save sites
-- (groups.lua, dashboard/tabops.lua).
local function devproxy_dir()
	return require("browser.session").DEVPROXY_DIR
end

local function tracked_files()
	local d = devproxy_dir()
	return {
		{ base = "groups", path = d .. "/groups.yaml" },
		{ base = "headings", path = d .. "/headings.yaml" },
		{ base = "tags", path = d .. "/tags.yaml" },
	}
end

local function history_dir()
	local d = devproxy_dir() .. "/.history"
	if vim.fn.isdirectory(d) == 0 then
		vim.fn.mkdir(d, "p")
	end
	return d
end

local function basename_for(source_path)
	return vim.fn.fnamemodify(source_path, ":t:r")
end

local function source_for_base(base)
	for _, f in ipairs(tracked_files()) do
		if f.base == base then
			return f.path
		end
	end
	return nil
end

-- ============================================================
-- snapshot
-- Copies source_path to .history/<base>.<ts>.yaml. No-op if source
-- doesn't exist. Prunes older snapshots beyond MAX_PER_FILE.
-- ============================================================
function M.snapshot(source_path)
	if vim.fn.filereadable(source_path) == 0 then
		return
	end
	local base = basename_for(source_path)
	local ts = os.time()
	local snap = string.format("%s/%s.%d.yaml", history_dir(), base, ts)

	local i = 0
	while vim.fn.filereadable(snap) == 1 do
		i = i + 1
		snap = string.format("%s/%s.%d.%d.yaml", history_dir(), base, ts, i)
	end

	local src = io.open(source_path, "r")
	if not src then
		return
	end
	local content = src:read("*a")
	src:close()
	local dst = io.open(snap, "w")
	if not dst then
		return
	end
	dst:write(content)
	dst:close()

	M._prune(base)
end

-- ============================================================
-- list_for_base
-- Snapshots for one basename, newest first. Internal helper.
-- ============================================================
local function list_for_base(base)
	local dir = history_dir()
	local result = {}
	local handle = vim.loop.fs_scandir(dir)
	if not handle then
		return result
	end
	while true do
		local name, typ = vim.loop.fs_scandir_next(handle)
		if not name then
			break
		end
		if typ == "file" then
			local ts = name:match("^" .. vim.pesc(base) .. "%.(%d+)%.%d*%.?yaml$")
				or name:match("^" .. vim.pesc(base) .. "%.(%d+)%.yaml$")
			if ts then
				local ts_n = tonumber(ts)
				local full = dir .. "/" .. name
				local stat = vim.loop.fs_stat(full)
				local size = stat and stat.size or 0
				table.insert(result, {
					path = full,
					ts = ts_n,
					base = base,
					size = size,
				})
			end
		end
	end
	table.sort(result, function(a, b)
		return a.ts > b.ts
	end)
	return result
end

-- ============================================================
-- list_all
-- Snapshots for ALL tracked files merged into one list, sorted by
-- timestamp newest first.
-- Each entry: { path, ts, base, size, label }
-- ============================================================
function M.list_all()
	local merged = {}
	for _, f in ipairs(tracked_files()) do
		for _, s in ipairs(list_for_base(f.base)) do
			s.label = string.format("%s  %-9s  (%d bytes)", os.date("%Y-%m-%d %H:%M:%S", s.ts), s.base, s.size)
			table.insert(merged, s)
		end
	end
	table.sort(merged, function(a, b)
		return a.ts > b.ts
	end)
	return merged
end

-- ============================================================
-- restore
-- Copies snap_path back to dest_path. Snapshots the current file
-- first so the restore itself can be undone.
-- ============================================================
function M.restore(snap_path, dest_path)
	if vim.fn.filereadable(snap_path) == 0 then
		return false, "snapshot not found: " .. snap_path
	end
	M.snapshot(dest_path)
	local src = io.open(snap_path, "r")
	if not src then
		return false, "cannot read snapshot"
	end
	local content = src:read("*a")
	src:close()
	local dst = io.open(dest_path, "w")
	if not dst then
		return false, "cannot write " .. dest_path
	end
	dst:write(content)
	dst:close()
	return true
end

function M._prune(base)
	local snaps = list_for_base(base)
	if #snaps <= MAX_PER_FILE then
		return
	end
	for i = MAX_PER_FILE + 1, #snaps do
		os.remove(snaps[i].path)
	end
end

local function read_file_lines(path)
	local f = io.open(path, "r")
	if not f then
		return { "-- cannot read file --" }
	end
	local content = f:read("*a")
	f:close()
	if content == "" then
		return { "-- empty --" }
	end
	local lines = vim.split(content, "\n", { plain = true })
	if lines[#lines] == "" then
		table.remove(lines)
	end
	return lines
end

-- ============================================================
-- pick
-- Two-pane floating picker over snapshots from all three files.
-- Left: list with timestamp + filename. Right: preview that follows
-- the cursor. CR restores selected snapshot to its source file.
-- r/h/t filter to groups/headings/tags only; a shows all.
-- on_done is called after a successful restore.
-- ============================================================
function M.pick(on_done)
	local all_snaps = M.list_all()
	if #all_snaps == 0 then
		vim.notify("browser.history: no snapshots yet", vim.log.levels.WARN)
		return
	end

	local total_w = math.min(120, vim.o.columns - 4)
	local total_h = math.min(28, math.max(#all_snaps + 4, 12))
	local left_w = math.min(48, math.floor(total_w * 0.42))
	local right_w = total_w - left_w - 1

	local row = math.floor((vim.o.lines - total_h) / 2)
	local col = math.floor((vim.o.columns - total_w) / 2)

	-- Left pane: snapshot list
	local list_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[list_buf].buftype = "nofile"
	vim.bo[list_buf].bufhidden = "wipe"
	vim.bo[list_buf].modifiable = false

	local list_win = vim.api.nvim_open_win(list_buf, true, {
		relative = "editor",
		row = row,
		col = col,
		width = left_w,
		height = total_h,
		style = "minimal",
		border = "rounded",
		title = " history  [a/r/h/t] ",
		title_pos = "center",
	})
	vim.wo[list_win].cursorline = true
	vim.wo[list_win].number = false
	vim.wo[list_win].signcolumn = "no"
	vim.wo[list_win].wrap = false

	-- Right pane: preview
	local prev_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[prev_buf].buftype = "nofile"
	vim.bo[prev_buf].bufhidden = "wipe"
	vim.bo[prev_buf].filetype = "yaml"
	vim.bo[prev_buf].modifiable = false

	local prev_win = vim.api.nvim_open_win(prev_buf, false, {
		relative = "editor",
		row = row,
		col = col + left_w + 1,
		width = right_w,
		height = total_h,
		style = "minimal",
		border = "rounded",
		title = " preview ",
		title_pos = "center",
	})
	vim.wo[prev_win].number = false
	vim.wo[prev_win].signcolumn = "no"
	vim.wo[prev_win].wrap = false

	-- Active filter and the snapshot list it produces.
	-- filter == nil means "all".
	local snaps = all_snaps
	local filter = nil

	local function set_list_title()
		if not vim.api.nvim_win_is_valid(list_win) then
			return
		end
		local label
		if filter == nil then
			label = "all"
		elseif filter == "groups" then
			label = "groups"
		elseif filter == "headings" then
			label = "headings"
		elseif filter == "tags" then
			label = "tags"
		else
			label = filter
		end
		pcall(vim.api.nvim_win_set_config, list_win, {
			relative = "editor",
			row = row,
			col = col,
			width = left_w,
			height = total_h,
			title = string.format(" history: %s  [a/r/h/t] ", label),
			title_pos = "center",
		})
	end

	local function rebuild_list()
		snaps = {}
		for _, s in ipairs(all_snaps) do
			if filter == nil or s.base == filter then
				table.insert(snaps, s)
			end
		end
		local items = {}
		for _, s in ipairs(snaps) do
			table.insert(items, s.label)
		end
		if #items == 0 then
			items = { "-- no snapshots for this filter --" }
		end
		vim.bo[list_buf].modifiable = true
		vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, items)
		vim.bo[list_buf].modifiable = false
		if vim.api.nvim_win_is_valid(list_win) then
			pcall(vim.api.nvim_win_set_cursor, list_win, { 1, 0 })
		end
		set_list_title()
	end

	local function update_preview()
		if not vim.api.nvim_win_is_valid(list_win) or not vim.api.nvim_buf_is_valid(prev_buf) then
			return
		end
		local lnum = vim.api.nvim_win_get_cursor(list_win)[1]
		local snap = snaps[lnum]
		if not snap then
			vim.bo[prev_buf].modifiable = true
			vim.api.nvim_buf_set_lines(prev_buf, 0, -1, false, { "-- no snapshot --" })
			vim.bo[prev_buf].modifiable = false
			pcall(vim.api.nvim_win_set_config, prev_win, {
				relative = "editor",
				row = row,
				col = col + left_w + 1,
				width = right_w,
				height = total_h,
				title = " preview ",
				title_pos = "center",
			})
			return
		end
		local lines = read_file_lines(snap.path)
		vim.bo[prev_buf].modifiable = true
		vim.api.nvim_buf_set_lines(prev_buf, 0, -1, false, lines)
		vim.bo[prev_buf].modifiable = false
		if vim.api.nvim_win_is_valid(prev_win) then
			pcall(vim.api.nvim_win_set_cursor, prev_win, { 1, 0 })
			pcall(vim.api.nvim_win_set_config, prev_win, {
				relative = "editor",
				row = row,
				col = col + left_w + 1,
				width = right_w,
				height = total_h,
				title = string.format(" preview: %s.yaml @ %s ", snap.base, os.date("%Y-%m-%d %H:%M:%S", snap.ts)),
				title_pos = "center",
			})
		end
	end

	rebuild_list()
	update_preview()

	local function close_all()
		if vim.api.nvim_win_is_valid(prev_win) then
			pcall(vim.api.nvim_win_close, prev_win, true)
		end
		if vim.api.nvim_win_is_valid(list_win) then
			pcall(vim.api.nvim_win_close, list_win, true)
		end
	end

	vim.api.nvim_create_autocmd("CursorMoved", {
		buffer = list_buf,
		callback = update_preview,
	})

	-- Filter keys: g/h/t pick a base, a clears the filter.
	local function set_filter(f)
		filter = f
		rebuild_list()
		update_preview()
	end
	vim.keymap.set("n", "r", function()
		set_filter("groups")
	end, { buffer = list_buf, nowait = true, noremap = true })
	vim.keymap.set("n", "h", function()
		set_filter("headings")
	end, { buffer = list_buf, nowait = true, noremap = true })
	vim.keymap.set("n", "t", function()
		set_filter("tags")
	end, { buffer = list_buf, nowait = true, noremap = true })
	vim.keymap.set("n", "a", function()
		set_filter(nil)
	end, { buffer = list_buf, nowait = true, noremap = true })

	vim.keymap.set("n", "<CR>", function()
		local lnum = vim.api.nvim_win_get_cursor(list_win)[1]
		local snap = snaps[lnum]
		if not snap then
			return
		end
		close_all()
		local dest = source_for_base(snap.base)
		if not dest then
			vim.notify("browser.history: no source path for base " .. snap.base, vim.log.levels.ERROR)
			return
		end
		local ok, err = M.restore(snap.path, dest)
		if not ok then
			vim.notify("browser.history: " .. tostring(err), vim.log.levels.ERROR)
			return
		end
		vim.notify(
			string.format("browser.history: restored %s.yaml from %s", snap.base, os.date("%Y-%m-%d %H:%M:%S", snap.ts))
		)
		if on_done then
			on_done()
		end
	end, { buffer = list_buf, nowait = true, noremap = true })

	vim.keymap.set("n", "q", close_all, { buffer = list_buf, nowait = true, noremap = true })
	vim.keymap.set("n", "<Esc>", close_all, { buffer = list_buf, nowait = true, noremap = true })

	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(list_win),
		once = true,
		callback = function()
			if vim.api.nvim_win_is_valid(prev_win) then
				pcall(vim.api.nvim_win_close, prev_win, true)
			end
		end,
	})
end

return M
