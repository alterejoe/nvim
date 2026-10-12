-- /home/altjoe/.config/nvim/lua/opencode-manage/links.lua FINAL-2
-- opencode-manage.links — follow doc/code links with gd.
-- One gesture, one syntax: a markdown link anywhere it appears — in a doc
-- OR in a code comment — jumps to its target. Bare note ids are also
-- accepted via the `managesee:` directive. When the cursor line carries no
-- link, gd falls back to LSP definition, so the key keeps its normal
-- meaning everywhere else.
--
--   [state paths](../../docs/slipbox/8h-state-paths.md)   -> opens the file
--   // managesee: 8h                                       -> resolves the id
--   [site](https://x.y)                                    -> external open
--
-- Resolution for a link target: relative to the current file first, then a
-- project-wide search for `<id>-*.md` under the git root, then the global
-- `~/docs` catalogue. Anchors (`#section`) are stripped before lookup.
--
-- NOTE: the entry point is `follow`, not `goto` — Lua reserves `goto` as a
-- keyword, so `M.goto` / `links.goto` would be a syntax error.

local M = {}

local function buf_dir()
	local name = vim.api.nvim_buf_get_name(0)
	if name == "" then
		return vim.fn.getcwd()
	end
	return vim.fn.fnamemodify(name, ":h")
end

-- Git root: walk up from `start` to the first directory containing .git.
local function git_root(start)
	local dir = start
	for _ = 1, 40 do
		if vim.fn.isdirectory(dir .. "/.git") == 1 then
			return dir
		end
		local parent = vim.fn.fnamemodify(dir, ":h")
		if parent == dir then
			return nil
		end
		dir = parent
	end
	return nil
end

-- The markdown `](target)` on this line nearest the cursor column, else the
-- first one on the line. Returns the raw target text or nil.
local function find_markdown_link(line, col)
	local best, best_dist
	local init = 1
	while true do
		local s, e, target = line:find("%]%(([^%)]*)%)", init)
		if not s then
			break
		end
		local dist = math.abs(s - 1 - col)
		if not best_dist or dist < best_dist then
			best, best_dist = target, dist
		end
		init = e + 1
	end
	return best
end

-- The `managesee: <id-or-path>` directive on this line, if present.
local function find_directive(line)
	return line:match("[Mm]anagesee:%s*([%w%-_%./#]+)")
end

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strip_anchor(t)
	return (t:gsub("#.*$", ""))
end

-- Search a root for a note file whose name starts with `<id>-`.
-- Prefers slipbox, then references, then the shortest path.
local function find_note(root, id)
	local hits = vim.fn.globpath(root, "**/" .. id .. "-*.md", false, true)
	if #hits == 0 then
		return nil
	end
	local function rank(p)
		if p:find("/slipbox/", 1, true) then
			return 1
		end
		if p:find("/references/", 1, true) then
			return 2
		end
		return 3
	end
	table.sort(hits, function(a, b)
		local ra, rb = rank(a), rank(b)
		if ra ~= rb then
			return ra < rb
		end
		return #a < #b
	end)
	return hits[1]
end

-- Resolve a link target to an existing absolute path, or nil.
local function resolve(target)
	target = trim(target)
	target = target:gsub("^<", ""):gsub(">$", "")
	local path = strip_anchor(target)
	if path == "" then
		return nil
	end

	-- Relative to the current file first.
	local rel = path
	if rel:sub(1, 1) ~= "/" and not rel:match("^~") then
		rel = buf_dir() .. "/" .. rel
	end
	rel = vim.fn.fnamemodify(rel, ":p")
	if vim.fn.filereadable(rel) == 1 then
		return rel
	end

	-- A bare id (no slash, no extension) -> search project + global docs.
	local id = path:gsub("%.md$", "")
	if not id:find("/") then
		local root = git_root(buf_dir()) or vim.fn.getcwd()
		local hit = find_note(root, id)
		if hit then
			return vim.fn.fnamemodify(hit, ":p")
		end
		local home = vim.env.HOME
		if home and home ~= "" then
			hit = find_note(home .. "/docs", id)
			if hit then
				return vim.fn.fnamemodify(hit, ":p")
			end
		end
	end
	return nil
end

local function open_target(target)
	if target:match("^%a[%w+.-]*://") or target:match("^mailto:") then
		local ok = pcall(vim.ui.open, target)
		if not ok then
			vim.notify("manage links: cannot open " .. target, vim.log.levels.WARN)
		end
		return true
	end
	local path = resolve(target)
	if not path then
		return false
	end
	vim.cmd("edit " .. vim.fn.fnameescape(path))
	return true
end

--- The link target on the cursor line, or nil.
--- @return string|nil
function M.link_under_cursor()
	local line = vim.api.nvim_get_current_line()
	local col = vim.api.nvim_win_get_cursor(0)[2]
	local target = find_markdown_link(line, col)
	if target and trim(target) ~= "" then
		return target
	end
	return find_directive(line)
end

--- Jump to the doc/code link on the cursor line. Falls back to LSP
--- definition when the line carries no link.
function M.follow()
	local target = M.link_under_cursor()
	if target and trim(target) ~= "" then
		if open_target(target) then
			return
		end
		vim.notify(
			"manage links: cannot resolve '" .. trim(target) .. "' from " .. buf_dir(),
			vim.log.levels.WARN
		)
		return
	end
	local ok = pcall(vim.lsp.buf.definition)
	if not ok then
		vim.notify("manage links: no link here and no LSP definition", vim.log.levels.INFO)
	end
end

return M
