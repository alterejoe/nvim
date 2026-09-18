-- lua/tmux_projects/sessions.lua FINAL-10
-- Live workspace board (<leader>ts) plus tmux session keymaps.
--
-- The board is an Oil-style browser over one workspace:
--   * live sessions show ●, saved-but-dead sessions show ○
--   * folders are virtual and stored in the workspace
--   * dd a session row, enter a folder, gp to move it; W commits the level, <C-W> saves the workspace
--   * W prompts for missing session paths via a fuzzy picker and recreates
--     live sessions whose path was edited
--   * a session lives in exactly one folder; the root never duplicates
--     sessions that live in a folder
--   * deleting a folder or a session row deletes it in tmux too
--   * A / O toggle panels listing the hidden air / opencode sessions;
--     deleting a row there and saving (W) kills that session
--   * Enter on a session opens it and closes the board
--   * sessions handed off from the palette (tp) are merged into the draft
--   * + saves the session on the current row to the palette (projects/)
--   * <C-l>/r refresh, "-"/<leader>e go up a level, <Tab> toggles name/path

local state = require("tmux_projects.state")
local browser = require("tmux_projects.browser")
local scratchbuf = require("scratchbuf")

local M_sub = {}

function M_sub.setup(M)
	-- Slot switching -------------------------------------------------------
	local function switch_slot(index)
		if not state.in_tmux() then
			vim.notify("Not in tmux", vim.log.levels.WARN)
			return
		end
		local sessions = state.ordered_sessions(M.get_show_hidden())
		local target = sessions[index]
		if not target then
			vim.notify("tmux: no session in slot " .. index, vim.log.levels.WARN)
			return
		end
		state.tmux("switch-client -t " .. vim.fn.shellescape(target))
	end

	for i, key in ipairs({ "j", "k", "l", ";" }) do
		vim.keymap.set("n", "<leader>t" .. key, function()
			switch_slot(i)
		end, { desc = "Tmux slot " .. i, noremap = true })
	end
	for i, key in ipairs({ "J", "K", "L", ":" }) do
		vim.keymap.set("n", "<leader>t" .. key, function()
			switch_slot(i + 4)
		end, { desc = "Tmux slot " .. (i + 4), noremap = true })
	end

	-- Sessionizer ----------------------------------------------------------
	vim.keymap.set("n", "<C-f>", function()
		if not state.in_tmux() then
			vim.notify("Not in tmux", vim.log.levels.WARN)
			return
		end
		local scan = require("plenary.scandir")
		local dirs = {}
		local seen = {}
		local function add(d)
			if not seen[d] then
				seen[d] = true
				table.insert(dirs, d)
			end
		end

		-- Priority directories (scan subdirs, depth 1)
		for _, root in ipairs({ "/projects", "/portal" }) do
			if vim.fn.isdirectory(root) == 1 then
				add(root)
				for _, d in ipairs(scan.scan_dir(root, { depth = 1, only_dirs = true, silent = true })) do
					add(d)
				end
			end
		end

		-- Also scan ~/projects and ~/tools if they exist
		for _, root in ipairs({ vim.fn.expand("~/projects"), vim.fn.expand("~/tools") }) do
			if vim.fn.isdirectory(root) == 1 then
				add(root)
				for _, d in ipairs(scan.scan_dir(root, { depth = 1, only_dirs = true, silent = true })) do
					add(d)
				end
			end
		end

		-- Add cwd and its immediate subdirs last
		local cwd = vim.fn.getcwd()
		add(cwd)
		for _, d in ipairs(scan.scan_dir(cwd, { depth = 1, only_dirs = true, silent = true })) do
			add(d)
		end
		require("telescope.pickers")
			.new({}, {
				prompt_title = "Tmux Sessionizer",
				finder = require("telescope.finders").new_table({
					results = dirs,
					entry_maker = function(entry)
						return { value = entry, display = vim.fn.fnamemodify(entry, ":~"), ordinal = entry }
					end,
				}),
				sorter = require("telescope.config").values.generic_sorter({}),
				attach_mappings = function(prompt_bufnr)
					require("telescope.actions").select_default:replace(function()
						local sel = require("telescope.actions.state").get_selected_entry()
						require("telescope.actions").close(prompt_bufnr)
						if sel then
							local path = sel.value
							local name = vim.fn.fnamemodify(path, ":t"):gsub("%.", "_")
							if state.session_exists(name) then
								state.tmux("switch-client -t " .. vim.fn.shellescape(name))
							else
								state.tmux(
									"new-session -ds " .. vim.fn.shellescape(name) .. " -c " .. vim.fn.shellescape(path)
								)
								state.tmux("switch-client -t " .. vim.fn.shellescape(name))
							end
						end
					end)
					return true
				end,
			})
			:find()
	end, { desc = "Tmux sessionizer" })

	-- Workspace board ------------------------------------------------------
	local draft = nil
	local workspace_name = nil
	local pending_board = {}

	-- Sessions handed off from the palette (tp) are merged into the draft the
	-- next time the board opens.
	function M.add_to_board(name, path)
		if not name or name == "" then
			return
		end
		for _, entry in ipairs(pending_board) do
			if entry.name == name then
				entry.path = path
				return
			end
		end
		table.insert(pending_board, { name = name, path = path })
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

	local function live_set()
		local all = browser.live_sessions()
		local visible = {}
		for name in pairs(all) do
			local hidden = name:find("^opencode%-")
				or name:find("^air%-")
				or name:find("^browser%-")
				or name:find("^devproxy%-")
			if M.get_show_hidden() or not hidden then
				visible[name] = true
			end
		end
		return visible
	end

	local function in_draft(name)
		for _, session in ipairs(draft.sessions) do
			if session.name == name then
				return true
			end
		end
		return false
	end

	local function load_draft()
		local active = M.get_active_project()
		if active and M.workspaces[active] then
			workspace_name = active
			draft = vim.deepcopy(M.workspaces[active])
		else
			workspace_name = nil
			draft = vim.deepcopy(M.board)
		end
		draft.folders = draft.folders or {}
		draft.sessions = draft.sessions or {}
		-- Merge sessions handed off from the palette.
		if #pending_board > 0 then
			for _, entry in ipairs(pending_board) do
				if not in_draft(entry.name) then
					table.insert(draft.sessions, { name = entry.name, path = entry.path, folder = "" })
				end
			end
			pending_board = {}
			M.board = vim.deepcopy(draft)
			if workspace_name then
				M.workspaces[workspace_name] = vim.deepcopy(draft)
			end
			M.save_store()
		end
	end

	local function child_folders(prefix)
		local folders, seen = {}, {}
		local base = prefix == "" and "" or (prefix .. "/")
		for _, folder in ipairs(draft.folders) do
			if folder ~= prefix and vim.startswith(folder, base) then
				local remainder = folder:sub(#base + 1)
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

	local function live_paths()
		local map = {}
		local home = vim.fn.expand("~")
		for _, line in ipairs(
			vim.fn.systemlist("tmux list-panes -a -F '#{session_name}|#{pane_current_path}' 2>/dev/null")
		) do
			local name, path = line:match("^([^|]+)|(.+)$")
			if name and path and not map[name] then
				if path:sub(1, #home) == home then
					path = "~" .. path:sub(#home + 1)
				end
				map[name] = path
			end
		end
		return map
	end

	local function render(prefix)
		local lines = {}
		for _, folder in ipairs(child_folders(prefix)) do
			table.insert(lines, folder .. "/")
		end
		for _, session in ipairs(draft.sessions) do
			if (session.folder or "") == prefix then
				table.insert(lines, session.name .. "\t" .. (session.path or ""))
			end
		end
		if prefix == "" then
			-- Root shows only live sessions that are saved nowhere: sessions
			-- living in a workboard folder or a palette folder never appear
			-- at the root.
			local visible = live_set()
			local live_only = {}
			for name in pairs(visible) do
				if not in_draft(name) and not find_session_path(name) then
					table.insert(live_only, name)
				end
			end
			table.sort(live_only)
			local paths = live_paths()
			for _, name in ipairs(live_only) do
				table.insert(lines, name .. "\t" .. (paths[name] or ""))
			end
		end
		return lines
	end

	local function commit(prefix, lines, prompt_paths)
		local old_children = child_folders(prefix)
		local old_by_name = {}
		for _, session in ipairs(draft.sessions) do
			if (session.folder or "") == prefix then
				old_by_name[session.name] = session
			end
		end

		local live = browser.live_sessions()
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
						kept_folders[prefix == "" and name or (prefix .. "/" .. name)] = true
					end
				else
					local name, path = raw:match("^(.-)%s+(.+)$")
					if not name then
						name, path = raw, ""
					end
					name = vim.trim(name)
					path = vim.trim(path or "")
					if name ~= "" then
						-- Ephemeral live rows (live but not in the draft) are
						-- only captured on explicit save (W); navigation never
						-- adds them to the draft, so no root duplicates.
						local ephemeral = live[name] and not in_draft(name)
						if not (ephemeral and not prompt_paths) then
							local existing = find_session_path(name)
							table.insert(new_sessions, {
								name = name,
								path = path ~= "" and path or (existing or ""),
								folder = prefix,
							})
						end
					end
				end
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

		-- Keep sessions that live outside this level, dropping same-name
		-- entries so a session lives in exactly one folder (no duplicates).
		local new_names = {}
		for _, session in ipairs(new_sessions) do
			new_names[session.name] = true
		end

		-- Sessions deleted at this level are killed in tmux too, so they do
		-- not reappear at the root as live sessions.
		local deleted_sessions = {}
		for name, old in pairs(old_by_name) do
			if not new_names[name] then
				table.insert(deleted_sessions, old)
			end
		end

		local kept_sessions = {}
		for _, session in ipairs(draft.sessions) do
			if (session.folder or "") ~= prefix and not new_names[session.name] then
				table.insert(kept_sessions, session)
			end
		end
		vim.list_extend(kept_sessions, new_sessions)

		-- Folders deleted at this level (and their subtrees) are removed.
		local removed = {}
		for _, child_name in ipairs(old_children) do
			local child = prefix == "" and child_name or (prefix .. "/" .. child_name)
			if not kept_folders[child] then
				removed[child] = true
			end
		end

		local function is_removed(folder)
			for base in pairs(removed) do
				if folder == base or vim.startswith(folder, base .. "/") then
					return true
				end
			end
			return false
		end

		-- Sessions inside deleted folders are deleted too (killed in tmux).
		local doomed_sessions = {}
		for _, session in ipairs(draft.sessions) do
			if is_removed(session.folder or "") then
				table.insert(doomed_sessions, session)
			end
		end

		local next_folders = {}
		for _, folder in ipairs(draft.folders) do
			if not is_removed(folder) then
				table.insert(next_folders, folder)
			end
		end
		for child in pairs(kept_folders) do
			if not vim.tbl_contains(next_folders, child) then
				table.insert(next_folders, child)
			end
		end
		table.sort(next_folders)

		local folder_set = {}
		for _, folder in ipairs(next_folders) do
			folder_set[folder] = true
		end
		local final_sessions = {}
		for _, session in ipairs(kept_sessions) do
			local folder = session.folder or ""
			if folder == "" or folder_set[folder] then
				table.insert(final_sessions, session)
			end
		end

		draft.folders = next_folders
		draft.sessions = final_sessions

		M.board = vim.deepcopy(draft)
		if workspace_name then
			M.workspaces[workspace_name] = vim.deepcopy(draft)
		end
		M.save_store()

		-- Kill the tmux sessions of deleted folders and deleted session rows
		-- so they do not reappear at the root as live sessions.
		for _, session in ipairs(doomed_sessions) do
			if state.session_exists(session.name) then
				state.tmux("kill-session -t " .. vim.fn.shellescape(session.name))
			end
		end
		for _, session in ipairs(deleted_sessions) do
			if state.session_exists(session.name) then
				state.tmux("kill-session -t " .. vim.fn.shellescape(session.name))
			end
		end
		if #doomed_sessions > 0 or #deleted_sessions > 0 then
			browser.invalidate_live()
		end
		return true
	end

	local function save_workspace()
		if not workspace_name or workspace_name == "" then
			local name = vim.trim(vim.fn.input("Workspace name: "))
			if name == "" then
				return
			end
			workspace_name = name
		end
		M.workspaces[workspace_name] = vim.deepcopy(draft)
		M.board = vim.deepcopy(draft)
		M.save_store()
		M.set_active_project(workspace_name)
		vim.notify("tmux: workspace '" .. workspace_name .. "' saved", vim.log.levels.INFO)
	end

	function M.open_workboard()
		load_draft()
		-- Open where the user already is: if the current tmux session lives
		-- in a workspace folder, open that folder and highlight its row.
		local current = nil
		if state.in_tmux() then
			current = vim.trim(vim.fn.system("tmux display-message -p '#S' 2>/dev/null"))
			if current == "" then
				current = nil
			end
		end
		local open_prefix = ""
		if current then
			for _, session in ipairs(draft.sessions) do
				if session.name == current then
					open_prefix = session.folder or ""
					break
				end
			end
		end
		browser.open_level({
			title_root = workspace_name and ("Workspace: " .. workspace_name) or "Workspace (unsaved)",
			title_prefix = workspace_name or "Workspace",
			prefix = open_prefix,
			current = current,
			render = render,
			commit = commit,
			live = live_set,
			open_session = function(name, path)
				local resolved = path
				if resolved == "" then
					resolved = find_session_path(name) or ""
				end
				if resolved == "" then
					resolved = state.get_session_path(name) or ""
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
					state.tmux(
						"new-session -ds "
							.. vim.fn.shellescape(name)
							.. " -c "
							.. vim.fn.shellescape(vim.fn.expand(resolved))
					)
				end
				state.tmux("switch-client -t " .. vim.fn.shellescape(name))
				browser.invalidate_live()
				return true
			end,
			on_missing_paths = function(buf, prefix)
				local missing = {}
				for _, session in ipairs(draft.sessions) do
					if (session.folder or "") == prefix and session.path == "" then
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
						browser.pick_path(
							find_session_path(session.name) or state.get_session_path(session.name) or "",
							function(path)
								if path and path ~= "" then
									session.path = path
									M.board = vim.deepcopy(draft)
									if workspace_name then
										M.workspaces[workspace_name] = vim.deepcopy(draft)
									end
									M.save_store()
								end
								process(i + 1)
							end
						)
					end
					process(1)
				end)
			end,
			on_ready = function(buf, prefix)
				-- R: restart the tmux session on the row under the cursor.
				-- This is a tmux-session reset, not an OpenCode-conversation
				-- reset. The saved conversation/database remains untouched.
				vim.keymap.set("n", "R", function()
					local raw = vim.trim(vim.api.nvim_get_current_line())
					if raw == "" or (raw:sub(-1) == "/" and not raw:find("%s")) then
						return
					end
					local name, path = raw:match("^(.-)%s+(.+)$")
					if not name then
						name, path = raw, ""
					end
					name = vim.trim(name)
					path = vim.trim(path or "")
					if name == "" then
						return
					end
					if path == "" then
						path = find_session_path(name) or state.get_session_path(name) or ""
					end
					if path == "" then
						vim.notify("tmux: no path for '" .. name .. "'", vim.log.levels.WARN)
						return
					end
					path = vim.fn.expand(path)
				local answer = vim.fn.confirm(
						"Restart tmux session?\n  " .. name .. "\n  " .. path,
						"&Restart\n&Cancel",
						1
					)
					if answer == 1 then
						browser.recreate_session(name, path)
					end
				end, { buffer = buf, nowait = true, noremap = true, silent = true, desc = "Restart tmux session" })

				-- A / O toggle panels listing the hidden air / opencode
				-- sessions that are filtered out of the main window.
				-- Deleting a row there and saving (W) kills that session.
				local function toggle_panel(title, filter)
					for _, w in ipairs(vim.api.nvim_list_wins()) do
						local b = vim.api.nvim_win_get_buf(w)
						if vim.b[b]._scratchbuf == title then
							vim.api.nvim_win_close(w, true)
							if vim.api.nvim_buf_is_valid(b) then
								vim.api.nvim_buf_delete(b, { force = true })
							end
							return
						end
					end
					local function list()
						local all = browser.live_sessions()
						local lines = {}
						for name in pairs(all) do
							if filter(name) then
								table.insert(lines, name)
							end
						end
						table.sort(lines)
						return lines
					end
					local lines = list()
					if #lines == 0 then
						vim.notify("tmux: no " .. title .. " sessions", vim.log.levels.WARN)
						return
					end
					scratchbuf.open({
						title = title,
						lines = lines,
						refresh = function()
							return list()
						end,
						on_open = function(entry)
							state.tmux("switch-client -t " .. vim.fn.shellescape(entry))
						end,
						on_save = function(changes)
							local current = vim.trim(vim.fn.system("tmux display-message -p '#S' 2>/dev/null"))
							for _, name in ipairs(changes.deleted) do
								if state.session_exists(name) then
									if name == current then
										browser.ensure_nvim_session()
									end
									state.tmux("kill-session -t " .. vim.fn.shellescape(name))
								end
							end
							if #changes.deleted > 0 then
								browser.invalidate_live()
								vim.notify("tmux: killed " .. #changes.deleted .. " session(s)", vim.log.levels.INFO)
							end
							return true
						end,
					})
				end

				vim.keymap.set("n", "A", function()
					toggle_panel("Air sessions", function(name)
						return name:find("^air%-") ~= nil
					end)
				end, { buffer = buf, nowait = true, noremap = true, desc = "Toggle air panel" })

				vim.keymap.set("n", "O", function()
					toggle_panel("Opencode sessions", function(name)
						return name:find("^opencode%-") ~= nil
					end)
				end, { buffer = buf, nowait = true, noremap = true, desc = "Toggle opencode panel" })

				vim.keymap.set("n", "+", function()
					local line = vim.trim(vim.api.nvim_get_current_line())
					if line == "" or (line:sub(-1) == "/" and not line:find("%s")) then
						return
					end
					local name, path = line:match("^(.-)%s+(.+)$")
					if not name then
						name, path = line, ""
					end
					name = vim.trim(name)
					path = vim.trim(path or "")
					if name == "" then
						return
					end
					if path == "" then
						path = find_session_path(name) or state.get_session_path(name) or ""
					end
					local folders = vim.tbl_keys(M.projects)
					table.sort(folders)
					local choices = { "(new folder)" }
					vim.list_extend(choices, folders)
					vim.ui.select(choices, { prompt = "Save '" .. name .. "' to palette folder" }, function(choice)
						if not choice then
							return
						end
						local target = choice
						if choice == "(new folder)" then
							target = vim.trim(vim.fn.input("Palette folder: "))
						end
						if target == "" then
							return
						end
						M.projects[target] = M.projects[target] or {}
						for _, entry in ipairs(M.projects[target]) do
							if entry.name == name then
								entry.path = path
								M.save_store()
								vim.notify("tmux: updated " .. name .. " in " .. target, vim.log.levels.INFO)
								return
							end
						end
						table.insert(M.projects[target], { name = name, path = path })
						M.save_store()
						vim.notify("tmux: saved " .. name .. " to " .. target, vim.log.levels.INFO)
					end)
				end, { buffer = buf, nowait = true, noremap = true, desc = "Save to palette" })

				vim.keymap.set("n", "<C-W>", function()
					commit(prefix, vim.api.nvim_buf_get_lines(buf, 0, -1, false), true)
					save_workspace()
				end, { buffer = buf, nowait = true, noremap = true, desc = "Save workspace" })
			end,
		})
	end

	-- All sessions debug ---------------------------------------------------
	vim.keymap.set("n", "<leader>tS", function()
		if not state.in_tmux() then
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
				state.tmux("switch-client -t " .. vim.fn.shellescape(entry))
			end,
			on_save = function() end,
		})
	end, { desc = "Tmux: all sessions (debug)" })

	-- Rename ---------------------------------------------------------------
	vim.keymap.set("n", "<leader>tr", function()
		if not state.in_tmux() then
			return
		end
		local current = vim.trim(vim.fn.system("tmux display-message -p '#S'"))
		local name = vim.fn.input("Rename session [" .. current .. "]: ")
		if name and name ~= "" then
			state.tmux("rename-session " .. vim.fn.shellescape(name))
			local slots = M.load_order()
			for i, slot in ipairs(slots) do
				if slot == current then
					slots[i] = name
					break
				end
			end
			M.save_order(slots)
			for _, entries in pairs(M.projects) do
				for _, entry in ipairs(entries) do
					if entry.name == current then
						entry.name = name
					end
				end
			end
			for _, workspace in pairs(M.workspaces) do
				for _, session in ipairs(workspace.sessions or {}) do
					if session.name == current then
						session.name = name
					end
				end
			end
			M.save_store()
			browser.invalidate_live()
			vim.notify("Session renamed to: " .. name)
		end
	end, { desc = "Tmux rename session" })

	-- Splits ---------------------------------------------------------------
	vim.keymap.set("n", "<leader>t|", function()
		if not state.in_tmux() then
			return
		end
		state.tmux("split-window -h -c " .. vim.fn.shellescape(vim.fn.getcwd()))
	end, { desc = "Tmux vertical split" })
	vim.keymap.set("n", "<leader>t-", function()
		if not state.in_tmux() then
			return
		end
		state.tmux("split-window -v -c " .. vim.fn.shellescape(vim.fn.getcwd()))
	end, { desc = "Tmux horizontal split" })

	-- Join / Break ---------------------------------------------------------
	vim.keymap.set("n", "<leader>ta", function()
		if not state.in_tmux() then
			return
		end
		scratchbuf.open({
			title = "Join pane from session",
			lines = state.ordered_sessions(M.get_show_hidden()),
			refresh = function()
				return state.ordered_sessions(M.get_show_hidden())
			end,
			on_open = function(entry)
				state.tmux("join-pane -h -s " .. vim.fn.shellescape(entry) .. ":.")
			end,
			on_save = function() end,
		})
	end, { desc = "Tmux: join pane from session" })
	vim.keymap.set("n", "<leader>tb", function()
		if not state.in_tmux() then
			return
		end
		state.tmux("break-pane -d -s !")
	end, { desc = "Tmux: break pane back to session" })

	-- Kill all -------------------------------------------------------------
	vim.keymap.set("n", "<leader>tT", function()
		if not state.in_tmux() then
			return
		end
		local confirm = vim.fn.input("Kill ALL tmux sessions? (y/N): ")
		if confirm == "y" or confirm == "Y" then
			state.tmux("kill-server")
			vim.notify("tmux: all sessions killed", vim.log.levels.INFO)
		end
	end, { desc = "Tmux: kill all sessions" })
end

return M_sub
