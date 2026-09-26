-- /home/altjoe/.config/nvim/lua/opencode-manage/verdictview.lua FINAL
-- opencode-manage.verdictview — verdict store panel (console adapter, T2 + T2.5).
-- Persistent two-pane viewer: verdict list (top) + detail preview (below).
--   j/k move · f verdict filter (all/accepted/corrected/rejected/moved_old/
--   aborted) · s scope filter (all/project/global) · r refresh · Q kill
-- List rows: verdict type colored, path (or reason for conversation
-- verdicts), project, scope, source, when.
-- Preview: corrected/aborted verdicts show the diff (proposed vs applied —
-- for aborted: the killed text vs your correction); others show metadata.
-- S0: opens even when the store is empty — the empty state renders in-pane.
-- The engine (opencode-manage.console) owns windows/keymaps/state; this
-- file owns the verdict-specific rendering and filters.

local verdicts = require("opencode-manage.verdicts")
local console = require("opencode-manage.console")

local M = {}

local VERDICT_CYCLE = { "all", "accepted", "corrected", "rejected", "moved_old", "aborted" }
local SCOPE_CYCLE = { "all", "project", "global" }

local VERDICT_HL = {
	accepted = "ManageNew",
	corrected = "ManageEdit",
	rejected = "ManageRejected",
	moved_old = "ManageDelete",
	aborted = "ManageRerun",
}

local adapter = { vfilter = "all", sfilter = "all" }

local function fmt_when(ts)
	if not ts or ts == 0 then
		return "?"
	end
	return os.date("%m-%d %H:%M", math.floor(ts / 1000))
end

--- Verdicts from the store, filtered by the current f/s filters.
--- @return table[]
local function list()
	local all = verdicts.recent(200)
	local out = {}
	for _, v in ipairs(all) do
		if adapter.vfilter == "all" or v.verdict == adapter.vfilter then
			if adapter.sfilter == "all" or v.scope == adapter.sfilter then
				out[#out + 1] = v
			end
		end
	end
	return out
end

--- Rows: verdict · scope · target · reason · source · project · when.
--- @param items table[]
--- @return table[]
local function rows(items)
	local out = {}
	for i, v in ipairs(items) do
		local target = v.path or (v.reason or "conversation")
		out[i] = {
			item = v,
			text = string.format(
				"%-9s [%-8s] %-28s %s  (%s · %s · %s)",
				v.verdict or "?",
				v.scope or "?",
				target,
				(v.reason or ""):sub(1, 30),
				v.source or "?",
				v.project or "?",
				fmt_when(v.ts)
			),
			hl = VERDICT_HL[v.verdict],
		}
	end
	return out
end

--- Simple line diff: proposed vs applied, -/+ prefixed. Good enough for
--- the viewer — the store keeps both contents, so nothing is lost.
--- @param a string[]  proposed lines
--- @param b string[]  applied lines
--- @return string[]
local function simple_diff(a, b)
	local out = {}
	local i, j = 1, 1
	local n, m = #a, #b
	while i <= n or j <= m do
		if i <= n and j <= m and a[i] == b[j] then
			out[#out + 1] = " " .. a[i]
			i, j = i + 1, j + 1
		else
			local di, dj = nil, nil
			for k = 1, 4 do
				if i + k <= n and j <= m and a[i + k] == b[j] then
					di = i + k
					break
				end
				if j + k <= m and i <= n and a[i] == b[j + k] then
					dj = j + k
					break
				end
			end
			if di then
				for x = i, di - 1 do
					out[#out + 1] = "-" .. (a[x] or "")
				end
				i = di
			elseif dj then
				for x = j, dj - 1 do
					out[#out + 1] = "+" .. (b[x] or "")
				end
				j = dj
			else
				if i <= n then
					out[#out + 1] = "-" .. (a[i] or "")
					i = i + 1
				end
				if j <= m then
					out[#out + 1] = "+" .. (b[j] or "")
					j = j + 1
				end
			end
		end
	end
	return out
end

--- Detail: corrected/aborted verdicts show the proposed-vs-applied diff
--- (red/green); everything else shows metadata.
--- @param v table
--- @return table
local function preview(v)
	local lines = {}
	local hl = {}
	if not v then
		lines = { "— nothing selected —" }
	elseif (v.verdict == "corrected" or v.verdict == "aborted") and v.proposed_content and v.applied_content then
		local proposed = vim.split(v.proposed_content, "\n", { plain = true })
		local applied = vim.split(v.applied_content, "\n", { plain = true })
		lines = simple_diff(proposed, applied)
		for ln, l in ipairs(lines) do
			local prefix = l:sub(1, 1)
			if prefix == "-" then
				hl[ln] = "ManageRemove"
			elseif prefix == "+" then
				hl[ln] = "ManageAdd"
			end
		end
	else
		lines = {
			"verdict:  " .. (v.verdict or "?"),
			"path:     " .. (v.path or "— (conversation)"),
			"reason:   " .. (v.reason or "—"),
			"project:  " .. (v.project or "?") .. "  ·  scope: " .. (v.scope or "?") .. "  ·  source: " .. (v.source or "?"),
			"session:  " .. (v.session_id or "?") .. "  ·  when: " .. fmt_when(v.ts),
			"group:    " .. (v.group_name or "—") .. "  ·  op: " .. (v.operation or "—"),
		}
	end
	return {
		left = {
			lines = lines,
			name = "VERDICT DETAIL",
			ft = "",
			modifiable = false,
			winbar = "VERDICT DETAIL",
			hl = hl,
		},
	}
end

--- f: cycle the verdict filter.
--- @param h table  console handle
local function toggle_filter(h)
	local cur = 1
	for i, f in ipairs(VERDICT_CYCLE) do
		if f == adapter.vfilter then
			cur = i
			break
		end
	end
	adapter.vfilter = VERDICT_CYCLE[(cur % #VERDICT_CYCLE) + 1]
	h.state.idx = 1
	h.refresh()
	vim.notify("verdict filter: " .. adapter.vfilter, vim.log.levels.INFO)
end

--- s: cycle the scope filter.
--- @param h table  console handle
local function toggle_scope(h)
	local cur = 1
	for i, f in ipairs(SCOPE_CYCLE) do
		if f == adapter.sfilter then
			cur = i
			break
		end
	end
	adapter.sfilter = SCOPE_CYCLE[(cur % #SCOPE_CYCLE) + 1]
	h.state.idx = 1
	h.refresh()
	vim.notify("scope filter: " .. adapter.sfilter, vim.log.levels.INFO)
end

function M.open()
	console.open({
		name = "Verdicts",
		layout = "detail",
		list = list,
		rows = rows,
		preview = preview,
		keys = {
			{ key = "f", desc = "verdict filter", fn = toggle_filter },
			{ key = "s", desc = "scope filter", fn = toggle_scope },
		},
		legend = function(h)
			return string.format(
				"VERDICTS · %d · f: %s · s: %s · j/k f s r Q",
				#h.state.items,
				adapter.vfilter,
				adapter.sfilter
			)
		end,
		empty_lines = function()
			if adapter.vfilter == "all" and adapter.sfilter == "all" then
				return {
					"— no verdicts yet — accept/reject a proposal or kill a generation to record one —",
					"  (if this stays empty after an accept, the store failed — check :messages for a verdicts ERROR)",
				}
			end
			return { "— no verdicts match the current filters — f: verdict · s: scope" }
		end,
		open_empty = true,
		keep_empty = true,
	})
end

return M
