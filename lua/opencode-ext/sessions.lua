-- /home/jmeyer/.config/nvim/lua/opencode-ext/sessions.lua FINAL-5
-- Manages OpenCode in dedicated tmux sessions.

local M = {}
local OC_PREFIX = "opencode-"
local MAIN_SESSION_FILE = vim.fn.stdpath("config") .. "/.opencode-main-session"

local function in_tmux()
	return vim.env.TMUX ~= nil
end

local function tmux(cmd)
	return vim.fn.system("tmux " .. cmd)
end

local function project_key()
	local cwd = vim.fn.getcwd()
	local parts = {}
	for part in cwd:gmatch("[^/]+") do
		table.insert(parts, part)
	end
	local key = (#parts >= 2 and parts[#parts - 1] .. "-" .. parts[#parts] or parts[#parts] or "unknown")
	return key:gsub("[%.%:]", "_")
end

local function session_name()
	return OC_PREFIX .. project_key()
end

local function session_exists(name)
	vim.fn.system("tmux has-session -t=" .. vim.fn.shellescape(name) .. " 2>/dev/null")
	return vim.v.shell_error == 0
end

local function find_oc_buf()
	local bufname = "opencode-term-" .. project_key()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):find(bufname, 1, true) then
			return buf
		end
	end
	return nil
end

local function protect_opencode_buf(buf)
	vim.keymap.set("n", "<C-c>", "<Nop>", { buffer = buf, noremap = true, silent = true })
	vim.keymap.set("t", "<C-c>", "<C-\\><C-c>", { buffer = buf, noremap = true })
end

local function open_oc_buffer()
	local name = session_name()
	local bufname = "opencode-term-" .. project_key()
	vim.cmd("vsplit")
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(0, buf)
	vim.fn.termopen("tmux attach-session -t " .. vim.fn.shellescape(name), {
		on_exit = function()
			if vim.api.nvim_buf_is_valid(buf) then
				vim.api.nvim_buf_delete(buf, { force = true })
			end
		end,
	})
	vim.api.nvim_buf_set_name(buf, bufname)
	vim.bo[buf].bufhidden = "hide"
	protect_opencode_buf(buf)
	vim.cmd("startinsert")
end

local function close_oc_buffer()
	local buf = find_oc_buf()
	if not buf then
		return false
	end
	local wins = vim.fn.win_findbuf(buf)
	local was_open = #wins > 0
	if was_open then
		for _, win in ipairs(wins) do
			vim.api.nvim_win_close(win, true)
		end
	end
	return was_open
end

--- Persisted main session (3-line format: name, dir, db_sid) ---------------

local function get_main_session()
	local f = io.open(MAIN_SESSION_FILE, "r")
	if not f then
		return nil, nil, nil
	end
	local name = f:read("*l")
	local path = f:read("*l")
	local sid = f:read("*l")
	f:close()
	name = name and name ~= "" and name or nil
	path = path and path ~= "" and path or nil
	sid = sid and sid ~= "" and sid or nil
	return name, path, sid
end

local function set_main_session(name, path, sid)
	local f = io.open(MAIN_SESSION_FILE, "w")
	if f then
		f:write((name or "") .. "\n")
		f:write((path or "") .. "\n")
		f:write((sid or "") .. "\n")
		f:close()
	end
end

local function list_oc_sessions()
	local out = vim.fn.systemlist("tmux list-sessions -F '#S' 2>/dev/null")
	local oc = {}
	for _, s in ipairs(out or {}) do
		if s:match("^" .. OC_PREFIX) then
			oc[#oc + 1] = s
		end
	end
	return oc
end

local function session_preview_lines(name)
	local _, windows = pcall(vim.fn.systemlist, { "tmux", "list-windows", "-F", "#W", "-t", name })
	local lines = { "Session: " .. name, "Windows:", "" }
	if _ and vim.v.shell_error == 0 then
		for _, w in ipairs(windows or {}) do
			lines[#lines + 1] = "  " .. w
		end
	end
	local _, pane = pcall(vim.fn.system, { "tmux", "capture-pane", "-t", name .. ":1", "-p", "-S", "-20" })
	if _ and vim.v.shell_error == 0 and pane and pane ~= "" then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "--- Last output ---"
		for _, l in ipairs(vim.split(pane, "\n", { plain = true })) do
			lines[#lines + 1] = l
		end
	end
	return lines
end

--- <leader>oo -- start/toggle ---------------------------------------------

vim.keymap.set("n", "<leader>oo", function()
	if not in_tmux() then
		vim.notify("opencode: not in tmux", vim.log.levels.WARN)
		return
	end

	local cwd = vim.fn.getcwd()
	local name = session_name()
	local tmux_dir = vim.fn.systemlist("tmux display-message -p '#{pane_current_path}' 2>/dev/null") or {}
	local pane_dir = vim.trim(tmux_dir[1] or "?")
	vim.notify("[oo] nvim_cwd=" .. cwd .. " tmux_pane=" .. pane_dir .. " session=" .. name, vim.log.levels.INFO)

	if not session_exists(name) then
		tmux("new-session -ds " .. vim.fn.shellescape(name) .. " -c " .. vim.fn.shellescape(cwd) .. " 'opencode'")
		vim.notify("opencode: started [" .. name .. "]")

		vim.defer_fn(function()
			local db = require("opencode-ext.db")
			local raw = db.fetch_by_worktree(cwd)
			vim.notify(
				"[oo] auto-reassign check: fetch_by_worktree(" .. cwd .. ") sid=" .. (raw and raw.sid or "nil"),
				vim.log.levels.INFO
			)
			if raw and raw.sid and raw.sid ~= vim.NIL then
				vim.notify("[oo] project already exists for " .. cwd .. " — no reassign needed", vim.log.levels.INFO)
				return
			end
			local sessions = db.fetch_sessions()
			if not sessions or #sessions == 0 then
				vim.notify("[oo] no sessions in DB, can't auto-reassign", vim.log.levels.INFO)
				return
			end
			local newest = sessions[1]
			if not newest or newest.time_updated < (os.time() - 10) * 1000 then
				vim.notify(
					"[oo] newest session too old (" .. (newest and newest.id or "nil") .. "), skipping reassign",
					vim.log.levels.INFO
				)
				return
			end
			local project = newest.project or ""
			vim.notify(
				"[oo] newest session: id=" .. newest.id .. " project=" .. project .. " cwd=" .. cwd,
				vim.log.levels.INFO
			)
			if project ~= cwd then
				local ok, err = db.reassign_session(newest.id, cwd)
				if ok then
					vim.notify("[oo] auto-reassigned " .. newest.id .. " to " .. cwd, vim.log.levels.INFO)
				else
					vim.notify("[oo] auto-reassign skipped: " .. (err or ""), vim.log.levels.INFO)
				end
			end
		end, 2000)
	end

	local existing_buf = find_oc_buf()
	if existing_buf and vim.api.nvim_buf_is_valid(existing_buf) then
		local wins = vim.fn.win_findbuf(existing_buf)
		if #wins > 0 then
			for _, win in ipairs(wins) do
				vim.api.nvim_win_close(win, true)
			end
		else
			vim.cmd("vsplit")
			vim.api.nvim_win_set_buf(0, existing_buf)
			vim.cmd("startinsert")
		end
	else
		open_oc_buffer()
	end
end, { desc = "OpenCode: start/toggle" })

--- <leader>or -- restart ---------------------------------------------------

vim.keymap.set("n", "<leader>or", function()
	if not in_tmux() then
		return
	end
	local name = session_name()
	if not session_exists(name) then
		vim.notify("opencode: no session for this project", vim.log.levels.WARN)
		return
	end
	close_oc_buffer()
	local buf = find_oc_buf()
	if buf and vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_delete(buf, { force = true })
	end
	tmux("kill-session -t " .. vim.fn.shellescape(name))
	local cwd = vim.fn.shellescape(vim.fn.getcwd())
	tmux("new-session -ds " .. vim.fn.shellescape(name) .. " -c " .. cwd .. " 'opencode'")
	vim.notify("opencode: restarted [" .. name .. "]")
	vim.defer_fn(function()
		open_oc_buffer()
	end, 500)
end, { desc = "OpenCode: restart" })

--- <leader>oq -- kill ------------------------------------------------------

vim.keymap.set("n", "<leader>oq", function()
	if not in_tmux() then
		return
	end
	local name = session_name()
	if not session_exists(name) then
		vim.notify("opencode: no session for this project", vim.log.levels.WARN)
		return
	end
	close_oc_buffer()
	local buf = find_oc_buf()
	if buf and vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_delete(buf, { force = true })
	end
	tmux("kill-session -t " .. vim.fn.shellescape(name))
	vim.notify("opencode: killed [" .. name .. "]")
end, { desc = "OpenCode: kill" })

--- <leader>os -- pick main session -----------------------------------------

vim.keymap.set("n", "<leader>os", function()
	if not in_tmux() then
		vim.notify("opencode: not in tmux", vim.log.levels.WARN)
		return
	end
	local sessions = list_oc_sessions()
	if #sessions == 0 then
		vim.notify("opencode: no sessions found", vim.log.levels.WARN)
		return
	end
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local state = require("telescope.actions.state")
	local previewers = require("telescope.previewers")
	local items = {}
	for _, s in ipairs(sessions) do
		local project = s:gsub("^opencode%-", ""):gsub("%-", "/")
		items[#items + 1] = { name = s, display = s .. "  (" .. project .. ")", ordinal = s }
	end
	pickers
		.new({}, {
			prompt_title = "Set main opencode session",
			finder = finders.new_table({
				results = items,
				entry_maker = function(i)
					return { value = i, display = i.display, ordinal = i.ordinal }
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = previewers.new_buffer_previewer({
				define_preview = function(self, entry)
					local l = session_preview_lines(entry.value.name)
					pcall(vim.api.nvim_buf_set_lines, self.state.bufnr, 0, -1, false, l)
				end,
			}),
			attach_mappings = function(pb)
				actions.select_default:replace(function()
					local sel = state.get_selected_entry()
					actions.close(pb)
					if sel then
						local name = sel.value.name
						local dir_result =
							vim.fn.systemlist({ "tmux", "list-windows", "-F", "#{pane_current_path}", "-t", name })
						local dir = nil
						if vim.v.shell_error == 0 and #dir_result > 0 then
							dir = dir_result[1]
						end
						local db = require("opencode-ext.db")
						local raw = dir and db.fetch_all(dir)
						local sid = raw and raw.sid and raw.sid ~= vim.NIL and raw.sid or nil
						set_main_session(name, dir, sid)
						vim.notify(
							"opencode: main -> [" .. name .. "]" .. (sid and "" or " (no DB session)"),
							vim.log.levels.INFO
						)
					end
				end)
				return true
			end,
		})
		:find()
end, { desc = "OpenCode: set main session" })

--- <leader>om -- toggle main session ---------------------------------------

vim.keymap.set("n", "<leader>om", function()
	if not in_tmux() then
		vim.notify("opencode: not in tmux", vim.log.levels.WARN)
		return
	end
	local name = get_main_session()
	if not name then
		vim.notify("opencode: no main session set (<leader>os to pick)", vim.log.levels.WARN)
		return
	end
	if not session_exists(name) then
		vim.notify("opencode: main session '" .. name .. "' no longer exists", vim.log.levels.WARN)
		return
	end
	local bufname = "opencode-main-term"
	local existing_buf = nil
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):find(bufname, 1, true) then
			existing_buf = buf
			break
		end
	end
	if existing_buf and vim.api.nvim_buf_is_valid(existing_buf) then
		local wins = vim.fn.win_findbuf(existing_buf)
		if #wins > 0 then
			for _, win in ipairs(wins) do
				vim.api.nvim_win_close(win, true)
			end
		else
			vim.cmd("vsplit")
			vim.api.nvim_win_set_buf(0, existing_buf)
			vim.cmd("startinsert")
		end
	else
		vim.cmd("vsplit")
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_win_set_buf(0, buf)
		vim.fn.termopen("tmux attach-session -t " .. vim.fn.shellescape(name), {
			on_exit = function()
				if vim.api.nvim_buf_is_valid(buf) then
					vim.api.nvim_buf_delete(buf, { force = true })
				end
			end,
		})
		vim.api.nvim_buf_set_name(buf, bufname)
		vim.bo[buf].bufhidden = "hide"
		protect_opencode_buf(buf)
		vim.cmd("startinsert")
		vim.notify("opencode: attached [" .. name .. "]", vim.log.levels.INFO)
	end
end, { desc = "OpenCode: toggle main session" })

--- <leader>am -- open code block picker for main session -------------------

vim.keymap.set("n", "<leader>am", function()
	if not in_tmux() then
		vim.notify("opencode: not in tmux", vim.log.levels.WARN)
		return
	end
	local name, dir, sid = get_main_session()
	if not name then
		vim.notify("opencode: no main session set (<leader>os to pick)", vim.log.levels.WARN)
		return
	end
	if sid then
		local ok = require("opencode-ext.viewer").open_by_id(sid, dir)
		if ok then
			return
		end
	end
	if session_exists(name) then
		local dir_result = vim.fn.systemlist({ "tmux", "list-windows", "-F", "#{pane_current_path}", "-t", name })
		if vim.v.shell_error == 0 and #dir_result > 0 then
			dir = dir_result[1]
		end
	end
	if not dir then
		vim.notify("opencode: main session '" .. name .. "' not found", vim.log.levels.WARN)
		return
	end
	require("opencode-ext.viewer").toggle_for_dir(dir)
end, { desc = "OpenCode: main session picker" })

return M
