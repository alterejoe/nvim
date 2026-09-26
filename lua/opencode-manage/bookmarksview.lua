-- /home/altjoe/.config/nvim/lua/opencode-manage/bookmarksview.lua FINAL
-- opencode-manage.bookmarksview — session bookmark review panel (console adapter).
-- One-glance review: the ROW is the decision — category (group separator),
-- title, ≤12-word why, session tag. da/dr on sight; the preview card is
-- only for the rare look-closer. Grouped by category; ga accepts a whole
-- category at once.
--   j/k move · da accept (stores the bookmark) · dr reject · ga category ·
--   o open the source session transcript · r refresh · Q kill
-- Bookmarks are proposals with the marker path <project>/.opencode/bookmarks.md,
-- emitted by the session-bookmarks evaluation skill at session end.
-- Accepted rows stay visible as [applied] so the review history is explicit.
-- The engine (opencode-manage.console) owns windows/keymaps/state; this
-- file owns the bookmark rendering and actions.

local proposals = require("opencode-manage.proposals")
local bookmarks = require("opencode-manage.bookmarks")
local console = require("opencode-manage.console")

local M = {}

-- Panel-specific row colors (the engine owns the shared Manage* set).
vim.api.nvim_set_hl(0, "ManageBmDecision", { fg = "#4ec9b0", bold = true })
vim.api.nvim_set_hl(0, "ManageBmBugfix", { fg = "#f44747" })
vim.api.nvim_set_hl(0, "ManageBmPattern", { fg = "#c586c0" })
vim.api.nvim_set_hl(0, "ManageBmDiscovery", { fg = "#dcdcaa" })
vim.api.nvim_set_hl(0, "ManageBmArchitecture", { fg = "#569cd6" })
vim.api.nvim_set_hl(0, "ManageBmConfig", { fg = "#6a9955" })
vim.api.nvim_set_hl(0, "ManageBmGotcha", { fg = "#e5c07b" })

local CATEGORY_HL = {
	decision = "ManageBmDecision",
	bugfix = "ManageBmBugfix",
	pattern = "ManageBmPattern",
	discovery = "ManageBmDiscovery",
	architecture = "ManageBmArchitecture",
	config = "ManageBmConfig",
	gotcha = "ManageBmGotcha",
}

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

local function fmt_when(ts)
	if not ts or ts == 0 then
		return "?"
	end
	return os.date("%m-%d %H:%M", math.floor(ts / 1000))
end

local function short_sid(sid)
	if not sid then
		return "?"
	end
	return sid:gsub("^ses_", ""):sub(1, 8)
end

local function list()
	local out = {}
	for _, p in ipairs(proposals.list_visible("all")) do
		if bookmarks.is_bookmark(p) then
			out[#out + 1] = p
		end
	end
	return out
end

--- Rows grouped by category; the row IS the decision.
local function rows(items)
	local out = {}
	local last_group = nil
	for i, p in ipairs(items) do
		local data = parse(p)
		local g = p.group or "misc"
		if g ~= last_group then
			last_group = g
			out[#out + 1] = { sep = g }
		end
		local st = p.status or "pending"
		local title = data and data.title or "(unparsed payload)"
		local why = p.reason or ""
		out[#out + 1] = {
			item = p,
			text = string.format(
				"%-28s — %s  (%s · %s)",
				title:sub(1, 28),
				why:sub(1, 40),
				short_sid(p.sessionID),
				fmt_when(p.ts)
			),
			hl = st == "accepted" and "ManageApplied" or (CATEGORY_HL[g] or "ManageBmDiscovery"),
			state = st,
			col = 2,
		}
	end
	return out
end

--- Compact card — only for the rare look-closer.
local function preview(p)
	local data = parse(p)
	local lines = {}
	if data then
		lines[#lines + 1] = "title:    " .. (data.title or "?")
		lines[#lines + 1] = "category: " .. (p.group or "misc")
		lines[#lines + 1] = "why:      " .. (p.reason or "—")
		lines[#lines + 1] = "summary:  " .. (data.summary or "—")
		lines[#lines + 1] = "keywords: " .. table.concat(data.keywords or {}, ", ")
		lines[#lines + 1] = "session:  " .. (data.session_id or p.sessionID or "?") .. "  ·  message: " .. (data.message_id or "?")
		if data.path and data.path ~= "" then
			lines[#lines + 1] = "path:     " .. data.path
		end
	else
		lines[#lines + 1] = "(unparsed bookmark payload — malformed emission)"
	end
	return {
		left = {
			lines = lines,
			name = "BOOKMARK CARD",
			ft = "",
			modifiable = false,
			winbar = "BOOKMARK CARD",
		},
	}
end

local function accept_current(p, h)
	if not p then
		return
	end
	if (p.status or "pending") ~= "pending" then
		vim.notify("ℹ️ Already " .. p.status, vim.log.levels.INFO)
		return
	end
	bookmarks.accept(p)
	h.refresh()
end

local function reject_current(p, h)
	if not p then
		return
	end
	proposals.reject(p)
	h.refresh()
end

--- ga: accept every pending bookmark in the current category.
local function apply_group(p, h)
	if not p then
		return
	end
	local group = p.group or "misc"
	local accepted, skipped = 0, 0
	for _, it in ipairs(h.state.items) do
		if (it.group or "misc") == group then
			if (it.status or "pending") == "pending" then
				if bookmarks.accept(it) then
					accepted = accepted + 1
				end
			else
				skipped = skipped + 1
			end
		end
	end
	h.refresh()
	vim.notify(
		string.format("🔖 Category %s: %d bookmarked, %d already decided", group, accepted, skipped),
		vim.log.levels.INFO
	)
end

--- o: open the source session transcript (best-effort; search the message
--- id inside to jump to the exchange).
local function open_session(p, h)
	if not p then
		return
	end
	local data = parse(p)
	local sid = data and data.session_id or p.sessionID
	local f = bookmarks.session_file(sid)
	if not f then
		vim.notify(
			"ℹ️ No session transcript file for " .. tostring(sid) .. " — the session may be pruned",
			vim.log.levels.INFO
		)
		return
	end
	local origin = h.state.origin_win
	if origin and vim.api.nvim_win_is_valid(origin) then
		local cur = vim.api.nvim_get_current_win()
		vim.api.nvim_set_current_win(origin)
		vim.cmd("edit " .. vim.fn.fnameescape(f))
		vim.api.nvim_set_current_win(cur)
		vim.notify("📍 Opened session transcript — search the message id to jump to the exchange", vim.log.levels.INFO)
	end
end

function M.open()
	console.open({
		name = "Bookmarks",
		layout = "detail",
		list = list,
		rows = rows,
		preview = preview,
		actions = {
			accept = accept_current,
			reject = reject_current,
			group_apply = apply_group,
			open = open_session,
		},
		swatches = "%#ManageBmDecision#██%*decision  %#ManageBmBugfix#██%*bugfix  %#ManageBmPattern#██%*pattern  "
			.. "%#ManageBmDiscovery#██%*discovery  %#ManageBmArchitecture#██%*architecture  "
			.. "%#ManageBmConfig#██%*config  %#ManageBmGotcha#██%*gotcha",
		empty_lines = {
			"— no bookmark proposals —",
			"  (the session-bookmarks evaluation emits them at session end; da stores, dr rejects)",
		},
		open_empty = true,
		keep_empty = true,
		identity = function(p)
			return p.path .. "\0" .. tostring(p.ts)
		end,
	})
end

return M
