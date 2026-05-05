-- browser/dashboard/htmlops.lua
-- HTML source panel: open, body/head toggle, motion-style search keys.
--
-- Motion keys (registered in keymaps/views.lua, gated to html view):
--   U   next UUID
--   P   next htmx partial attribute (hx-get/hx-post/hx-put/hx-delete/hx-patch)
--   T   next hx-trigger
--   Y   next hx-target
--   S   next hx-swap
--   B   next hx-boost
--
-- Each motion is cursor-relative: search forward from current cursor
-- position, wrap to top of buffer if no match below. The match position
-- lands the cursor INSIDE the quoted attribute value (uses \zs anchor)
-- so `yi"` yanks the value cleanly.
--
-- Notifications:
--   first hit shows total count and current index, e.g.
--     "hx-target: 3 matches (1/3)"
--   subsequent same-key presses cycle: (2/3), (3/3), (1/3) ...
--   no matches: "hx-target: no matches found"

local M = {}

local util = require("browser.dashboard.util")

-- ============================================================
-- Search patterns
--
-- All patterns use \v (very magic) and \zs to set the match start
-- position just past the opening quote. \zs is a vim regex feature:
-- the actual match boundary is at \zs, while the lookbehind portion
-- before it must still match. So [`hx-target="`]\zs lands the cursor
-- at the first char of the value, perfect for `yi"`.
--
-- The label is shown in notifications. Used as the cycle-state key
-- so two motions with the same label share state (only one motion
-- shares its label with itself, in practice).
-- ============================================================
local PATTERNS = {
	uuid = {
		label = "UUID",
		regex = [[\v[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}]],
	},
	partial = {
		label = "htmx partial",
		regex = [[\v(hx-get|hx-post|hx-put|hx-delete|hx-patch)\=["']\zs]],
	},
	trigger = {
		label = "hx-trigger",
		regex = [[\vhx-trigger\=["']\zs]],
	},
	target = {
		label = "hx-target",
		regex = [[\vhx-target\=["']\zs]],
	},
	swap = {
		label = "hx-swap",
		regex = [[\vhx-swap\=["']\zs]],
	},
	boost = {
		label = "hx-boost",
		regex = [[\vhx-boost\=["']\zs]],
	},
}

local function send_cmd(cmd)
	return require("browser.session").send_cmd(cmd)
end

-- ============================================================
-- count_matches
-- Returns the total number of matches of pattern in the buffer and
-- a list of {row,col} positions, sorted by buffer order. Used for
-- the (N/total) display - vim's searchcount() requires the pattern
-- to be in the / register first which causes side effects we don't
-- want. Implemented manually with a saved cursor + scan.
-- ============================================================
local function count_matches(buf, pattern)
	-- Save cursor, jump to the buffer, count by repeated search from
	-- buffer start. Restore cursor when done. The buffer is scanned
	-- via getline so we don't move the user's cursor here.
	local total = 0
	local positions = {}

	local line_count = vim.api.nvim_buf_line_count(buf)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, line_count, false)
	-- Use vim.regex to compile the pattern once and scan each line.
	-- vim.regex understands the same \v / \zs syntax as vim.fn.search.
	local ok, re = pcall(vim.regex, pattern)
	if not ok then
		return 0, {}
	end
	for i, line in ipairs(lines) do
		local start_col = 0
		while true do
			local s, e = re:match_str(line:sub(start_col + 1))
			if not s then
				break
			end
			-- s,e are 0-indexed byte offsets within line:sub(...).
			-- Translate back to absolute column in the original line.
			local abs_col = start_col + s
			total = total + 1
			table.insert(positions, { row = i, col = abs_col })
			-- Advance past this match. If the pattern matched zero
			-- width (\zs at the start), step forward by 1 to avoid
			-- infinite loop.
			if e <= s then
				start_col = start_col + s + 1
			else
				start_col = start_col + e
			end
			if start_col >= #line then
				break
			end
		end
	end
	return total, positions
end

-- ============================================================
-- find_index_after_cursor
-- Given positions (list of {row,col}) and a cursor {row,col}, returns
-- the 1-based index of the FIRST position at or after the cursor.
-- Wraps to 1 if cursor is past every match.
-- ============================================================
local function find_index_after_cursor(positions, cur_row, cur_col)
	for i, p in ipairs(positions) do
		if p.row > cur_row or (p.row == cur_row and p.col >= cur_col) then
			return i
		end
	end
	return 1
end

-- ============================================================
-- jump_pattern
-- The motion implementation. Called by the keymaps once per press.
--
-- buf, win  - target buffer/window (works for primary or split).
-- pat_key   - one of the PATTERNS keys.
--
-- Behavior:
--   1. Count all matches in the buffer.
--   2. If zero, notify and return.
--   3. Otherwise, find the first match at or after the cursor; if
--      none below, wrap to first. Move cursor there.
--   4. Notify with (current/total).
-- ============================================================
function M.jump_pattern(buf, win, pat_key)
	local pat = PATTERNS[pat_key]
	if not pat then
		return
	end
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	if not (win and vim.api.nvim_win_is_valid(win)) then
		return
	end

	local total, positions = count_matches(buf, pat.regex)
	if total == 0 then
		vim.notify(string.format("browser: %s: no matches found", pat.label), vim.log.levels.INFO)
		return
	end

	-- Cursor position. nvim_win_get_cursor returns {row(1-based), col(0-based)}.
	local cur = vim.api.nvim_win_get_cursor(win)
	local cur_row, cur_col = cur[1], cur[2]

	-- If the cursor is already exactly on a match, advance to the
	-- next one (so repeated key presses cycle). "Exactly on" means
	-- same row, same col.
	local idx = find_index_after_cursor(positions, cur_row, cur_col)
	if positions[idx] and positions[idx].row == cur_row and positions[idx].col == cur_col then
		idx = (idx % total) + 1
	end

	local target = positions[idx]
	pcall(vim.api.nvim_win_set_cursor, win, { target.row, target.col })
	vim.notify(string.format("browser: %s (%d/%d)", pat.label, idx, total))
end

-- ============================================================
-- Public motion functions
--
-- Each is a thin wrapper around jump_pattern. The keymap layer
-- decides which buf/win to pass (primary vs split) so this module
-- doesn't need view-mode awareness.
-- ============================================================
function M.next_uuid(buf, win)
	M.jump_pattern(buf, win, "uuid")
end
function M.next_partial(buf, win)
	M.jump_pattern(buf, win, "partial")
end
function M.next_trigger(buf, win)
	M.jump_pattern(buf, win, "trigger")
end
function M.next_target(buf, win)
	M.jump_pattern(buf, win, "target")
end
function M.next_swap(buf, win)
	M.jump_pattern(buf, win, "swap")
end
function M.next_boost(buf, win)
	M.jump_pattern(buf, win, "boost")
end

-- ============================================================
-- open_html
-- Fetches the body innerHTML for meta.tab_id, formats it, and
-- loads it into buf. Updates html panel state.
-- ============================================================
function M.open_html(meta, buf, state)
	local body = send_cmd("page-source-body " .. meta.tab_id)
	if not body or vim.startswith(body, "err:") then
		vim.notify("browser: " .. (body or "no response"), vim.log.levels.WARN)
		return
	end
	local html_lines = vim.split(util.format_html(body), "\n", { plain = true })
	state.html_body_lines = html_lines
	state.html_full_lines = nil
	state.html_show_full = false
	state.html_source_meta = meta
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, html_lines)
	vim.bo[buf].filetype = "html"
	vim.bo[buf].modifiable = false
	vim.bo[buf].modified = false
	state.view_mode = "html"
	vim.notify("browser: html body - b=head U=uuid P=partial T=trigger Y=target S=swap B=boost  H/r/<C-o>=back")
end

-- ============================================================
-- toggle_body_head
-- Toggles the primary pane between body innerHTML and the full
-- page source. Fetches full source on first toggle.
-- ============================================================
function M.toggle_body_head(buf, state)
	local lines
	if state.html_show_full then
		state.html_show_full = false
		lines = state.html_body_lines or { "-- no body --" }
		vim.notify("browser: html body view")
	else
		if not state.html_full_lines and state.html_source_meta then
			local full = send_cmd("page-source " .. state.html_source_meta.tab_id)
			if full and not vim.startswith(full, "err:") then
				state.html_full_lines = vim.split(util.format_html(full), "\n", { plain = true })
			end
		end
		state.html_show_full = true
		lines = state.html_full_lines or { "-- no full html --" }
		vim.notify("browser: html full page - b=back to body")
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].modified = false
end

return M
