-- /home/altjoe/.config/nvim/lua/opencode-manage/vaultview.lua FINAL
-- opencode-manage.vaultview — vault panel (console adapter, global refs CV1).
-- Persistent two-pane viewer, same shape as the other manage viewers:
--   j/k move · d prune (with reason) · o open path · i re-index vault ·
--   x show/hide pruned · r refresh · Q kill
-- The vault is the GLOBAL ref store (~/.config/opencode/state.db,
-- scope='global') — folders approved as "common" land here, so a component
-- lives once and is visible from every project (doc 20 CV1).
-- Reads come from opencode-manage.refs; actions route through
-- refs.prune_global / refs.index(root, { global = true }).
-- The engine (opencode-manage.console) owns windows/keymaps/state; this
-- file owns the vault-specific rendering and actions.

local refs = require("opencode-manage.refs")
local console = require("opencode-manage.console")

local M = {}

local VAULT_ROOT = (vim.env.HOME or "") .. "/projects/shared"

local adapter = { show_pruned = false }

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

--- Global references, filtered by pruned visibility.
--- @return table[]
local function list()
	local all = refs.list_global()
	local out = {}
	for _, r in ipairs(all) do
		if adapter.show_pruned or not r.pruned_ts then
			out[#out + 1] = r
		end
	end
	return out
end

--- Rows: kind · uses · subject · path.
--- @param items table[]
--- @return table[]
local function rows(items)
	local out = {}
	for i, r in ipairs(items) do
		out[i] = {
			item = r,
			text = string.format(
				"%-6s %-4s %-24s %s",
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
	lines[#lines + 1] = "kind:     " .. (r.kind or "?")
	lines[#lines + 1] = "subject:  " .. (r.subject or "—")
	lines[#lines + 1] = "uses:     " .. tostring(r.uses or 0) .. "  ·  pinned: " .. (r.pinned and "yes" or "no")
	lines[#lines + 1] = "indexed:  " .. fmt_when(r.indexed_ts) .. "  ·  last used: " .. fmt_when(r.last_used_ts)
	if r.pruned_ts then
		lines[#lines + 1] = "pruned:   " .. fmt_when(r.pruned_ts) .. "  ·  reason: " .. (r.prune_reason or "—")
	end
	return {
		left = {
			lines = lines,
			name = "VAULT DETAIL",
			ft = "",
			modifiable = false,
			winbar = "VAULT DETAIL",
		},
	}
end

--- d: prune the selected global reference (with reason).
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
		refs.prune_global(r.id, reason)
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

--- i: re-index the vault root into the GLOBAL ref store.
--- @param h table  console handle
local function reindex(h)
	vim.notify("vault: indexing " .. VAULT_ROOT .. " (global)", vim.log.levels.INFO)
	refs.index(VAULT_ROOT, { global = true })
	h.refresh()
end

--- x: toggle pruned visibility.
--- @param h table  console handle
local function toggle_pruned(h)
	adapter.show_pruned = not adapter.show_pruned
	h.state.idx = 1
	h.refresh()
	vim.notify("vault: " .. (adapter.show_pruned and "showing pruned" or "hiding pruned"), vim.log.levels.INFO)
end

function M.open()
	console.open({
		name = "Vault",
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
			{ key = "i", desc = "re-index", fn = reindex },
			{ key = "x", desc = "pruned", fn = toggle_pruned },
		},
		legend = function(h)
			return string.format(
				"VAULT · %d global ref(s) · pruned: %s · j/k d o i x r Q",
				#h.state.items,
				adapter.show_pruned and "shown" or "hidden"
			)
		end,
		empty_lines = function()
			if adapter.show_pruned then
				return { "— no vault references at all — :ManageVault to index ~/projects/shared" }
			end
			return { "— no vault references yet — approve a common folder or :ManageVault" }
		end,
		open_empty = true,
		keep_empty = true,
	})
end

return M
