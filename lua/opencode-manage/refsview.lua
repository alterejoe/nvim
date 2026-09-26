-- /home/altjoe/.config/nvim/lua/opencode-manage/refsview.lua FINAL
-- opencode-manage.refsview — references panel (console adapter, doc 20 R1a/R1b).
-- Persistent two-pane viewer, same shape as the other manage viewers:
--   j/k move · d prune (with reason) · o open path · s source filter ·
--   x show/hide pruned · r refresh · Q kill
-- List: source · kind · uses · subject · path.
-- Detail: everything about the selected reference, including the prune
-- reason when it was dropped — pruning with reason is context.
-- Data comes from opencode-manage.refs — reads only; actions route through
-- refs.pin/prune (user-initiated, never automatic).
-- The engine (opencode-manage.console) owns windows/keymaps/state; this
-- file owns the refs-specific rendering and filters.

local refs = require("opencode-manage.refs")
local console = require("opencode-manage.console")

local M = {}

local SOURCES = { "all", "index", "pin", "correction" }

local adapter = { source = "all", show_pruned = false }

local function short(path)
	if not path or path == "" then
		return ""
	end
	return (path:gsub("^" .. vim.pesc(vim.env.HOME or ""), "~"))
end

local function fmt_when(ts)
	if not ts or ts == 0 then
		return "?"
	end
	return os.date("%m-%d %H:%M", math.floor(ts / 1000))
end

--- References from the store, filtered by source + pruned visibility.
--- @return table[]
local function list()
	local all = refs.list()
	local out = {}
	for _, r in ipairs(all) do
		if adapter.source == "all" or r.source == adapter.source then
			if adapter.show_pruned or not r.pruned_ts then
				out[#out + 1] = r
			end
		end
	end
	return out
end

--- Rows: source · kind · uses · subject · path.
--- @param items table[]
--- @return table[]
local function rows(items)
	local out = {}
	for i, r in ipairs(items) do
		out[i] = {
			item = r,
			text = string.format(
				"%-9s %-6s %-4s %-24s %s",
				r.source or "?",
				r.kind or "?",
				tostring(r.uses or 0),
				(r.subject or ""):sub(1, 24),
				short(r.path)
			),
		}
	end
	return out
end

--- Detail: everything about the reference, including the prune reason.
--- @param r table
--- @return table
local function preview(r)
	local lines = {}
	lines[#lines + 1] = "path:     " .. (r.path or "?")
	lines[#lines + 1] = "source:   " .. (r.source or "?") .. "  ·  kind: " .. (r.kind or "?")
	lines[#lines + 1] = "subject:  " .. (r.subject or "—")
	lines[#lines + 1] = "uses:     " .. tostring(r.uses or 0) .. "  ·  pinned: " .. (r.pinned and "yes" or "no")
	lines[#lines + 1] = "indexed:  " .. fmt_when(r.indexed_ts) .. "  ·  last used: " .. fmt_when(r.last_used_ts)
	if r.pruned_ts then
		lines[#lines + 1] = "pruned:   " .. fmt_when(r.pruned_ts) .. "  ·  reason: " .. (r.prune_reason or "—")
	end
	return {
		left = {
			lines = lines,
			name = "REF DETAIL",
			ft = "",
			modifiable = false,
			winbar = "REF DETAIL",
		},
	}
end

--- d: prune the selected reference (with reason — pruning with reason is
--- context, not deletion).
--- @param r table
--- @param h table  console handle
local function prune_current(r, h)
	if not r then
		return
	end
	vim.ui.input({ prompt = "prune reason (kept in the store): " }, function(reason)
		if reason == nil then
			return
		end
		refs.prune(r.id, reason)
		h.refresh()
	end)
end

--- o: open the reference path in the origin window.
--- @param r table
--- @param h table  console handle
local function open_in_origin(r, h)
	if not r or not r.path then
		return
	end
	local origin = h.state.origin_win
	if origin and vim.api.nvim_win_is_valid(origin) then
		local cur = vim.api.nvim_get_current_win()
		vim.api.nvim_set_current_win(origin)
		vim.cmd("edit " .. vim.fn.fnameescape(r.path))
		vim.api.nvim_set_current_win(cur)
		vim.notify("📍 Opened " .. short(r.path), vim.log.levels.INFO)
	end
end

--- s: cycle the source filter (all / index / pin / correction).
--- @param h table  console handle
local function toggle_source(h)
	local cur = 1
	for i, f in ipairs(SOURCES) do
		if f == adapter.source then
			cur = i
			break
		end
	end
	adapter.source = SOURCES[(cur % #SOURCES) + 1]
	h.state.idx = 1
	h.refresh()
	vim.notify("refs source: " .. adapter.source, vim.log.levels.INFO)
end

--- x: toggle pruned visibility.
--- @param h table  console handle
local function toggle_pruned(h)
	adapter.show_pruned = not adapter.show_pruned
	h.state.idx = 1
	h.refresh()
	vim.notify("refs: " .. (adapter.show_pruned and "showing pruned" or "hiding pruned"), vim.log.levels.INFO)
end

function M.open()
	console.open({
		name = "Refs",
		layout = "detail",
		list = list,
		rows = rows,
		preview = preview,
		actions = {
			open = open_in_origin,
		},
		keys = {
			{
				key = "d",
				desc = "prune",
				fn = function(h)
					prune_current(h.state.items[h.state.idx], h)
				end,
			},
			{ key = "s", desc = "source filter", fn = toggle_source },
			{ key = "x", desc = "pruned", fn = toggle_pruned },
		},
		legend = function(h)
			return string.format(
				"REFS · %d · source: %s · pruned: %s · j/k d o s x r Q",
				#h.state.items,
				adapter.source,
				adapter.show_pruned and "shown" or "hidden"
			)
		end,
		empty_lines = function()
			if adapter.source ~= "all" or adapter.show_pruned then
				return { "— no references match the filter —" }
			end
			return { "— no references yet — :ManageIndex <root> to scan a project" }
		end,
		open_empty = true,
		keep_empty = true,
	})
end

return M
