-- opencode-viewer.lua
-- Conversation viewer for opencode sessions.
-- Reads directly from the opencode SQLite database — no /export needed.
--
-- Keymaps (buffer-local):
--   <CR>    toggle fold (za)
--   y       yank current turn content
--   Y       yank content with session header
--   o       open filepath under cursor
--   /       filter turns by content (space-separated terms match all)
--   r       refresh from database
--   q       close viewer
--   <Esc>   clear active filter
--   ?       show help
--
-- Keymap (global):
--   <leader>ae   toggle viewer open/closed

local M = {}

-- ── Constants ──────────────────────────────────────────────────────────────────

local DB_PATH = vim.fn.expand("~/.local/share/opencode/opencode.db")
local MARKER_PATTERN = "^───%[%d+%]── "

-- ── Database helpers ───────────────────────────────────────────────────────────

---Run a read-only query against the opencode SQLite database.
---Returns the decoded JSON array, or nil + error string on failure.
local function db_query(sql)
	-- Sanitize: escape single quotes to prevent injection from session IDs
	-- (sqlite3 handles this with single-quote doubling)
	local ok, result = pcall(vim.fn.system, { "sqlite3", "-json", "-readonly", DB_PATH, sql })
	if not ok then
		return nil, "Failed to run sqlite3: " .. tostring(result)
	end
	if vim.v.shell_error ~= 0 then
		local err = (type(result) == "string" and result or "sqlite3 exit code " .. vim.v.shell_error)
		return nil, err
	end
	if type(result) ~= "string" or result == "" then
		return nil, "Empty result"
	end
	local ok2, decoded = pcall(vim.fn.json_decode, result)
	if not ok2 then
		return nil, "Failed to parse database output"
	end
	return decoded
end

---Escape a string literal for use in SQL.
local function esc(val)
	return (val:gsub("'", "''"))
end

-- ── Data model ─────────────────────────────────────────────────────────────────

---Fetch all sessions from the database, newest first.
---@return table[]|nil { id, title, directory, time_updated }
local function get_sessions()
	return db_query([[
    SELECT id, title, directory, time_updated
    FROM session
    WHERE time_archived IS NULL
    ORDER BY time_updated DESC
  ]])
end

---Fetch messages for a session (ordered oldest-first).
---@param session_id string
---@return table[]|nil { id, time_created, data }
local function get_messages(session_id)
	return db_query(string.format(
		[[
    SELECT id, time_created, data
    FROM message
    WHERE session_id = '%s'
    ORDER BY time_created ASC
  ]],
		esc(session_id)
	))
end

---Fetch parts for a session (ordered by message then part position).
---@param session_id string
---@return table[]|nil { message_id, id, data }
local function get_parts(session_id)
	return db_query(string.format(
		[[
    SELECT message_id, id, data
    FROM part
    WHERE session_id = '%s'
    ORDER BY message_id ASC, id ASC
  ]],
		esc(session_id)
	))
end

-- ── Turn builder ───────────────────────────────────────────────────────────────

local function build_turns_from_db(messages, parts)
	-- Index parts by message_id
	local parts_by_msg = {}
	for _, p in ipairs(parts or {}) do
		local ok, decoded = pcall(vim.fn.json_decode, p.data)
		if ok then
			parts_by_msg[p.message_id] = parts_by_msg[p.message_id] or {}
			table.insert(parts_by_msg[p.message_id], decoded)
		end
	end

	local turns = {}
	for _, msg in ipairs(messages or {}) do
		local ok, data = pcall(vim.fn.json_decode, msg.data)
		if not ok then
			goto continue
		end

		local role = data.role -- "user" | "assistant"
		if role ~= "user" and role ~= "assistant" then
			goto continue
		end
		local speaker = (role == "user") and "User" or "Assistant"

		local msg_parts = parts_by_msg[msg.id] or {}
		local lines = {}

		for _, part in ipairs(msg_parts) do
			if part.type == "text" and part.text and part.text ~= "" then
				-- Ignore synthetic separator text
				if not part.synthetic then
					-- Split multi-line text into individual lines
					for _, text_line in ipairs(vim.split(part.text, "\n", { plain = true })) do
						table.insert(lines, text_line)
					end
				end
			elseif part.type == "reasoning" and part.text and part.text ~= "" then
				table.insert(lines, "_Thinking:_")
				for _, rl in ipairs(vim.split(part.text, "\n", { plain = true })) do
					table.insert(lines, rl)
				end
			elseif part.type == "tool" then
				local tool_name = part.tool or "unknown"
				table.insert(lines, "**Tool: " .. tool_name .. "**")
				if part.state and part.state.status == "completed" and part.state.output then
					table.insert(lines, "```")
					for _, ol in ipairs(vim.split(part.state.output, "\n", { plain = true })) do
						table.insert(lines, ol)
					end
					table.insert(lines, "```")
				elseif part.state and part.state.status == "error" then
					table.insert(lines, "> Error: " .. (part.state.error or "unknown"))
				elseif part.state and part.state.status == "running" then
					table.insert(lines, "_(running…)_")
				elseif part.state and part.state.status == "pending" then
					table.insert(lines, "_(pending)_")
				end
			elseif part.type == "subtask" then
				table.insert(lines, "**Subtask: " .. (part.description or part.prompt or "") .. "**")
			elseif part.type == "file" then
				table.insert(lines, "_[File: " .. (part.filename or "attachment") .. " (" .. (part.mime or "") .. ")]_")
			end
		end

		-- Skip empty turns (e.g. assistant messages with only tool calls that had no text)
		if #lines == 0 then
			goto continue
		end

		local label = ""
		for _, l in ipairs(lines) do
			local t = vim.trim(l)
			if t ~= "" then
				label = t:sub(1, 70)
				break
			end
		end

		table.insert(turns, {
			speaker = speaker,
			label = label,
			lines = lines,
			raw = table.concat(lines, "\n"),
		})

		::continue::
	end

	return turns
end

-- ── Buffer construction ────────────────────────────────────────────────────────
-- Each turn becomes a fold. The fold summary line is:
--   ───[N]── <speaker>: <first meaningful line>

local function build_lines(turns, session_label)
	local lines = {}
	local fold_starts = {}

	-- Header
	local header = string.format("Opencode Viewer — %d turns", #turns)
	if session_label and session_label ~= "" then
		header = header .. "  |  " .. session_label
	end
	table.insert(lines, header)
	table.insert(lines, string.rep("═", 60))
	table.insert(lines, "")

	-- Turns
	for i, turn in ipairs(turns) do
		local speaker_icon = (turn.speaker == "User") and "User" or "Asst"
		local summary = string.format("───[%d]── %s: %s", i, speaker_icon, turn.label)
		table.insert(fold_starts, #lines + 1)
		table.insert(lines, summary)
		for _, cl in ipairs(turn.lines) do
			table.insert(lines, "  " .. cl)
		end
		table.insert(lines, "")
	end

	-- Footer
	table.insert(lines, "")
	table.insert(lines, string.rep("─", 60))
	table.insert(lines, "<CR>=toggle  y=yank  Y=yank+path  o=open file  /=filter  r=refresh  q=close  ?=help")

	return lines, fold_starts
end

-- ── State ──────────────────────────────────────────────────────────────────────

local viewer_buf = nil
local viewer_win = nil
local current_turns = nil
local current_session_label = ""
local current_filter = ""

-- ── Turn lookup ────────────────────────────────────────────────────────────────

local function find_turn_at(lnum)
	local foldstart
	for l = lnum, 1, -1 do
		if vim.fn.getline(l):match(MARKER_PATTERN) then
			foldstart = l
			break
		end
	end
	if not foldstart then
		return nil
	end

	local idx = tonumber(vim.fn.getline(foldstart):match("───%[(%d+)%]──"))
	if not idx or idx < 1 or idx > #current_turns then
		return nil
	end
	local turn = current_turns[idx]

	local foldend = vim.fn.line("$")
	for l = foldstart + 1, vim.fn.line("$") do
		if vim.fn.getline(l):match(MARKER_PATTERN) then
			foldend = l - 1
			break
		end
	end

	local content_lines = {}
	for l = foldstart + 1, foldend do
		local text = vim.fn.getline(l):gsub("^  ", "")
		table.insert(content_lines, text)
	end
	while #content_lines > 0 and content_lines[#content_lines] == "" do
		table.remove(content_lines)
	end

	return {
		content = table.concat(content_lines, "\n"),
		idx = idx,
		turn = turn,
		foldstart = foldstart,
		foldend = foldend,
	}
end

-- ── File path detection ────────────────────────────────────────────────────────

local function find_filepath_on_line(lnum)
	local line = vim.fn.getline(lnum)
	if not line or line == "" then
		return nil
	end

	for fp in line:gmatch("([%w_%-/%.]+%.%w+)") do
		if not fp:match("^%d+%.%w+$") and not fp:match("^[%w_]+%.%w+$") then
			if vim.fn.filereadable(fp) == 1 then
				return fp, nil
			end
			local cwd_path = vim.fn.getcwd() .. "/" .. fp
			if vim.fn.filereadable(cwd_path) == 1 then
				return cwd_path, nil
			end
			if fp:match("^lua/") or fp:match("^after/") or fp:match("^plugin/") then
				local config_path = vim.fn.stdpath("config") .. "/" .. fp
				if vim.fn.filereadable(config_path) == 1 then
					return config_path, nil
				end
			end
		end
	end

	for fp, lnum_str in line:gmatch("([%w_%-/%.]+%.%w+)[:#](%d+)") do
		return fp, tonumber(lnum_str)
	end

	return nil, nil
end

-- ── Yank actions ───────────────────────────────────────────────────────────────

local function yank_current()
	local info = find_turn_at(vim.fn.line("."))
	if not info then
		vim.notify("No turn at cursor", vim.log.levels.WARN)
		return
	end
	local content = info.content
	if content == "" then
		vim.notify("Turn is empty", vim.log.levels.WARN)
		return
	end
	vim.fn.setreg("+", content)
	vim.fn.setreg('"', content)
	vim.notify("Yanked turn " .. info.idx .. " (" .. #vim.split(content, "\n") .. " lines)", vim.log.levels.INFO)
end

local function yank_current_with_header()
	local info = find_turn_at(vim.fn.line("."))
	if not info then
		vim.notify("No turn at cursor", vim.log.levels.WARN)
		return
	end
	local summary = vim.fn.getline(info.foldstart):gsub("^───%[%d+%]── ", "")
	local header = "-- " .. summary .. "\n"
	local content = info.content
	if content == "" then
		vim.notify("Turn is empty", vim.log.levels.WARN)
		return
	end
	vim.fn.setreg("+", header .. content)
	vim.fn.setreg('"', header .. content)
	vim.notify("Yanked turn " .. info.idx .. " with header", vim.log.levels.INFO)
end

-- ── Open file under cursor ─────────────────────────────────────────────────────

local function open_file_at_cursor()
	local lnum = vim.fn.line(".")
	local fp, lnum_ref = find_filepath_on_line(lnum)

	if not fp then
		local line = vim.fn.getline(lnum)
		for match in line:gmatch("([%w_%-/%.]+%.%w+)") do
			if not match:match("%.com$") and not match:match("%.org$") then
				local abs = vim.fn.getcwd() .. "/" .. match
				if vim.fn.filereadable(abs) == 1 then
					fp = abs
					break
				end
				local config_abs = vim.fn.stdpath("config") .. "/" .. match
				if vim.fn.filereadable(config_abs) == 1 then
					fp = config_abs
					break
				end
			end
		end
	end

	if not fp then
		vim.notify("No filepath found on this line", vim.log.levels.WARN)
		return
	end

	vim.cmd("edit " .. vim.fn.fnameescape(fp))
	if lnum_ref then
		pcall(function()
			vim.api.nvim_win_set_cursor(0, { lnum_ref, 0 })
			vim.cmd("normal! zz")
		end)
	end
	vim.notify("Opened " .. vim.fn.fnamemodify(fp, ":~:."), vim.log.levels.INFO)
end

-- ── Filter ─────────────────────────────────────────────────────────────────────

local function update_header()
	local total = #(current_turns or {})
	local base = string.format("Opencode Viewer — %d turns", total)
	if current_session_label ~= "" then
		base = base .. "  |  " .. current_session_label
	end
	if current_filter ~= "" then
		local open = 0
		for l = 1, vim.fn.line("$") do
			if vim.fn.getline(l):match(MARKER_PATTERN) and vim.fn.foldclosed(l) == -1 then
				open = open + 1
			end
		end
		base = base .. string.format(" [%d/%d match: %s]", open, total, current_filter)
	end
	if viewer_buf and vim.api.nvim_buf_is_valid(viewer_buf) then
		vim.api.nvim_buf_set_lines(viewer_buf, 0, 1, false, { base })
	end
end

local function apply_filter(filter_text)
	current_filter = vim.trim(filter_text)
	vim.cmd("normal! zM")

	if current_filter == "" then
		update_header()
		return
	end

	local terms = vim.split(current_filter:lower(), "%s+")

	for l = 1, vim.fn.line("$") do
		if not vim.fn.getline(l):match(MARKER_PATTERN) then
			goto continue
		end

		local combined = vim.fn.getline(l):lower()
		for l2 = l + 1, vim.fn.line("$") do
			if vim.fn.getline(l2):match(MARKER_PATTERN) then
				break
			end
			combined = combined .. " " .. vim.fn.getline(l2):lower()
		end

		local all_match = true
		for _, term in ipairs(terms) do
			if not combined:find(term, 1, true) then
				all_match = false
				break
			end
		end

		if all_match and viewer_win and vim.api.nvim_win_is_valid(viewer_win) then
			vim.api.nvim_win_set_cursor(viewer_win, { l, 0 })
			vim.cmd("normal! zo")
		end

		::continue::
	end

	update_header()
end

local function filter_prompt()
	vim.ui.input({
		prompt = "Filter turns: ",
		default = current_filter,
	}, function(input)
		if input == nil then
			return
		end
		apply_filter(input)
	end)
end

-- ── Fetch session data ─────────────────────────────────────────────────────────

local function fetch_current_session()
	-- Try sqlite3
	local ok_sqlite, sqlite_check = pcall(vim.fn.executable, "sqlite3")
	if not ok_sqlite or sqlite_check ~= 1 then
		return nil, "sqlite3 not found — install it to use the viewer"
	end

	local dbls = vim.fn.glob(DB_PATH, false, true)
	if #dbls == 0 then
		return nil, "No opencode database found at " .. DB_PATH .. " — is opencode running?"
	end

	local sessions = get_sessions()
	if not sessions or #sessions == 0 then
		return nil, "No sessions found in database — start an opencode conversation first"
	end

	-- Use the most recently updated session
	local session = sessions[1]
	local session_id = session.id
	local label = (session.title or session_id):sub(1, 50)

	local messages = get_messages(session_id)
	if not messages or #messages == 0 then
		return nil, 'Session "' .. label .. '" has no messages'
	end

	local parts = get_parts(session_id)
	if not parts then
		return nil, "Failed to load message parts"
	end

	local turns = build_turns_from_db(messages, parts)
	if #turns == 0 then
		return nil, 'No readable turns in session "' .. label .. '"'
	end

	return { turns = turns, label = label }
end

-- ── Refresh ────────────────────────────────────────────────────────────────────

local function refresh_viewer()
	if not viewer_buf or not vim.api.nvim_buf_is_valid(viewer_buf) then
		vim.notify("Viewer not open", vim.log.levels.WARN)
		return
	end

	local result, err = fetch_current_session()
	if not result then
		vim.notify(err, vim.log.levels.WARN)
		return
	end

	current_turns = result.turns
	current_session_label = result.label

	local lines, _ = build_lines(current_turns, current_session_label)
	vim.api.nvim_buf_set_lines(viewer_buf, 0, -1, false, lines)

	if current_filter ~= "" then
		apply_filter(current_filter)
	else
		vim.cmd("normal! zM")
		update_header()
	end

	-- Jump to first turn
	for l = 1, #lines do
		if lines[l]:match(MARKER_PATTERN) then
			if viewer_win and vim.api.nvim_win_is_valid(viewer_win) then
				vim.api.nvim_win_set_cursor(viewer_win, { l, 0 })
			end
			break
		end
	end

	vim.notify("Viewer refreshed — " .. #current_turns .. " turns", vim.log.levels.INFO)
end

-- ── Fold helpers (global so v:lua can reach them) ──────────────────────────────

_G.opencode_viewer_foldtext = function()
	local line = vim.fn.getline(vim.v.foldstart)
	local count = vim.v.foldend - vim.v.foldstart - 1
	if count < 0 then
		count = 0
	end
	local padding = string.rep(" ", math.max(1, 60 - #line))
	return " " .. line .. padding .. " [" .. count .. " lines]"
end

_G.opencode_viewer_foldexpr = function()
	return vim.fn.getline(vim.v.lnum):match(MARKER_PATTERN) and "1" or "="
end

-- ── Open / Toggle ─────────────────────────────────────────────────────────────

local function close_viewer()
	if viewer_win and vim.api.nvim_win_is_valid(viewer_win) then
		vim.api.nvim_win_close(viewer_win, true)
	end
	viewer_buf = nil
	viewer_win = nil
	current_turns = nil
	current_session_label = ""
	current_filter = ""
end

local function open_viewer()
	local result, err = fetch_current_session()
	if not result then
		vim.notify(err, vim.log.levels.WARN)
		return
	end

	current_turns = result.turns
	current_session_label = result.label

	local lines, fold_starts = build_lines(current_turns, current_session_label)

	-- Create scratch buffer
	viewer_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(viewer_buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_name(viewer_buf, "opencode-viewer")
	vim.bo[viewer_buf].buftype = "nofile"
	vim.bo[viewer_buf].bufhidden = "wipe"
	vim.bo[viewer_buf].modifiable = false
	vim.bo[viewer_buf].filetype = "opencode-viewer"

	-- Open vsplit
	vim.cmd("vsplit")
	viewer_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(viewer_win, viewer_buf)

	-- Window-local fold settings
	vim.wo[viewer_win].foldmethod = "expr"
	vim.wo[viewer_win].foldexpr = "v:lua.opencode_viewer_foldexpr()"
	vim.wo[viewer_win].foldtext = "v:lua.opencode_viewer_foldtext()"
	vim.wo[viewer_win].foldlevel = 0
	vim.wo[viewer_win].foldcolumn = "2"
	vim.wo[viewer_win].number = true
	vim.wo[viewer_win].numberwidth = 3
	vim.wo[viewer_win].spell = false
	vim.wo[viewer_win].list = false
	vim.wo[viewer_win].wrap = false

	-- Buffer-local keymaps
	local opts = { buffer = viewer_buf, noremap = true, silent = true }
	vim.keymap.set("n", "<CR>", "za", opts)
	vim.keymap.set("n", "y", yank_current, opts)
	vim.keymap.set("n", "Y", yank_current_with_header, opts)
	vim.keymap.set("n", "o", open_file_at_cursor, opts)
	vim.keymap.set("n", "/", filter_prompt, opts)
	vim.keymap.set("n", "r", refresh_viewer, opts)
	vim.keymap.set("n", "q", close_viewer, opts)
	vim.keymap.set("n", "<Esc>", function()
		if current_filter ~= "" then
			apply_filter("")
		end
	end, opts)
	vim.keymap.set("n", "?", function()
		vim.notify(
			"<CR>=toggle  y=yank  Y=yank+path  o=open file  /=filter  r=refresh  q=close  Esc=clear  ?=help",
			vim.log.levels.INFO
		)
	end, opts)

	-- Close all folds
	vim.cmd("normal! zM")

	-- Position at first turn
	if #fold_starts > 0 then
		vim.api.nvim_win_set_cursor(viewer_win, { fold_starts[1], 0 })
	end

	vim.notify("Opencode Viewer — " .. #current_turns .. " turns", vim.log.levels.INFO)
end

-- ── Keymap ─────────────────────────────────────────────────────────────────────

vim.keymap.set("n", "<leader>ae", function()
	if viewer_win and vim.api.nvim_win_is_valid(viewer_win) then
		close_viewer()
	else
		open_viewer()
	end
end, { desc = "Opencode: toggle session viewer" })

return M
