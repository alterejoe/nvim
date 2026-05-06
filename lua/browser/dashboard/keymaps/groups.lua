-- browser/dashboard/keymaps/groups.lua
--
-- Group editor and history keymaps:
--   gz         - toggle into / out of the group editor (sets view_mode = "groups")
--   +          - add the current tab to a group (path picker)
--   <leader>u  - groups view: open the snapshot history picker.
--                anywhere else: fall through to UndotreeToggle.
--
-- Exposes on ctx for use elsewhere:
--   ctx.open_group_editor()
-- which is also passed as the on_done callback to the history picker so
-- that a successful restore re-renders the gz buffer in place.

local M = {}

local util = require("browser.dashboard.util")
local tabops = require("browser.dashboard.tabops")

function M.register(ctx)
	local buf = ctx.buf
	local state = ctx.state
	local map = ctx.map
	local restore_tabs = ctx.restore_tabs
	local do_buf_refresh = ctx.do_buf_refresh
	local current_meta = ctx.current_meta

	-- ----------------------------------------------------------------
	-- open_group_editor
	-- Renders groups.yaml + headings.yaml + tags.yaml + server_tags.yaml
	-- into the dashboard primary buffer as an editable text view. Sets
	-- view_mode = "groups" so on_save dispatches to the group save handler.
	--
	-- Section markers in the editor:
	--   #    group       chi_path templates
	--   ##   heading     glob patterns
	--   ###  tag         chi_path templates
	--   #### server_tag  glob patterns; binds tab to server name
	--
	-- Order on disk drives buffer order. New names not yet in their file
	-- get appended alphabetically (yaml_order.resolve_order). Reordering
	-- in the buffer + W persists the new order.
	-- ----------------------------------------------------------------
	local function open_group_editor()
		if state.view_mode == "groups" then
			restore_tabs(buf)
			return
		end
		if state.view_mode ~= "tabs" then
			return
		end
		local groups = require("browser.groups").load_groups()
		local headings = tabops.load_headings()
		local tags = tabops.load_tags()
		local server_tags = tabops.load_server_tags()
		local new_lines = {}

		local yaml_order = require("browser.yaml_order")
		local sess = require("browser.session")

		-- # groups (chi_path templates) - order from groups.yaml file
		local group_names = yaml_order.resolve_order(
			nil,
			groups,
			yaml_order.read_top_level_order(sess.DEVPROXY_DIR .. "/groups.yaml", "groups")
		)
		for _, name in ipairs(group_names) do
			table.insert(new_lines, "# " .. name)
			for _, p in ipairs(type(groups[name]) == "table" and groups[name] or {}) do
				table.insert(new_lines, p)
			end
			table.insert(new_lines, "")
		end

		-- ## headings (glob patterns) - already file-ordered via headings.order
		for _, hname in ipairs(headings.order) do
			table.insert(new_lines, "## " .. hname)
			for _, p in ipairs(headings.patterns[hname] or {}) do
				table.insert(new_lines, p)
			end
			table.insert(new_lines, "")
		end

		-- ### tags (chi_path templates) - order from tags.yaml file
		local tag_names = yaml_order.resolve_order(
			nil,
			tags,
			yaml_order.read_top_level_order(sess.DEVPROXY_DIR .. "/tags.yaml", "tags")
		)
		for _, name in ipairs(tag_names) do
			table.insert(new_lines, "### " .. name)
			for _, p in ipairs(type(tags[name]) == "table" and tags[name] or {}) do
				table.insert(new_lines, p)
			end
			table.insert(new_lines, "")
		end

		-- #### server tags (glob patterns) - order from server_tags.yaml file
		local server_tag_names = yaml_order.resolve_order(
			nil,
			server_tags,
			yaml_order.read_top_level_order(sess.DEVPROXY_DIR .. "/server_tags.yaml", "server_tags")
		)
		for _, name in ipairs(server_tag_names) do
			table.insert(new_lines, "#### " .. name)
			for _, p in ipairs(type(server_tags[name]) == "table" and server_tags[name] or {}) do
				table.insert(new_lines, p)
			end
			table.insert(new_lines, "")
		end

		if #group_names == 0 and #headings.order == 0 and #tag_names == 0 and #server_tag_names == 0 then
			table.insert(new_lines, "# new-group")
			table.insert(new_lines, "")
		end
		while #new_lines > 0 and new_lines[#new_lines] == "" do
			table.remove(new_lines)
		end
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
		vim.bo[buf].filetype = "scratchbuf"
		vim.bo[buf].modified = false
		state.view_mode = "groups"
		vim.notify("browser: group editor - W=save  :=add path  CR=open  gz/r=back  #=group  ###=tag  ####=server")
	end

	-- Expose for cross-submodule use (history picker on_done callback).
	ctx.open_group_editor = open_group_editor

	-- ----------------------------------------------------------------
	-- Keymaps
	-- ----------------------------------------------------------------

	vim.keymap.set("n", "gz", open_group_editor, { buffer = buf, nowait = true, noremap = true, desc = "Group editor" })
	table.insert(state.registered_keymaps, { lhs = "gz", fn = open_group_editor, desc = "Group editor" })

	local function leader_u()
		if state.view_mode ~= "groups" then
			vim.cmd.UndotreeToggle()
			return
		end
		require("browser.groups_history").pick(function()
			open_group_editor()
		end)
	end
	vim.keymap.set("n", "<leader>u", leader_u, {
		buffer = buf,
		nowait = true,
		noremap = true,
		desc = "Groups history (or undotree)",
	})
	table.insert(state.registered_keymaps, { lhs = "<leader>u", fn = leader_u, desc = "Groups history (or undotree)" })

	map("+", function()
		if state.view_mode ~= "tabs" then
			return
		end
		local meta = current_meta()
		if not meta then
			vim.notify("browser: no tab selected", vim.log.levels.WARN)
			return
		end
		local chi_path = meta.chi_path or meta.path
		local groups_mod = require("browser.groups")
		local groups = groups_mod.load_groups()
		local names = {}
		for name in pairs(groups) do
			table.insert(names, name)
		end
		table.sort(names)
		if #names == 0 then
			vim.notify("browser: no groups defined - use gz to create one", vim.log.levels.WARN)
			return
		end
		util.path_picker(names, function(name, _)
			local gs = groups_mod.load_groups()
			gs[name] = gs[name] or {}
			for _, p in ipairs(gs[name]) do
				if p == chi_path then
					vim.notify("browser: " .. chi_path .. " already in '" .. name .. "'")
					return
				end
			end
			table.insert(gs[name], chi_path)
			groups_mod.save_groups(gs)
			vim.notify("browser: added " .. chi_path .. " to '" .. name .. "'")
			do_buf_refresh(buf)
		end)
	end, "Add tab to group")
end

return M
