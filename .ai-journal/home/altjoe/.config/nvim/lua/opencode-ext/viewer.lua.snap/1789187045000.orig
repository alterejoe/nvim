-- /home/jmeyer/.config/nvim/lua/opencode-ext/viewer.lua FINAL-10
local db = require("opencode-ext.db")
local model = require("opencode-ext.model")
local M = {}

local viewer_win = nil

-- Last-session-per-CWD store. Persists to disk across nvim restarts.
local LAST_SESSION_FILE = vim.fn.stdpath("config") .. "/.opencode-last-session.json"

local function load_last_sessions()
	local f = io.open(LAST_SESSION_FILE, "r")
	if not f then
		return {}
	end
	local raw = f:read("*a")
	f:close()
	if not raw or raw == "" then
		return {}
	end
	local ok, data = pcall(vim.fn.json_decode, raw)
	return ok and data or {}
end

local function save_last_session(cwd, session_id)
	local sessions = load_last_sessions()
	sessions[cwd] = session_id
	local f = io.open(LAST_SESSION_FILE, "w")
	if f then
		f:write(vim.fn.json_encode(sessions))
		f:close()
	end
	vim.notify("[ae] SAVE last-session: cwd=" .. cwd .. " sid=" .. session_id, vim.log.levels.INFO)
end

local function get_last_session(cwd)
	local sessions = load_last_sessions()
	local sid = sessions[cwd]
	vim.notify("[ae] LOOKUP last-session: cwd=" .. cwd .. " found=" .. (sid or "nil"), vim.log.levels.INFO)
	return sid
end

local function extract_path_from_line(line)
	local t = vim.trim(line)
	local p, n = t:match("^//%s*([%w_%-/%.~]+%.[%w_]+):?(%d*)")
		or t:match("^#%s*([%w_%-/%.~]+%.[%w_]+):?(%d*)")
		or t:match("^%-%-%s*([%w_%-/%.~]+%.[%w_]+):?(%d*)")
		or t:match("^;%s*([%w_%-/%.~]+%.[%w_]+):?(%d*)")
	return p and p or nil, tonumber(n)
end

local function find_code_blocks(lines)
	local blocks, stack = {}, {}
	for i = 1, #lines do
		local m = lines[i]:match("^```(.+)")
		if m then
			table.insert(stack, { lang = vim.trim(m), start_line = i, lines = {} })
		elseif lines[i]:match("^```%s*$") and #stack > 0 then
			local b = table.remove(stack)
			b.end_line = i
			table.insert(blocks, b)
		else
			for _, b in ipairs(stack) do
				table.insert(b.lines, lines[i])
			end
		end
	end
	return blocks
end

local function sanitize_lines(arr)
	local out = {}
	for _, s in ipairs(arr or {}) do
		if type(s) == "string" and s:find("\n") then
			for _, p in ipairs(vim.split(s, "\n", { plain = true })) do
				table.insert(out, p)
			end
		else
			table.insert(out, s or "")
		end
	end
	return out
end

local function render_content(conv)
	local lines, blocks, bp = {}, {}, {}
	if conv.user_lines then
		for _, l in ipairs(sanitize_lines(conv.user_lines)) do
			table.insert(lines, l)
		end
	end
	for _, asst in ipairs(conv.asst_sections or {}) do
		local src = sanitize_lines(asst.all_lines or asst.text_lines)
		if src and #src > 0 then
			table.insert(
				lines,
				(
					(asst.label or ""):sub(1, 60) ~= "" and "─── " .. asst.label .. " ───"
					or "─── Assistant ───"
				)
			)
			local bf = #lines + 1
			for _, l in ipairs(src) do
				table.insert(lines, l)
			end
			for _, blk in ipairs(find_code_blocks(src)) do
				blk.start_line = blk.start_line + bf - 1
				blk.end_line = blk.end_line + bf - 1
				table.insert(blocks, blk)
			end
		end
	end
	for bi = #blocks, 1, -1 do
		for l = blocks[bi].start_line, blocks[bi].end_line do
			bp[l] = bi
		end
	end
	return lines, blocks, bp
end

local function navigate_block(dir, lnum, blocks, bp)
	local bi = bp[lnum]
	local t = dir == "next" and (bi and bi + 1 or 1) or (bi and bi - 1 or #blocks)
	if t >= 1 and t <= #blocks then
		vim.api.nvim_win_set_cursor(0, { blocks[t].start_line, 0 })
	end
end

local function nav_path(rp, ln, pp, vb)
	if not rp then
		return
	end
	local res = rp:sub(1, 1) == "/" and rp or vim.fn.resolve(pp .. "/" .. rp)
	local tw = nil
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(w) ~= vb and vim.api.nvim_buf_is_valid(vim.api.nvim_win_get_buf(w)) then
			tw = w
			break
		end
	end
	if not tw then
		vim.cmd("vsplit")
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_buf(w) ~= vb then
				tw = w
				break
			end
		end
	end
	if not tw then
		return
	end
	if vim.fn.filereadable(res) ~= 1 then
		if vim.fn.confirm("Create file?\n  " .. res, "&Yes\n&No", 1) ~= 1 then
			return
		end
		local ph = vim.fn.fnamemodify(res, ":h")
		if vim.fn.isdirectory(ph) == 0 then
			vim.fn.mkdir(ph, "p")
		end
	end
	local vw = vim.api.nvim_get_current_win()
	vim.api.nvim_set_current_win(tw)
	vim.cmd("edit " .. vim.fn.fnameescape(res))
	if ln then
		vim.api.nvim_win_set_cursor(tw, { ln, 0 })
	end
	vim.api.nvim_set_current_win(vw)
end

local function extract_func_name(line, lang)
	if not line or not lang then
		return nil
	end
	if lang == "go" then
		return line:match("^%s*func%s+%([^)]*%)%s+(%w+)%s*%(") or line:match("^%s*func%s+(%w+)%s*%(")
	end
	if lang == "templ" then
		return line:match("^%s*templ%s+(%w+)%s*%(")
	end
	if lang == "python" or lang == "py" then
		return line:match("^%s*def%s+(%w+)%s*%(")
	end
	if lang == "rust" or lang == "rs" then
		return line:match("^%s*fn%s+(%w+)%s*%(")
	end
	if lang == "lua" then
		return line:match("^%s*function%s+([%w.:]+)%s*%(")
	end
	if lang == "js" or lang == "ts" or lang == "tsx" or lang == "jsx" then
		return line:match("^%s*function%s+(%w+)%s*%(")
	end
	if lang == "ruby" or lang == "rb" then
		return line:match("^%s*def%s+(%w+)%s[%(]")
	end
end

local function nav_func(rp, fn, pp, vb, lang)
	if not rp or not fn then
		return
	end
	local res = rp:sub(1, 1) == "/" and rp or vim.fn.resolve(pp .. "/" .. rp)
	local tw = nil
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(w) ~= vb and vim.api.nvim_buf_is_valid(vim.api.nvim_win_get_buf(w)) then
			tw = w
			break
		end
	end
	if not tw then
		vim.cmd("vsplit")
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_buf(w) ~= vb then
				tw = w
				break
			end
		end
	end
	if not tw then
		return
	end
	if vim.fn.filereadable(res) ~= 1 then
		if vim.fn.confirm("Create file?\n  " .. res, "&Yes\n&No", 1) ~= 1 then
			return
		end
		local ph = vim.fn.fnamemodify(res, ":h")
		if vim.fn.isdirectory(ph) == 0 then
			vim.fn.mkdir(ph, "p")
		end
	end
	local vw = vim.api.nvim_get_current_win()
	vim.api.nvim_set_current_win(tw)
	vim.cmd("edit " .. vim.fn.fnameescape(res))
	local kw = {
		go = "func",
		templ = "templ",
		py = "def",
		python = "def",
		rs = "fn",
		rust = "fn",
		lua = "function",
		js = "function",
		ts = "function",
		tsx = "function",
		jsx = "function",
		rb = "def",
		ruby = "def",
	}
	local pat = kw[lang] and ("\\v" .. kw[lang] .. "\\s+" .. vim.pesc(fn) .. "\\s*\\(")
		or "\\v" .. vim.pesc(fn) .. "\\s*\\("
	vim.fn.setreg("/", pat)
	vim.opt.hlsearch = true
	vim.fn.search(pat, "w")
	vim.api.nvim_set_current_win(vw)
end

local help_win = nil
local HELP_LINES = {
	"── Keymaps ────────────────────────────────────────────────",
	"",
	"[               previous code block",
	"]               next code block",
	"<A-[>           previous conversation",
	"<A-]>           next conversation",
	"c               copy code block",
	"C               copy + navigate",
	"m               copy markdown file",
	"M               copy markdown + navigate",
	"r               refresh",
	"Y               yank all conversation text",
	"?               toggle this help",
	"s               open session picker",
	"q / <Esc>       close viewer",
	"",
	"Press ? or q to close",
}
local function close_help()
	if help_win and vim.api.nvim_win_is_valid(help_win) then
		vim.api.nvim_win_close(help_win, true)
		help_win = nil
	end
end
local function open_help()
	close_help()
	local b = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(b, 0, -1, false, HELP_LINES)
	vim.bo[b].modifiable = false
	vim.bo[b].bufhidden = "wipe"
	local w, h = 52, #HELP_LINES
	local ui = vim.api.nvim_list_uis()[1]
	help_win = vim.api.nvim_open_win(b, true, {
		relative = "editor",
		width = w,
		height = h,
		row = math.floor((ui.height - h) / 2),
		col = math.floor((ui.width - w) / 2),
		style = "minimal",
		border = "rounded",
	})
	local o = { buffer = b, nowait = true, noremap = true, silent = true }
	vim.keymap.set("n", "q", close_help, o)
	vim.keymap.set("n", "?", close_help, o)
	vim.keymap.set("n", "<Esc>", close_help, o)
end
local function toggle_help()
	if help_win and vim.api.nvim_win_is_valid(help_win) then
		close_help()
	else
		open_help()
	end
end

local function open_chat_buffer(conv, project_path, all_convs, conv_idx, raw)
	if not conv then
		return
	end
	if viewer_win and vim.api.nvim_win_is_valid(viewer_win) then
		vim.api.nvim_win_close(viewer_win, true)
		viewer_win = nil
	end
	local cl, blocks, bp = render_content(conv)
	if #cl == 0 then
		vim.notify("No content in this conversation", vim.log.levels.WARN)
		return
	end
	local b = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(b, 0, -1, false, cl)
	vim.bo[b].buftype = "nofile"
	vim.bo[b].bufhidden = "wipe"
	vim.bo[b].swapfile = false
	vim.bo[b].modifiable = false
	vim.bo[b].filetype = "markdown"
	vim.cmd("vsplit")
	local w = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(w, b)
	vim.cmd("stopinsert")
	viewer_win = w
	local label = (conv.label or ""):sub(1, 70)
	vim.wo[w].winbar = (label ~= "" and "─── " .. label .. " ───" or "─── User ───"):gsub(
		"%%",
		"%%%%"
	)
	vim.wo[w].statusline = "c copy C nav m md M md+nav [ ] <A-[> <A-]> conv ? help"
	local km = { buffer = b, nowait = true, noremap = true }
	local function cv()
		close_help()
		viewer_win = nil
		if vim.api.nvim_win_is_valid(w) then
			vim.api.nvim_win_close(w, true)
		end
	end
	vim.keymap.set("n", "]", function()
		navigate_block("next", vim.fn.line("."), blocks, bp)
	end, km)
	vim.keymap.set("n", "[", function()
		navigate_block("prev", vim.fn.line("."), blocks, bp)
	end, km)
	if all_convs then
		vim.keymap.set("n", "<A-[>", function()
			if conv_idx > 1 then
				cv()
				open_chat_buffer(all_convs[conv_idx - 1], project_path, all_convs, conv_idx - 1, nil)
			end
		end, km)
		vim.keymap.set("n", "<A-]>", function()
			if conv_idx < #all_convs then
				cv()
				open_chat_buffer(all_convs[conv_idx + 1], project_path, all_convs, conv_idx + 1, nil)
			end
		end, km)
	end
	vim.keymap.set("n", "c", function()
		local blk = bp[vim.fn.line(".")]
		blk = blk and blocks[blk] or nil
		if not blk then
			vim.notify("Not inside a code block", vim.log.levels.WARN)
			return
		end
		local t = table.concat(blk.lines, "\n")
		vim.fn.setreg("+", t)
		vim.fn.setreg('"', t)
		vim.notify(string.format("Copied block %d chars", #t), vim.log.levels.INFO)
	end, km)
	vim.keymap.set("n", "C", function()
		local blk = bp[vim.fn.line(".")]
		blk = blk and blocks[blk] or nil
		if not blk then
			vim.notify("Not inside a code block", vim.log.levels.WARN)
			return
		end
		local t = table.concat(blk.lines, "\n")
		vim.fn.setreg("+", t)
		vim.fn.setreg('"', t)
		vim.notify(string.format("Copied block %d chars", #t), vim.log.levels.INFO)
		local rp, ln = extract_path_from_line(blk.lines[1] or "")
		if not rp then
			vim.notify("No file path in this block", vim.log.levels.WARN)
			return
		end
		local fn = extract_func_name(vim.fn.getline("."), vim.trim(blk.lang))
		if fn then
			nav_func(rp, fn, project_path, b, vim.trim(blk.lang))
		else
			nav_path(rp, ln, project_path, b)
		end
	end, km)
	local function fm(lnum)
		for _, blk in ipairs(blocks) do
			if vim.trim(blk.lang):sub(1, 2) == "md" and lnum >= blk.start_line and lnum <= blk.end_line then
				return blk
			end
		end
	end
	vim.keymap.set("n", "m", function()
		local md = fm(vim.fn.line("."))
		if not md then
			vim.notify("Not inside a markdown block", vim.log.levels.WARN)
			return
		end
		local c = {}
		for i = 2, #md.lines do
			table.insert(c, md.lines[i])
		end
		local t = table.concat(c, "\n")
		vim.fn.setreg("+", t)
		vim.fn.setreg('"', t)
		vim.notify(string.format("Copied markdown file (%d chars)", #t), vim.log.levels.INFO)
	end, km)
	vim.keymap.set("n", "M", function()
		local md = fm(vim.fn.line("."))
		if not md then
			vim.notify("Not inside a markdown block", vim.log.levels.WARN)
			return
		end
		local c = {}
		for i = 2, #md.lines do
			table.insert(c, md.lines[i])
		end
		local t = table.concat(c, "\n")
		vim.fn.setreg("+", t)
		vim.fn.setreg('"', t)
		vim.notify(string.format("Copied markdown file (%d chars)", #t), vim.log.levels.INFO)
		local rp, ln = extract_path_from_line(md.lines[1] or "")
		if not rp then
			vim.notify("No file path in markdown block", vim.log.levels.WARN)
			return
		end
		nav_path(rp, ln, project_path, b)
	end, km)
	vim.keymap.set("n", "Y", function()
		local t = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
		vim.fn.setreg("+", t)
		vim.fn.setreg('"', t)
		vim.notify(string.format("Yanked conversation (%d chars)", #t), vim.log.levels.INFO)
	end, km)
	vim.keymap.set("n", "r", function()
		if not raw then
			return
		end
		cv()
		local f = model.build(raw)
		if #f == 0 then
			vim.notify("No conversations after refresh", vim.log.levels.WARN)
			return
		end
		open_chat_buffer(f[math.min(conv_idx, #f)], project_path, f, conv_idx, raw)
	end, km)
	vim.keymap.set("n", "?", toggle_help, km)
	vim.keymap.set("n", "q", cv, km)
	vim.keymap.set("n", "s", function()
		cv()
		pick_session()
	end, km)
end

-- ── Entry points ───────────────────────────────────────────────────────────

function M.toggle()
	local cwd = vim.fn.getcwd()
	local oscwd = vim.fn.systemlist("tmux display-message -p '#{pane_current_path}' 2>/dev/null") or {}
	local tmux_dir = vim.trim(oscwd[1] or "not-in-tmux")
	vim.notify("[ae] TOGGLE nvim_cwd=" .. cwd .. " tmux_pane_dir=" .. tmux_dir, vim.log.levels.INFO)

	-- 1. Check last-picked session for this CWD (highest priority)
	local last_sid = get_last_session(cwd)
	if last_sid then
		local raw = db.fetch_session(last_sid)
		if raw and raw.sid and raw.sid ~= vim.NIL then
			local convs = model.build(raw)
			if #convs > 0 then
				local project_dir = db.fetch_session_project(last_sid) or "?"
				vim.notify(
					"[ae] PICKED last-session: sid="
						.. last_sid
						.. " project="
						.. project_dir
						.. " label="
						.. (raw.label or ""),
					vim.log.levels.INFO
				)
				open_chat_buffer(convs[#convs], cwd, convs, #convs, raw)
				return
			end
		end
		vim.notify("[ae] last-session expired, falling through", vim.log.levels.INFO)
	end

	-- 2. Gather candidates from all lookup paths, pick newest
	local candidates = {}

	local exact = db.fetch_by_worktree(cwd)
	if exact and exact.sid and exact.sid ~= vim.NIL then
		local p = db.fetch_session_project(exact.sid) or "?"
		vim.notify(
			"[ae] CANDIDATE exact-match: sid="
				.. exact.sid
				.. " project="
				.. p
				.. " time="
				.. (exact.time_updated or "?")
				.. " label="
				.. (exact.label or ""),
			vim.log.levels.INFO
		)
		table.insert(candidates, exact)
	else
		vim.notify("[ae] CANDIDATE exact-match: none", vim.log.levels.INFO)
	end

	local parent = db.fetch_all(cwd)
	if parent and parent.sid and parent.sid ~= vim.NIL then
		local dup = false
		for _, c in ipairs(candidates) do
			if c.sid == parent.sid then
				dup = true
				break
			end
		end
		if not dup then
			local p = db.fetch_session_project(parent.sid) or "?"
			vim.notify(
				"[ae] CANDIDATE parent-walk: sid="
					.. parent.sid
					.. " project="
					.. p
					.. " time="
					.. (parent.time_updated or "?")
					.. " label="
					.. (parent.label or ""),
				vim.log.levels.INFO
			)
			table.insert(candidates, parent)
		end
	else
		vim.notify("[ae] CANDIDATE parent-walk: none", vim.log.levels.INFO)
	end

	local global = db.fetch_global_by_directory(cwd)
	if global and global.sid and global.sid ~= vim.NIL then
		local dup = false
		for _, c in ipairs(candidates) do
			if c.sid == global.sid then
				dup = true
				break
			end
		end
		if not dup then
			local p = db.fetch_session_project(global.sid) or "?"
			vim.notify(
				"[ae] CANDIDATE global-dir: sid="
					.. global.sid
					.. " project="
					.. p
					.. " time="
					.. (global.time_updated or "?")
					.. " label="
					.. (global.label or ""),
				vim.log.levels.INFO
			)
			table.insert(candidates, global)
		end
	else
		vim.notify("[ae] CANDIDATE global-dir: none", vim.log.levels.INFO)
	end

	if #candidates == 0 then
		vim.notify("[ae] NO CANDIDATES for cwd=" .. cwd, vim.log.levels.WARN)
		vim.notify("opencode: no session under " .. cwd, vim.log.levels.WARN)
		return
	end

	table.sort(candidates, function(a, b)
		return (a.time_updated or 0) > (b.time_updated or 0)
	end)

	local chosen = candidates[1]
	local chosen_project = db.fetch_session_project(chosen.sid) or "?"
	vim.notify(
		"[ae] CHOSEN sid="
			.. chosen.sid
			.. " project="
			.. chosen_project
			.. " time="
			.. (chosen.time_updated or "?")
			.. " label="
			.. (chosen.label or ""),
		vim.log.levels.INFO
	)

	local convs = model.build(chosen)
	if #convs == 0 then
		vim.notify("No messages in this session", vim.log.levels.WARN)
		return
	end
	open_chat_buffer(convs[#convs], cwd, convs, #convs, chosen)
end

function M.toggle_for_dir(dir)
	local candidates = {}

	local exact = db.fetch_by_worktree(dir)
	if exact and exact.sid and exact.sid ~= vim.NIL then
		table.insert(candidates, exact)
	end

	local parent = db.fetch_all(dir)
	if parent and parent.sid and parent.sid ~= vim.NIL then
		local dup = false
		for _, c in ipairs(candidates) do
			if c.sid == parent.sid then
				dup = true
				break
			end
		end
		if not dup then
			table.insert(candidates, parent)
		end
	end

	local global = db.fetch_global_by_directory(dir)
	if global and global.sid and global.sid ~= vim.NIL then
		local dup = false
		for _, c in ipairs(candidates) do
			if c.sid == global.sid then
				dup = true
				break
			end
		end
		if not dup then
			table.insert(candidates, global)
		end
	end

	if #candidates == 0 then
		vim.notify("No session for this directory", vim.log.levels.WARN)
		return
	end

	table.sort(candidates, function(a, b)
		return (a.time_updated or 0) > (b.time_updated or 0)
	end)

	local raw = candidates[1]
	local convs = model.build(raw)
	if #convs == 0 then
		vim.notify("No messages in this session", vim.log.levels.WARN)
		return
	end
	open_chat_buffer(convs[#convs], dir, convs, #convs, raw)
end

function M.open_by_id(sid, display_dir)
	local raw = db.fetch_session(sid)
	if not raw or not raw.sid or raw.sid == vim.NIL then
		vim.notify("opencode: session not found", vim.log.levels.WARN)
		return false
	end
	local convs = model.build(raw)
	if #convs == 0 then
		vim.notify("No messages in this session", vim.log.levels.WARN)
		return false
	end
	open_chat_buffer(convs[#convs], display_dir or vim.fn.getcwd(), convs, #convs, raw)
	return true
end

pick_session = function()
	local sessions = db.fetch_sessions()
	if not sessions or #sessions == 0 then
		vim.notify("No opencode sessions found", vim.log.levels.WARN)
		return
	end
	vim.notify("[s-picker] opened with " .. #sessions .. " sessions, nvim_cwd=" .. vim.fn.getcwd(), vim.log.levels.INFO)
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local state = require("telescope.actions.state")
	local function ft(ts)
		if not ts then
			return "?"
		end
		local d = os.time() - ts
		if d < 60 then
			return "now"
		elseif d < 3600 then
			return math.floor(d / 60) .. "m"
		elseif d < 86400 then
			return math.floor(d / 3600) .. "h"
		elseif d < 604800 then
			return math.floor(d / 86400) .. "d"
		end
		return os.date("%b %d", ts)
	end
	pickers
		.new({}, {
			prompt_title = "Opencode Sessions  (R=reassign)",
			finder = finders.new_table({
				results = sessions,
				entry_maker = function(s)
					local t = (s.title or ""):gsub("\n", " "):sub(1, 60)
					if t == "" then
						t = "(untitled)"
					end
					local p = s.project or ""
					local ps = ""
					if p ~= "" then
						local sp = vim.split(p, "/")
						ps = #sp >= 2 and sp[#sp - 1] .. "/" .. sp[#sp] or sp[#sp]
					end
					local preview_raw = s.preview
					if preview_raw == vim.NIL then
						preview_raw = nil
					end
					local preview = (preview_raw or ""):gsub("\n", " "):sub(1, 80)
					return {
						value = s,
						display = string.format(
							"%-55s %-25s %5s  %2d msgs",
							t,
							ps,
							ft(s.time_updated),
							s.msg_count or 0
						),
						ordinal = t .. " " .. p .. " " .. preview,
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(pb)
				actions.select_default:replace(function()
					local sel = state.get_selected_entry()
					actions.close(pb)
					if sel and sel.value then
						vim.notify(
							"[s-picker] SELECTED id="
								.. sel.value.id
								.. " title="
								.. (sel.value.title or "untitled"):gsub("\n", " "):sub(1, 40)
								.. " project="
								.. (sel.value.project or "nil")
								.. " nvim_cwd="
								.. vim.fn.getcwd(),
							vim.log.levels.INFO
						)
						save_last_session(vim.fn.getcwd(), sel.value.id)
						local raw = db.fetch_session(sel.value.id)
						if raw then
							local c = model.build(raw)
							if #c > 0 then
								open_chat_buffer(c[#c], sel.value.project or vim.fn.getcwd(), c, #c, raw)
							end
						else
							vim.notify("Failed to load session", vim.log.levels.WARN)
						end
					end
				end)
				vim.keymap.set("n", "R", function()
					local sel = state.get_selected_entry()
					if not sel or not sel.value then
						return
					end
					local s = sel.value
					local title = (s.title or "session"):gsub("\n", " "):sub(1, 40)
					local new_dir = vim.fn.input("Reassign [" .. title .. "] to dir: ", s.project or "", "dir")
					if new_dir == "" or new_dir == s.project then
						return
					end
					local ok, err = db.reassign_session(s.id, new_dir)
					if ok then
						vim.notify("Reassigned to " .. new_dir, vim.log.levels.INFO)
						actions.close(pb)
					else
						vim.notify("Reassign failed: " .. (err or "unknown"), vim.log.levels.ERROR)
					end
				end, { buffer = pb, nowait = true, noremap = true })
				return true
			end,
		})
		:find()
end

vim.keymap.set("n", "<leader>ae", M.toggle, { desc = "OpenCode: latest conversation" })
return M
