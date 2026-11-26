-- /home/jmeyer/.config/nvim/lua/opencode-manage/previewview.lua FINAL-14
-- Group view: one proposal group as a reading view in its own tab.
-- Selection at the TOP; the selected file below, full width.
-- One row = one screen line (no wrap). The selection shows min(MAX_ROWS,
-- #rows) text rows; the split height reserves the window statusline
-- (laststatus=2). The statusline is a clean bar:
--   viewing (first-last) of total            +N more
-- left in teal, right in yellow, on a dark underlined bar. It updates on j/k.
-- The viewport top is tracked explicitly (state.top) and applied with
-- winrestview, so the range and the scrollbar thumb never read the wrong
-- window's w0/w$.
-- A 1-column scrollbar floats on the right edge at all times: full (all █)
-- when every row fits, thumb + track when rows are hidden. The list window
-- forces scrolloff=0 so a short list actually scrolls and the thumb moves.
-- The newest row per group+path is listed; superseded revisions are hidden.
-- An update shows the green/red diff; a new file shows its content.
-- ga applies all; da accepts one code file (never a note); v/q/Q closes the
-- tab and reopens the group selector.

local proposals = require("opencode-manage.proposals")
local diff = require("opencode-manage.reviewview.diff")
local console = require("opencode-manage.console")
local reviewview = require("opencode-manage.reviewview")

local M = {}
local active = nil
local ns = vim.api.nvim_create_namespace("manage-view")

vim.api.nvim_set_hl(0, "ManageScrollThumb", { fg = "#4ec9b0", bold = true })
vim.api.nvim_set_hl(0, "ManageScrollTrack", { fg = "#3a3a3a" })
local status_bg = "#252526"
vim.api.nvim_set_hl(0, "ManageViewStatus", { bg = status_bg, fg = "#808080", underline = true })
vim.api.nvim_set_hl(0, "ManageViewRange", { bg = status_bg, fg = "#4ec9b0", bold = true, underline = true })
vim.api.nvim_set_hl(0, "ManageViewMore", { bg = status_bg, fg = "#dcdcaa", bold = true, underline = true })

-- Test cap: 3 so the scrollbar is easy to see working. Set back to 10 later.
local MAX_ROWS = 3

local function is_note(p)
	local path = p.path or ""
	return path:find("/docs/slipbox/", 1, true) ~= nil
		or path:find("/docs/references/", 1, true) ~= nil
		or path:find("/docs/fleeting/", 1, true) ~= nil
end

local function short_path(p)
	local path = p._rel or p.path or "?"
	local tail = path:match("([^/]+/[^/]+)$")
	return tail or path
end

local function group_rows(group, selected)
	local newest = {}
	for _, p in ipairs(proposals.list_visible("all")) do
		if (p.group or "misc") == group and (p.status or "pending") ~= "superseded" then
			local key = (p.group or "misc") .. "\0" .. (p.path or "")
			local cur = newest[key]
			if not cur or (p.ts or 0) > (cur.ts or 0) then
				newest[key] = p
			end
		end
	end
	local rows = {}
	for _, p in pairs(newest) do
		rows[#rows + 1] = p
	end
	table.sort(rows, function(a, b)
		local an = is_note(a) and 0 or 1
		local bn = is_note(b) and 0 or 1
		if an ~= bn then
			return an < bn
		end
		return (a.path or "") < (b.path or "")
	end)
	return rows
end

local function after_content(p)
	local path = p.path or ""
	local disk = {}
	if path ~= "" and vim.fn.filereadable(path) == 1 then
		disk = vim.fn.readfile(path)
	end
	if p.operation == "delete" then
		return table.concat(disk, "\n")
	end
	if p.operation == "edit_range" and p.start_line then
		local block = vim.split(p.content or "", "\n", { plain = true })
		if block[#block] == "" then
			table.remove(block)
		end
		local s = math.max(1, math.floor(tonumber(p.start_line) or 1))
		local e = math.max(s, math.floor(tonumber(p.end_line) or s))
		local lines = {}
		for i = 1, math.min(s - 1, #disk) do
			lines[#lines + 1] = disk[i]
		end
		for _, l in ipairs(block) do
			lines[#lines + 1] = l
		end
		for i = e + 1, #disk do
			lines[#lines + 1] = disk[i]
		end
		return table.concat(lines, "\n")
	end
	return p.content or ""
end

local function content_lines(p)
	local lines = vim.split(after_content(p), "\n", { plain = true })
	if lines[#lines] == "" then
		table.remove(lines)
	end
	if #lines == 0 then
		lines = { "" }
	end
	return lines
end

function M.open(group, close_console, return_to, selected)
	if close_console then
		close_console()
	end
	console.define_hls()
	local rows = group_rows(group, selected)
	if #rows == 0 then
		vim.notify("No rows in group " .. group, vim.log.levels.INFO)
		if return_to then
			pcall(return_to)
		end
		return
	end

	vim.cmd("tabnew")
	local main_win = vim.api.nvim_get_current_win()
	local view_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[view_buf].bufhidden = "wipe"
	vim.bo[view_buf].modifiable = false
	vim.bo[view_buf].filetype = "markdown"
	vim.api.nvim_win_set_buf(main_win, view_buf)

	local want = math.min(MAX_ROWS, #rows)
	local extra = (vim.o.laststatus == 2) and 1 or 0
	local list_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[list_buf].bufhidden = "wipe"
	vim.bo[list_buf].filetype = "managelist"
	local list_win = vim.api.nvim_open_win(list_buf, false, {
		split = "above",
		win = main_win,
		height = want + extra,
	})
	vim.api.nvim_win_set_height(list_win, want + extra)
	vim.wo[list_win].wrap = false
	vim.wo[list_win].linebreak = false
	-- The global scrolloff (8) is bigger than a short list; without this the
	-- window never scrolls and the thumb stays put.
	vim.wo[list_win].scrolloff = 0
	vim.wo[list_win].sidescrolloff = 0
	vim.wo[list_win].winhighlight = "StatusLine:ManageViewStatus"

	local bar, bar_buf = nil, nil
	if #rows > 1 then
		bar_buf = vim.api.nvim_create_buf(false, true)
		vim.bo[bar_buf].bufhidden = "wipe"
		bar = vim.api.nvim_open_win(bar_buf, false, {
			relative = "win",
			win = list_win,
			row = 0,
			col = vim.api.nvim_win_get_width(list_win) - 1,
			width = 1,
			height = want,
			style = "minimal",
			focusable = false,
			noautocmd = true,
		})
	end

	local state = { idx = 1, top = 1, rows = rows }
	active = { main_win = main_win, list_win = list_win }

	local function render_bar(first, visible)
		if not bar then
			return
		end
		local n = #state.rows
		local h = want
		first = first or 1
		visible = visible or math.min(h, n)
		local thumb = math.max(1, math.floor(h * visible / n + 0.5))
		local start = math.floor((first - 1) * h / n) + 1
		if start + thumb - 1 > h then
			start = h - thumb + 1
		end
		if start < 1 then
			start = 1
		end
		local lines = {}
		for i = 1, h do
			lines[i] = (i >= start and i < start + thumb) and "█" or "│"
		end
		vim.bo[bar_buf].modifiable = true
		vim.api.nvim_buf_set_lines(bar_buf, 0, -1, false, lines)
		vim.bo[bar_buf].modifiable = false
		vim.api.nvim_buf_clear_namespace(bar_buf, ns, 0, -1)
		for i = 1, h do
			local hl = (i >= start and i < start + thumb) and "ManageScrollThumb" or "ManageScrollTrack"
			vim.api.nvim_buf_add_highlight(bar_buf, ns, hl, i - 1, 0, -1)
		end
	end

	local function render_main()
		local p = state.rows[state.idx]
		if not p then
			return
		end
		local after = content_lines(p)
		local path = p.path or ""
		local disk = {}
		if path ~= "" and vim.fn.filereadable(path) == 1 then
			disk = vim.fn.readfile(path)
		end
		local lines, hl = {}, {}
		local added, removed = 0, 0
		if p.operation == "delete" then
			lines = disk
			for i = 1, #lines do
				hl[i] = "ManageRemove"
			end
			removed = #lines
		elseif #disk == 0 then
			lines = after
		else
			local dl = diff.build_diff(disk, after)
			for _, l in ipairs(dl) do
				local mark = l:sub(1, 1)
				local text = l:sub(2)
				lines[#lines + 1] = text
				if mark == "+" then
					hl[#lines] = "ManageAdd"
					added = added + 1
				elseif mark == "-" then
					hl[#lines] = "ManageRemove"
					removed = removed + 1
				end
			end
		end
		if #lines == 0 then
			lines = { "" }
		end
		vim.bo[view_buf].modifiable = true
		vim.api.nvim_buf_set_lines(view_buf, 0, -1, false, lines)
		vim.bo[view_buf].modifiable = false
		vim.bo[view_buf].filetype = vim.filetype.match({ filename = p.path }) or ""
		vim.api.nvim_buf_clear_namespace(view_buf, ns, 0, -1)
		for line, group_hl in pairs(hl) do
			vim.api.nvim_buf_add_highlight(view_buf, ns, group_hl, line - 1, 0, -1)
		end
		vim.wo[main_win].winbar = string.format(
			"VIEW %s · %s  (+%d −%d)",
			p.operation or "?",
			p._rel or p.path or "?",
			added,
			removed
		)
	end

	local function render_list()
		local lines, row_hl, tag_hl, tag_col, tag_end = {}, {}, {}, {}, {}
		for i, p in ipairs(state.rows) do
			local marker = (i == state.idx) and "▶ " or "  "
			local tag = is_note(p) and "[note] " or "[emit] "
			lines[#lines + 1] = string.format(
				"%s%s%-9s %-10s %s",
				marker,
				tag,
				p.operation or "?",
				p.status or "pending",
				short_path(p)
			)
			row_hl[#lines] = reviewview.hl_for(reviewview.row_state(p))
			tag_hl[#lines] = is_note(p) and "ManageNoteTag" or "ManageEmitTag"
			tag_col[#lines] = 2
			tag_end[#lines] = 2 + #tag
		end
		vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
		vim.api.nvim_buf_clear_namespace(list_buf, ns, 0, -1)
		for i, hl in pairs(row_hl) do
			vim.api.nvim_buf_add_highlight(list_buf, ns, hl, i - 1, 0, -1)
		end
		for i, hl in pairs(tag_hl) do
			vim.api.nvim_buf_add_highlight(list_buf, ns, hl, i - 1, tag_col[i], tag_end[i])
		end
		vim.api.nvim_win_set_cursor(list_win, { state.idx, 0 })
		local first = state.top
		local last = math.min(#state.rows, first + want - 1)
		local visible = last - first + 1
		local more = #state.rows - visible
		local range = string.format(" viewing (%d-%d) of %d ", first, last, #state.rows)
		local extra_txt = (more > 0) and string.format(" +%d more ", more) or ""
		vim.wo[list_win].statusline = "%#ManageViewRange#"
			.. range
			.. "%="
			.. ((extra_txt ~= "") and ("%#ManageViewMore#" .. extra_txt) or "")
		vim.api.nvim_win_call(list_win, function()
			vim.fn.winrestview({ topline = first })
		end)
		render_bar(first, visible)
	end

	local function close()
		active = nil
		if bar and vim.api.nvim_win_is_valid(bar) then
			pcall(vim.api.nvim_win_close, bar, true)
		end
		bar = nil
		vim.cmd("tabclose")
		if return_to then
			pcall(return_to)
		end
	end

	local function move(delta)
		local n = #state.rows
		if n == 0 then
			return
		end
		state.idx = ((state.idx - 1 + delta) % n) + 1
		if state.idx < state.top then
			state.top = state.idx
		elseif state.idx > state.top + want - 1 then
			state.top = state.idx - want + 1
		end
		local max_top = math.max(1, n - want + 1)
		state.top = math.max(1, math.min(state.top, max_top))
		render_list()
		render_main()
	end

	local function yank()
		local p = state.rows[state.idx]
		if not p then
			return
		end
		local text = table.concat(content_lines(p), "\n")
		vim.fn.setreg("+", text)
		vim.fn.setreg('"', text)
		vim.notify("copied " .. (p._rel or p.path or "file"), vim.log.levels.INFO)
	end

	local function apply_all()
		for _, it in ipairs(state.rows) do
			if it.operation == "mark-proposals" and (it.status or "pending") ~= "rejected" then
				local ok, spec = pcall(vim.json.decode, it.content or "")
				if ok and type(spec) == "table" and spec.mark == "do-not-apply" then
					vim.notify("⛔ Group " .. group .. " is marked do-not-apply — " .. tostring(it.reason), vim.log.levels.ERROR)
					return false
				end
			end
		end
		local batch = {}
		for _, it in ipairs(state.rows) do
			if (it.status or "pending") == "pending" then
				if
					it.operation == "mark-proposals"
					or it.operation == "reject-proposals"
					or it.operation == "folder-approve"
					or it.operation == "goal-suggest"
					or it.operation == "placement-preview"
				then
					proposals.accept(it, it.content, it.content)
				else
					batch[#batch + 1] = {
						proposal = it,
						path = it.path or "",
						content = (it.operation == "delete") and nil or after_content(it),
					}
				end
			end
		end
		if #batch > 0 then
			local journal = require("opencode-manage.journal")
			local ok, n = proposals.apply_group_atomic(group, batch, journal.project_root())
			if not ok then
				return false
			end
			vim.notify(string.format("✅ Group %s: %d applied atomically", group, n), vim.log.levels.INFO)
		end
		return true
	end

	local function accept_one()
		local p = state.rows[state.idx]
		if not p then
			return
		end
		if is_note(p) then
			vim.notify("⛔ Note proposals are all-or-nothing — use ga", vim.log.levels.WARN)
			return
		end
		if (p.status or "pending") ~= "pending" then
			vim.notify("already " .. tostring(p.status), vim.log.levels.INFO)
			return
		end
		if p.operation == "delete" then
			local choice = vim.fn.confirm(
				"Move to _old?\n  " .. (p.path or "") .. "\n\nFile goes to _old/ — reversible from the journal.",
				"&Yes\n&No",
				1
			)
			if choice == 1 then
				proposals.move_to_old(p)
			else
				proposals.reject(p)
			end
			state.rows = group_rows(group, nil)
			if #state.rows == 0 then
				close()
				return
			end
			state.idx = math.min(state.idx, #state.rows)
			render_list()
			render_main()
			return
		end
		local content = table.concat(content_lines(p), "\n")
		local baseline = nil
		if p.operation == "edit_range" then
			baseline = content
		end
		proposals.accept(p, content, baseline)
		vim.notify("accepted " .. (p._rel or p.path or "file"), vim.log.levels.INFO)
		state.rows = group_rows(group, nil)
		if #state.rows == 0 then
			close()
			return
		end
		state.idx = math.min(state.idx, #state.rows)
		render_list()
		render_main()
	end

	local opts = { buffer = list_buf, nowait = true, noremap = true, silent = true }
	vim.keymap.set("n", "j", function()
		move(1)
	end, opts)
	vim.keymap.set("n", "k", function()
		move(-1)
	end, opts)
	vim.keymap.set("n", "<C-j>", function()
		move(1)
	end, opts)
	vim.keymap.set("n", "<C-k>", function()
		move(-1)
	end, opts)
	vim.keymap.set("n", "y", yank, opts)
	vim.keymap.set("n", "ga", function()
		if apply_all() then
			close()
		end
	end, opts)
	vim.keymap.set("n", "da", accept_one, opts)
	vim.keymap.set("n", "q", close, opts)
	vim.keymap.set("n", "Q", close, opts)
	vim.keymap.set("n", "v", close, opts)

	local view_opts = { buffer = view_buf, nowait = true, noremap = true, silent = true }
	vim.keymap.set("n", "<C-j>", function()
		move(1)
	end, view_opts)
	vim.keymap.set("n", "<C-k>", function()
		move(-1)
	end, view_opts)
	vim.keymap.set("n", "y", yank, view_opts)
	vim.keymap.set("n", "ga", function()
		if apply_all() then
			close()
		end
	end, view_opts)
	vim.keymap.set("n", "da", accept_one, view_opts)
	vim.keymap.set("n", "q", close, view_opts)
	vim.keymap.set("n", "Q", close, view_opts)
	vim.keymap.set("n", "v", close, view_opts)

	render_list()
	render_main()
	vim.api.nvim_set_current_win(list_win)
end

function M.split_target_for(win)
	if active and (win == active.main_win or win == active.list_win) then
		return active.main_win
	end
	return nil
end

return M
