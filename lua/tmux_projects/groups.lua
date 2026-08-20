-- /home/jmeyer/.config/nvim/lua/tmux_projects/groups.lua FINAL-2
-- Group CRUD: add/remove sessions from project groups, edit session paths.

local state = require("tmux_projects.state")

local M_sub = {}

function M_sub.setup(M)
	function M.add_to_group(session_name, group_name)
		vim.schedule(function()
			local path = state.get_session_path(session_name)
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
			M.save_overrides()
			local expanded = vim.fn.expand(confirmed)
			state.tmux("new-session -ds " .. vim.fn.shellescape(session_name) .. " -c " .. vim.fn.shellescape(expanded))
			vim.notify("tmux: added " .. session_name .. " to " .. group_name, vim.log.levels.INFO)
			-- Refresh session editor if open
			for _, w in ipairs(vim.api.nvim_list_wins()) do
				local b = vim.api.nvim_win_get_buf(w)
				if vim.b[b]._scratchbuf == "Tmux Sessions" then
					local fresh = state.ordered_sessions(M.get_show_hidden())
					vim.api.nvim_buf_set_lines(b, 0, -1, false, fresh)
					vim.bo[b].modified = false
					break
				end
			end
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
		M.save_overrides()
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
		M.save_overrides()
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
			local prefill = stored_path ~= "" and stored_path or state.get_session_path(session_name)
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
				M.save_overrides()
			end
			vim.notify(
				"tmux: " .. session_name .. " path updated to " .. new_path .. " — restart session to apply",
				vim.log.levels.INFO
			)
		end)
	end
end

return M_sub
