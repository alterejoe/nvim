-- opencode-ext/viewer.lua
-- Conversation viewer for opencode sessions.
-- Reads directly from SQLite -- no /export needed.
--
-- Architecture:
--   Data layer: Two SQLite queries (sessions, then messages+parts joined)
--   State: Table stored in b:opencode_viewer (survives :luafile %)
--   Line map: Parallel array mapping buffer line -> {type, conv_idx, ...}
--   Debug: D toggle, time markers shown in notifications

local M = {}

-- == Config ======================================================================

local DB_PATH = vim.fn.expand("~/.local/share/opencode/opencode.db")
local verbose = false -- toggle with D key

-- == Debug helpers ===============================================================

local t0 = 0
local function timer(label)
	if not verbose then
		return
	end
	local now = vim.uv.hrtime()
	local dt = (now - t0) / 1e6 -- ms
	t0 = now
	if dt > 0 then
		vim.notify(string.format("[%.0fms] %s", dt, label), vim.log.levels.INFO)
	end
end

local function tick()
	t0 = vim.uv.hrtime()
end

-- == Highlight system ============================================================

local hl_ns = vim.api.nvim_create_namespace("opencode-viewer")

local function setup_highlights()
	local ok = pcall(function()
		vim.api.nvim_set_hl(0, "OU", { link = "Title" })
		vim.api.nvim_set_hl(0, "OCS", { link = "Special" })
		vim.api.nvim_set_hl(0, "OTS", { link = "Identifier" })
		vim.api.nvim_set_hl(0, "OS", { link = "Comment" })
		vim.api.nvim_set_hl(0, "OCT", { link = "Special" })
		vim.api.nvim_set_hl(0, "OCC", { link = "LineNr" })
		vim.api.nvim_set_hl(0, "OText", { link = "Normal" })
		vim.api.nvim_set_hl(0, "OT", { link = "Comment" })
		vim.api.nvim_set_hl(0, "OH", { link = "Statement" })
		vim.api.nvim_set_hl(0, "OSP", { link = "NonText" })
	end)
	if not ok then
		vim.api.nvim_set_hl(0, "OU", { fg = "#89b4fa", bold = true })
		vim.api.nvim_set_hl(0, "OCS", { fg = "#f9e2af" })
		vim.api.nvim_set_hl(0, "OTS", { fg = "#fab387" })
		vim.api.nvim_set_hl(0, "OS", { fg = "#6c7086" })
		vim.api.nvim_set_hl(0, "OCT", { fg = "#f9e2af" })
		vim.api.nvim_set_hl(0, "OCC", { fg = "#585b70" })
		vim.api.nvim_set_hl(0, "OText", { fg = "#bac2de" })
		vim.api.nvim_set_hl(0, "OT", { fg = "#6c7086" })
		vim.api.nvim_set_hl(0, "OH", { fg = "#89b4fa", bold = true })
		vim.api.nvim_set_hl(0, "OSP", { fg = "#6c7086" })
	end
end

local function line_indent(line)
	return #line - #(line:gsub("^ +", ""))
end

local function apply_highlights(buf, lines)
	vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
	for i, line in ipairs(lines) do
		local lnum = i - 1
		local len = #line
		if len == 0 then
			goto next
		end

		local indent = line_indent(line)
		local hl

		if indent == 0 then
			if line:match("^---%[%d+%]-- User:") then
				hl = "OU"
			elseif line:match("^---%[code%]") then
				hl = "OCS"
			elseif line:match("^---%[tool%]") then
				hl = "OTS"
			elseif line:match("^---%[summary%]") then
				hl = "OS"
			elseif line:match("^Opencode Viewer") then
				hl = "OH"
			elseif line:match("^=+$") or line:match("^-+$") then
				hl = "OSP"
			end
		elseif indent == 2 then
			if line:match("^  >") then
				hl = "OT"
			elseif line:match("^  -- %[code%]") then
				hl = "OCT"
			else
				hl = "OText"
			end
		elseif indent >= 4 then
			hl = "OCC"
		end

		if hl then
			vim.api.nvim_buf_set_extmark(buf, hl_ns, lnum, 0, { end_row = lnum, end_col = len, hl_group = hl })
		end
		::next::
	end
end
-- == Database ====================================================================

local function db_query(sql)
	tick()
	local ok, res = pcall(vim.fn.system, { "sqlite3", "-json", "-readonly", DB_PATH, sql })
	timer("sqlite3")
	if not ok then
		return nil, "sqlite3: " .. tostring(res)
	end
	if vim.v.shell_error ~= 0 then
		return nil, type(res) == "string" and res or "exit " .. vim.v.shell_error
	end
	if type(res) ~= "string" or res == "" then
		return nil, "empty"
	end
	tick()
	local ok2, dec = pcall(vim.fn.json_decode, res)
	timer("json_decode")
	if not ok2 then
		return nil, "json parse failed"
	end
	return dec
end

local function esc(s)
	return (s:gsub("'", "''"))
end

-- Two queries: sessions, then messages+parts joined.
local function fetch_data()
	-- Validate sqlite3
	local ok, chk = pcall(vim.fn.executable, "sqlite3")
	if not ok or chk ~= 1 then
		return nil, "sqlite3 not installed"
	end
	if #vim.fn.glob(DB_PATH, false, true) == 0 then
		return nil, "No DB at " .. DB_PATH
	end

	tick()
	local sessions = db_query([[
		SELECT id, title, directory, time_updated
		FROM session WHERE time_archived IS NULL
		ORDER BY time_updated DESC
	]])
	if not sessions or #sessions == 0 then
		return nil, "No sessions"
	end

	local s = sessions[1]
	local label = (s.title or s.id):sub(1, 50)

	-- Single query: messages + parts joined
	local rows = db_query(string.format(
		[[
		SELECT m.data AS msg_data, p.data AS part_data
		FROM message m
		LEFT JOIN part p ON p.session_id = m.session_id AND p.message_id = m.id
		WHERE m.session_id = '%s'
		ORDER BY m.time_created ASC, p.id ASC
	]],
		esc(s.id)
	))
	if not rows or #rows == 0 then
		return nil, "No messages"
	end

	timer("fetch_data")
	return { label = label, rows = rows }
end

-- == Part helpers =================================================================

local function extract_code_blocks(rendered)
	local blocks = {}
	local i = 1
	while i <= #rendered do
		if rendered[i]:match("^```") then
			local lang = rendered[i]:match("^```(.+)") or ""
			local code = {}
			i = i + 1
			while i <= #rendered and not rendered[i]:match("^```") do
				table.insert(code, rendered[i])
				i = i + 1
			end
			i = i + 1
			table.insert(blocks, { lang = lang, lines = code })
		else
			i = i + 1
		end
	end
	return blocks
end

local function render_part(part)
	local lines = {}

	if part.type == "text" and part.text and part.text ~= "" then
		if not part.synthetic then
			for _, tl in ipairs(vim.split(part.text, "\n", { plain = true })) do
				table.insert(lines, tl)
			end
		end
	elseif part.type == "reasoning" and part.text and part.text ~= "" then
		for _, rl in ipairs(vim.split(part.text, "\n", { plain = true })) do
			table.insert(lines, rl)
		end
	elseif part.type == "tool" then
		local name = part.tool or "unknown"
		table.insert(lines, "> Tool: " .. name)
		if part.state then
			local st = part.state
			if st.status == "completed" then
				if st.output then
					table.insert(lines, "```")
					for _, ol in ipairs(vim.split(st.output, "\n", { plain = true })) do
						table.insert(lines, ol)
					end
					table.insert(lines, "```")
				elseif st.input and st.input.description then
					table.insert(lines, "  " .. st.input.description)
				end
			elseif st.status == "error" then
				table.insert(lines, "  ! " .. (st.error or "error"))
			elseif st.status == "running" then
				table.insert(lines, "  ... running")
			elseif st.status == "pending" then
				table.insert(lines, "  ... pending")
			end
		end
	elseif part.type == "subtask" then
		table.insert(lines, "> Subtask: " .. (part.description or part.prompt or ""))
	elseif part.type == "file" then
		table.insert(lines, "  [file] " .. (part.filename or "attachment") .. " (" .. (part.mime or "") .. ")")
		if part.url and not part.url:match("^data:") then
			table.insert(lines, "    " .. part.url)
		end
	end

	return lines
end

-- == Build conversations =========================================================

local function build_conversations(rows)
	tick()
	local msgs = {} -- msg_id -> { role, parts = {} }
	local order = {} -- ordered list of msg_ids

	-- First pass: group parts under messages
	tick()
	for _, row in ipairs(rows) do
		local ok_m, msg_data = pcall(vim.fn.json_decode, row.msg_data)
		if not ok_m then
			goto next_row
		end
		local msg_id = msg_data.id or (msg_data.role .. tostring(msg_data.time_created))
		if not msgs[msg_id] then
			msgs[msg_id] = {
				role = msg_data.role,
				parts = {},
			}
			order[#order + 1] = msg_id
		end
		if row.part_data and row.part_data ~= vim.NIL then
			local ok_p, part = pcall(vim.fn.json_decode, row.part_data)
			if ok_p then
				msgs[msg_id].parts[#msgs[msg_id].parts + 1] = part
			end
		end
		::next_row::
	end
	timer("group_messages")

	-- Second pass: build conversations
	tick()
	local conversations = {}
	local current_user = nil

	for _, msg_id in ipairs(order) do
		local msg = msgs[msg_id]
		local role = msg.role
		if role ~= "user" and role ~= "assistant" then
			goto next_msg
		end

		local all_lines = {}
		local rendered_parts = {}
		for _, part in ipairs(msg.parts) do
			local plines = render_part(part)
			rendered_parts[#rendered_parts + 1] = {
				type = part.type,
				lines = plines,
			}
			for _, l in ipairs(plines) do
				table.insert(all_lines, l)
			end
		end

		if #all_lines == 0 then
			goto next_msg
		end

		local label = ""
		for _, l in ipairs(all_lines) do
			local t = vim.trim(l)
			if t ~= "" then
				label = t:sub(1, 70)
				break
			end
		end

		if role == "user" then
			current_user = {
				idx = #conversations + 1,
				label = label,
				user_lines = all_lines,
				asst_sections = {},
			}
			table.insert(conversations, current_user)
		elseif role == "assistant" and current_user then
			local text_lines = {}
			local code_blocks = {}
			local has_tool = false
			local has_code_from_text = false

			for _, rp in ipairs(rendered_parts) do
				if rp.type == "tool" then
					has_tool = true
					for _, l in ipairs(rp.lines) do
						table.insert(text_lines, l)
					end
				else
					local i = 1
					while i <= #rp.lines do
						if rp.lines[i]:match("^```") then
							local lang = rp.lines[i]:match("^```(.+)") or ""
							local code = {}
							i = i + 1
							while i <= #rp.lines and not rp.lines[i]:match("^```") do
								table.insert(code, rp.lines[i])
								i = i + 1
							end
							i = i + 1
							table.insert(code_blocks, { lang = lang, lines = code })
							has_code_from_text = true
						else
							table.insert(text_lines, rp.lines[i])
							i = i + 1
						end
					end
				end
			end

			local asst_label = ""
			for _, tl in ipairs(text_lines) do
				local t = vim.trim(tl)
				if t ~= "" then
					asst_label = t:sub(1, 70)
					break
				end
			end
			if asst_label == "" and #code_blocks > 0 then
				asst_label = "(" .. #code_blocks .. " blocks)"
			end

			local kind = has_code_from_text and "code" or (has_tool and "tool" or "summary")

			table.insert(current_user.asst_sections, {
				label = asst_label,
				text_lines = text_lines,
				code_blocks = code_blocks,
				kind = kind,
			})
		end
		::next_msg::
	end

	timer("build_conversations")
	return conversations
end

-- == Buffer layout ===============================================================

-- Builds buffer lines AND a line_map for O(1) lookups.
-- line_map[lnum] = { type = "user"|"asst"|"code"|"sep", conv_idx, asst_idx, block_idx }
local function build_lines(conversations)
	local lines = {}
	local line_map = {}
	local function add(line, entry)
		line_map[#lines + 1] = entry
		table.insert(lines, line)
	end

	add(string.format("Opencode Viewer -- %d conversations", #conversations), { type = "header" })
	add(string.rep("=", 60), { type = "sep" })
	add("", { type = "blank" })

	for ci, conv in ipairs(conversations) do
		add(string.format("---[%d]-- User: %s", conv.idx, conv.label), { type = "user", conv_idx = ci })

		for _, cl in ipairs(conv.user_lines) do
			table.insert(lines, "  " .. cl)
			table.insert(line_map, { type = "text", conv_idx = ci })
		end

		for ai, asst in ipairs(conv.asst_sections) do
			add(string.format("---[%s] %s", asst.kind, asst.label), { type = "asst", conv_idx = ci, asst_idx = ai })

			for _, tl in ipairs(asst.text_lines) do
				table.insert(lines, "  " .. tl)
				table.insert(line_map, { type = "text", conv_idx = ci })
			end

			for bi, cb in ipairs(asst.code_blocks) do
				local fname = ""
				local title_line = cb.lines[1] or ""
				if title_line ~= "" then
					fname = " " .. vim.trim(title_line)
				end
				local lang_tag = (cb.lang ~= "") and (" (" .. cb.lang .. ")") or ""
				add(
					string.format("  -- [code]%s%s --", fname, lang_tag),
					{ type = "code", conv_idx = ci, asst_idx = ai, block_idx = bi }
				)

				for _, cl in ipairs(cb.lines) do
					table.insert(lines, "    " .. cl)
					table.insert(line_map, { type = "code_line", conv_idx = ci })
				end
			end
		end

		table.insert(lines, "")
		table.insert(line_map, { type = "blank", conv_idx = ci })
	end

	table.insert(lines, "")
	table.insert(line_map, { type = "blank" })
	add(string.rep("-", 60), { type = "sep" })
	add(
		"<CR>=toggle  [=prev code  ]=next code  y=yank  Y=yank+hdr  c=cpy  o=open  ff=search  /=filt  r=ref  q=quit  D=debug  ?=help",
		{ type = "help" }
	)

	timer("build_lines")
	return lines, line_map
end

-- == State =======================================================================

-- State is stored in b:opencode_viewer so it survives :luafile %
-- The local `S` is a fast reference; it's synced to/from b:opencode_viewer.

local S = {
	buf = nil,
	win = nil,
	convs = nil,
	label = "",
	filter = "",
	line_map = {},
}

local function save_state()
	if S.buf and vim.api.nvim_buf_is_valid(S.buf) then
		vim.b[S.buf].opencode_viewer = {
			convs = S.convs,
			label = S.label,
			filter = S.filter,
		}
	end
end

local function restore_state()
	if S.buf and vim.api.nvim_buf_is_valid(S.buf) then
		local saved = vim.b[S.buf].opencode_viewer
		if saved then
			S.convs = saved.convs
			S.label = saved.label or ""
			S.filter = saved.filter or ""
			return true
		end
	end
	return false
end

-- On module load, recover orphaned viewer buffers
local function recover()
	-- Find any existing "opencode-viewer" buffer
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr):match("opencode%-viewer$") then
			S.buf = bufnr
			-- Find its window
			for _, winid in ipairs(vim.api.nvim_list_wins()) do
				if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
					S.win = winid
					break
				end
			end
			-- Restore state from buffer variable
			if restore_state() then
				if verbose then
					vim.notify("Recovered viewer (" .. #S.convs .. " convs)", vim.log.levels.INFO)
				end
				return true
			end
		end
	end
	return false
end

-- == Find helpers =================================================================

local function find_conv(lnum)
	local entry = S.line_map[lnum]
	if entry and entry.conv_idx then
		return S.convs[entry.conv_idx]
	end
	-- Walk backward
	for l = lnum - 1, 1, -1 do
		local e = S.line_map[l]
		if e and e.type == "user" and e.conv_idx then
			return S.convs[e.conv_idx]
		end
	end
	return nil
end

local function get_block_range(lnum)
	local start_line = 1
	for l = lnum, 1, -1 do
		local e = S.line_map[l]
		if e and e.type == "user" then
			start_line = l
			break
		end
	end
	local end_line = vim.fn.line("$")
	for l = start_line + 1, vim.fn.line("$") do
		local e = S.line_map[l]
		if e and e.type == "user" then
			end_line = l - 1
			break
		end
	end
	return start_line, end_line
end

local function get_line_paths(lnum)
	local line = vim.fn.getline(lnum)
	local paths = {}
	for fp in line:gmatch("[%w_%-/%.~]+%.[%w_]+") do
		if not fp:match("^%d+%.%w+$") then
			paths[#paths + 1] = fp
		end
	end
	return paths
end

local function get_block_paths(lnum)
	local start_line, end_line = get_block_range(lnum)
	local seen = {}
	local paths = {}
	for l = start_line, end_line do
		for _, fp in ipairs(get_line_paths(l)) do
			if not seen[fp] then
				seen[fp] = true
				paths[#paths + 1] = fp
			end
		end
	end
	return paths
end

local function build_conv_search_text(conv)
	local parts = {}
	table.insert(parts, conv.label or "")
	for _, l in ipairs(conv.user_lines) do
		table.insert(parts, l)
	end
	for _, asst in ipairs(conv.asst_sections) do
		table.insert(parts, asst.label or "")
		for _, tl in ipairs(asst.text_lines) do
			table.insert(parts, tl)
		end
		for _, cb in ipairs(asst.code_blocks) do
			for _, cl in ipairs(cb.lines) do
				table.insert(parts, cl)
			end
		end
	end
	return table.concat(parts, " ")
end

local function text_matches(query, text)
	local t = text:lower()
	local words = vim.split(query:lower(), "%s+")
	for _, word in ipairs(words) do
		if word ~= "" then
			local pos = 1
			for j = 1, #word do
				local char = word:sub(j, j)
				pos = t:find(char, pos, true)
				if not pos then
					return false
				end
				pos = pos + 1
			end
		end
	end
	return true
end

-- == Navigation ===================================================================

local function is_code_line(line)
	return line:match("^---%[code%]") or line:match("^  -- %[code%]")
end

local function next_code()
	local lnum = vim.fn.line(".")
	for l = lnum + 1, vim.fn.line("$") do
		if is_code_line(vim.fn.getline(l)) then
			vim.api.nvim_win_set_cursor(0, { l, 0 })
			return
		end
	end
	vim.notify("No next [code]", vim.log.levels.INFO)
end

local function prev_code()
	local lnum = vim.fn.line(".")
	for l = lnum - 1, 1, -1 do
		if is_code_line(vim.fn.getline(l)) then
			vim.api.nvim_win_set_cursor(0, { l, 0 })
			return
		end
	end
	vim.notify("No prev [code]", vim.log.levels.INFO)
end

-- == Actions =====================================================================

local function yank_fold()
	local conv = find_conv(vim.fn.line("."))
	if not conv then
		vim.notify("Not in a conversation", vim.log.levels.WARN)
		return
	end
	-- Yank all text from this conversation
	local lines = {}
	table.insert(lines, string.format("---[%d]-- User: %s", conv.idx, conv.label))
	for _, cl in ipairs(conv.user_lines) do
		table.insert(lines, cl)
	end
	for _, asst in ipairs(conv.asst_sections) do
		table.insert(lines, string.format("---[%s] %s", asst.kind, asst.label))
		for _, tl in ipairs(asst.text_lines) do
			table.insert(lines, tl)
		end
		for _, cb in ipairs(asst.code_blocks) do
			local fname = (cb.lines[1] and cb.lines[1] ~= "") and (" " .. vim.trim(cb.lines[1])) or ""
			local lang_tag = (cb.lang ~= "") and (" (" .. cb.lang .. ")") or ""
			table.insert(lines, string.format("  -- [code]%s%s --", fname, lang_tag))
			for _, cl in ipairs(cb.lines) do
				table.insert(lines, cl)
			end
		end
	end
	local content = table.concat(lines, "\n")
	vim.fn.setreg("+", content)
	vim.fn.setreg('"', content)
	local n = #lines
	vim.notify("Yanked conv " .. conv.idx .. " (" .. n .. " lines)", vim.log.levels.INFO)
end

local function yank_with_header()
	local conv = find_conv(vim.fn.line("."))
	if not conv then
		vim.notify("Not in a conversation", vim.log.levels.WARN)
		return
	end
	local header = "-- " .. conv.label
	local lines = { header }
	for _, cl in ipairs(conv.user_lines) do
		table.insert(lines, cl)
	end
	for _, asst in ipairs(conv.asst_sections) do
		table.insert(lines, string.format("-- %s", asst.label))
		for _, tl in ipairs(asst.text_lines) do
			table.insert(lines, tl)
		end
		for _, cb in ipairs(asst.code_blocks) do
			for _, cl in ipairs(cb.lines) do
				table.insert(lines, cl)
			end
		end
	end
	local content = table.concat(lines, "\n")
	vim.fn.setreg("+", content)
	vim.fn.setreg('"', content)
	vim.notify("Yanked conv " .. conv.idx .. " with header", vim.log.levels.INFO)
end

local function yank_code()
	local conv = find_conv(vim.fn.line("."))
	if not conv then
		vim.notify("Not in a conversation", vim.log.levels.WARN)
		return
	end

	-- Collect all code blocks from data structure
	local blocks = {}
	for _, asst in ipairs(conv.asst_sections) do
		for _, cb in ipairs(asst.code_blocks) do
			blocks[#blocks + 1] = cb
		end
	end

	if #blocks == 0 then
		vim.notify("No code blocks in this conversation", vim.log.levels.WARN)
		return
	end

	if #blocks == 1 then
		local text = table.concat(blocks[1].lines, "\n")
		vim.fn.setreg("+", text)
		vim.fn.setreg('"', text)
		local n = #blocks[1].lines
		local tag = (blocks[1].lang ~= "") and (" (" .. blocks[1].lang .. ")") or ""
		vim.notify("Copied code" .. tag .. " (" .. n .. " lines)", vim.log.levels.INFO)
		return
	end

	-- Multiple: picker
	local items = {}
	for i, cb in ipairs(blocks) do
		local first = (cb.lines[1] or ""):gsub("^%s+", ""):gsub("%s+$", "")
		if first == "" then
			first = "(empty)"
		end
		items[i] = {
			idx = i,
			display = string.format("%d lines | %s", #cb.lines, first:sub(1, 70)),
			lang = cb.lang or "",
			lines = cb.lines,
		}
	end

	tick()
	vim.ui.select(items, {
		prompt = "Select code block to copy:",
		format_item = function(item)
			return item.display
		end,
	}, function(choice)
		if choice then
			local text = table.concat(choice.lines, "\n")
			vim.fn.setreg("+", text)
			vim.fn.setreg('"', text)
			local tag = (choice.lang ~= "") and (" (" .. choice.lang .. ")") or ""
			vim.notify("Copied block " .. choice.idx .. tag .. " (" .. #choice.lines .. " lines)", vim.log.levels.INFO)
		end
	end)
end

-- == File ops ====================================================================

local function open_file()
	local l = vim.fn.line(".")
	local paths = get_line_paths(l)
	if #paths == 0 then
		vim.notify("No filepath on this line", vim.log.levels.WARN)
		return
	end
	local fp = paths[1]
	local abs = vim.fn.getcwd() .. "/" .. fp
	if vim.fn.filereadable(abs) == 1 then
		fp = abs
	elseif vim.fn.filereadable(fp) ~= 1 then
		vim.notify("Not found: " .. fp, vim.log.levels.WARN)
		return
	end
	vim.cmd("edit " .. vim.fn.fnameescape(fp))
end

local function search_file()
	local l = vim.fn.line(".")
	local paths = get_block_paths(l)

	if #paths == 0 then
		vim.notify("No filepaths in this block", vim.log.levels.WARN)
		return
	end

	-- Resolve to absolute where possible
	local resolved = {}
	for _, fp in ipairs(paths) do
		local abs = vim.fn.getcwd() .. "/" .. fp
		if vim.fn.filereadable(abs) == 1 then
			resolved[#resolved + 1] = abs
		elseif vim.fn.filereadable(fp) == 1 then
			resolved[#resolved + 1] = fp
		else
			resolved[#resolved + 1] = fp
		end
	end

	if #resolved == 1 then
		vim.fn.setreg("+", resolved[1])
		vim.cmd("split " .. vim.fn.fnameescape(resolved[1]))
		vim.notify("Opened: " .. resolved[1], vim.log.levels.INFO)
		return
	end

	vim.ui.select(resolved, {
		prompt = "Open file in split:",
		format_item = function(item)
			return item
		end,
	}, function(choice)
		if choice then
			vim.fn.setreg("+", choice)
			vim.cmd("split " .. vim.fn.fnameescape(choice))
			vim.notify("Opened: " .. choice, vim.log.levels.INFO)
		end
	end)
end

-- == Filter ======================================================================

local function update_header()
	local total = #(S.convs or {})
	local base = string.format("Opencode Viewer -- %d conversations", total)
	if S.label ~= "" then
		base = base .. "  |  " .. S.label
	end
	if S.filter ~= "" and S.buf and vim.api.nvim_buf_is_valid(S.buf) then
		local visible = 0
		for _, line in ipairs(vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)) do
			if line:match("^---%[%d+%]-- User:") then
				visible = visible + 1
			end
		end
		base = base .. string.format(" [%d/%d filtered: %s]", visible, total, S.filter)
	end
	if S.buf and vim.api.nvim_buf_is_valid(S.buf) then
		vim.bo[S.buf].modifiable = true
		vim.api.nvim_buf_set_lines(S.buf, 0, 1, false, { base })
		vim.bo[S.buf].modifiable = false
	end
end

local function apply_lines(lines, line_map)
	if not S.buf or not vim.api.nvim_buf_is_valid(S.buf) then
		return
	end
	tick()
	vim.bo[S.buf].modifiable = true
	vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, lines)
	vim.bo[S.buf].modifiable = false
	S.line_map = line_map
	apply_highlights(S.buf, lines)
	timer("apply_lines")

	tick()
	vim.cmd("normal! zM")
	-- Cursor to newest user line
	for l = #lines, 1, -1 do
		local e = line_map[l]
		if e and e.type == "user" then
			if S.win and vim.api.nvim_win_is_valid(S.win) then
				vim.api.nvim_win_set_cursor(S.win, { l, 0 })
			end
			break
		end
	end
	timer("cursor_position")
	update_header()
end

local function rebuild_display(convs)
	convs = convs or S.convs
	tick()
	local lines, line_map = build_lines(convs)
	timer("total_rebuild")
	apply_lines(lines, line_map)
end

local function apply_filter(text)
	S.filter = vim.trim(text)
	save_state()

	if S.filter == "" then
		rebuild_display(S.convs)
		return
	end

	local matched = {}
	for _, conv in ipairs(S.convs) do
		local search_text = build_conv_search_text(conv)
		if text_matches(S.filter, search_text) then
			table.insert(matched, conv)
		end
	end
	rebuild_display(matched)
end

local function filter_prompt()
	vim.ui.input({ prompt = "Filter: ", default = S.filter }, function(i)
		if i == nil then
			return
		end
		apply_filter(i)
	end)
end

-- == Debug =======================================================================

local function toggle_debug()
	verbose = not verbose
	vim.notify("Opencode viewer debug: " .. (verbose and "on" or "off"), vim.log.levels.INFO)
end

-- == Refresh =====================================================================

local function refresh()
	if not S.buf or not vim.api.nvim_buf_is_valid(S.buf) then
		vim.notify("Viewer not open", vim.log.levels.WARN)
		return
	end

	tick()
	local res, err = fetch_data()
	if not res then
		vim.notify(err, vim.log.levels.WARN)
		return
	end

	tick()
	local convs = build_conversations(res.rows)
	timer("total_fetch_and_build")

	S.convs = convs
	S.label = res.label
	S.filter = ""
	save_state()

	rebuild_display(S.convs)
	vim.notify("Refreshed -- " .. #S.convs .. " conversations", vim.log.levels.INFO)
end

-- == Open / close ================================================================

local function close()
	if S.win and vim.api.nvim_win_is_valid(S.win) then
		vim.api.nvim_win_close(S.win, true)
	end
	S.buf = nil
	S.win = nil
	S.convs = nil
	S.label = ""
	S.filter = ""
	S.line_map = {}
end

local function setup_keymaps()
	if not S.buf or not vim.api.nvim_buf_is_valid(S.buf) then
		return
	end
	local opts = { buffer = S.buf, noremap = true, silent = true }
	vim.keymap.set("n", "<CR>", "za", opts)
	vim.keymap.set("n", "]", next_code, opts)
	vim.keymap.set("n", "[", prev_code, opts)
	vim.keymap.set("n", "y", yank_fold, opts)
	vim.keymap.set("n", "Y", yank_with_header, opts)
	vim.keymap.set("n", "c", yank_code, opts)
	vim.keymap.set("n", "o", open_file, opts)
	vim.keymap.set("n", "ff", search_file, opts)
	vim.keymap.set("n", "/", filter_prompt, opts)
	vim.keymap.set("n", "r", refresh, opts)
	vim.keymap.set("n", "q", close, opts)
	vim.keymap.set("n", "D", toggle_debug, opts)
	vim.keymap.set("n", "<Esc>", function()
		if S.filter ~= "" then
			apply_filter("")
		end
	end, opts)
	vim.keymap.set("n", "?", function()
		vim.notify(
			"<CR>=toggle  [=prev code  ]=next code  y=yank  Y=yank+hdr  c=cpy  o=open  ff=search  /=filt  r=ref  q=quit  D=debug  ?=help",
			vim.log.levels.INFO
		)
	end, opts)
end

local function open()
	-- If we recovered from a stale state, just focus existing window
	if recover() and S.win and vim.api.nvim_win_is_valid(S.win) then
		vim.api.nvim_set_current_win(S.win)
		if verbose then
			vim.notify("Viewer already open (" .. #S.convs .. " convs)", vim.log.levels.INFO)
		end
		return
	end

	tick()
	local res, err = fetch_data()
	if not res then
		vim.notify(err, vim.log.levels.WARN)
		return
	end
	timer("fetch")

	local convs = build_conversations(res.rows)

	S.convs = convs
	S.label = res.label
	S.filter = ""
	S.buf = nil
	S.win = nil
	S.line_map = {}

	local lines, line_map = build_lines(S.convs)

	-- Create buffer
	S.buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_name(S.buf, "opencode-viewer")
	vim.bo[S.buf].buftype = "nofile"
	vim.bo[S.buf].bufhidden = "wipe"
	vim.bo[S.buf].modifiable = false
	vim.bo[S.buf].shiftwidth = 2

	S.line_map = line_map
	save_state()

	-- Highlights
	setup_highlights()
	apply_highlights(S.buf, lines)

	-- Window
	if S.win and vim.api.nvim_win_is_valid(S.win) then
		vim.api.nvim_win_set_buf(S.win, S.buf)
		S.win = vim.api.nvim_get_current_win()
	end
	if not S.win or not vim.api.nvim_win_is_valid(S.win) then
		vim.cmd("vsplit")
		S.win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(S.win, S.buf)
	end

	-- Window options
	vim.wo[S.win].foldmethod = "indent"
	vim.wo[S.win].foldlevel = 0
	vim.wo[S.win].foldcolumn = "2"
	vim.wo[S.win].number = true
	vim.wo[S.win].numberwidth = 3
	vim.wo[S.win].spell = false
	vim.wo[S.win].list = false
	vim.wo[S.win].wrap = true

	setup_keymaps()

	-- Close all folds, cursor to newest
	vim.cmd("normal! zM")
	for l = #lines, 1, -1 do
		local e = S.line_map[l]
		if e and e.type == "user" then
			vim.api.nvim_win_set_cursor(S.win, { l, 0 })
			break
		end
	end

	timer("total_open")
	vim.notify("Opencode Viewer -- " .. #S.convs .. " conversations", vim.log.levels.INFO)
end

-- == Global toggle ===============================================================

vim.keymap.set("n", "<leader>ae", function()
	if S.win and vim.api.nvim_win_is_valid(S.win) then
		close()
	elseif recover() then
		-- Found orphaned viewer; focus it
		if S.win and vim.api.nvim_win_is_valid(S.win) then
			vim.api.nvim_set_current_win(S.win)
		end
	else
		open()
	end
end, { desc = "Opencode: toggle viewer" })

return M
