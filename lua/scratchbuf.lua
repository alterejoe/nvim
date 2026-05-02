--[[
scratchbuf.lua v2
Generic oil.nvim-style editable list buffer with optional multi-pane layout.

Single-pane mode (v1 - no opts.right):
  Backwards compatible. All v1 opts work unchanged.

Multi-pane mode (opts.right declared):
  opts:
    title        string          Primary pane title
    lines        string[]        Primary pane initial lines
    prefixes     string[]        Typed mode prefixes (optional)
    metadata     table           Opaque data keyed by content (optional)
    on_open      fn(line)        Called on CR in primary pane
    on_save      fn(changes)     Called on W in primary pane
    on_ready     fn(buf, win, layout)  Called after all panes are ready
    on_cursor    fn(line, parsed, layout)  Called on CursorMoved in primary pane
    right_width  number          Fixed fraction of total width for right column (optional)
                                 Omit to auto-size from content.
    right        table[]         Right column panes, top to bottom:
      {
        title    string          Pane title
        role     string          "editable" (default) or "readonly"
        height   number          Fraction of total height this pane takes (last pane fills remainder)
        lines    string[]        Initial lines
        prefixes string[]        Typed mode prefixes (optional)
        metadata table           Opaque data keyed by content (optional)
        on_open  fn(line)        Called on CR (editable panes only)
        on_save  fn(changes)     Called on W (editable panes only, optional)
        refresh  fn()            Returns fresh string[] (optional)
        current  string          Line to highlight on open (optional)
        filetype string          Buffer filetype (optional)
      }

layout API (passed to on_ready and on_cursor):
  layout.set(title, lines)   Replace lines in named pane, preserve cursor position
  layout.get(title)          Get current lines from named pane

All panes share:
  <Tab>   Focus next pane
  <S-Tab> Focus prev pane
  q / Esc Close all panes

Editable panes have full scratchbuf keymaps (CR, W, o, O, dd, p, P, /).
Readonly panes are scroll-only.
Keymaps configured in keymaps/scratchbuf.lua.

Typed mode (opts.prefixes / rp.prefixes):
  Prefix strings e.g. { "GET ", "POST ", "header:" }
  Indentation = nesting. on_open/on_save entries carry { prefix, content, indent, parents, meta }.
--]]
local M = {}
local km = require("keymaps.scratchbuf")

-- ============================================================
-- Flat diff
-- ============================================================
local function diff(original, current)
	local orig_idx = {}
	for i, v in ipairs(original) do
		orig_idx[v] = i
	end
	local curr_idx = {}
	for i, v in ipairs(current) do
		curr_idx[v] = i
	end
	local renamed, deleted, created = {}, {}, {}
	for i, orig in ipairs(original) do
		if not curr_idx[orig] then
			local curr = current[i]
			if curr and curr ~= "" and not orig_idx[curr] then
				table.insert(renamed, { old = orig, new = curr })
			else
				table.insert(deleted, orig)
			end
		end
	end
	for i, curr in ipairs(current) do
		if curr ~= "" and not orig_idx[curr] then
			local orig = original[i]
			if not orig then
				table.insert(created, curr)
			end
		end
	end
	local reordered = false
	if #original == #current then
		local all_present = true
		for _, v in ipairs(original) do
			if not curr_idx[v] then
				all_present = false
				break
			end
		end
		if all_present then
			for i, v in ipairs(original) do
				if current[i] ~= v then
					reordered = true
					break
				end
			end
		end
	end
	return {
		renamed = renamed,
		deleted = deleted,
		created = created,
		reordered = reordered,
		order = current,
	}
end

-- ============================================================
-- Typed mode: parse + diff
-- ============================================================
local function parse_line(line, prefixes)
	local indent_str = line:match("^(%s*)") or ""
	local indent = #indent_str
	local trimmed = vim.trim(line)
	for _, prefix in ipairs(prefixes) do
		if vim.startswith(trimmed, prefix) then
			local content = vim.trim(trimmed:sub(#prefix + 1))
			return { prefix = prefix, content = content, indent = indent, raw = line }
		end
	end
	return { prefix = nil, content = trimmed, indent = indent, raw = line }
end

local function parse_lines(lines, prefixes)
	local result = {}
	local stack = {}
	for _, line in ipairs(lines) do
		if vim.trim(line) ~= "" then
			local parsed = parse_line(line, prefixes)
			while #stack > 0 and stack[#stack].indent >= parsed.indent do
				table.remove(stack)
			end
			local parents = {}
			for _, frame in ipairs(stack) do
				table.insert(parents, frame.parsed)
			end
			parsed.parents = parents
			table.insert(result, parsed)
			table.insert(stack, { indent = parsed.indent, parsed = parsed })
		end
	end
	return result
end

local function typed_diff(orig_parsed, curr_parsed, metadata)
	local meta = metadata or {}
	local orig_by_content = {}
	for i, p in ipairs(orig_parsed) do
		orig_by_content[p.content] = i
	end
	local curr_by_content = {}
	for i, p in ipairs(curr_parsed) do
		curr_by_content[p.content] = i
	end
	local renamed, deleted, created = {}, {}, {}
	for i, orig in ipairs(orig_parsed) do
		if not curr_by_content[orig.content] then
			local curr = curr_parsed[i]
			if curr and curr.content ~= "" and not orig_by_content[curr.content] then
				table.insert(renamed, {
					old = orig.content, new = curr.content,
					old_prefix = orig.prefix, new_prefix = curr.prefix,
					old_parents = orig.parents, new_parents = curr.parents,
					meta = meta[orig.content],
				})
			else
				table.insert(deleted, {
					content = orig.content, prefix = orig.prefix,
					parents = orig.parents, meta = meta[orig.content],
				})
			end
		end
	end
	for i, curr in ipairs(curr_parsed) do
		if curr.content ~= "" and not orig_by_content[curr.content] then
			local orig = orig_parsed[i]
			if not orig then
				table.insert(created, {
					content = curr.content, prefix = curr.prefix,
					parents = curr.parents, meta = nil,
				})
			end
		end
	end
	local reordered = false
	local orig_common, curr_common = {}, {}
	for _, p in ipairs(orig_parsed) do
		if curr_by_content[p.content] then table.insert(orig_common, p.content) end
	end
	for _, p in ipairs(curr_parsed) do
		if orig_by_content[p.content] then table.insert(curr_common, p.content) end
	end
	if #orig_common == #curr_common then
		for i, v in ipairs(orig_common) do
			if curr_common[i] ~= v then reordered = true; break end
		end
	end
	return {
		renamed = renamed, deleted = deleted, created = created,
		reordered = reordered, order = curr_parsed,
	}
end

-- ============================================================
-- Buffer helpers
-- ============================================================
local function fuzzy_filter(buf, win, lines)
	local ns = vim.api.nvim_create_namespace("scratchbuf_filter")
	local query = ""
	local function apply(q)
		local filtered = {}
		for _, l in ipairs(lines) do
			if q == "" or l:lower():find(q:lower(), 1, true) then
				table.insert(filtered, l)
			end
		end
		if #filtered == 0 then filtered = lines end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, filtered)
		vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
			virt_text = { { "  /" .. q .. "Û", "Comment" } },
			virt_text_pos = "eol",
		})
		vim.api.nvim_win_set_cursor(win, { 1, 0 })
		vim.cmd("redraw")
		return filtered
	end
	local filtered = apply("")
	local function loop()
		while true do
			local ok, ch = pcall(vim.fn.getcharstr)
			if not ok then break end
			if ch == "\27" then
				vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
				vim.cmd("redraw")
				break
			elseif ch == "\r" then
				vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
				vim.cmd("redraw")
				break
			elseif ch == "\8" or ch == "\127" or ch == "\x80\xfd-" or ch == "\x80kb" then
				if #query > 0 then
					query = query:sub(1, -2)
					filtered = apply(query)
				end
			elseif ch == "\14" or ch == "j" then
				local row = vim.api.nvim_win_get_cursor(win)[1]
				local total = vim.api.nvim_buf_line_count(buf)
				if row < total then
					vim.api.nvim_win_set_cursor(win, { row + 1, 0 })
					vim.cmd("redraw")
				end
			elseif ch == "\16" or ch == "k" then
				local row = vim.api.nvim_win_get_cursor(win)[1]
				if row > 1 then
					vim.api.nvim_win_set_cursor(win, { row - 1, 0 })
					vim.cmd("redraw")
				end
			elseif #ch == 1 and ch:byte() >= 32 then
				query = query .. ch
				filtered = apply(query)
			end
		end
	end
	loop()
end

-- raw=true: preserve indent, filter only blank lines (typed mode)
-- raw=false: trim each line, filter blanks (flat mode)
local function get_lines(buf, raw)
	local result = {}
	for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if vim.trim(l) ~= "" then
			table.insert(result, raw and l or vim.trim(l))
		end
	end
	return result
end

-- ============================================================
-- Layout dimensions
-- ============================================================
local function compute_dims(opts)
	local total_w = math.floor(vim.o.columns * 0.88)
	local total_h = math.min(math.floor(vim.o.lines * 0.78), 48)

	-- single-pane: v1 sizing
	if not opts.right then
		local w = math.floor(vim.o.columns * 0.5)
		local h = math.min(math.max(#opts.lines + 2, 5), math.floor(vim.o.lines * 0.6))
		return {
			single = true,
			primary = {
				row = math.floor((vim.o.lines - h) / 2),
				col = math.floor((vim.o.columns - w) / 2),
				width = w,
				height = h,
			},
		}
	end

	-- compute right column content width
	local right_w
	if opts.right_width then
		right_w = math.max(math.floor(total_w * opts.right_width), 20)
	else
		local max_len = 18
		for _, rp in ipairs(opts.right) do
			for _, l in ipairs(rp.lines or {}) do
				max_len = math.max(max_len, #l + 2)
			end
			max_len = math.max(max_len, #(rp.title or "") + 4)
		end
		right_w = math.min(math.max(max_len + 2, 24), math.floor(total_w * 0.42))
	end

	-- total_w = left_w + 2(borders) + 1(gap) + right_w + 2(borders)
	local left_w = total_w - right_w - 5
	local start_r = math.floor((vim.o.lines - total_h) / 2)
	local start_c = math.floor((vim.o.columns - total_w) / 2)
	-- right column starts after left window's right border + 1 gap
	local right_col = start_c + left_w + 3

	-- distribute right pane heights (visual height = content_h + 2 for borders)
	local right_dims = {}
	local current_row = start_r
	local remaining_visual = total_h
	local n = #opts.right

	for i, rp in ipairs(opts.right) do
		local visual_h
		if i == n then
			visual_h = remaining_visual
		elseif rp.height then
			visual_h = math.max(math.floor(total_h * rp.height), 5)
		else
			visual_h = math.floor(total_h / n)
		end
		local content_h = math.max(visual_h - 2, 3)
		table.insert(right_dims, {
			row = current_row,
			col = right_col,
			width = right_w,
			height = content_h,
		})
		current_row = current_row + visual_h
		remaining_visual = remaining_visual - visual_h
	end

	return {
		single = false,
		primary = {
			row = start_r,
			col = start_c,
			width = left_w,
			height = total_h,
		},
		right = right_dims,
	}
end

-- ============================================================
-- Window helpers
-- ============================================================
local function open_win_at(buf, dims, title, focus)
	return vim.api.nvim_open_win(buf, focus or false, {
		relative = "editor",
		width = dims.width,
		height = dims.height,
		row = dims.row,
		col = dims.col,
		style = "minimal",
		border = "rounded",
		title = title and (" " .. title .. " ") or nil,
		title_pos = "center",
	})
end

local function set_win_opts(win)
	vim.wo[win].cursorline = true
	vim.wo[win].number = true
	vim.wo[win].signcolumn = "no"
	vim.wo[win].wrap = false
end

local function set_readonly_win_opts(win)
	vim.wo[win].cursorline = false
	vim.wo[win].number = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].wrap = false
end

-- ============================================================
-- Layout API
-- ============================================================
local function make_layout(panes_by_title)
	return {
		set = function(title, new_lines)
			local p = panes_by_title[title]
			if not p or not vim.api.nvim_buf_is_valid(p.buf) then return end
			local cursor = { 1, 0 }
			if vim.api.nvim_win_is_valid(p.win) then
				cursor = vim.api.nvim_win_get_cursor(p.win)
			end
			local was_mod = vim.bo[p.buf].modifiable
			vim.bo[p.buf].modifiable = true
			vim.api.nvim_buf_set_lines(p.buf, 0, -1, false, new_lines)
			vim.bo[p.buf].modifiable = was_mod
			if vim.api.nvim_win_is_valid(p.win) then
				local total = vim.api.nvim_buf_line_count(p.buf)
				local row = math.min(cursor[1], math.max(total, 1))
				pcall(vim.api.nvim_win_set_cursor, p.win, { row, 0 })
			end
		end,
		get = function(title)
			local p = panes_by_title[title]
			if not p or not vim.api.nvim_buf_is_valid(p.buf) then return {} end
			return vim.api.nvim_buf_get_lines(p.buf, 0, -1, false)
		end,
	}
end

-- ============================================================
-- Pane setup
-- pane   = { buf, win, title, role, original, scratch_reg }
-- pane_opts = the opts table for this pane (primary opts or rp opts)
-- ============================================================
local function setup_pane(pane, all_panes, layout, pane_opts)
	local buf = pane.buf
	local win = pane.win
	local k = km.keys
	local typed = pane_opts.prefixes ~= nil

	local function map(lhs, rhs, desc, mode)
		if not lhs then return end
		vim.keymap.set(mode or "n", lhs, rhs, {
			buffer = buf, nowait = true, noremap = true, desc = desc,
		})
	end

	-- close all panes
	local function close_all()
		vim.schedule(function()
			for _, p in ipairs(all_panes) do
				if vim.api.nvim_win_is_valid(p.win) then
					vim.api.nvim_win_close(p.win, true)
				end
				if vim.api.nvim_buf_is_valid(p.buf) then
					vim.api.nvim_buf_delete(p.buf, { force = true })
				end
			end
		end)
	end

	for _, lhs in ipairs(k.close) do
		map(lhs, close_all, "Close all panes")
	end

	-- focus cycling
	local my_idx = 1
	for i, p in ipairs(all_panes) do
		if p.buf == buf then my_idx = i; break end
	end

	if #all_panes > 1 then
		map(k.focus_next, function()
			local next_idx = (my_idx % #all_panes) + 1
			vim.api.nvim_set_current_win(all_panes[next_idx].win)
		end, "Focus next pane")
		map(k.focus_prev, function()
			local prev_idx = ((my_idx - 2) % #all_panes) + 1
			vim.api.nvim_set_current_win(all_panes[prev_idx].win)
		end, "Focus prev pane")
	end

	-- unsaved changes warning on window close
	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		once = true,
		callback = function()
			if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
				vim.notify(
					"[" .. (pane_opts.title or "scratchbuf") .. "] unsaved changes discarded",
					vim.log.levels.WARN
				)
			end
		end,
	})

	-- readonly: no editing keymaps
	if pane.role == "readonly" then
		return
	end

	-- current line highlight
	if pane_opts.current then
		local hl_ns = vim.api.nvim_create_namespace("scratchbuf_current_" .. buf)
		for i, line in ipairs(pane_opts.lines or {}) do
			if vim.trim(line) == pane_opts.current then
				vim.api.nvim_buf_add_highlight(buf, hl_ns, "CursorLine", i - 1, 0, -1)
				vim.api.nvim_win_set_cursor(win, { i, 0 })
				break
			end
		end
	end

	-- CR: open entry, close all panes first
	if pane_opts.on_open then
		map(k.open, function()
			local raw_line = vim.api.nvim_get_current_line()
			local line = vim.trim(raw_line)
			if line == "" then return end
			local parsed_entry = nil
			if typed then
				local all_raw = get_lines(buf, true)
				local all_parsed = parse_lines(all_raw, pane_opts.prefixes)
				for _, p in ipairs(all_parsed) do
					if p.raw == raw_line then
						p.meta = pane_opts.metadata and pane_opts.metadata[p.content]
						parsed_entry = p
						break
					end
				end
				if not parsed_entry then
					parsed_entry = parse_line(raw_line, pane_opts.prefixes)
					parsed_entry.parents = {}
					parsed_entry.meta = pane_opts.metadata and pane_opts.metadata[parsed_entry.content]
				end
			end
			vim.schedule(function()
				for _, p in ipairs(all_panes) do
					if vim.api.nvim_win_is_valid(p.win) then
						vim.api.nvim_win_close(p.win, true)
					end
					if vim.api.nvim_buf_is_valid(p.buf) then
						vim.api.nvim_buf_delete(p.buf, { force = true })
					end
				end
				if typed then
					pane_opts.on_open(parsed_entry.content, parsed_entry)
				else
					pane_opts.on_open(line)
				end
			end)
		end, "Open entry")
	end

	map(k.new_below, function()
		local lnum = vim.api.nvim_win_get_cursor(win)[1]
		vim.api.nvim_buf_set_lines(buf, lnum, lnum, false, { "" })
		vim.api.nvim_win_set_cursor(win, { lnum + 1, 0 })
		vim.cmd("startinsert")
	end, "New entry below")

	map(k.new_above, function()
		local lnum = vim.api.nvim_win_get_cursor(win)[1]
		vim.api.nvim_buf_set_lines(buf, lnum - 1, lnum - 1, false, { "" })
		vim.api.nvim_win_set_cursor(win, { lnum, 0 })
		vim.cmd("startinsert")
	end, "New entry above")

	map("d", "<Nop>", "Block d operator")
	map(k.cut, function()
		local lnum = vim.api.nvim_win_get_cursor(win)[1]
		local lines = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)
		local raw = lines[1] or ""
		local line = vim.trim(raw)
		if line == "" then return end
		pane.scratch_reg = raw
		vim.api.nvim_buf_set_lines(buf, lnum - 1, lnum, false, {})
		vim.bo[buf].modified = true
		local total = vim.api.nvim_buf_line_count(buf)
		local new_row = math.min(lnum, math.max(total, 1))
		if total > 0 then vim.api.nvim_win_set_cursor(win, { new_row, 0 }) end
		vim.notify("cut: " .. line, vim.log.levels.INFO)
	end, "Cut entry")

	map(k.paste_below, function()
		if not pane.scratch_reg then
			vim.notify("scratchbuf: register empty", vim.log.levels.WARN)
			return
		end
		local lnum = vim.api.nvim_win_get_cursor(win)[1]
		vim.api.nvim_buf_set_lines(buf, lnum, lnum, false, { pane.scratch_reg })
		vim.bo[buf].modified = true
		vim.api.nvim_win_set_cursor(win, { lnum + 1, 0 })
	end, "Paste below")

	map(k.paste_above, function()
		if not pane.scratch_reg then
			vim.notify("scratchbuf: register empty", vim.log.levels.WARN)
			return
		end
		local lnum = vim.api.nvim_win_get_cursor(win)[1]
		vim.api.nvim_buf_set_lines(buf, lnum - 1, lnum - 1, false, { pane.scratch_reg })
		vim.bo[buf].modified = true
		vim.api.nvim_win_set_cursor(win, { lnum, 0 })
	end, "Paste above")

	map(k.filter, function()
		fuzzy_filter(buf, win, get_lines(buf, typed))
	end, "Fuzzy filter")

	if k.refresh then
		map(k.refresh, function()
			if pane_opts.refresh then
				local fresh = pane_opts.refresh()
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, fresh)
				pane.original = vim.deepcopy(fresh)
				pane.scratch_reg = nil
				vim.bo[buf].modified = false
				vim.notify("scratchbuf: refreshed", vim.log.levels.INFO)
			end
		end, "Refresh")
	end

	-- W / BufWriteCmd: only set up if on_save provided
	if pane_opts.on_save then
		map(k.save, function()
			vim.api.nvim_exec_autocmds("BufWriteCmd", { buffer = buf })
		end, "Save")

		vim.api.nvim_create_autocmd("BufWriteCmd", {
			buffer = buf,
			callback = function()
				local changes
				if typed then
					local curr_raw = get_lines(buf, true)
					local orig_parsed = parse_lines(pane.original, pane_opts.prefixes)
					local curr_parsed = parse_lines(curr_raw, pane_opts.prefixes)
					changes = typed_diff(orig_parsed, curr_parsed, pane_opts.metadata)
				else
					local current = get_lines(buf)
					changes = diff(pane.original, current)
				end
				local ok, err = pcall(pane_opts.on_save, changes)
				if ok then
					vim.bo[buf].modified = false
					local parts = {}
					if #changes.renamed > 0 then table.insert(parts, #changes.renamed .. " renamed") end
					if #changes.deleted > 0 then table.insert(parts, #changes.deleted .. " deleted") end
					if #changes.created > 0 then table.insert(parts, #changes.created .. " created") end
					if changes.reordered then table.insert(parts, "reordered") end
					vim.notify(
						"[" .. (pane_opts.title or "scratchbuf") .. "] "
							.. (#parts > 0 and table.concat(parts, ", ") or "no changes"),
						vim.log.levels.INFO
					)
					if pane_opts.refresh then
						local fresh = pane_opts.refresh()
						vim.api.nvim_buf_set_lines(buf, 0, -1, false, fresh)
						pane.original = vim.deepcopy(fresh)
						pane.scratch_reg = nil
					end
				else
					vim.notify(
						"[" .. (pane_opts.title or "scratchbuf") .. "] save failed: " .. tostring(err),
						vim.log.levels.ERROR
					)
				end
			end,
		})
	end
end

-- ============================================================
-- on_cursor helper: parse current line in primary pane
-- ============================================================
local function resolve_cursor_entry(buf, opts)
	local raw_line = vim.api.nvim_get_current_line()
	local line = vim.trim(raw_line)
	local parsed_entry = nil
	if opts.prefixes then
		local all_raw = get_lines(buf, true)
		local all_parsed = parse_lines(all_raw, opts.prefixes)
		for _, p in ipairs(all_parsed) do
			if p.raw == raw_line then
				p.meta = opts.metadata and opts.metadata[p.content]
				parsed_entry = p
				break
			end
		end
		if not parsed_entry then
			parsed_entry = parse_line(raw_line, opts.prefixes)
			parsed_entry.parents = {}
			parsed_entry.meta = opts.metadata and opts.metadata[parsed_entry.content]
		end
	end
	return line, parsed_entry
end

-- ============================================================
-- M.open
-- ============================================================
function M.open(opts)
	assert(opts.title, "scratchbuf: title required")
	assert(opts.lines, "scratchbuf: lines required")
	assert(opts.on_save, "scratchbuf: on_save required")

	-- dedupe: if already open, focus it
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		local b = vim.api.nvim_win_get_buf(w)
		if vim.b[b]._scratchbuf == opts.title then
			vim.api.nvim_set_current_win(w)
			return
		end
	end

	local dims = compute_dims(opts)
	local all_panes = {}
	local panes_by_title = {}

	-- --------------------------------------------------------
	-- Primary pane
	-- --------------------------------------------------------
	local primary_buf = vim.api.nvim_create_buf(false, true)
	vim.b[primary_buf]._scratchbuf = opts.title
	vim.api.nvim_buf_set_lines(primary_buf, 0, -1, false, opts.lines)
	vim.bo[primary_buf].buftype = "acwrite"
	vim.bo[primary_buf].bufhidden = "wipe"
	vim.bo[primary_buf].swapfile = false
	vim.bo[primary_buf].filetype = opts.filetype or "scratchbuf"
	vim.bo[primary_buf].modified = false

	local primary_win = open_win_at(primary_buf, dims.primary, opts.title, true)
	set_win_opts(primary_win)

	local primary_pane = {
		buf = primary_buf,
		win = primary_win,
		title = opts.title,
		role = "primary",
		original = vim.deepcopy(opts.lines),
		scratch_reg = nil,
	}
	table.insert(all_panes, primary_pane)
	panes_by_title[opts.title] = primary_pane

	-- --------------------------------------------------------
	-- Right panes
	-- --------------------------------------------------------
	if opts.right then
		for i, rp_opts in ipairs(opts.right) do
			local rp_buf = vim.api.nvim_create_buf(false, true)
			local role = rp_opts.role or "editable"
			local lines = rp_opts.lines or {}

			vim.api.nvim_buf_set_lines(rp_buf, 0, -1, false, lines)
			vim.bo[rp_buf].bufhidden = "wipe"
			vim.bo[rp_buf].swapfile = false
			vim.bo[rp_buf].filetype = rp_opts.filetype or "scratchbuf"

			if role == "readonly" then
				vim.bo[rp_buf].buftype = "nofile"
				vim.bo[rp_buf].modifiable = false
			else
				vim.bo[rp_buf].buftype = "acwrite"
				vim.bo[rp_buf].modified = false
			end

			local rp_win = open_win_at(rp_buf, dims.right[i], rp_opts.title, false)

			if role == "readonly" then
				set_readonly_win_opts(rp_win)
			else
				set_win_opts(rp_win)
			end

			local rp = {
				buf = rp_buf,
				win = rp_win,
				title = rp_opts.title,
				role = role,
				original = vim.deepcopy(lines),
				scratch_reg = nil,
			}
			table.insert(all_panes, rp)
			if rp_opts.title then
				panes_by_title[rp_opts.title] = rp
			end
		end
	end

	-- --------------------------------------------------------
	-- Layout API
	-- --------------------------------------------------------
	local layout = opts.right and make_layout(panes_by_title) or nil

	-- --------------------------------------------------------
	-- Keymaps for all panes
	-- --------------------------------------------------------
	setup_pane(primary_pane, all_panes, layout, opts)

	if opts.right then
		for i, rp_opts in ipairs(opts.right) do
			local rp = all_panes[i + 1]
			setup_pane(rp, all_panes, layout, rp_opts)
		end
	end

	-- --------------------------------------------------------
	-- on_cursor: fires on CursorMoved in primary pane
	-- --------------------------------------------------------
	if opts.on_cursor then
		vim.api.nvim_create_autocmd("CursorMoved", {
			buffer = primary_buf,
			callback = function()
				if not vim.api.nvim_buf_is_valid(primary_buf) then return end
				local line, parsed = resolve_cursor_entry(primary_buf, opts)
				opts.on_cursor(line, parsed, layout)
			end,
		})
		-- fire once on open so preview is populated immediately
		vim.schedule(function()
			if vim.api.nvim_buf_is_valid(primary_buf) and vim.api.nvim_win_is_valid(primary_win) then
				local line, parsed = resolve_cursor_entry(primary_buf, opts)
				opts.on_cursor(line, parsed, layout)
			end
		end)
	end

	-- --------------------------------------------------------
	-- which-key + on_ready
	-- --------------------------------------------------------
	km.register_which_key(primary_buf)

	if opts.on_ready then
		opts.on_ready(primary_buf, primary_win, layout)
	end

	-- ensure primary has focus
	vim.api.nvim_set_current_win(primary_win)
end

return M
