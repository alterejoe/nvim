-- /home/jmeyer/.config/nvim/lua/opencode-ext/viewer.lua FINAL-9
-- One-keybind, full-chat buffer.  No scratchbuf, no 3-hop navigation.
--
-- Flow:
--   <leader>ae  → opens latest conversation from latest CWD session directly
--   <leader>am  → same for main session
--   In buffer:  [] cycle blocks, <A-[> <A-]> cycle conversations
--               c copy block, C copy + navigate, Y yank all,
--               r refresh, ? help, q close, s picker

local db = require("opencode-ext.db")
local model = require("opencode-ext.model")

local M = {}

-- Valid file extensions for path detection
local VALID_EXTS = {
	go = true,
	templ = true,
	js = true,
	ts = true,
	jsx = true,
	tsx = true,
	sql = true,
	py = true,
	rb = true,
	rs = true,
	lua = true,
	md = true,
	yaml = true,
	yml = true,
	json = true,
	xml = true,
	css = true,
	scss = true,
	html = true,
	htm = true,
	sh = true,
	bash = true,
	zsh = true,
	toml = true,
	cfg = true,
	conf = true,
	env = true,
	gitignore = true,
	dockerfile = true,
	mjs = true,
	cjs = true,
	mts = true,
	cts = true,
	dart = true,
	kt = true,
	swift = true,
	c = true,
	cpp = true,
	h = true,
	hpp = true,
}

-- Extract a file path with optional line number from a comment-styled line.
-- Handles: // path, # path, -- path, ; path
-- Also: // path:42 for line-number
local function extract_path_from_line(line)
	local trimmed = vim.trim(line)
	local path, lineno = trimmed:match("^//%s*([%w_%-/%.~]+%.[%w_]+):?(%d*)")
		or trimmed:match("^#%s*([%w_%-/%.~]+%.[%w_]+):?(%d*)")
		or trimmed:match("^%-%-%s*([%w_%-/%.~]+%.[%w_]+):?(%d*)")
		or trimmed:match("^;%s*([%w_%-/%.~]+%.[%w_]+):?(%d*)")
	if not path then
		return nil, nil
	end
	lineno = tonumber(lineno) or nil
	return path, lineno
end

-- Find all code blocks in a line array, returning position info.
local function find_code_blocks(lines)
	local blocks = {}
	local i = 1
	while i <= #lines do
		local open_lang = lines[i]:match("^```(.+)")
		local is_bare_open = lines[i]:match("^```%s*$")
		if open_lang or is_bare_open then
			local lang = open_lang or ""
			local code = {}
			local start_idx = i
			i = i + 1
			while i <= #lines and not lines[i]:match("^```%s*$") do
				table.insert(code, lines[i])
				i = i + 1
			end
			local end_idx = i
			i = i + 1
			table.insert(blocks, {
				lang = lang,
				start_line = start_idx,
				end_line = end_idx,
				lines = code,
			})
		else
			i = i + 1
		end
	end
	return blocks
end

--- Ensure every element is a true single line (no embedded \n).
local function sanitize_lines(arr)
	local out = {}
	for _, s in ipairs(arr or {}) do
		if type(s) == "string" and s:find("\n") then
			for _, part in ipairs(vim.split(s, "\n", { plain = true })) do
				table.insert(out, part)
			end
		else
			table.insert(out, s or "")
		end
	end
	return out
end

-- Render conversation content (no title — that's in the winbar).
-- Returns: { content_lines, blocks, block_positions }
--   content_lines[1..n]  — flat array with sections and fences intact
--   blocks[1..m]         — { lang, start_line, end_line, lines }
--   block_positions[l]   — block index for line l, or nil
local function render_content(conv)
	local lines = {}
	local blocks = {}
	local block_positions = {}

	if conv.user_lines then
		for _, l in ipairs(sanitize_lines(conv.user_lines)) do
			table.insert(lines, l)
		end
	end

	for _, asst in ipairs(conv.asst_sections or {}) do
		local src = sanitize_lines(asst.all_lines or asst.text_lines)
		if not src or #src == 0 then
			goto next_asst
		end
		local asst_label = (asst.label or ""):sub(1, 60)
		if asst_label ~= "" then
			table.insert(lines, "─── " .. asst_label .. " ───")
		else
			table.insert(lines, "─── Assistant ───")
		end
		local before = #lines + 1
		for _, l in ipairs(src) do
			table.insert(lines, l)
		end
		local section_blocks = find_code_blocks(src)
		for _, block in ipairs(section_blocks) do
			block.start_line = block.start_line + before - 1
			block.end_line = block.end_line + before - 1
			table.insert(blocks, block)
		end
		::next_asst::
	end

	for bi, block in ipairs(blocks) do
		for l = block.start_line, block.end_line do
			block_positions[l] = bi
		end
	end

	return lines, blocks, block_positions
end

-- One-line title for the winbar (first user message, decorated).
local function get_title_line(conv)
	local conv_label = (conv.label or ""):sub(1, 70)
	if conv_label ~= "" then
		return "─── " .. conv_label .. " ───"
	else
		return "─── User ───"
	end
end

-- Find the block under the cursor.
local function find_block_at_line(lnum, block_positions, blocks)
	local bi = block_positions[lnum]
	if bi then
		return blocks[bi], bi
	end
	return nil, nil
end

-- Navigate to the next or previous code block.
local function navigate_block(direction, lnum, blocks, block_positions)
	local current_bi = block_positions[lnum]
	local target_bi
	if direction == "next" then
		target_bi = current_bi and (current_bi + 1) or 1
		if target_bi > #blocks then
			return
		end
	else
		target_bi = current_bi and (current_bi - 1) or #blocks
		if target_bi < 1 then
			return
		end
	end
	local target = blocks[target_bi]
	vim.api.nvim_win_set_cursor(0, { target.start_line, 0 })
end

--- Help float ----------------------------------------------------------------

local help_win = nil

local HELP_LINES = {
	"── Keymaps ────────────────────────────────────────────────",
	"",
	"[               previous code block",
	"]               next code block",
	"<A-[>           previous conversation",
	"<A-]>           next conversation",
	"c               copy code block",
	"C               copy + navigate to file",
	"r               refresh (re-read session)",
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

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, HELP_LINES)
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"

	local width = 52
	local height = #HELP_LINES
	local ui = vim.api.nvim_list_uis()[1]
	local row = math.floor((ui.height - height) / 2)
	local col = math.floor((ui.width - width) / 2)

	help_win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
	})

	local opts = { buffer = buf, nowait = true, noremap = true, silent = true }
	vim.keymap.set("n", "q", close_help, opts)
	vim.keymap.set("n", "?", close_help, opts)
	vim.keymap.set("n", "<Esc>", close_help, opts)
end

local function toggle_help()
	if help_win and vim.api.nvim_win_is_valid(help_win) then
		close_help()
	else
		open_help()
	end
end

--- Main viewer ---------------------------------------------------------------

-- Open a full-chat buffer with title in winbar, hints in statusline, ? for full legend.
-- raw is the DB fetch result used to build convs — needed for `r` refresh keymap.
local function open_chat_buffer(conv, project_path, all_convs, conv_idx, raw)
	if not conv then
		return
	end

	local content_lines, blocks, block_positions = render_content(conv)
	if #content_lines == 0 then
		vim.notify("No content in this conversation", vim.log.levels.WARN)
		return
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, content_lines)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = "markdown"

	vim.cmd("vsplit")
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.cmd("stopinsert")

	-- Sticky title bar at top of the window
	local title = get_title_line(conv):gsub("%%", "%%%%")
	vim.wo[win].winbar = title

	-- Minimal statusline with most-used keymaps
	vim.wo[win].statusline = "c copy    [ ] blocks    C copy+navigate    <A-[> <A-]> conv    ? help"

	local km_opts = { buffer = buf, nowait = true, noremap = true }

	-- Close the vsplit window (restores original layout)
	local function close_view()
		close_help()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	-- Block navigation
	vim.keymap.set("n", "]", function()
		navigate_block("next", vim.fn.line("."), blocks, block_positions)
	end, km_opts)

	vim.keymap.set("n", "[", function()
		navigate_block("prev", vim.fn.line("."), blocks, block_positions)
	end, km_opts)

	-- Conversation navigation
	if all_convs then
		vim.keymap.set("n", "<A-[>", function()
			if conv_idx > 1 then
				close_view()
				open_chat_buffer(all_convs[conv_idx - 1], project_path, all_convs, conv_idx - 1, nil)
			end
		end, km_opts)

		vim.keymap.set("n", "<A-]>", function()
			if conv_idx < #all_convs then
				close_view()
				open_chat_buffer(all_convs[conv_idx + 1], project_path, all_convs, conv_idx + 1, nil)
			end
		end, km_opts)
	end

	-- Copy code block under cursor
	vim.keymap.set("n", "c", function()
		local block, bi = find_block_at_line(vim.fn.line("."), block_positions, blocks)
		if not block then
			vim.notify("Not inside a code block", vim.log.levels.WARN)
			return
		end
		local text = table.concat(block.lines, "\n")
		vim.fn.setreg("+", text)
		vim.fn.setreg('"', text)
		vim.notify(string.format("Copied block %d (%d chars)", bi, #text), vim.log.levels.INFO)
	end, km_opts)

	-- Copy + navigate to file
	vim.keymap.set("n", "C", function()
		local block, bi = find_block_at_line(vim.fn.line("."), block_positions, blocks)
		if not block then
			vim.notify("Not inside a code block", vim.log.levels.WARN)
			return
		end

		-- 1. Copy
		local text = table.concat(block.lines, "\n")
		vim.fn.setreg("+", text)
		vim.fn.setreg('"', text)
		vim.notify(string.format("Copied block %d (%d chars)", bi, #text), vim.log.levels.INFO)

		-- 2. Extract path from first line
		local raw_path, lineno = extract_path_from_line(block.lines[1] or "")
		if not raw_path then
			vim.notify("No file path in this block", vim.log.levels.WARN)
			return
		end

		-- 3. Resolve to absolute
		local resolved
		if raw_path:sub(1, 1) == "/" then
			resolved = raw_path
		else
			resolved = vim.fn.resolve(project_path .. "/" .. raw_path)
		end

		-- 4. Find target window (not the viewer)
		local target_win = nil
		local viewer_buf = buf
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			local wbuf = vim.api.nvim_win_get_buf(w)
			if wbuf ~= viewer_buf and vim.api.nvim_buf_is_valid(wbuf) then
				target_win = w
				break
			end
		end
		if not target_win then
			vim.notify("No other window — vsplitting", vim.log.levels.INFO)
			vim.cmd("vsplit")
			for _, w in ipairs(vim.api.nvim_list_wins()) do
				local wbuf = vim.api.nvim_win_get_buf(w)
				if wbuf ~= viewer_buf then
					target_win = w
					break
				end
			end
			if not target_win then
				vim.notify("Failed to create split", vim.log.levels.ERROR)
				return
			end
		end

		-- 5. Navigate
		local open_path = resolved
		if not vim.fn.filereadable(resolved) then
			-- Try basename search with ../ and ../../ prefix scans
			local basename = vim.fn.fnamemodify(resolved, ":t")
			local resolved_dir = vim.fn.fnamemodify(resolved, ":h")
			local search_dirs = { resolved_dir }
			local up = resolved_dir
			for _ = 1, 4 do
				local parent = vim.fn.fnamemodify(up, ":h")
				if parent == up then
					break
				end
				table.insert(search_dirs, parent)
				up = parent
			end
			local found = ""
			for _, d in ipairs(search_dirs) do
				local m = vim.fn.findfile(d .. "/" .. basename)
				if m ~= "" then
					for _, candidate in ipairs(vim.split(m, "\n")) do
						local full = vim.fn.resolve(candidate)
						if vim.fn.filereadable(full) == 1 then
							found = full
							break
						end
					end
				end
				if found ~= "" then
					break
				end
			end
			if found ~= "" then
				local choice = vim.fn.confirm(
					"Not found at:\n  " .. resolved .. "\n\nOpen instead:\n  " .. found .. "?",
					"&Yes\n&No",
					1
				)
				if choice == 1 then
					open_path = found
				else
					return
				end
			else
				local create = vim.fn.confirm("Create file?\n  " .. resolved, "&Yes\n&No", 1)
				if create ~= 1 then
					return
				end
				local parent = vim.fn.fnamemodify(resolved, ":h")
				if vim.fn.isdirectory(parent) == 0 then
					vim.fn.mkdir(parent, "p")
				end
			end
		end

		-- Save viewer win, open file in target, restore focus
		local viewer_win = vim.api.nvim_get_current_win()
		vim.api.nvim_set_current_win(target_win)
		vim.cmd("edit " .. vim.fn.fnameescape(open_path))
		if lineno then
			vim.api.nvim_win_set_cursor(target_win, { lineno, 0 })
		end
		vim.api.nvim_set_current_win(viewer_win)
	end, km_opts)

	-- Yank all conversation text
	vim.keymap.set("n", "Y", function()
		local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local text = table.concat(all, "\n")
		vim.fn.setreg("+", text)
		vim.fn.setreg('"', text)
		vim.notify(string.format("Yanked conversation (%d chars)", #text), vim.log.levels.INFO)
	end, km_opts)

	-- Refresh: re-read session from DB, rebuild, re-open same conv
	vim.keymap.set("n", "r", function()
		if not raw then
			return
		end
		close_view()
		local fresh = model.build(raw)
		if #fresh == 0 then
			vim.notify("No conversations after refresh", vim.log.levels.WARN)
			return
		end
		local idx = math.min(conv_idx, #fresh)
		open_chat_buffer(fresh[idx], project_path, fresh, idx, raw)
	end, km_opts)

	-- Toggle help float
	vim.keymap.set("n", "?", toggle_help, km_opts)

	-- Close viewer
	vim.keymap.set("n", "q", close_view, km_opts)

	-- Session picker
	vim.keymap.set("n", "s", function()
		close_view()
		pick_session()
	end, km_opts)
end

--- Entry: open latest conversation from latest CWD session -----------

function M.toggle()
	local raw, err = db.fetch_all()
	if not raw or not raw.sid or raw.sid == vim.NIL then
		pick_session()
		return
	end
	local conversations = model.build(raw)
	if #conversations == 0 then
		vim.notify("No messages in this session", vim.log.levels.WARN)
		return
	end
	open_chat_buffer(conversations[#conversations], vim.fn.getcwd(), conversations, #conversations, raw)
end

function M.toggle_for_dir(dir)
	local raw, err = db.fetch_all(dir)
	if not raw or not raw.sid or raw.sid == vim.NIL then
		vim.notify(err or "No session for this directory", vim.log.levels.WARN)
		return
	end
	local conversations = model.build(raw)
	if #conversations == 0 then
		vim.notify("No messages in this session", vim.log.levels.WARN)
		return
	end
	open_chat_buffer(conversations[#conversations], dir, conversations, #conversations, raw)
end

--- Session picker (telescope, fallback) --------------------------------

local function pick_session()
	local sessions, err = db.fetch_sessions()
	if not sessions then
		vim.notify(err or "No sessions", vim.log.levels.WARN)
		return
	end
	if #sessions == 0 then
		vim.notify("No opencode sessions found", vim.log.levels.WARN)
		return
	end

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	local function format_time(ts)
		if not ts then
			return "?"
		end
		local diff = os.time() - ts
		if diff < 60 then
			return "now"
		elseif diff < 3600 then
			return math.floor(diff / 60) .. "m"
		elseif diff < 86400 then
			return math.floor(diff / 3600) .. "h"
		elseif diff < 604800 then
			return math.floor(diff / 86400) .. "d"
		end
		return os.date("%b %d", ts)
	end

	local function make_entry(s)
		local title = (s.title or ""):gsub("\n", " "):sub(1, 60)
		if title == "" then
			title = "(untitled)"
		end
		local proj = s.project or ""
		local proj_short = ""
		if proj ~= "" then
			local p = vim.split(proj, "/")
			proj_short = #p >= 2 and p[#p - 1] .. "/" .. p[#p] or p[#p]
		end
		return {
			value = s,
			display = string.format(
				"%-60s %-28s %6s  %d msgs",
				title,
				proj_short,
				format_time(s.time_updated),
				s.msg_count or 0
			),
			ordinal = title .. " " .. proj,
		}
	end

	pickers
		.new({}, {
			prompt_title = "Opencode Sessions",
			finder = finders.new_table({ results = sessions, entry_maker = make_entry }),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, _)
				actions.select_default:replace(function()
					local s = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if s and s.value then
						local raw, err = db.fetch_session(s.value.id)
						if raw then
							local convs = model.build(raw)
							if #convs > 0 then
								open_chat_buffer(convs[#convs], s.value.project or vim.fn.getcwd(), convs, #convs, raw)
							end
						else
							vim.notify(err or "Failed to load session", vim.log.levels.WARN)
						end
					end
				end)
				return true
			end,
		})
		:find()
end

vim.keymap.set("n", "<leader>ae", M.toggle, { desc = "OpenCode: latest conversation" })
return M
