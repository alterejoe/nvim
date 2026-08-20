-- /home/jmeyer/.config/nvim/lua/tmux_projects/projects.lua FINAL-2
-- Project-level operations: open, switch, recover, pick, group drill-down.

local state = require("tmux_projects.state")
local scratchbuf = require("scratchbuf")

local M_sub = {}

function M_sub.setup(M)
	local function create_session(s)
		local path = vim.fn.expand(s.path)
		local exists =
			vim.trim(vim.fn.system("tmux has-session -t=" .. vim.fn.shellescape(s.name) .. " 2>/dev/null; echo $?"))
		if exists ~= "0" then
			local cmd = "new-session -ds " .. vim.fn.shellescape(s.name) .. " -c " .. vim.fn.shellescape(path)
			if s.nvim ~= false and M.nvim then
				cmd = cmd .. " " .. vim.fn.shellescape("nvim .")
			end
			state.tmux(cmd)
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
		M.save_order(slots)
		M.set_active_project(name)
		state.tmux("switch-client -t " .. vim.fn.shellescape(proj[1].name))
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
		local active = M.get_active_project()
		if active and M.projects[active] then
			M.open_project(active)
		else
			vim.notify("tmux: no active project to recover", vim.log.levels.WARN)
		end
	end

	-- Group drill-down -----------------------------------------------------
	local function show_group_sessions(group_name)
		local proj = M.projects[group_name]
		if not proj then
			vim.notify("tmux: unknown project '" .. group_name .. "'", vim.log.levels.ERROR)
			return
		end

		local entries = {}
		local path_map = {}
		for _, s in ipairs(proj) do
			local e = { name = s.name, path = s.path }
			table.insert(entries, e)
			path_map[s.name] = s.path
		end
		for _, s in ipairs(M.default) do
			local e = { name = s.name, path = s.path, _default = true }
			table.insert(entries, e)
			path_map[s.name] = s.path
		end

		local live_sessions = vim.fn.systemlist("tmux list-sessions -F '#S' 2>/dev/null") or {}
		local hidden_ocs = {}
		for _, s in ipairs(live_sessions) do
			if s:find("^opencode%-") then
				local oc_tail = s:gsub("^opencode%-", "")
				for _, e in ipairs(entries) do
					local e_key = e.name:gsub("/", "-"):gsub("%.", "_")
					if oc_tail == e_key then
						table.insert(hidden_ocs, s)
						break
					end
				end
			end
		end

		local showing_hidden = false
		local function build_lines()
			local lines = {}
			for _, e in ipairs(entries) do
				table.insert(lines, e.name)
			end
			if showing_hidden then
				for _, h in ipairs(hidden_ocs) do
					table.insert(lines, h .. "  (opencode)")
				end
			end
			return lines
		end

		local current = vim.trim(vim.fn.system("tmux display-message -p '#S' 2>/dev/null"))

		scratchbuf.open({
			title = group_name .. " sessions",
			lines = build_lines(),
			current = current,
			refresh = function()
				local fresh = vim.fn.systemlist("tmux list-sessions -F '#S' 2>/dev/null") or {}
				hidden_ocs = {}
				for _, s in ipairs(fresh) do
					if s:find("^opencode%-") then
						local oc_tail = s:gsub("^opencode%-", "")
						for _, e in ipairs(entries) do
							local e_key = e.name:gsub("/", "-"):gsub("%.", "_")
							if oc_tail == e_key then
								table.insert(hidden_ocs, s)
								break
							end
						end
					end
				end
				return build_lines()
			end,
			on_open = function(name)
				local clean = name:gsub("%s*%(opencode%)$", "")
				local is_oc = false
				for _, h in ipairs(hidden_ocs) do
					if name == h .. "  (opencode)" then
						is_oc = true
						break
					end
				end
				if is_oc then
					state.tmux("switch-client -t " .. vim.fn.shellescape(clean))
					return
				end
				local path = path_map[clean]
				if not path then
					vim.notify("tmux: no path for '" .. clean .. "'", vim.log.levels.WARN)
					return
				end
				local exists = vim.trim(
					vim.fn.system("tmux has-session -t=" .. vim.fn.shellescape(clean) .. " 2>/dev/null; echo $?")
				)
				if exists ~= "0" then
					local expanded = vim.fn.expand(path)
					local cmd = "new-session -ds "
						.. vim.fn.shellescape(clean)
						.. " -c "
						-- FIXED: use expanded (already resolved) not raw path
						.. vim.fn.shellescape(expanded)
					if M.nvim then
						cmd = cmd .. " " .. vim.fn.shellescape("nvim .")
					end
					state.tmux(cmd)
					vim.notify("tmux: created session '" .. clean .. "'", vim.log.levels.INFO)
				end
				state.tmux("switch-client -t " .. vim.fn.shellescape(clean))
			end,
			-- FIXED: no rename detection. Simple path_map lookup.
			-- name in path_map → keep with existing path
			-- name NOT in path_map → new entry, needs path prompt
			on_save = function()
				local buf = vim.api.nvim_get_current_buf()
				local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
				local default_names = {}
				for _, d in ipairs(M.default) do
					default_names[d.name] = true
				end
				local new_entries = {}
				local needs_path = {}
				for _, raw in ipairs(lines) do
					local name = vim.trim(raw)
					if name == "" or name:find("%(opencode%)$") or default_names[name] then
						goto next_line
					end
					local path = path_map[name]
					if path then
						table.insert(new_entries, { name = name, path = path })
					else
						table.insert(new_entries, { name = name, path = "" })
						table.insert(needs_path, name)
					end
					::next_line::
				end
				if #new_entries == 0 then
					return
				end
				M.projects[group_name] = new_entries
				M.save_overrides()
				entries = {}
				path_map = {}
				for _, s in ipairs(new_entries) do
					table.insert(entries, { name = s.name, path = s.path })
					path_map[s.name] = s.path
				end
				for _, d in ipairs(M.default) do
					table.insert(entries, { name = d.name, path = d.path, _default = true })
				end
				vim.notify("tmux: saved '" .. group_name .. "' order", vim.log.levels.INFO)
				if #needs_path > 0 then
					vim.schedule(function()
						local function process(i)
							if i > #needs_path then
								return
							end
							local name = needs_path[i]
							state.pick_directory(function(path)
								if path and path ~= "" then
									for _, e in ipairs(M.projects[group_name] or {}) do
										if e.name == name then
											e.path = path
											break
										end
									end
									M.save_overrides()
									local expanded = vim.fn.expand(path)
									state.tmux(
										"new-session -ds "
											.. vim.fn.shellescape(name)
											.. " -c "
											.. vim.fn.shellescape(expanded)
									)
									vim.notify(
										"tmux: created session '" .. name .. "' at " .. path,
										vim.log.levels.INFO
									)
								end
								process(i + 1)
							end)
						end
						process(1)
					end)
				end
				return true
			end,
			on_ready = function(buf, _win)
				local ns = vim.api.nvim_create_namespace("tmux_drilldown_hints")
				local function render_hints()
					vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
					local lc = vim.api.nvim_buf_line_count(buf)
					vim.api.nvim_buf_set_extmark(buf, ns, math.max(lc - 1, 0), 0, {
						virt_lines = {
							{ { "  ", "Comment" } },
							{
								{ "<CR> ", "Title" },
								{ "select  ", "Comment" },
								{ "H ", "Title" },
								{ "opencode  ", "Comment" },
								{ "o ", "Title" },
								{ "new  ", "Comment" },
								{ "e ", "Title" },
								{ "path  ", "Comment" },
								{ "W ", "Title" },
								{ "save  ", "Comment" },
								{ "r ", "Title" },
								{ "refresh  ", "Comment" },
								{ "/ ", "Title" },
								{ "filter  ", "Comment" },
								{ "S ", "Title" },
								{ "switch  ", "Comment" },
								{ "Q ", "Title" },
								{ "close", "Comment" },
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
					if #hidden_ocs == 0 then
						vim.notify("tmux: no opencode sessions for this group", vim.log.levels.WARN)
						return
					end
					showing_hidden = not showing_hidden
					vim.api.nvim_buf_set_lines(buf, 0, -1, false, build_lines())
					vim.notify(
						"tmux: " .. (showing_hidden and "showing" or "hiding") .. " opencode sessions",
						vim.log.levels.INFO
					)
				end, { buffer = buf, nowait = true, noremap = true, desc = "Toggle opencode sessions" })

				vim.keymap.set("n", "e", function()
					local session = vim.trim(vim.api.nvim_get_current_line())
					if session == "" then
						return
					end
					local clean = session:gsub("%s*%(opencode%)$", "")
					M.edit_session(clean)
				end, { buffer = buf, nowait = true, noremap = true, desc = "Edit session path" })

				vim.keymap.set("n", "S", function()
					local line = vim.trim(vim.api.nvim_get_current_line())
					if line == "" then
						return
					end
					local clean = line:gsub("%s*%(opencode%)$", "")
					local path = path_map[clean]
					if not path then
						vim.notify("tmux: no path for '" .. clean .. "'", vim.log.levels.WARN)
						return
					end
					vim.schedule(function()
						if vim.api.nvim_buf_is_valid(buf) then
							vim.api.nvim_buf_delete(buf, { force = true })
						end
						M.switch_project(group_name)
					end)
				end, { buffer = buf, nowait = true, noremap = true, desc = "Switch project (kill old)" })
			end,
		})
	end

	-- Project picker -------------------------------------------------------
	function M.pick_project()
		if not state.in_tmux() then
			return
		end
		local names = M.project_order
		if #names == 0 then
			vim.notify("tmux: no projects defined", vim.log.levels.WARN)
			return
		end
		local active = M.get_active_project()
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
				show_group_sessions(entry)
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
				local plines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
				local default_parts = {}
				for _, s in ipairs(M.default) do
					local icon = live_set[s.name] and "*" or "-"
					table.insert(default_parts, icon .. " " .. s.name)
				end
				local default_str = #default_parts > 0 and ("  |  " .. table.concat(default_parts, "  ")) or ""
				for i, line in ipairs(plines) do
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
end

return M_sub
