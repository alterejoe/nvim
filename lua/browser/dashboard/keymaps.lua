-- browser/dashboard/keymaps.lua
--
-- Orchestrator for the dashboard's keymap registration. The actual keymap
-- bodies live in four submodules under dashboard/keymaps/:
--
--   core.lua    - generic navigation and dispatch keys that don't belong
--                 to a single panel:
--                   <CR> q r <C-o> <leader>e \ / t T <C-w>* <leader>w :
--
--   split.lua   - split pane lifecycle and the split-aware focus toggle:
--                   S s
--                 plus the close_split / split_set / split_restore_tabs /
--                 split_selected_meta helpers used by the other submodules.
--
--   groups.lua  - group editor and history:
--                   gz +  <leader>u
--                 plus the open_group_editor helper (also used as the
--                 on_done callback for <leader>u's history picker).
--
--   views.lua   - panel-specific actions:
--                   e H b U A ? c C n N R
--
-- Registration model:
-- M.register(buf, win, layout, state, opts) builds a single `ctx` table
-- that bundles every shared closure and value the submodules need, then
-- calls each submodule's register(ctx) once. The submodules use ctx.map
-- to register keymaps so they all land on the dashboard buffer and are
-- recorded in state.registered_keymaps for later copy to the split buf.
--
-- Important: the order in which the submodules register doesn't matter,
-- because all registration completes before any keymap can fire. The S
-- mapping (which copies state.registered_keymaps to a new split buffer)
-- runs after all registration is done.

local M = {}

local util = require("browser.dashboard.util")

-- ============================================================
-- register
-- Entry point called from on_ready in dashboard.lua.
--
-- buf:    dashboard primary buffer
-- win:    dashboard primary window
-- layout: scratchbuf layout handle (for setting pane content)
-- state:  per-open shared state table (see dashboard.lua for shape)
-- opts:   { restore_tabs_fn, do_buf_refresh_fn }
-- ============================================================
function M.register(buf, win, layout, state, opts)
	local restore_tabs = opts.restore_tabs_fn
	local do_buf_refresh = opts.do_buf_refresh_fn

	-- map: registers on primary buf and records for split copy.
	-- Used by every submodule. state.registered_keymaps is what the
	-- S split-pane mapping copies into the split buffer so the same
	-- keys work there.
	local function map(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, noremap = true, desc = desc })
		table.insert(state.registered_keymaps, { lhs = lhs, fn = fn, desc = desc })
	end

	-- current_meta: meta for the tab line under the cursor in the
	-- primary buffer. Used by t/T/+/e/H to identify which tab the
	-- user is acting on.
	local function current_meta()
		return state.tab_metadata[util.strip_prefix(vim.api.nvim_get_current_line())]
	end

	-- ctx is the single object passed to every submodule. It carries
	-- all shared closures (so each submodule has the same view of
	-- "current state") and the bookkeeping helpers.
	--
	-- Some fields are populated below by the split submodule's register
	-- call (close_split, is_in_split, split_set, etc) before the other
	-- submodules need them.
	local ctx = {
		buf = buf,
		win = win,
		layout = layout,
		state = state,
		map = map,
		restore_tabs = restore_tabs,
		do_buf_refresh = do_buf_refresh,
		current_meta = current_meta,
		-- filled in by split submodule:
		is_in_split = nil,
		split_selected_meta = nil,
		split_set = nil,
		split_restore_tabs = nil,
		close_split = nil,
		-- filled in by groups submodule:
		open_group_editor = nil,
	}

	-- Order matters only insofar as split must register first so its
	-- helpers are available on ctx for the others. groups must register
	-- before views because nothing in views uses groups, but core needs
	-- close_split (from split) for <C-w>* handling.
	require("browser.dashboard.keymaps.split").register(ctx)
	require("browser.dashboard.keymaps.groups").register(ctx)
	require("browser.dashboard.keymaps.views").register(ctx)
	require("browser.dashboard.keymaps.core").register(ctx)
end

return M
