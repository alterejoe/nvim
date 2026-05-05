-- browser/dashboard/keymaps/split.lua
--
-- Split-pane keymaps and the helpers that other submodules use to interact
-- with the split. Registers S (open/close split) and s (focus toggle).
--
-- Exposes on ctx, for use by views.lua and groups.lua:
--   ctx.is_in_split()           -> bool
--   ctx.split_selected_meta()   -> meta for currently selected tab in split
--   ctx.split_set(lines, ft, ro)-> replace split buffer contents
--   ctx.split_restore_tabs()    -> reset split to tabs view
--   ctx.close_split()           -> tear down split window/buffer

local M = {}

local util = require("browser.dashboard.util")
local tabops = require("browser.dashboard.tabops")

function M.register(ctx)
	local buf = ctx.buf
	local win = ctx.win
	local state = ctx.state
	local map = ctx.map

	-- ----------------------------------------------------------------
	-- Helpers (also exposed on ctx for cross-module use)
	-- ----------------------------------------------------------------

	-- is_in_split: true iff the cursor is currently in the split pane.
	local function is_in_split()
		return state.split_win
			and vim.api.nvim_win_is_valid(state.split_win)
			and vim.api.nvim_get_current_win() == state.split_win
	end

	-- split_selected_meta: meta for the tab the split has highlighted.
	-- Tracked via CursorMoved on the split buffer when in tabs view.
	local function split_selected_meta()
		if not state.split_selected_tab_id then
			return nil
		end
		for _, m in pairs(state.split_meta) do
			if m.tab_id == state.split_selected_tab_id then
				return m
			end
		end
		return nil
	end

	-- split_set: replace contents of the split buffer with `lines`,
	-- set its filetype, optionally make it readonly. Used by every
	-- submodule that drives a different split view (html, console, etc).
	local function split_set(lines, ft, readonly)
		if not vim.api.nvim_buf_is_valid(state.split_buf or -1) then
			return
		end
		vim.bo[state.split_buf].modifiable = true
		vim.api.nvim_buf_set_lines(state.split_buf, 0, -1, false, lines)
		vim.bo[state.split_buf].filetype = ft or "scratchbuf"
		vim.bo[state.split_buf].modifiable = not readonly
		vim.bo[state.split_buf].modified = false
	end

	-- split_restore_tabs: re-fetch tabs and reset the split to tabs view.
	-- Submodules call this when leaving a non-tabs split view (e.g. r in
	-- console view returns to tabs).
	local function split_restore_tabs()
		local tabs = tabops.fetch_tabs(state.tab_htmx)
		local lines, meta = tabops.build_tab_lines(tabs, state.show_chi_path)
		state.split_meta = meta
		state.split_selected_tab_id = nil
		split_set(lines, "scratchbuf", false)
		state.split_view = "tabs"
	end

	-- close_split: tear down the split window and buffer, restore the
	-- primary window's original width, return focus to primary.
	local function close_split()
		if state.split_win and vim.api.nvim_win_is_valid(state.split_win) then
			vim.api.nvim_win_close(state.split_win, true)
		end
		if state.split_buf and vim.api.nvim_buf_is_valid(state.split_buf) then
			vim.api.nvim_buf_delete(state.split_buf, { force = true })
		end
		state.split_win = nil
		state.split_buf = nil
		state.split_meta = {}
		state.split_view = "tabs"
		state.split_html_body = nil
		state.split_html_full = nil
		state.split_html_show_full = false
		state.split_selected_tab_id = nil
		if state.primary_w and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_set_width(win, state.primary_w)
		end
		state.primary_w = nil
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_set_current_win(win)
		end
	end

	-- Expose helpers for other submodules. Set BEFORE registering keymaps
	-- so any module loaded afterward can read these (groups, views, core).
	ctx.is_in_split = is_in_split
	ctx.split_selected_meta = split_selected_meta
	ctx.split_set = split_set
	ctx.split_restore_tabs = split_restore_tabs
	ctx.close_split = close_split

	-- ----------------------------------------------------------------
	-- Keymaps
	-- ----------------------------------------------------------------

	-- s: switch focus between primary and split panes.
	map("s", function()
		if not (state.split_win and vim.api.nvim_win_is_valid(state.split_win)) then
			return
		end
		local cur = vim.api.nvim_get_current_win()
		if cur == state.split_win then
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_set_current_win(win)
			end
		else
			vim.api.nvim_set_current_win(state.split_win)
		end
	end, "Switch between primary and split pane")

	-- S: dual purpose, dispatched by view_mode.
	--   html view -> jump to next hx-swap attribute (cursor inside
	--                quoted value so yi" yanks it).
	--   tabs view (or anywhere else) -> open or close the split pane.
	-- Lives here (not in keymaps/views.lua) because vim.keymap.set
	-- overwrites previous registrations on the same buffer; one
	-- callback per key. Same pattern as T in keymaps/core.lua.
	--
	-- When opening the split, halves the primary window width, creates
	-- a new buffer, copies all registered keymaps from
	-- state.registered_keymaps so the same keys work in the split.
	map("S", function()
		if state.view_mode == "html" then
			require("browser.dashboard.htmlops").next_swap(buf, win)
			return
		end
		if is_in_split() and state.split_view == "html" then
			require("browser.dashboard.htmlops").next_swap(state.split_buf, state.split_win)
			return
		end
		if state.split_win and vim.api.nvim_win_is_valid(state.split_win) then
			close_split()
			return
		end
		if not vim.api.nvim_win_is_valid(win) then
			return
		end

		local pos = vim.api.nvim_win_get_position(win)
		local w = vim.api.nvim_win_get_width(win)
		local h = vim.api.nvim_win_get_height(win)
		local half = math.floor(w / 2) - 1
		if half < 10 then
			vim.notify("browser: not enough space to split", vim.log.levels.WARN)
			return
		end

		state.primary_w = w
		vim.api.nvim_win_set_width(win, half)

		state.split_buf = vim.api.nvim_create_buf(false, true)
		vim.b[state.split_buf]._scratchbuf = util.TITLE
		vim.bo[state.split_buf].bufhidden = "wipe"
		vim.bo[state.split_buf].swapfile = false

		local tabs = tabops.fetch_tabs(state.tab_htmx)
		local lines, smeta = tabops.build_tab_lines(tabs, state.show_chi_path)
		state.split_meta = smeta
		state.split_view = "tabs"
		vim.api.nvim_buf_set_lines(state.split_buf, 0, -1, false, lines)
		vim.bo[state.split_buf].filetype = "scratchbuf"
		vim.bo[state.split_buf].modified = false

		state.split_win = vim.api.nvim_open_win(state.split_buf, true, {
			relative = "editor",
			row = pos[1],
			col = pos[2] + half + 2,
			width = w - half - 2,
			height = h,
			style = "minimal",
			border = "rounded",
			title = util.TITLE .. " [S]",
			title_pos = "left",
		})
		vim.wo[state.split_win].cursorline = true
		vim.wo[state.split_win].number = true
		vim.wo[state.split_win].signcolumn = "no"
		vim.wo[state.split_win].wrap = false
		vim.wo[state.split_win].winhighlight = "Visual:ScratchbufVisual,CursorLine:ScratchbufCursorLine"
		util.browser_highlights(state.split_win)

		-- Copy all registered keymaps to the split buffer so the dashboard
		-- shortcuts work in either pane. By the time S fires, every
		-- submodule has registered, so state.registered_keymaps is complete.
		for _, km in ipairs(state.registered_keymaps) do
			pcall(vim.keymap.set, "n", km.lhs, km.fn, {
				buffer = state.split_buf,
				nowait = true,
				noremap = true,
				desc = km.desc,
			})
		end

		-- q/Esc/S/<C-w> in the split close ONLY the split, not the dashboard.
		-- These overrides win because they're set after the bulk copy above.
		for _, lhs in ipairs({ "q", "<Esc>", "S", "<C-w>" }) do
			vim.keymap.set("n", lhs, close_split, { buffer = state.split_buf, nowait = true, noremap = true })
		end

		-- Visual-mode highlight tweak: change cursorline color while in
		-- visual selection so the selection stands out against cursorline.
		vim.api.nvim_create_autocmd("ModeChanged", {
			buffer = state.split_buf,
			callback = function()
				if not vim.api.nvim_win_is_valid(state.split_win) then
					return
				end
				local mode = vim.api.nvim_get_mode().mode
				vim.wo[state.split_win].winhighlight = (mode == "v" or mode == "\22")
						and "Visual:ScratchbufVisual,CursorLine:ScratchbufCursorLineV"
					or "Visual:ScratchbufVisual,CursorLine:ScratchbufCursorLine"
			end,
		})

		-- Track which tab is selected in the split. Persists across view
		-- switches so e/H/c/n can act on "the tab I had highlighted in
		-- tabs view" even after switching to console/network.
		vim.api.nvim_create_autocmd("CursorMoved", {
			buffer = state.split_buf,
			callback = function()
				if state.split_view ~= "tabs" then
					return
				end
				if
					not (
						vim.api.nvim_win_is_valid(state.split_win)
						and vim.api.nvim_get_current_win() == state.split_win
					)
				then
					return
				end
				local lnum = vim.api.nvim_win_get_cursor(state.split_win)[1]
				local raw = vim.api.nvim_buf_get_lines(state.split_buf, lnum - 1, lnum, false)[1] or ""
				local m = state.split_meta[util.strip_prefix(raw)]
				if m then
					state.split_selected_tab_id = m.tab_id
				end
			end,
		})

		-- Close split when the dashboard itself closes.
		vim.api.nvim_create_autocmd("BufWipeout", {
			buffer = buf,
			once = true,
			callback = function()
				vim.schedule(function()
					if state.split_win and vim.api.nvim_win_is_valid(state.split_win) then
						vim.api.nvim_win_close(state.split_win, true)
					end
					if state.split_buf and vim.api.nvim_buf_is_valid(state.split_buf) then
						vim.api.nvim_buf_delete(state.split_buf, { force = true })
					end
					state.split_win = nil
					state.split_buf = nil
				end)
			end,
		})
	end, "Toggle split pane")
end

return M
