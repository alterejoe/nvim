-- /home/altjoe/.config/nvim/lua/opencode-manage/bookmarks.lua FINAL
-- opencode-manage.bookmarks — the session bookmark store.
-- Bookmarks are PROPOSALS with the marker path <project>/.opencode/bookmarks.md:
-- the session-bookmarks evaluation skill emits them via emit_proposal at
-- session end, the bookmarksview panel reviews them (da/dr/ga), and
-- accept() moves them into the project's accepted store
-- (manage.bookmarks.jsonl). The marker path is VIRTUAL — accepting a
-- bookmark never writes a file; it appends a structured entry
-- {title, category, summary, keywords, why, session_id, message_id, path}.
-- Search runs over the NORMALIZED layer (title/summary/keywords/category/
-- why), not raw session prose — that is what makes it reliable across
-- terminology drift. The store is per-project, next to the proposal queue
-- the bookmark came from.

local proposals = require("opencode-manage.proposals")

local M = {}

--- Marker: any absolute path ending in /.opencode/bookmarks.md.
--- @param p table
--- @return boolean
function M.is_bookmark(p)
	return type(p.path) == "string" and p.path:match("/%.opencode/bookmarks%.md$") ~= nil
end

--- Parse the bookmark payload from a proposal's content (JSON).
--- @param p table
--- @return table|nil
local function parse(p)
	if type(p.content) ~= "string" or p.content == "" then
		return nil
	end
	local ok, data = pcall(vim.json.decode, p.content)
	if not ok or type(data) ~= "table" then
		return nil
	end
	return data
end

--- Accepted store path: next to the proposal file that carried the bookmark.
--- @param p table
--- @return string
local function accepted_file(p)
	local dir = p._file and vim.fn.fnamemodify(p._file, ":h") or (vim.fn.getcwd() .. "/.opencode")
	return dir .. "/manage.bookmarks.jsonl"
end

--- All accepted bookmarks in the current project.
--- @return table[]
function M.list_accepted()
	local f = vim.fn.getcwd() .. "/.opencode/manage.bookmarks.jsonl"
	if vim.fn.filereadable(f) ~= 1 then
		return {}
	end
	local out = {}
	for _, line in ipairs(vim.fn.readfile(f)) do
		if line ~= "" then
			local ok, e = pcall(vim.json.decode, line)
			if ok and type(e) == "table" then
				out[#out + 1] = e
			end
		end
	end
	return out
end

--- Accept a bookmark proposal: append the structured entry to the store and
--- mark the proposal accepted (stays visible in the queue as [applied]).
--- @param p table
--- @return boolean
function M.accept(p)
	if not M.is_bookmark(p) then
		return false
	end
	local data = parse(p)
	if not data then
		vim.notify("❌ bookmarks: malformed payload — nothing accepted", vim.log.levels.ERROR)
		return false
	end
	local entry = {
		ts = p.ts or os.time() * 1000,
		session_id = data.session_id or p.sessionID or "",
		message_id = data.message_id or "",
		category = p.group or "misc",
		title = data.title or "(untitled)",
		summary = data.summary or "",
		keywords = data.keywords or {},
		why = p.reason or "",
		path = data.path or "",
		project = p._project or "",
	}
	local f = accepted_file(p)
	vim.fn.mkdir(vim.fn.fnamemodify(f, ":h"), "p")
	local fd = io.open(f, "a")
	if not fd then
		vim.notify("❌ bookmarks: cannot write " .. f, vim.log.levels.ERROR)
		return false
	end
	fd:write(vim.json.encode(entry), "\n")
	fd:close()
	proposals.set_status(p, "accepted")
	vim.notify("🔖 Bookmarked: " .. entry.title, vim.log.levels.INFO)
	return true
end

--- Keyword search over the normalized layer. Every token must match
--- somewhere in title/summary/keywords/category/why (case-insensitive).
--- @param query string
--- @return table[]
function M.search(query)
	local items = M.list_accepted()
	if #items == 0 then
		return {}
	end
	local tokens = {}
	for t in (query or ""):lower():gmatch("%S+") do
		tokens[#tokens + 1] = t
	end
	if #tokens == 0 then
		return items
	end
	local out = {}
	for _, e in ipairs(items) do
		local hay = table.concat({
			e.title or "",
			e.summary or "",
			e.category or "",
			e.why or "",
			e.path or "",
			table.concat(e.keywords or {}, " "),
		}, " "):lower()
		local all = true
		for _, t in ipairs(tokens) do
			if not hay:find(t, 1, true) then
				all = false
				break
			end
		end
		if all then
			out[#out + 1] = e
		end
	end
	return out
end

--- Best-effort session transcript file for a session id (session_diff JSON).
--- @param session_id string|nil
--- @return string|nil
function M.session_file(session_id)
	if not session_id or session_id == "" then
		return nil
	end
	local f = (vim.env.HOME or "") .. "/.local/share/opencode/storage/session_diff/" .. session_id .. ".json"
	if vim.fn.filereadable(f) == 1 then
		return f
	end
	return nil
end

return M
