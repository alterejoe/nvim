-- /home/altjoe/.config/nvim/lua/opencode-manage/registryview.lua FINAL
-- opencode-manage.registryview — registry review panel (console adapter).
-- Top = pending/merged registry entries (from .opencode/manage.registry.pending.jsonl).
-- Below: TWO side-by-side preview windows — ENTRY DETAILS (left) vs the
-- MERGED BLOCK (right, exactly what da appends to manage.registry.json).
--   j/k move · gg/G jump · [/] scroll both previews · da merge (confirm —
--   the right pane shows what will be appended; summary MD regenerates) ·
--   dr reject (status flip only, row stays marked rejected) · r refresh ·
--   o open the project's manage.registry.json in your buffer · Q kill.
-- Row colors: red=shared · blue=canonical · yellow=modularize ·
-- magenta=consolidations · dim green=merged · dim strike=rejected
-- MERGED ROWS STAY: the list shows pending + merged rows; merged ones
-- render dim-green [merged] so the review history is explicit.
-- The engine (opencode-manage.console) owns windows/keymaps/state; this
-- file owns the registry-specific rendering and actions.
--
-- DEFENSE IN DEPTH: every field rendered through s()/join() coercion — a
-- userdata (cjson null sentinel from a stale decode), table, or number can
-- never crash a concatenation. Display-only; the merge path in registry.lua
-- is the one that must never see non-strings (it decodes with luanil).

local registry = require("opencode-manage.registry")
local console = require("opencode-manage.console")

local M = {}

local KIND_HL = {
	shared = "ManageRegShared",
	canonical = "ManageRegCanonical",
	modularize = "ManageRegModularize",
	consolidations = "ManageRegConsolidate",
}

local KIND_TAG = {
	shared = "shared",
	canonical = "canon",
	modularize = "modular",
	consolidations = "consol",
}

--- Render ANY field value safely — never crash on weird types.
--- @param v any
--- @param fallback string
--- @return string
local function s(v, fallback)
	if v == nil then
		return fallback or "—"
	end
	local t = type(v)
	if t == "string" then
		return v
	end
	if t == "number" or t == "boolean" then
		return tostring(v)
	end
	return vim.inspect(v)
end

--- Join a list of values safely (each coerced via s()).
--- @param vals any
--- @param sep string
--- @return string
local function join(vals, sep)
	sep = sep or ", "
	if type(vals) ~= "table" then
		return ""
	end
	local parts = {}
	for _, v in ipairs(vals) do
		parts[#parts + 1] = s(v)
	end
	return table.concat(parts, sep)
end

--- Rows: pending/merged entries, colored by kind or status.
--- @param items table[]
--- @return table[]
local function rows(items)
	local out = {}
	for i, e in ipairs(items) do
		local st = e.status or "pending"
		local tag, hl
		if st == "merged" then
			tag, hl = "merged", "ManageRegMerged"
		elseif st == "rejected" then
			tag, hl = "rejected", "ManageRegRejected"
		else
			tag = KIND_TAG[e.kind] or s(e.kind, "?")
			hl = KIND_HL[e.kind] or "ManageRegShared"
		end
		local ts = type(e.ts) == "number" and e.ts or 0
		local when = os.date("%H:%M:%S", math.floor(ts / 1000))
		out[i] = {
			item = e,
			text = string.format(
				"%s  %-9s [%-8s] %-32s %s",
				when,
				tag,
				s(e._project, "?"),
				s(e._rel, "?"),
				s(e.rationale, ""):sub(1, 26)
			),
			hl = hl,
		}
	end
	return out
end

--- ENTRY DETAILS (left) and the MERGED BLOCK (right) side by side.
--- @param e table
--- @return table
local function preview(e)
	local D = {}
	D[#D + 1] = "KIND: " .. s(e.kind, "?") .. (e.fragile and " [FRAGILE]" or "")
	D[#D + 1] = "PROJECT: " .. s(e._project, "?")
	if e.kind == "consolidations" then
		D[#D + 1] = "PATHS: " .. join(e.paths)
	else
		D[#D + 1] = "PATH: " .. s(e.path, "?")
	end
	if e.symbols and #e.symbols > 0 then
		D[#D + 1] = "SYMBOLS: " .. join(e.symbols)
	end
	if e.concept then
		D[#D + 1] = "CONCEPT: " .. s(e.concept)
	end
	D[#D + 1] = "RATIONALE: " .. s(e.rationale, "—")
	if e.constraints then
		D[#D + 1] = "CONSTRAINTS: " .. s(e.constraints)
	end
	if e.suggested_target then
		D[#D + 1] = "SUGGESTED TARGET: " .. s(e.suggested_target)
	end
	if e.refs and #e.refs > 0 then
		D[#D + 1] = "REFS:"
		for _, r in ipairs(e.refs) do
			local rel = r.relation and (" (" .. s(r.relation) .. ")") or ""
			D[#D + 1] = "  - " .. s(r.path) .. rel
		end
	end
	D[#D + 1] = "GROUP: " .. s(e.group, "misc")
	D[#D + 1] = "SESSION: " .. s(e.sessionID, "?")
	D[#D + 1] = "STATUS: " .. s(e.status, "pending")

	local block_lines = vim.split(registry.preview_block(e), "\n", { plain = true })
	if block_lines[#block_lines] == "" then
		table.remove(block_lines)
	end

	return {
		left = {
			lines = D,
			name = "ENTRY: " .. s(e._rel),
			ft = "managelist",
			modifiable = false,
			winbar = string.format("ENTRY DETAILS  [%s · %s]", s(e.kind, "?"), s(e._project, "?")),
		},
		right = {
			lines = block_lines,
			name = "MERGED BLOCK: " .. s(e._rel),
			ft = "json",
			modifiable = false,
			winbar = "MERGED BLOCK — da appends this to manage.registry.json",
		},
		focus = { left = 1, right = 1 },
	}
end

--- da: merge into the registry (confirm — the right pane shows what will
--- be appended; summary MD regenerates).
--- @param e table
--- @param h table  console handle
local function merge_current(e, h)
	if not e then
		return
	end
	if (e.status or "pending") ~= "pending" then
		vim.notify("ℹ️ Already " .. s(e.status), vim.log.levels.INFO)
		return
	end
	local choice = vim.fn.confirm(
		"Merge into the registry?\n  "
			.. s(e.kind, "?")
			.. ": "
			.. s(e.path or table.concat(e.paths or {}, " + "))
			.. "\n\nRegistry file gets the entry; summary MD regenerates. (Reversible via journal.)",
		"&Yes\n&No",
		1
	)
	if choice == 1 then
		registry.accept(e)
	end
	h.refresh()
end

--- dr: reject (status flip only, row stays marked rejected).
--- @param e table
--- @param h table  console handle
local function reject_current(e, h)
	if not e then
		return
	end
	registry.reject(e)
	h.refresh()
end

--- o: open the project's manage.registry.json in your buffer.
--- @param e table
--- @param h table  console handle
local function open_registry(e, h)
	if not e or not e._file then
		return
	end
	local target = vim.fn.fnamemodify(e._file, ":h") .. "/manage.registry.json"
	local origin = h.state.origin_win
	if origin and vim.api.nvim_win_is_valid(origin) then
		local cur = vim.api.nvim_get_current_win()
		vim.api.nvim_set_current_win(origin)
		vim.cmd("edit " .. vim.fn.fnameescape(target))
		vim.api.nvim_set_current_win(cur)
		vim.notify("📍 Opened " .. target, vim.log.levels.INFO)
	end
end

function M.open()
	console.open({
		name = "Registry",
		layout = "pair",
		list = function()
			return registry.list_visible()
		end,
		rows = rows,
		preview = preview,
		actions = {
			accept = merge_current,
			reject = reject_current,
			open = open_registry,
		},
		legend = "j/k move · gg/G jump · [/] scroll · da merge · dr reject · r refresh · o registry · Q kill",
		swatches = "%#ManageRegShared#██%*shared  %#ManageRegCanonical#██%*canonical  "
			.. "%#ManageRegModularize#██%*modularize  %#ManageRegConsolidate#██%*consolidate  "
			.. "%#ManageRegMerged#██%*merged  %#ManageRegRejected#██%*rejected",
		empty_msg = "No registry entries — queue is empty (.opencode/manage.registry.pending.jsonl)",
		identity = function(e)
			return (e.group or "misc") .. "\0" .. (e.path or "") .. "\0" .. tostring(e.ts)
		end,
	})
end

return M
