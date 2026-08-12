-- One-keybind, full-chat buffer.  No scratchbuf, no 3-hop navigation.
--
-- Flow:
--   <leader>ae  → opens latest conversation from latest CWD session directly
--   <leader>am  → same for main session
--   In buffer:  [] cycle files (this conversation), <A-[> <A-]> cycle conversations
--               a apply block (stages; :w commits), c copy block,
--               C copy+navigate, m copy markdown, M md+navigate,
--               Y yank all, r refresh, ? help, q close, s picker

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

-- Find all code/markdown blocks using CommonMark fence matching by
-- backtick count: a fence of N backticks closes only with N+ backticks.
--
--   - 3-tick fences (```go, ```markdown): the common delivery form.
--   - 4-tick fences (````markdown ... ````): used when a markdown file
--     CONTAINS inner ``` fences — the inner 3-tick lines are literal
--     content of the 4-tick container (never structural), so applying
--     preserves them verbatim. Unambiguous; no heuristic needed.
--   - A tagged fence inside an open fence is content (added to parents).
--   - A bare fence with FEWER ticks than the open fence is content.
--
-- Fence lines themselves are KEPT in parent containers (so applying a
-- markdown file with embedded code blocks preserves the fences) but
-- excluded from the leaf block they delimit.
-- Returns: { lang, start_line, end_line, lines }[]
--   Inner blocks appear first, outer containers last.
local function find_code_blocks(lines)
	local blocks = {}
	local stack = {} -- { lang, ticks, start_line, lines }

	local function open_block(lang, ticks, start_line)
		table.insert(stack, {
			lang = lang,
			ticks = ticks,
			start_line = start_line,
			lines = {},
		})
	end

	for i = 1, #lines do
		local line = lines[i]
		local open_ticks, lang = line:match("^(%`+)[ \t]*(%S.*)$")
		local bare_ticks = line:match("^(%`+)[ \t]*$")

		if open_ticks then
			-- Tagged fence: opens a block only at top level; inside an open
			-- fence it's literal content (e.g. ```go inside a 4-tick md container)
			if #stack == 0 then
				open_block(vim.trim(lang), #open_ticks, i)
			else
				for _, b in ipairs(stack) do
					table.insert(b.lines, line)
				end
			end
		elseif bare_ticks then
			local n = #bare_ticks
			local top = stack[#stack]
			if not top then
				-- Stray bare fence at top level: lang-less opener
				open_block("", n, i)
			elseif top.ticks <= n then
				-- Closes the innermost open fence (CommonMark: closing fence
				-- needs >= the opening fence's backtick count)
				local block = table.remove(stack)
				for _, b in ipairs(stack) do
					table.insert(b.lines, line)
				end
				block.end_line = i
				table.insert(blocks, block)
			else
				-- Fewer ticks than the open fence: literal content
				for _, b in ipairs(stack) do
					table.insert(b.lines, line)
				end
			end
		else
			-- Regular content line: add to all currently open blocks
			for _, b in ipairs(stack) do
				table.insert(b.lines, line)
			end
		end
	end

	-- Finalize unclosed blocks (unbalanced input) — lines are already complete.
	for _, b in ipairs(stack) do
		b.end_line = #lines
		table.insert(blocks, b)
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
--   Block positions: inner blocks (inserted first) override outer containers,
--   so `c` on a line inside a nested ```go copies only that block's lines.
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

	-- Reverse iteration: inner blocks (first in list) win over outer containers
	for bi = #blocks, 1, -1 do
		local block = blocks[bi]
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

-- Find the block under the cursor (uses block_positions, so returns
-- the innermost block at that line).
local function find_block_at_line(lnum, block_positions, blocks)
	local bi = block_positions[lnum]
	if bi then
		return blocks[bi], bi
	end
	return nil, nil
end

--- Find the outermost ```md or ```markdown container block containing the
--- given line. Returns nil if the cursor is not inside a markdown block.
local function find_md_container(lnum, blocks)
	local result = nil
	for _, block in ipairs(blocks) do
		local lang = vim.trim(block.lang)
		local is_md = lang:sub(1, 2) == "md" or lang == "markdown"
		if is_md and lnum >= block.start_line and lnum <= block.end_line then
			result = block
		end
	end
	return result
end

-- Tolerant file-block detection: a block is a FILE block if ANY of its
-- first 3 lines carries a path comment (the path comment may be preceded
-- by a blank line or fence noise). Uses the battle-tested extractor that
-- `C`/`M` navigation already relies on.
--- @param block table
--- @return string|nil  the detected path, or nil
local function block_file_path(block)
	for i = 1, math.min(3, #(block.lines or {})) do
		local path = extract_path_from_line(block.lines[i] or "")
		if path then
			return path
		end
	end
	return nil
end

-- Navigate between blocks in the CURRENT conversation only. Primary target:
-- FILE blocks (blocks whose first few lines carry a path comment — whole
-- delivered files, incl. markdown containers). If classification finds none,
-- FALL BACK to all blocks so [ ] always navigates something. `[` first jumps
-- to the current block's start if mid-block; `]` jumps to the next. WRAPS.
-- @param direction string  "next" | "prev"
-- @param lnum number  current line
-- @param file_blocks table  blocks sorted by start_line (may be empty)
-- @param all_blocks table  every block (fallback)
local function navigate_block(direction, lnum, file_blocks, all_blocks)
	local nav = file_blocks
	if #nav == 0 then
		nav = all_blocks
	end
	if #nav == 0 then
		vim.notify("❌ No code blocks in this conversation", vim.log.levels.WARN)
		return
	end

	-- Find the block containing the cursor
	local current_idx = nil
	for i, b in ipairs(nav) do
		if lnum >= b.start_line and lnum <= b.end_line then
			current_idx = i
			break
		end
	end

	local target
	if direction == "next" then
		if current_idx and current_idx < #nav then
			target = nav[current_idx + 1]
		elseif current_idx == #nav then
			target = nav[1] -- wrap to first
		elseif not current_idx then
			target = nav[1]
		end
	else -- "prev"
		if current_idx and lnum > nav[current_idx].start_line then
			-- Mid-block: first jump to the start of the current block
			target = nav[current_idx]
		elseif current_idx and current_idx > 1 then
			target = nav[current_idx - 1]
		elseif current_idx == 1 then
			target = nav[#nav] -- wrap to last
		elseif not current_idx then
			target = nav[#nav]
		end
	end

	if target then
		vim.api.nvim_win_set_cursor(0, { target.start_line, 0 })
		local path = block_file_path(target)
		local label = path or ("(" .. (target.lang or "?") .. " block)")
		local shown = current_idx or 1
		if direction == "next" then
			shown = current_idx and math.min(current_idx + 1, #nav) or 1
		else
			shown = current_idx and math.max(current_idx - 1, 1) or 1
		end
		vim.notify(string.format("→ %d/%d %s", shown, #nav, label), vim.log.levels.INFO)
	end
end

--- Navigate to a resolved file path in a non-viewer window.
--- Handles absolute/relative resolution, basename fallback search,
--- file-not-found prompts, and window management (reuse existing split
--- or create new vsplit). Returns true if navigation was attempted.
local function navigate_to_path(raw_path, lineno, project_path, viewer_buf)
	if not raw_path then
		return false
	end

	-- Resolve to absolute
	local resolved
	if raw_path:sub(1, 1) == "/" then
		resolved = raw_path
	else
		resolved = vim.fn.resolve(project_path .. "/" .. raw_path)
	end

	-- Find target window (not the viewer)
	local target_win = nil
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
			return true
		end
	end

	-- Navigate with file-not-found fallback
	local open_path = resolved
	if vim.fn.filereadable(resolved) ~= 1 then
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
				return true
			end
		else
			local create = vim.fn.confirm("Create file?\n  " .. resolved, "&Yes\n&No", 1)
			if create ~= 1 then
				return true
			end
			local parent = vim.fn.fnamemodify(resolved, ":h")
			if vim.fn.isdirectory(parent) == 0 then
				vim.fn.mkdir(parent, "p")
			end
		end
	end

	local viewer_win = vim.api.nvim_get_current_win()
	vim.api.nvim_set_current_win(target_win)
	vim.cmd("edit " .. vim.fn.fnameescape(open_path))
	if lineno then
		vim.api.nvim_win_set_cursor(target_win, { lineno, 0 })
	end
	vim.api.nvim_set_current_win(viewer_win)
	return true
end

--- Extract a function name from a single line of code, based on its block
--- language tag. Returns the name string, or nil if the line isn't a
--- function/component declaration.
--- @param line string
--- @param lang string
--- @return string|nil
local function extract_func_name(line, lang)
	if not line or not lang then
		return nil
	end
	if lang == "go" then
		-- Method: func (r *Receiver) MethodName(
		local name = line:match("^%s*func%s+%([^)]*%)%s+(%w+)%s*%(")
		if name then
			return name
		end
		-- Regular: func FuncName(
		return line:match("^%s*func%s+(%w+)%s*%(")
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
		return line:match("^%s*def%s+(%w+)%s*[%(]")
	end
	return nil
end

--- Navigate to a specific function in the source file. Opens the file,
--- searches for the function declaration with a language-appropriate
--- pattern, and highlights all matches.
--- @param raw_path string  path from block's first line
--- @param func_name string  extracted function name
--- @param project_path string  CWD for relative resolution
--- @param viewer_buf integer  viewer buffer handle
--- @param lang string  block language tag
--- @return boolean  true if navigation was attempted
local function navigate_to_function(raw_path, func_name, project_path, viewer_buf, lang)
	if not raw_path or not func_name then
		return false
	end

	-- Resolve to absolute
	local resolved
	if raw_path:sub(1, 1) == "/" then
		resolved = raw_path
	else
		resolved = vim.fn.resolve(project_path .. "/" .. raw_path)
	end

	-- Find target window (not the viewer)
	local target_win = nil
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
			return true
		end
	end

	-- File existence check with create prompt
	if vim.fn.filereadable(resolved) ~= 1 then
		local create = vim.fn.confirm("Create file?\n  " .. resolved, "&Yes\n&No", 1)
		if create ~= 1 then
			return true
		end
		local parent = vim.fn.fnamemodify(resolved, ":h")
		if vim.fn.isdirectory(parent) == 0 then
			vim.fn.mkdir(parent, "p")
		end
	end

	-- Open file then search for the function declaration
	local viewer_win = vim.api.nvim_get_current_win()
	vim.api.nvim_set_current_win(target_win)
	vim.cmd("edit " .. vim.fn.fnameescape(resolved))

	-- Build language-appropriate declaration search pattern and highlight
	local decl_keywords = {
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
	local keyword = decl_keywords[lang]
	local decl_pattern
	if keyword then
		decl_pattern = "\\v" .. keyword .. "\\s+" .. vim.pesc(func_name) .. "\\s*\\("
	else
		decl_pattern = "\\v" .. vim.pesc(func_name) .. "\\s*\\("
	end

	vim.fn.setreg("/", decl_pattern)
	vim.opt.hlsearch = true
	vim.fn.search(decl_pattern, "w")

	vim.api.nvim_set_current_win(viewer_win)
	return true
end

--- Parse an apply target from a block's path comment (line 1).
--- Handles: // path, // path:42, // path:42-58 — plus # / -- / ; styles
--- for markdown and other comment languages. FINAL/FINAL-N suffixes ignored.
--- Returns path, start_line, end_line (nil when absent).
--- @param line string
--- @return string|nil, number|nil, number|nil
local function parse_apply_path(line)
	local trimmed = vim.trim(line)
	local path, start_s, end_s = trimmed:match("^//%s*([%w_%-/%.~]+%.[%w_]+):?(%d*)%-?(%d*)")
		or trimmed:match("^#%s*([%w_%-/%.~]+%.[%w_]+):?(%d*)%-?(%d*)")
		or trimmed:match("^%-%-%s*([%w_%-/%.~]+%.[%w_]+):?(%d*)%-?(%d*)")
		or trimmed:match("^;%s*([%w_%-/%.~]+%.[%w_]+):?(%d*)%-?(%d*)")
	if not path then
		return nil, nil, nil
	end
	local start_line = tonumber(start_s) or nil
	local end_line = tonumber(end_s) or nil
	return path, start_line, end_line
end

-- Locate the fence-delimited block around the cursor DIRECTLY FROM THE
-- BUFFER (parser-independent). Scans up for the nearest tagged opener
-- (```lang) and down for the matching bare closer (N+ backticks, CommonMark
-- tick rule). Returns { start_line, end_line, content_lines }.
-- @param viewer_buf integer  rendered conversation buffer
-- @param lnum number  cursor line
local function block_from_buffer(viewer_buf, lnum)
	local total = vim.api.nvim_buf_line_count(viewer_buf)
	local function getline(n)
		return vim.api.nvim_buf_get_lines(viewer_buf, n - 1, n, false)[1] or ""
	end

	-- Scan up for the nearest tagged opening fence
	for open = lnum, 1, -1 do
		local text = getline(open)
		local ticks, lang = text:match("^(%`+)[ \t]*(%S.*)$")
		if ticks then
			-- Scan down for the matching bare closer (>= opener tick count)
			for close = open + 1, total do
				local ctext = getline(close)
				local cticks = ctext:match("^(%`+)[ \t]*$")
				if cticks and #cticks >= #ticks then
					local content = vim.api.nvim_buf_get_lines(viewer_buf, open, close - 1, false)
					-- content = 1-based lines open+1 .. close-1
					return { start_line = open, end_line = close, lang = vim.trim(lang), lines = content }
				end
			end
			return nil -- opener with no matching close
		end
	end
	return nil
end

--- LSP-verify a staged buffer: wait briefly for the server to re-publish
--- diagnostics after the replace, then report the error count. Never writes.
--- Skips silently when no LSP client is attached to the buffer (e.g. md/yaml).
--- @param buf integer  target buffer
--- @param resolved string  absolute path (for the notify message)
local function lsp_check_staged(buf, resolved)
	local clients = vim.lsp.get_clients({ bufnr = buf })
	if #clients == 0 then
		return
	end

	vim.defer_fn(function()
		if not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		local diags = vim.diagnostic.get(buf)
		local errs = vim.tbl_filter(function(d)
			return d.severity and d.severity <= vim.diagnostic.severity.ERROR
		end, diags)
		if #errs == 0 then
			vim.notify(string.format("LSP: %d diagnostic(s), 0 errors", #diags), vim.log.levels.INFO)
		else
			local d = errs[1]
			local sev = vim.diagnostic.severity[d.severity] or "?"
			vim.notify(
				string.format("⚠ LSP: %d error(s) — first %s at %d:%d", #errs, sev, d.lnum + 1, d.col + 1),
				vim.log.levels.WARN
			)
		end
	end, 400)
end

--- Apply the block under the cursor to its target file.
--- Content is read DIRECTLY FROM THE VIEWER BUFFER via block_from_buffer —
--- never from the parser's lines array, which has repeatedly truncated
--- content. Stages in the target buffer only — NO write. The user reviews,
--- then :w commits or u undoes. Full-file blocks replace the whole buffer;
--- path:42-58 blocks replace that line range.
--- Reports explicit success ("✅ Staged N lines → path") or failure
--- ("❌ <reason>") notifications.
--- @param lnum number  cursor line in the viewer
--- @param project_path string  CWD for relative path resolution
--- @param viewer_buf integer  viewer buffer handle
local function apply_block(lnum, project_path, viewer_buf)
	local viewer_win = vim.api.nvim_get_current_win()

	-- 1. Read the block content straight from the buffer (parser-independent)
	local blk = block_from_buffer(viewer_buf, lnum)
	if not blk then
		vim.notify("❌ Not inside a fenced code block", vim.log.levels.WARN)
		return
	end

	-- 2. Find the path comment among the first few content lines
	local path_line = nil
	local raw_path, start_line, end_line
	for i = 1, math.min(3, #blk.lines) do
		local p, s, e = parse_apply_path(blk.lines[i] or "")
		if p then
			path_line = i
			raw_path, start_line, end_line = p, s, e
			break
		end
	end
	if not raw_path then
		vim.notify("❌ No file path in this block — not a file block (use c to copy)", vim.log.levels.WARN)
		return
	end

	-- 3. Resolve to absolute
	local resolved
	if raw_path:sub(1, 1) == "/" then
		resolved = raw_path
	else
		resolved = vim.fn.resolve(project_path .. "/" .. raw_path)
	end

	-- 4. Content = buffer lines minus the path-comment line
	local content = {}
	for i = 1, #blk.lines do
		if i ~= path_line then
			table.insert(content, blk.lines[i])
		end
	end
	if #content == 0 then
		vim.notify("❌ Block is empty — nothing to apply", vim.log.levels.WARN)
		return
	end

	-- 5. File existence check with create prompt (mkdir parents).
	--    When the parent directory doesn't exist, ask explicitly and show
	--    the FULL path that would be created.
	local exists = vim.fn.filereadable(resolved) == 1
	if not exists then
		local parent = vim.fn.fnamemodify(resolved, ":h")
		local dir_exists = vim.fn.isdirectory(parent) == 1
		local msg
		if dir_exists then
			msg = "Create file?\n  " .. resolved
		else
			msg = "Directory doesn't exist:\n  " .. parent .. "\n\nCreate it and the file?\n  " .. resolved
		end
		local create = vim.fn.confirm(msg, "&Yes\n&No", 1)
		if create ~= 1 then
			vim.notify("❌ Cancelled — file not created", vim.log.levels.INFO)
			return
		end
		if not dir_exists then
			vim.fn.mkdir(parent, "p")
		end
	end

	-- 6. Find target window (not the viewer), vsplit if needed
	local target_win = nil
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		local wbuf = vim.api.nvim_win_get_buf(w)
		if wbuf ~= viewer_buf and vim.api.nvim_buf_is_valid(wbuf) then
			target_win = w
			break
		end
	end
	if not target_win then
		vim.cmd("vsplit")
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			local wbuf = vim.api.nvim_win_get_buf(w)
			if wbuf ~= viewer_buf then
				target_win = w
				break
			end
		end
		if not target_win then
			vim.notify("❌ Failed to create split", vim.log.levels.ERROR)
			return
		end
	end

	-- 7. Open the file and stage the replacement
	vim.api.nvim_set_current_win(target_win)
	local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(resolved))
	if not ok then
		vim.notify("❌ Failed to open: " .. tostring(err), vim.log.levels.ERROR)
		vim.api.nvim_set_current_win(viewer_win)
		return
	end
	local buf = vim.api.nvim_get_current_buf()
	if not vim.bo[buf].modifiable then
		vim.notify("❌ Buffer is not modifiable — won't apply", vim.log.levels.ERROR)
		vim.api.nvim_set_current_win(viewer_win)
		return
	end

	local total = vim.api.nvim_buf_line_count(buf)
	if start_line then
		-- Range replacement: validate against current buffer
		local finish = end_line or start_line
		if start_line < 1 or finish < start_line then
			vim.notify("❌ Invalid range " .. start_line .. "-" .. finish, vim.log.levels.ERROR)
			vim.api.nvim_set_current_win(viewer_win)
			return
		end
		if start_line > total then
			vim.notify(string.format("❌ Start %d beyond EOF (%d lines)", start_line, total), vim.log.levels.ERROR)
			vim.api.nvim_set_current_win(viewer_win)
			return
		end
		finish = math.min(finish, total)
		vim.api.nvim_buf_set_lines(buf, start_line - 1, finish, false, content)
		vim.api.nvim_win_set_cursor(target_win, { start_line, 0 })
	else
		-- Full-file replacement
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
		vim.api.nvim_win_set_cursor(target_win, { 1, 0 })
	end

	vim.notify(
		string.format("✅ Staged %d lines → %s — :w to commit, u to undo", #content, resolved),
		vim.log.levels.INFO
	)
	lsp_check_staged(buf, resolved)
end

--- Help float ----------------------------------------------------------------

local help_win = nil

local HELP_LINES = {
	"── Keymaps ────────────────────────────────────────────────",
	"",
	"[               previous file (this conversation)",
	"]               next file (this conversation)",
	"<A-[>           previous conversation",
	"<A-]>           next conversation",
	"a               apply block to file (stages; :w to commit)",
	"c               copy code block",
	"C               copy + navigate (to func decl if cursor on one)",
	"m               copy markdown file",
	"M               copy markdown + navigate to file",
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

	-- File-level blocks: blocks whose first few lines carry a path comment
	-- (whole delivered files, incl. markdown containers). Inner code blocks
	-- inside containers have no path comment and are excluded, so [ ]
	-- navigation lands on file starts first. Sorted by start_line.
	local file_blocks = {}
	for _, b in ipairs(blocks) do
		if block_file_path(b) then
			table.insert(file_blocks, b)
		end
	end
	table.sort(file_blocks, function(a, b)
		return a.start_line < b.start_line
	end)
	vim.notify(
		string.format("Viewer: %d file block(s), %d total — %s", #file_blocks, #blocks, get_title_line(conv)),
		vim.log.levels.INFO
	)

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
	vim.wo[win].statusline = "a apply c copy C nav m md M md+nav [ ] <A-[> <A-]> conv ? help"

	local km_opts = { buffer = buf, nowait = true, noremap = true }

	-- Close the vsplit window (restores original layout)
	local function close_view()
		close_help()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	-- File navigation: [ ] jumps between file starts IN THIS CONVERSATION
	-- only (falls back to all blocks when no file blocks are detected, so
	-- it never dead-ends). Conversation switching stays on <A-[> / <A-]>.
	vim.keymap.set("n", "]", function()
		navigate_block("next", vim.fn.line("."), file_blocks, blocks)
	end, km_opts)

	vim.keymap.set("n", "[", function()
		navigate_block("prev", vim.fn.line("."), file_blocks, blocks)
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

	-- Copy code block + navigate to file (or to function if on a decl line)
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

		-- 2. Extract path
		local raw_path, lineno = extract_path_from_line(block.lines[1] or "")
		if not raw_path then
			vim.notify("No file path in this block", vim.log.levels.WARN)
			return
		end

		-- 3. Check if cursor is on a function declaration — if so, navigate
		--    to that specific function instead of the file root + highlight it
		local cursor_line = vim.fn.getline(".")
		local lang = vim.trim(block.lang)
		local func_name = extract_func_name(cursor_line, lang)

		if func_name then
			navigate_to_function(raw_path, func_name, project_path, buf, lang)
		else
			navigate_to_path(raw_path, lineno, project_path, buf)
		end
	end, km_opts)

	-- Copy markdown file content
	vim.keymap.set("n", "m", function()
		local lnum = vim.fn.line(".")
		local md_block = find_md_container(lnum, blocks)
		if not md_block then
			vim.notify("Not inside a markdown block", vim.log.levels.WARN)
			return
		end
		-- Skip first line (path comment like # path/to/file.md FINAL)
		local content = {}
		for i = 2, #md_block.lines do
			table.insert(content, md_block.lines[i])
		end
		local text = table.concat(content, "\n")
		vim.fn.setreg("+", text)
		vim.fn.setreg('"', text)
		vim.notify(string.format("Copied markdown file (%d chars)", #text), vim.log.levels.INFO)
	end, km_opts)

	-- Copy markdown file content + navigate to file
	vim.keymap.set("n", "M", function()
		local lnum = vim.fn.line(".")
		local md_block = find_md_container(lnum, blocks)
		if not md_block then
			vim.notify("Not inside a markdown block", vim.log.levels.WARN)
			return
		end

		-- 1. Copy (skip path comment line)
		local content = {}
		for i = 2, #md_block.lines do
			table.insert(content, md_block.lines[i])
		end
		local text = table.concat(content, "\n")
		vim.fn.setreg("+", text)
		vim.fn.setreg('"', text)
		vim.notify(string.format("Copied markdown file (%d chars)", #text), vim.log.levels.INFO)

		-- 2. Extract path from first line + navigate
		local raw_path, lineno = extract_path_from_line(md_block.lines[1] or "")
		if not raw_path then
			vim.notify("No file path in markdown block", vim.log.levels.WARN)
			return
		end
		navigate_to_path(raw_path, lineno, project_path, buf)
	end, km_opts)

	-- Apply the block under the cursor (reads content from the buffer,
	-- parser-independent; stages in target; :w commits, u undoes)
	vim.keymap.set("n", "a", function()
		apply_block(vim.fn.line("."), project_path, buf)
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

pick_session = function()
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
