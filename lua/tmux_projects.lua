--[[
Keymaps:
<C-f>    Sessionizer telescope project picker
<leader>ts  Edit tmux sessions (scratchbuf)
<leader>tr  Rename current session
<leader>t|  Vertical split in cwd
<leader>t-  Horizontal split in cwd
<leader>ta  Join pane from another session (split + pull)
<leader>tb  Break non-active pane back to its session
<leader>tT  Kill all tmux sessions
Slot switching (line order in scratchbuf = slot order):
<leader>tj  slot 1    <leader>tJ  slot 5
<leader>tk  slot 2    <leader>tK  slot 6
<leader>tl  slot 3    <leader>tL  slot 7
<leader>t;  slot 4    <leader>t:  slot 8
Scratchbuf keymaps (inside <leader>ts):
<CR>  switch to session
o     new session below
O     new session above
dd    cut session
gp    paste below  (reorder)
gP    paste above  (reorder)
W     save persists slot order
/     fuzzy filter
r     refresh
Q     close
+     add session to existing group
+g    add session to new group
-     remove session from group
-g    remove entire group
e     edit session path (updates group refs, reopens session)
Project keymaps (set in after/):
<leader>tp  Pick project (scratchbuf) - <CR> to load, S to switch (kills old)
<leader>tP  Recover active project (recreate missing sessions)
--]]
local scratchbuf = require("scratchbuf")
local M = {}

-- -----------------------------------------------------------------------
-- Persistence
-- -----------------------------------------------------------------------

local order_file = vim.fn.stdpath("data") .. "/tmux_session_slots"
local active_project_file = vim.fn.stdpath("data") .. "/tmux_active_project"
local overrides_file = vim.fn.stdpath("data") .. "/tmux_project_overrides.json"

local function load_order()
	local f = io.open(order_file, "r")
	if not f then
		return {}
	end
	local slots = {}
	for line in f:lines() do
		local t = vim.trim(line)
		if t ~= "" then
			table.insert(slots, t)
		end
	end
	f:close()
	return slots
end

local function save_order(slots)
	local f = io.open(order_file, "w")
	if not f then
		vim.notify("tmux: could not write " .. order_file, vim.log.levels.ERROR)
		return
	end
	for _, s in ipairs(slots) do
		f:write(s .. "\n")
	end
	f:close()
end

local function load_overrides()
	local f = io.open(overrides_file, "r")
	if not f then
		return {}
	end
	local raw = f:read("*a")
	f:close()
	if not raw or raw == "" then
		return {}
	end
	local ok, data = pcall(vim.fn.json_decode, raw)
	if not ok or type(data) ~= "table" then
		return {}
	end
	return data
end

local function save_overrides()
	local data = {}
	for group, entries in pairs(M.projects) do
		data[group] = entries
	end
	local f = io.open(overrides_file, "w")
	if not f then
		vim.notify("tmux: could not write overrides", vim.log.levels.ERROR)
		return
	end
	f:write(vim.fn.json_encode(data))
	f:close()
end

local function merge_overrides()
	local overrides = load_overrides()
	for group, entries in pairs(overrides) do
		M.projects[group] = entries
	end
	local in_order = {}
	for _, g in ipairs(M.project_order) do
		in_order[g] = true
	end
	for group in pairs(overrides) do
		if not in_order[group] then
			table.insert(M.project_order, group)
		end
	end
end

-- -----------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------

local function in_tmux()
	return vim.env.TMUX ~= nil
end

local function tmux(cmd)
	vim.fn.system("tmux " .. cmd)
end

local function ordered_sessions()
	local live = vim.fn.systemlist("tmux list-sessions -F '#S' 2>/dev/null")
	if vim.v.shell_error ~= 0 then
		return {}
	end
	local live_set = {}
	for _, s in ipairs(live) do
		live_set[s] = true
	end
	local result = {}
	local seen = {}
	for _, s in ipairs(load_order()) do
		if live_set[s] then
			table.insert(result, s)
			seen[s] = true
		end
	end
	local unseen = {}
	for _, s in ipairs(live) do
		if not seen[s] and not s:find("^air%-") and not s:find("^browser%-") and not s:find("^devproxy%-") then
			table.insert(unseen, s)
		end
	end
	table.sort(unseen)
	for _, s in ipairs(unseen) do
		table.insert(result, s)
	end
	return result
end

local function sessionize(path)
	local name = vim.fn.fnamemodify(path, ":t"):gsub("%.", "_")
	local exists = vim.fn.system("tmux has-session -t=" .. vim.fn.shellescape(name) .. " 2>/dev/null; echo $?")
	exists = vim.trim(exists)
	if exists == "0" then
		tmux("switch-client -t " .. vim.fn.shellescape(name))
	else
		tmux("new-session -ds " .. vim.fn.shellescape(name) .. " -c " .. vim.fn.shellescape(path))
		tmux("switch-client -t " .. vim.fn.shellescape(name))
	end
end

local function get_session_path(session_name)
	local lines = vim.fn.systemlist("tmux list-panes -a -F '#{session_name}|#{pane_current_path}' 2>/dev/null")
	for _, line in ipairs(lines) do
		local name, path = line:match("^([^|]+)|(.+)$")
		if name == session_name then
			local home = vim.fn.expand("~")
			if path:sub(1, #home) == home then
				path = "~" .. path:sub(#home + 1)
			end
			return path
		end
	end
	return ""
end

local function switch_to_first_available(exclude)
	local remaining = vim.fn.systemlist("tmux list-sessions -F '#S' 2>/dev/null")
	for _, s in ipairs(remaining) do
		if s ~= exclude then
			tmux("switch-client -t " .. vim.fn.shellescape(s))
			return
		end
	end
end

-- -----------------------------------------------------------------------
-- Slot switching
-- -----------------------------------------------------------------------

local function switch_slot(index)
	if not in_tmux() then
		vim.notify("Not in tmux", vim.log.levels.WARN)
		return
	end
	local sessions = ordered_sessions()
	local target = sessions[index]
	if not target then
		vim.notify("tmux: no session in slot " .. index, vim.log.levels.WARN)
		return
	end
	tmux("switch-client -t " .. vim.fn.shellescape(target))
end

-- Slots 1-4: <leader>t j/k/l/;
for i, key in ipairs({ "j", "k", "l", ";" }) do
	vim.keymap.set("n", "<leader>t" .. key, function()
		switch_slot(i)
	end, { desc = "Tmux slot " .. i, noremap = true })
end

-- Slots 5-8: <leader>t J/K/L/:
for i, key in ipairs({ "J", "K", "L", ":" }) do
	vim.keymap.set("n", "<leader>t" .. key, function()
		switch_slot(i + 4)
	end, { desc = "Tmux slot " .. (i + 4), noremap = true })
end

-- -----------------------------------------------------------------------
-- Sessionizer
-- -----------------------------------------------------------------------

vim.keymap.set("n", "<C-f>", function()
	if not in_tmux() then
		vim.notify("Not in tmux", vim.log.levels.WARN)
		return
	end
	local scan = require("plenary.scandir")
	local cwd = vim.fn.getcwd()
	local home_projects = vim.fn.expand("~/projects")
	local tools = vim.fn.expand("~/tools")
	local dirs = {}
	local seen = {}
	local function add(d)
		if not seen[d] then
			seen[d] = true
			table.insert(dirs, d)
		end
	end
	add(cwd)
	if vim.fn.isdirectory(home_projects) == 1 then
		for _, d in ipairs(scan.scan_dir(home_projects, { depth = 1, only_dirs = true, silent = true })) do
			add(d)
		end
	end
	if vim.fn.isdirectory(tools) == 1 then
		for _, d in ipairs(scan.scan_dir(tools, { depth = 1, only_dirs = true, silent = true })) do
			add(d)
		end
	end
	for _, d in ipairs(scan.scan_dir(cwd, { only_dirs = true, silent = true })) do
		add(d)
	end
	require("telescope.pickers")
		.new({}, {
			prompt_title = "Tmux Sessionizer",
			finder = require("telescope.finders").new_table({
				results = dirs,
				entry_maker = function(entry)
					return {
						value = entry,
						display = vim.fn.fnamemodify(entry, ":~"),
						ordinal = entry,
					}
				end,
			}),
			sorter = require("telescope.config").values.generic_sorter({}),
			attach_mappings = function(prompt_bufnr)
				require("telescope.actions").select_default:replace(function()
					local sel = require("telescope.actions.state").get_selected_entry()
					require("telescope.actions").close(prompt_bufnr)
					if sel then
						sessionize(sel.value)
					end
				end)
				return true
			end,
		})
		:find()
end, { desc = "Tmux sessionizer" })

-- -----------------------------------------------------------------------
-- Session editor
-- -----------------------------------------------------------------------

vim.keymap.set("n", "<leader>ts", function()
	if not in_tmux() then
		return
	end
	local current_session = vim.trim(vim.fn.system("tmux display-message -p '#S'"))
	local sessions = ordered_sessions()
	vim.notify(table.concat(sessions, ", "), vim.log.levels.INFO)
	scratchbuf.open({
		title = "Tmux Sessions",
		lines = sessions,
		refresh = ordered_sessions,
		current = current_session,
		close_on_open = false,
		on_open = function(entry)
			local current = vim.trim(vim.fn.system("tmux display-message -p '#S'"))
			if entry ~= current then
				-- close the scratchbuf then switch
				for _, w in ipairs(vim.api.nvim_list_wins()) do
					local b = vim.api.nvim_win_get_buf(w)
					if vim.b[b]._scratchbuf == "Tmux Sessions" then
						vim.api.nvim_buf_delete(b, { force = true })
						break
					end
				end
				tmux("switch-client -t " .. vim.fn.shellescape(entry))
			end
		end,
		on_save = function(changes)
			for _, r in ipairs(changes.renamed) do
				tmux("rename-session -t " .. vim.fn.shellescape(r.old) .. " " .. vim.fn.shellescape(r.new))
			end
			for _, d in ipairs(changes.deleted) do
				local current = vim.trim(vim.fn.system("tmux display-message -p '#S' 2>/dev/null"))
				if current == d then
					switch_to_first_available(d)
				end
				tmux("kill-session -t " .. vim.fn.shellescape(d))
			end
			for _, c in ipairs(changes.created) do
				local path = vim.fn.input("Path for [" .. c .. "]: ", vim.fn.getcwd(), "dir")
				if path and path ~= "" then
					tmux("new-session -ds " .. vim.fn.shellescape(c) .. " -c " .. vim.fn.shellescape(path))
				end
			end
			local rename_map = {}
			for _, r in ipairs(changes.renamed) do
				rename_map[r.old] = r.new
			end
			local deleted_set = {}
			for _, d in ipairs(changes.deleted) do
				deleted_set[d] = true
			end
			local final = {}
			for _, s in ipairs(changes.order) do
				if not deleted_set[s] then
					table.insert(final, rename_map[s] or s)
				end
			end
			for _, c in ipairs(changes.created) do
				local already = false
				for _, s in ipairs(final) do
					if s == c then
						already = true
						break
					end
				end
				if not already then
					table.insert(final, c)
				end
			end
			save_order(final)
		end,
		on_ready = function(buf, _win)
			local ns = vim.api.nvim_create_namespace("tmux_session_group_hints")

			local function render_hints()
				vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
				local line_count = vim.api.nvim_buf_line_count(buf)
				vim.api.nvim_buf_set_extmark(buf, ns, math.max(line_count - 1, 0), 0, {
					virt_lines = {
						{
							{ "  ", "Comment" },
						},
						{
							{ "  + ", "Title" },
							{ "add to group  ", "Comment" },
							{ "  +g ", "Title" },
							{ "add to new group  ", "Comment" },
							{ "  - ", "Title" },
							{ "remove from group  ", "Comment" },
							{ "  -g ", "Title" },
							{ "remove group  ", "Comment" },
							{ "  e ", "Title" },
							{ "edit path", "Comment" },
						},
					},
					virt_lines_above = false,
				})
			end

			render_hints()

			vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
				buffer = buf,
				callback = function()
					render_hints()
				end,
			})

			local function pick_group(title, groups, callback)
				if #groups == 0 then
					vim.notify("tmux: no groups available", vim.log.levels.WARN)
					return
				end
				scratchbuf.open({
					title = title,
					lines = groups,
					on_open = function(group)
						callback(group)
					end,
					on_save = function() end,
				})
			end

			-- + add cursor session to an existing group
			vim.keymap.set("n", "+", function()
				local session = vim.trim(vim.api.nvim_get_current_line())
				if session == "" then
					return
				end
				local groups = vim.tbl_keys(M.projects)
				table.sort(groups)
				pick_group("Add to Group", groups, function(group)
					M.add_to_group(session, group)
				end)
			end, { buffer = buf, nowait = true, noremap = true, desc = "Add session to group" })

			-- +g add cursor session to a new group
			vim.keymap.set("n", "+g", function()
				local session = vim.trim(vim.api.nvim_get_current_line())
				if session == "" then
					return
				end
				local group = vim.fn.input("New group name: ")
				if group == "" then
					return
				end
				M.add_to_group(session, group)
			end, { buffer = buf, nowait = true, noremap = true, desc = "Add session to new group" })

			-- - remove cursor session from a group it belongs to
			vim.keymap.set("n", "-", function()
				local session = vim.trim(vim.api.nvim_get_current_line())
				if session == "" then
					return
				end
				local matching = {}
				for group, entries in pairs(M.projects) do
					for _, e in ipairs(entries) do
						if e.name == session then
							table.insert(matching, group)
							break
						end
					end
				end
				table.sort(matching)
				if #matching == 0 then
					vim.notify("tmux: " .. session .. " is not in any group", vim.log.levels.WARN)
					return
				end
				pick_group("Remove from Group", matching, function(group)
					M.remove_from_group(session, group)
				end)
			end, { buffer = buf, nowait = true, noremap = true, desc = "Remove session from group" })

			-- -g remove an entire group
			vim.keymap.set("n", "-g", function()
				local groups = vim.tbl_keys(M.projects)
				table.sort(groups)
				pick_group("Remove Group", groups, function(group)
					local confirm = vim.fn.input("Remove group '" .. group .. "'? (y/N): ")
					if confirm == "y" or confirm == "Y" then
						M.remove_group(group)
					end
				end)
			end, { buffer = buf, nowait = true, noremap = true, desc = "Remove entire group" })

			-- e edit session path, update group refs, reopen session
			vim.keymap.set("n", "e", function()
				local session = vim.trim(vim.api.nvim_get_current_line())
				if session == "" then
					return
				end
				M.edit_session(session)
			end, { buffer = buf, nowait = true, noremap = true, desc = "Edit session path" })
		end,
	})
end, { desc = "Tmux sessions (edit)" })

vim.keymap.set("n", "<leader>tS", function()
	if not in_tmux() then
		return
	end
	local all = vim.fn.systemlist("tmux list-sessions -F '#S' 2>/dev/null")
	if vim.v.shell_error ~= 0 or #all == 0 then
		vim.notify("tmux: no sessions", vim.log.levels.WARN)
		return
	end
	scratchbuf.open({
		title = "All Tmux Sessions (incl. air)",
		lines = all,
		refresh = function()
			return vim.fn.systemlist("tmux list-sessions -F '#S' 2>/dev/null")
		end,
		on_open = function(entry)
			tmux("switch-client -t " .. vim.fn.shellescape(entry))
		end,
		on_save = function() end,
	})
end, { desc = "Tmux: all sessions (debug)" })

-- -----------------------------------------------------------------------
-- Rename
-- -----------------------------------------------------------------------

vim.keymap.set("n", "<leader>tr", function()
	if not in_tmux() then
		return
	end
	local current = vim.trim(vim.fn.system("tmux display-message -p '#S'"))
	local name = vim.fn.input("Rename session [" .. current .. "]: ")
	if name and name ~= "" then
		tmux("rename-session " .. vim.fn.shellescape(name))
		local slots = load_order()
		for i, s in ipairs(slots) do
			if s == current then
				slots[i] = name
				break
			end
		end
		save_order(slots)
		vim.notify("Session renamed to: " .. name)
	end
end, { desc = "Tmux rename session" })

-- -----------------------------------------------------------------------
-- Splits
-- -----------------------------------------------------------------------

vim.keymap.set("n", "<leader>t|", function()
	if not in_tmux() then
		return
	end
	tmux("split-window -h -c " .. vim.fn.shellescape(vim.fn.getcwd()))
end, { desc = "Tmux vertical split" })

vim.keymap.set("n", "<leader>t-", function()
	if not in_tmux() then
		return
	end
	tmux("split-window -v -c " .. vim.fn.shellescape(vim.fn.getcwd()))
end, { desc = "Tmux horizontal split" })

-- -----------------------------------------------------------------------
-- Join / Break pane
-- -----------------------------------------------------------------------

vim.keymap.set("n", "<leader>ta", function()
	if not in_tmux() then
		return
	end
	scratchbuf.open({
		title = "Join pane from session",
		lines = ordered_sessions(),
		refresh = ordered_sessions,
		on_open = function(entry)
			tmux("join-pane -h -s " .. vim.fn.shellescape(entry) .. ":.")
		end,
		on_save = function() end,
	})
end, { desc = "Tmux: join pane from session" })

vim.keymap.set("n", "<leader>tb", function()
	if not in_tmux() then
		return
	end
	tmux("break-pane -d -s !")
end, { desc = "Tmux: break pane back to session" })

-- -----------------------------------------------------------------------
-- Kill all sessions
-- -----------------------------------------------------------------------

vim.keymap.set("n", "<leader>tT", function()
	if not in_tmux() then
		return
	end
	local confirm = vim.fn.input("Kill ALL tmux sessions? (y/N): ")
	if confirm == "y" or confirm == "Y" then
		tmux("kill-server")
		vim.notify("tmux: all sessions killed", vim.log.levels.INFO)
	end
end, { desc = "Tmux: kill all sessions" })

-- -----------------------------------------------------------------------
-- Projects
-- -----------------------------------------------------------------------

M.projects = {}
M.default = {}
M.nvim = false
M.project_order = {}

local function get_active_project()
	local f = io.open(active_project_file, "r")
	if not f then
		return nil
	end
	local name = vim.trim(f:read("*a"))
	f:close()
	return name ~= "" and name or nil
end

local function set_active_project(name)
	local f = io.open(active_project_file, "w")
	if not f then
		return
	end
	f:write(name)
	f:close()
end

local function create_session(s)
	local path = vim.fn.expand(s.path)
	local exists =
		vim.trim(vim.fn.system("tmux has-session -t=" .. vim.fn.shellescape(s.name) .. " 2>/dev/null; echo $?"))
	if exists ~= "0" then
		local cmd = "new-session -ds " .. vim.fn.shellescape(s.name) .. " -c " .. vim.fn.shellescape(path)
		if s.nvim ~= false and M.nvim then
			cmd = cmd .. " " .. vim.fn.shellescape("nvim .")
		end
		tmux(cmd)
	end
end

function M.open_project(name)
	local proj = M.projects[name]
	if not proj then
		vim.notify("tmux: unknown project '" .. name .. "'", vim.log.levels.ERROR)
		return
	end
	local slots = {}
	for _, s in ipairs(proj) do
		table.insert(slots, s.name)
		create_session(s)
	end
	for _, s in ipairs(M.default) do
		table.insert(slots, s.name)
		create_session(s)
	end
	save_order(slots)
	set_active_project(name)
	tmux("switch-client -t " .. vim.fn.shellescape(proj[1].name))
	vim.notify("Project loaded: " .. name, vim.log.levels.INFO)
end

function M.switch_project(name)
	M.open_project(name)
	local keep = {}
	for _, s in ipairs(M.default) do
		keep[s.name] = true
	end
	if M.projects[name] then
		for _, s in ipairs(M.projects[name]) do
			keep[s.name] = true
		end
	end
	local live = vim.fn.systemlist("tmux list-sessions -F '#S' 2>/dev/null")
	for _, s in ipairs(live) do
		if not keep[s] then
			vim.fn.system("tmux kill-session -t=" .. vim.fn.shellescape(s) .. " 2>/dev/null")
		end
	end
end

function M.recover_project()
	local active = get_active_project()
	if active and M.projects[active] then
		M.open_project(active)
	else
		vim.notify("tmux: no active project to recover", vim.log.levels.WARN)
	end
end

function M.pick_project()
	if not in_tmux() then
		return
	end
	local names = M.project_order
	if #names == 0 then
		vim.notify("tmux: no projects defined", vim.log.levels.WARN)
		return
	end
	local active = get_active_project()
	local live_set = {}
	local live = vim.fn.systemlist("tmux list-sessions -F '#S' 2>/dev/null")
	for _, s in ipairs(live) do
		live_set[s] = true
	end
	local title = "Tmux Projects" .. (active and (" [" .. active .. "]") or "")
	scratchbuf.open({
		title = title,
		lines = names,
		current = active,
		refresh = function()
			return names
		end,
		on_open = function(entry)
			M.open_project(entry)
		end,
		on_save = function() end,
		on_ready = function(buf, _win)
			vim.keymap.set("n", "S", function()
				local line = vim.trim(vim.api.nvim_get_current_line())
				if line == "" then
					return
				end
				vim.schedule(function()
					if vim.api.nvim_buf_is_valid(buf) then
						vim.api.nvim_buf_delete(buf, { force = true })
					end
					M.switch_project(line)
				end)
			end, { buffer = buf, nowait = true, noremap = true, desc = "Switch project (kill old)" })
			local ns = vim.api.nvim_create_namespace("tmux_project_preview")
			local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			local default_parts = {}
			for _, s in ipairs(M.default) do
				local icon = live_set[s.name] and "*" or "-"
				table.insert(default_parts, icon .. " " .. s.name)
			end
			local default_str = #default_parts > 0 and ("  |  " .. table.concat(default_parts, "  ")) or ""
			for i, line in ipairs(lines) do
				local proj = M.projects[vim.trim(line)]
				if proj then
					local parts = {}
					for _, s in ipairs(proj) do
						local icon = live_set[s.name] and "*" or "-"
						table.insert(parts, icon .. " " .. s.name)
					end
					vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
						virt_text = { { "  " .. table.concat(parts, "  ") .. default_str, "Comment" } },
						virt_text_pos = "eol",
					})
				end
			end
		end,
	})
end

-- -----------------------------------------------------------------------
-- Group management
-- -----------------------------------------------------------------------

function M.add_to_group(session_name, group_name)
	vim.schedule(function()
		local path = get_session_path(session_name)
		local confirmed = vim.fn.input("Path for [" .. session_name .. "]: ", path, "dir")
		if confirmed == "" then
			return
		end
		if not M.projects[group_name] then
			M.projects[group_name] = {}
			local in_order = {}
			for _, g in ipairs(M.project_order) do
				in_order[g] = true
			end
			if not in_order[group_name] then
				table.insert(M.project_order, group_name)
			end
		end
		for _, e in ipairs(M.projects[group_name]) do
			if e.name == session_name then
				vim.notify("tmux: " .. session_name .. " already in " .. group_name, vim.log.levels.WARN)
				return
			end
		end
		table.insert(M.projects[group_name], { name = session_name, path = confirmed })
		save_overrides()
		vim.notify("tmux: added " .. session_name .. " to " .. group_name, vim.log.levels.INFO)
	end)
end

function M.remove_from_group(session_name, group_name)
	local proj = M.projects[group_name]
	if not proj then
		vim.notify("tmux: group " .. group_name .. " not found", vim.log.levels.WARN)
		return
	end
	local new_entries = {}
	local found = false
	for _, e in ipairs(proj) do
		if e.name == session_name then
			found = true
		else
			table.insert(new_entries, e)
		end
	end
	if not found then
		vim.notify("tmux: " .. session_name .. " not in " .. group_name, vim.log.levels.WARN)
		return
	end
	M.projects[group_name] = new_entries
	save_overrides()
	vim.notify("tmux: removed " .. session_name .. " from " .. group_name, vim.log.levels.INFO)
end

function M.remove_group(group_name)
	if not M.projects[group_name] then
		vim.notify("tmux: group " .. group_name .. " not found", vim.log.levels.WARN)
		return
	end
	M.projects[group_name] = nil
	local new_order = {}
	for _, g in ipairs(M.project_order) do
		if g ~= group_name then
			table.insert(new_order, g)
		end
	end
	M.project_order = new_order
	save_overrides()
	vim.notify("tmux: removed group " .. group_name, vim.log.levels.INFO)
end

function M.edit_session(session_name)
	vim.schedule(function()
		local stored_path = ""
		for _, entries in pairs(M.projects) do
			for _, e in ipairs(entries) do
				if e.name == session_name then
					stored_path = e.path
					break
				end
			end
			if stored_path ~= "" then
				break
			end
		end
		local prefill = stored_path ~= "" and stored_path or get_session_path(session_name)
		local new_path = vim.fn.input("Path for [" .. session_name .. "]: ", prefill, "dir")
		if new_path == "" or new_path == prefill then
			return
		end
		local updated = false
		for _, entries in pairs(M.projects) do
			for _, e in ipairs(entries) do
				if e.name == session_name then
					e.path = new_path
					updated = true
				end
			end
		end
		if updated then
			save_overrides()
		end
		local current = vim.trim(vim.fn.system("tmux display-message -p '#S' 2>/dev/null"))
		if current == session_name then
			switch_to_first_available(session_name)
		end
		local expanded = vim.fn.expand(new_path)
		tmux("kill-session -t " .. vim.fn.shellescape(session_name))
		tmux("new-session -ds " .. vim.fn.shellescape(session_name) .. " -c " .. vim.fn.shellescape(expanded))
		vim.notify("tmux: " .. session_name .. " reopened at " .. new_path, vim.log.levels.INFO)
	end)
end
-- -----------------------------------------------------------------------
-- Setup
-- -----------------------------------------------------------------------

function M.setup(opts)
	M.projects = opts.projects or {}
	M.default = opts.default or {}
	M.nvim = opts.nvim or false
	M.project_order = opts.project_order or vim.tbl_keys(M.projects)
	merge_overrides()
end

return M
