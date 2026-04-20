--[[
Keymaps:
<C-f>    Sessionizer telescope project picker
<leader>ts  Edit tmux sessions (scratchbuf)
<leader>tr  Rename current session
<leader>t|  Vertical split in cwd
<leader>t-  Horizontal split in cwd

Slot switching (line order in scratchbuf = slot order):
<leader>7  slot 1    <leader><leader>7  slot 5
<leader>8  slot 2    <leader><leader>8  slot 6
<leader>9  slot 3    <leader><leader>9  slot 7
<leader>0  slot 4    <leader><leader>0  slot 8

Scratchbuf keymaps (inside <leader>ts):
<CR>  switch to session
o     new session below
O     new session above
dd    cut session
p     paste below  (reorder)
P     paste above  (reorder)
W     save persists slot order
/     fuzzy filter
r     refresh
q     close

Project keymaps (set in after/):
<leader>tp  Pick project (scratchbuf) - <CR> to load
<leader>tP  Recover active project (recreate missing sessions)
--]]

local scratchbuf = require("scratchbuf")
local M = {}

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

local order_file = vim.fn.stdpath("data") .. "/tmux_session_slots"
local active_project_file = vim.fn.stdpath("data") .. "/tmux_active_project"

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

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

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
		if not seen[s] and not s:find("^air%-") then
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

-- ---------------------------------------------------------------------------
-- Slot switching
-- ---------------------------------------------------------------------------

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

for i, key in ipairs({ "7", "8", "9", "0" }) do
	vim.keymap.set("n", "<leader>" .. key, function()
		switch_slot(i)
	end, { desc = "Tmux slot " .. i, noremap = true })
end

for i, key in ipairs({ "7", "8", "9", "0" }) do
	vim.keymap.set("n", "<leader><leader>" .. key, function()
		switch_slot(i + 4)
	end, { desc = "Tmux slot " .. (i + 4), noremap = true })
end

-- ---------------------------------------------------------------------------
-- Sessionizer
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- Session editor
-- ---------------------------------------------------------------------------

vim.keymap.set("n", "<leader>ts", function()
	if not in_tmux() then
		return
	end

	local sessions = ordered_sessions()
	local current_session = vim.trim(vim.fn.system("tmux display-message -p '#S'"))
	vim.notify(table.concat(sessions, ", "), vim.log.levels.INFO)

	scratchbuf.open({
		title = "Tmux Sessions",
		lines = ordered_sessions(),
		refresh = ordered_sessions,
		current = current_session,
		on_open = function(entry)
			tmux("switch-client -t " .. vim.fn.shellescape(entry))
		end,
		on_save = function(changes)
			for _, r in ipairs(changes.renamed) do
				tmux("rename-session -t " .. vim.fn.shellescape(r.old) .. " " .. vim.fn.shellescape(r.new))
			end
			for _, d in ipairs(changes.deleted) do
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

-- ---------------------------------------------------------------------------
-- Rename
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- Splits
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- Projects
-- ---------------------------------------------------------------------------

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
		-- launch nvim unless explicitly disabled for this session
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

	-- project sessions first
	for _, s in ipairs(proj) do
		table.insert(slots, s.name)
		create_session(s)
	end

	-- default sessions at the bottom
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
	-- create new project sessions first so we never have zero sessions
	M.open_project(name)

	-- build set of sessions to keep: default + new project
	local keep = {}
	for _, s in ipairs(M.default) do
		keep[s.name] = true
	end
	if M.projects[name] then
		for _, s in ipairs(M.projects[name]) do
			keep[s.name] = true
		end
	end

	-- kill everything else
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

	-- check which sessions are already alive
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
	})

	-- add virtual text + extra keymaps after scratchbuf opens
	vim.schedule(function()
		local buf
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.b[b]._scratchbuf == title then
				buf = b
				break
			end
		end
		if not buf then
			return
		end

		-- S = clean switch (kill old project sessions, then load new)
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

		-- build default session names for display
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
	end)
end

function M.setup(opts)
	M.projects = opts.projects or {}
	M.default = opts.default or {}
	M.nvim = opts.nvim or false
	M.project_order = opts.project_order or vim.tbl_keys(M.projects)
end

return M
