-- /home/jmeyer/.config/nvim/lua/tmux_projects/sessions.lua FINAL-2
-- Session-level operations: editor, slot switching, rename, splits, sessionizer, join/break.

local state = require("tmux_projects.state")
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
		-- /home/jmeyer/.config/nvim/lua/tmux_projects/sessions.lua:42 FINAL
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

	-- Session editor -------------------------------------------------------
	vim.keymap.set("n", "<leader>ts", function()
		if not state.in_tmux() then
			return
		end
		local current_session = vim.trim(vim.fn.system("tmux display-message -p '#S'"))
		local sessions = state.ordered_sessions(M.get_show_hidden())
		local original_sessions = vim.deepcopy(sessions)

		scratchbuf.open({
			title = "Tmux Sessions",
			lines = sessions,
			refresh = function()
				local fresh = state.ordered_sessions(M.get_show_hidden())
				original_sessions = vim.deepcopy(fresh)
				return fresh
			end,
			current = current_session,
			close_on_open = false,
			on_open = function(entry)
				local current = vim.trim(vim.fn.system("tmux display-message -p '#S'"))
				if entry ~= current then
					for _, w in ipairs(vim.api.nvim_list_wins()) do
						local b = vim.api.nvim_win_get_buf(w)
						if vim.b[b]._scratchbuf == "Tmux Sessions" then
							vim.api.nvim_buf_delete(b, { force = true })
							break
						end
					end
					state.tmux("switch-client -t " .. vim.fn.shellescape(entry))
				end
			end,
			on_save = function(changes)
				local current_lines = {}
				for _, s in ipairs(changes.order) do
					local t = vim.trim(s)
					if t ~= "" then
						table.insert(current_lines, t)
					end
				end

				local orig_counts, curr_counts = {}, {}
				for _, s in ipairs(original_sessions) do
					orig_counts[s] = (orig_counts[s] or 0) + 1
				end
				for _, s in ipairs(current_lines) do
					curr_counts[s] = (curr_counts[s] or 0) + 1
				end

				for name, count in pairs(curr_counts) do
					local orig_c = orig_counts[name] or 0
					if count > math.max(orig_c, 1) then
						vim.notify("tmux: duplicate session name '" .. name .. "' - save aborted", vim.log.levels.ERROR)
						return
					end
				end

				local deleted_set, deleted = {}, {}
				for _, s in ipairs(original_sessions) do
					if (curr_counts[s] or 0) < (orig_counts[s] or 0) and not deleted_set[s] then
						table.insert(deleted, s)
						deleted_set[s] = true
					end
				end

				local created_set, created = {}, {}
				for _, s in ipairs(current_lines) do
					if not created_set[s] then
						local orig_c = orig_counts[s] or 0
						local curr_c = curr_counts[s] or 0
						if curr_c > orig_c then
							table.insert(created, s)
							created_set[s] = true
						end
					end
				end

				local renamed = {}
				for i, orig in ipairs(original_sessions) do
					if deleted_set[orig] then
						local curr = current_lines[i]
						if curr and created_set[curr] then
							table.insert(renamed, { old = orig, new = curr })
							deleted_set[orig] = nil
							created_set[curr] = nil
						end
					end
				end

				local final_deleted = {}
				for s in pairs(deleted_set) do
					table.insert(final_deleted, s)
				end
				local final_created_list = {}
				for s in pairs(created_set) do
					table.insert(final_created_list, s)
				end

				-- Apply renames: update tmux session + matching group entries
				for _, r in ipairs(renamed) do
					state.tmux("rename-session -t " .. vim.fn.shellescape(r.old) .. " " .. vim.fn.shellescape(r.new))
					for _, entries in pairs(M.projects) do
						for _, e in ipairs(entries) do
							if e.name == r.old then
								e.name = r.new
							end
						end
					end
				end
				if #renamed > 0 then
					M.save_overrides()
				end

				-- Kill deleted sessions
				for _, d in ipairs(final_deleted) do
					local cur = vim.trim(vim.fn.system("tmux display-message -p '#S' 2>/dev/null"))
					if cur == d then
						state.switch_to_first_available(d)
					end
					state.tmux("kill-session -t " .. vim.fn.shellescape(d))
				end

				-- Rebuild slot order
				local rename_map = {}
				for _, r in ipairs(renamed) do
					rename_map[r.old] = r.new
				end
				local seen_order, final_order = {}, {}
				for _, s in ipairs(current_lines) do
					local mapped = rename_map[s] or s
					if not deleted_set[s] and not seen_order[mapped] then
						table.insert(final_order, mapped)
						seen_order[mapped] = true
					end
				end
				for _, c in ipairs(final_created_list) do
					if not seen_order[c] then
						table.insert(final_order, c)
						seen_order[c] = true
					end
				end
				M.save_order(final_order)
				original_sessions = vim.deepcopy(state.ordered_sessions(M.get_show_hidden()))

				-- Prompt for paths for new sessions — does NOT add to any group
				if #final_created_list > 0 then
					local creates_copy = vim.deepcopy(final_created_list)
					vim.schedule(function()
						local function process(i)
							if i > #creates_copy then
								return
							end
							local name = creates_copy[i]
							if name and name ~= "" then
								state.pick_directory(function(path)
									if path and path ~= "" then
										state.tmux(
											"new-session -ds "
												.. vim.fn.shellescape(name)
												.. " -c "
												.. vim.fn.shellescape(path)
										)
										vim.notify(
											"tmux: created session '" .. name .. "' at " .. path,
											vim.log.levels.INFO
										)
									end
									process(i + 1)
								end)
							else
								process(i + 1)
							end
						end
						process(1)
					end)
				end
			end,
			on_ready = function(buf, _win)
				local ns = vim.api.nvim_create_namespace("tmux_session_group_hints")
				local function render_hints()
					vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
					local lc = vim.api.nvim_buf_line_count(buf)
					vim.api.nvim_buf_set_extmark(buf, ns, math.max(lc - 1, 0), 0, {
						virt_lines = {
							{ { "  ", "Comment" } },
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
								{ "edit path  ", "Comment" },
								{ "  H ", "Title" },
								{ "toggle hidden", "Comment" },
							},
						},
						virt_lines_above = false,
					})
				end
				render_hints()
				vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
					buffer = buf,
					callback = render_hints,
				})

				vim.keymap.set("n", "H", function()
					M.set_show_hidden(not M.get_show_hidden())
					local fresh = state.ordered_sessions(M.get_show_hidden())
					original_sessions = vim.deepcopy(fresh)
					vim.api.nvim_buf_set_lines(buf, 0, -1, false, fresh)
					vim.bo[buf].modified = false
					vim.notify(
						"tmux: " .. (M.get_show_hidden() and "showing" or "hiding") .. " hidden sessions",
						vim.log.levels.INFO
					)
				end, { buffer = buf, nowait = true, noremap = true, desc = "Toggle hidden sessions" })

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
			for i, s in ipairs(slots) do
				if s == current then
					slots[i] = name
					break
				end
			end
			M.save_order(slots)
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
