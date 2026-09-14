-- lua/tmux_projects/projects.lua FINAL-9
-- Tmux palette: saved sessions, folders and workspaces (<leader>tp).
--
-- The palette is a launcher, not a session holder. Enter on a session or
-- workspace creates the sessions and hands them off to the workspace board
-- (<leader>ts), which opens in their place. Switching happens in the board.
--
-- Root shows two containers:
--   projects/   saved session definitions as folders, sessions are "name<TAB>path"
--   workspaces/ named session combinations; Enter opens the whole workspace
--
-- Folders are edited Oil-style: change the text, W to apply. W prompts for
-- missing session paths via a fuzzy picker and recreates live sessions whose
-- path changed. A session lives in exactly one folder. Deleting a folder or
-- a session row deletes it in tmux too.

local state = require("tmux_projects.state")
local browser = require("tmux_projects.browser")

local M_sub = {}

function M_sub.setup(M)
	local function shell(value)
		return vim.fn.shellescape(value)
	end

	local function find_session_path(name)
		for _, entries in pairs(M.projects) do
			for _, entry in ipairs(entries) do
				if entry.name == name then
					return entry.path
				end
			end
		end
		return nil
	end

	local function project_key(prefix)
		if prefix == "projects" then
			return ""
		end
		return (prefix:gsub("^projects/", ""))
	end

	local function is_project_level(prefix)
		return prefix == "projects" or vim.startswith(prefix, "projects/")
	end

	local function child_folders(key)
		local folders, seen = {}, {}
		local base = key == "" and "" or (key .. "/")
		for name in pairs(M.projects) do
			if name ~= key and vim.startswith(name, base) then
				local remainder = name:sub(#base + 1)
				local child = remainder:match("^([^/]+)/") or remainder
				if child ~= "" and not seen[child] then
					seen[child] = true
					table.insert(folders, child)
				end
			end
		end
		table.sort(folders)
		return folders
	end

	-- Delete a folder tree and kill the tmux sessions of its sessions.
	local function delete_tree(key)
		local doomed = {}
		for name in pairs(M.projects) do
			if name == key or vim.startswith(name, key .. "/") then
				table.insert(doomed, name)
			end
		end
		local sessions_to_kill = {}
		for _, name in ipairs(doomed) do
			for _, entry in ipairs(M.projects[name] or {}) do
				table.insert(sessions_to_kill, entry)
			end
			M.projects[name] = nil
		end
		for _, entry in ipairs(sessions_to_kill) do
			if state.session_exists(entry.name) then
				state.tmux("kill-session -t " .. shell(entry.name))
			end
		end
		if #sessions_to_kill > 0 then
			browser.invalidate_live()
		end
	end

	local function render(prefix)
		if prefix == "" then
			return { "projects/", "workspaces/" }
		end
		if prefix == "workspaces" then
			local names = vim.tbl_keys(M.workspaces)
			table.sort(names)
			return names
		end
		local key = project_key(prefix)
		local lines = {}
		for _, folder in ipairs(child_folders(key)) do
			table.insert(lines, folder .. "/")
		end
		for _, session in ipairs(M.projects[key] or {}) do
			table.insert(lines, session.name .. "\t" .. (session.path or ""))
		end
		return lines
	end

	local function commit(prefix, lines, prompt_paths)
		if prefix == "" then
			return true
		end
		if prefix == "workspaces" then
			local next_workspaces = {}
			for _, line in ipairs(lines) do
				local name = vim.trim(line)
				if name ~= "" and name:sub(-1) ~= "/" then
					next_workspaces[name] = M.workspaces[name] or { folders = {}, sessions = {} }
				end
			end
			M.workspaces = next_workspaces
			M.save_store()
			return true
		end
		if not is_project_level(prefix) then
			return true
		end

		local key = project_key(prefix)
		local old_sessions = M.projects[key] or {}
		local old_by_name = {}
		for _, session in ipairs(old_sessions) do
			old_by_name[session.name] = session
		end
		local old_children = child_folders(key)

		local new_sessions = {}
		local kept_folders = {}
		for _, line in ipairs(lines) do
			local raw = vim.trim(line)
			if raw ~= "" then
				-- Folder rows are single tokens ending in "/"; a session row
				-- with a trailing-slash path (e.g. "test<TAB>/") is a session.
				if raw:sub(-1) == "/" and not raw:find("%s") then
					local name = vim.trim(raw:sub(1, -2))
					if name ~= "" then
						kept_folders[key == "" and name or (key .. "/" .. name)] = true
					end
				else
					local name, path = raw:match("^(.-)%s+(.+)$")
					if not name then
						name, path = raw, ""
					end
					name = vim.trim(name)
					path = vim.trim(path or "")
					if name ~= "" then
						local old = old_by_name[name]
						table.insert(new_sessions, {
							name = name,
							path = path ~= "" and path or (old and old.path or ""),
						})
					end
				end
			end
		end

		-- A session lives in exactly one folder: drop same-name entries from
		-- every other folder so moves/creates never duplicate.
		local new_names = {}
		for _, session in ipairs(new_sessions) do
			new_names[session.name] = true
		end

		-- Sessions deleted at this level are killed in tmux too, so they do
		-- not reappear at the board root as live sessions.
		local deleted_sessions = {}
		for name, old in pairs(old_by_name) do
			if not new_names[name] then
				table.insert(deleted_sessions, old)
			end
		end

		for other_key, entries in pairs(M.projects) do
			if other_key ~= key then
				local filtered = {}
				for _, entry in ipairs(entries) do
					if not new_names[entry.name] then
						table.insert(filtered, entry)
					end
				end
				M.projects[other_key] = filtered
			end
		end

		-- On explicit save (W): recreate live sessions whose base path changed.
		if prompt_paths then
			for _, session in ipairs(new_sessions) do
				local old = old_by_name[session.name]
				if old and old.path ~= session.path and session.path ~= "" and state.session_exists(session.name) then
					browser.recreate_session(session.name, session.path)
				end
			end
		end

		M.projects[key] = new_sessions
		for _, child_name in ipairs(old_children) do
			local child = key == "" and child_name or (key .. "/" .. child_name)
			if not kept_folders[child] then
				delete_tree(child)
			end
		end
		for child in pairs(kept_folders) do
			M.projects[child] = M.projects[child] or {}
		end
		M.save_store()

		for _, session in ipairs(deleted_sessions) do
			if state.session_exists(session.name) then
				state.tmux("kill-session -t " .. shell(session.name))
			end
		end
		if #deleted_sessions > 0 then
			browser.invalidate_live()
		end
		return true
	end

	local function create_session(name, path)
		if not path or path == "" then
			return false
		end
		if not state.session_exists(name) then
			state.tmux("new-session -ds " .. shell(name) .. " -c " .. shell(vim.fn.expand(path)))
		end
		return true
	end

	-- Launch a saved session into the board: create it if missing, hand it to
	-- the board, and let the board open in the palette's place.
	local function open_saved_session(name, path)
		local resolved = path
		if resolved == "" then
			resolved = find_session_path(name) or ""
		end
		if resolved == "" then
			local entered = vim.fn.input("Path for [" .. name .. "]: ", "", "dir")
			if entered == "" then
				vim.notify("tmux: no path for '" .. name .. "'", vim.log.levels.WARN)
				return false
			end
			resolved = vim.trim(entered)
		end
		if not state.session_exists(name) then
			state.tmux("new-session -ds " .. shell(name) .. " -c " .. shell(vim.fn.expand(resolved)))
		end
		M.add_to_board(name, resolved)
		browser.invalidate_live()
		return true
	end

	local function open_workspace(name)
		local workspace = M.workspaces[name]
		if not workspace then
			vim.notify("tmux: unknown workspace '" .. name .. "'", vim.log.levels.ERROR)
			return false
		end
		for _, session in ipairs(workspace.sessions or {}) do
			local path = session.path
			if not path or path == "" then
				path = find_session_path(session.name)
			end
			if path and path ~= "" then
				if not state.session_exists(session.name) then
					state.tmux("new-session -ds " .. shell(session.name) .. " -c " .. shell(vim.fn.expand(path)))
				end
				M.add_to_board(session.name, path)
			end
		end
		M.set_active_project(name)
		browser.invalidate_live()
		vim.notify("Workspace loaded: " .. name, vim.log.levels.INFO)
		return true
	end

	function M.open_project(name)
		local sessions = M.projects[name]
		if not sessions then
			vim.notify("tmux: unknown project '" .. name .. "'", vim.log.levels.ERROR)
			return
		end
		local slots, first = {}, nil
		for _, session in ipairs(sessions) do
			if create_session(session.name, session.path) then
				table.insert(slots, session.name)
				first = first or session.name
			end
		end
		for _, session in ipairs(M.default) do
			if create_session(session.name, session.path) then
				table.insert(slots, session.name)
				first = first or session.name
			end
		end
		M.save_order(slots)
		M.set_active_project(name)
		if first then
			state.tmux("switch-client -t " .. shell(first))
		end
		vim.notify("Project loaded: " .. name, vim.log.levels.INFO)
	end

	function M.switch_project(name)
		M.open_project(name)
		local keep = {}
		for _, session in ipairs(M.default) do
			keep[session.name] = true
		end
		for _, session in ipairs(M.projects[name] or {}) do
			keep[session.name] = true
		end
		for _, live in ipairs(vim.fn.systemlist("tmux list-sessions -F '#S' 2>/dev/null")) do
			if not keep[live] then
				vim.fn.system("tmux kill-session -t=" .. shell(live) .. " 2>/dev/null")
			end
		end
	end

	function M.recover_project()
		local active = M.get_active_project()
		if active and M.workspaces[active] then
			open_workspace(active)
		elseif active and M.projects[active] then
			M.open_project(active)
		else
			vim.notify("tmux: no active project to recover", vim.log.levels.WARN)
		end
	end

	function M.pick_project()
		browser.open_level({
			title_root = "Tmux Palette",
			title_prefix = "Palette",
			prefix = "",
			render = render,
			commit = commit,
			open_session = function(name, path, prefix)
				local ok
				if prefix == "workspaces" then
					ok = open_workspace(name)
				else
					ok = open_saved_session(name, path)
				end
				if ok then
					-- Hand off to the board: it opens after the palette closes.
					vim.schedule(function()
						M.open_workboard()
					end)
				end
				return ok
			end,
			on_missing_paths = function(buf, prefix)
				if not is_project_level(prefix) then
					return
				end
				local key = project_key(prefix)
				local missing = {}
				for _, session in ipairs(M.projects[key] or {}) do
					if session.path == "" then
						table.insert(missing, session)
					end
				end
				if #missing == 0 then
					return
				end
				vim.schedule(function()
					local function process(i)
						if i > #missing then
							if vim.api.nvim_buf_is_valid(buf) then
								vim.api.nvim_buf_set_lines(buf, 0, -1, false, render(prefix))
								vim.bo[buf].modified = false
							end
							return
						end
						local session = missing[i]
						browser.pick_path(find_session_path(session.name) or "", function(path)
							if path and path ~= "" then
								session.path = path
								M.save_store()
							end
							process(i + 1)
						end)
					end
					process(1)
				end)
			end,
			on_ready = function(buf, prefix)
				vim.keymap.set("n", "S", function()
					if not is_project_level(prefix) then
						return
					end
					local key = project_key(prefix)
					if key == "" then
						return
					end
					M.switch_project(key)
					browser.invalidate_live()
					vim.api.nvim_buf_set_lines(buf, 0, -1, false, render(prefix))
					vim.bo[buf].modified = false
				end, { buffer = buf, nowait = true, noremap = true, desc = "Open all (kill others)" })
			end,
		})
	end
end

return M_sub
