-- opencode-manage.reviewview.diff — diff building + hunk navigation.
-- Pure functions (state passed in): build_diff renders a unified diff for
-- create/replace rows; jump_hunk moves between change hunks in the panes.

local M = {}

--- Highlight a 1-based inclusive line span with an extmark background.
--- @param buf number
--- @param ns number
--- @param hl string
--- @param from number
--- @param to number
function M.hl_span(buf, ns, hl, from, to)
	if not from or not to or to < from then
		return
	end
	for ln = from, to do
		vim.api.nvim_buf_add_highlight(buf, ns, hl, ln - 1, 0, -1)
	end
end

--- Build a unified diff (disk vs proposed) for create/replace rows.
--- Returns the diff lines, the diff line of the first change, and the
--- proposed-content line of the first added line (for AFTER-pane focus).
--- @param disk string[]
--- @param proposed string[]
--- @return string[], number|nil, number|nil
function M.build_diff(disk, proposed)
	local out = {}
	local first_change, first_added = nil, nil
	local i, j = 1, 1
	local n, m = #disk, #proposed
	while i <= n or j <= m do
		if i <= n and j <= m and disk[i] == proposed[j] then
			out[#out + 1] = " " .. disk[i]
			i, j = i + 1, j + 1
		else
			local di, dj = nil, nil
			for k = 1, 4 do
				if i + k <= n and j <= m and disk[i + k] == proposed[j] then
					di = i + k
					break
				end
				if j + k <= m and i <= n and disk[i] == proposed[j + k] then
					dj = j + k
					break
				end
			end
			if di then
				for x = i, di - 1 do
					out[#out + 1] = "-" .. (disk[x] or "")
					first_change = first_change or #out
				end
				i = di
			elseif dj then
				for x = j, dj - 1 do
					out[#out + 1] = "+" .. (proposed[x] or "")
					first_change = first_change or #out
					first_added = first_added or x
				end
				j = dj
			else
				if i <= n then
					out[#out + 1] = "-" .. (disk[i] or "")
					first_change = first_change or #out
					i = i + 1
				end
				if j <= m then
					out[#out + 1] = "+" .. (proposed[j] or "")
					first_change = first_change or #out
					first_added = first_added or j
					j = j + 1
				end
			end
		end
	end
	return out, first_change, first_added
end

--- Jump between diff hunks in the CURRENT pane; scrolls both panes so the
--- change is visible.
--- @param state table  viewer state (cur_buf/cur_win/after_win)
--- @param delta number  -1 or 1
function M.jump_hunk(state, delta)
	if not state.cur_buf or not vim.api.nvim_buf_is_valid(state.cur_buf) then
		return
	end
	local lines = vim.api.nvim_buf_get_lines(state.cur_buf, 0, -1, false)
	local hunks = {}
	for i, l in ipairs(lines) do
		local p = l:sub(1, 1)
		if p == "-" or p == "+" then
			if #hunks == 0 or i > hunks[#hunks] + 1 then
				hunks[#hunks + 1] = i
			end
		end
	end
	if #hunks == 0 then
		vim.notify("no changes in this proposal", vim.log.levels.INFO)
		return
	end
	local cur_line = vim.api.nvim_win_get_cursor(state.cur_win)[1]
	local pos = 1
	for i, h in ipairs(hunks) do
		if h <= cur_line then
			pos = i
		end
	end
	local target = hunks[math.max(1, math.min(#hunks, pos + delta))]
	for _, w in ipairs({ state.cur_win, state.after_win }) do
		if w and vim.api.nvim_win_is_valid(w) then
			vim.api.nvim_win_call(w, function()
				vim.api.nvim_win_set_cursor(0, { target, 0 })
				vim.cmd("normal! zt")
			end)
		end
	end
end

return M
