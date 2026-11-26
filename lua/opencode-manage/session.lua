-- /home/jmeyer/.config/nvim/lua/opencode-manage/session.lua FINAL-5
-- Which session(s) is this console looking at?
--
-- Three records, each with a different trigger:
--   1. ~/.config/nvim/.opencode-last-session.json — written the instant a
--      session is picked (viewer.lua save_last_session). Freshest intent.
--   2. <tmp>/opencode-manage/panes/<tty>.json — written by the plugin on the
--      first tool call; exact, but stale until the model acts.
--   3. every store under ~/.local/share/opencode-manage/sessions/ — what exists.
--
-- They are UNIONED, never tried in order. A confident-but-wrong id used to hide
-- queues sitting right there, which is worse than showing a row from a session
-- you are not in: accepting a row acts on that row's own store.
local M = {}

--- Durable session store root: <data>/sessions/<session-id>/.
function M.store_root()
	return (vim.env.HOME or "") .. "/.local/share/opencode-manage/sessions"
end

local function pointer_dir()
	return (vim.env.TMPDIR or "/tmp") .. "/opencode-manage/panes"
end

local function decode_json(text)
	local ok, value = pcall(function()
		return vim.json.decode(text)
	end)
	if not ok then
		return nil
	end
	return value
end

--- Every readable pointer, newest first.
local function read_pointers()
	local out = {}
	for _, f in ipairs(vim.fn.glob(pointer_dir() .. "/*.json", false, true)) do
		local ok, lines = pcall(vim.fn.readfile, f)
		if ok and type(lines) == "table" then
			local ptr = decode_json(table.concat(lines, "\n"))
			if type(ptr) == "table" and type(ptr.session_id) == "string" then
				ptr._mtime = vim.fn.getftime(f)
				out[#out + 1] = ptr
			end
		end
	end
	table.sort(out, function(a, b)
		return a._mtime > b._mtime
	end)
	return out
end

--- The session the viewer last attached, for this nvim cwd.
local function last_pick(cwd)
	local path = vim.fn.stdpath("config") .. "/.opencode-last-session.json"
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok or type(lines) ~= "table" then
		return nil
	end
	local data = decode_json(table.concat(lines, "\n"))
	if type(data) ~= "table" then
		return nil
	end
	local id = data[cwd]
	if type(id) == "string" and id ~= "" then
		return id
	end
	return nil
end

--- The tmux session this nvim pane belongs to, or nil outside tmux.
local function tmux_session_name()
	local pane = vim.env.TMUX_PANE
	if not pane or pane == "" then
		return nil
	end
	local ok, out = pcall(vim.fn.system, {
		"tmux",
		"display-message",
		"-p",
		"-t",
		pane,
		"#{session_name}",
	})
	if not ok or vim.v.shell_error ~= 0 then
		return nil
	end
	local name = vim.trim(out or "")
	if name == "" then
		return nil
	end
	return name
end

--- tty -> tmux session map, built once per nvim run.
local pane_sessions
local function tty_to_tmux_session()
	if pane_sessions then
		return pane_sessions
	end
	pane_sessions = {}
	local ok, out = pcall(vim.fn.system, {
		"tmux",
		"list-panes",
		"-a",
		"-F",
		"#{session_name}\t#{pane_tty}",
	})
	if ok and vim.v.shell_error == 0 then
		for line in tostring(out):gmatch("[^\n]+") do
			local name, tty = line:match("^(.-)\t(.*)$")
			if name and tty then
				pane_sessions[tty] = name
			end
		end
	end
	return pane_sessions
end

--- Sessions whose TUI shares this pane's tmux session, newest first.
local function pointer_sessions()
	local mine = tmux_session_name()
	if not mine then
		return {}
	end
	local map = tty_to_tmux_session()
	local out = {}
	for _, ptr in ipairs(read_pointers()) do
		if ptr.tty and map[ptr.tty] == mine then
			out[#out + 1] = ptr.session_id
		end
	end
	return out
end

--- Session ids that have a store on disk.
local function stored_sessions()
	local out = {}
	for _, d in ipairs(vim.fn.glob(M.store_root() .. "/*", false, true)) do
		if vim.fn.isdirectory(d) == 1 then
			out[#out + 1] = vim.fn.fnamemodify(d, ":t")
		end
	end
	return out
end

--- Every session the console should read, deduped, freshest first:
--- the picked session, then this tmux session's TUIs, then everything stored.
--- @param legacy_dirs function|nil only consulted when nothing else exists
--- @return string[]
function M.session_ids(legacy_dirs)
	local ids, seen = {}, {}
	local function add(id)
		if type(id) == "string" and id ~= "" and not seen[id] then
			seen[id] = true
			ids[#ids + 1] = id
		end
	end

	add(last_pick(vim.fn.getcwd()))
	for _, id in ipairs(pointer_sessions()) do
		add(id)
	end
	for _, id in ipairs(stored_sessions()) do
		add(id)
	end

	if #ids > 0 then
		return ids
	end

	if type(legacy_dirs) == "function" then
		local best, best_mtime = nil, 0
		for d in pairs(legacy_dirs() or {}) do
			for _, f in ipairs(vim.fn.glob(d .. "/ses_*.jsonl", false, true)) do
				local mtime = vim.fn.getftime(f)
				if mtime > best_mtime then
					best_mtime = mtime
					best = f
				end
			end
		end
		if best then
			return { best:match("ses_[%w-]+") }
		end
	end

	return {}
end

--- The session the console treats as current. @return string|nil
function M.current_session(legacy_dirs)
	local ids = M.session_ids(legacy_dirs)
	return ids[1]
end

return M
