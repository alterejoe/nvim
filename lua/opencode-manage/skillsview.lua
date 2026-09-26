-- /home/altjoe/.config/nvim/lua/opencode-manage/skillsview.lua FINAL
-- opencode-manage.skillsview — skills lifecycle panel (console adapter, doc 22 SL2).
-- Persistent two-pane viewer over the merged routing manifests (global +
-- nearest project, project wins by name):
--   j/k move · t re-tier · n note · s subjects · D drop entry ·
--   o open SKILL.md · r refresh · Q kill
-- Lifecycle is RE-TIERING first: `legacy` retires a skill (kept for history,
-- never hinted), `emergency` always hints, `explicit` never hints,
-- `conditional` requires an exact subject match, `default` hints by subject.
-- `D` drops the manifest entry — the deliberate full prune; the SKILL.md
-- file is never deleted here (an unrouted skill is simply inert).
-- Detail: entry metadata + note, usage from THIS project's metrics store
-- (skill-tag touches + recent loads), and a preview of the SKILL.md body.
-- Writes route through opencode-manage.skills — snapshot + journal each time.
-- The engine (opencode-manage.console) owns windows/keymaps/state; this
-- file owns the skills-specific rendering and actions.

local skills = require("opencode-manage.skills")
local metrics = require("opencode-manage.metrics")
local console = require("opencode-manage.console")

local M = {}

local TIER_HL = {
	default = "ManageSkillDefault",
	conditional = "ManageSkillConditional",
	emergency = "ManageSkillEmergency",
	explicit = "ManageSkillExplicit",
	legacy = "ManageSkillLegacy",
}

local function short(path)
	if not path or path == "" then
		return ""
	end
	return (path:gsub("^" .. vim.pesc(vim.env.HOME or ""), "~"))
end

--- Epoch millis (or seconds) -> seconds.
--- @param v any
--- @return number
local function secs(v)
	local n = tonumber(v) or 0
	if n > 100000000000 then
		return n / 1000
	end
	return n
end

local function fmt_when(ts)
	local n = tonumber(ts)
	if not n or n == 0 then
		return "?"
	end
	return os.date("%m-%d %H:%M", math.floor(secs(n)))
end

--- Skills + usage enrichment from THIS project's metrics store (fail-open).
--- @return table[]
local function list()
	local all = skills.list()
	local ok, objects = pcall(metrics.objects, 500)
	if not ok or type(objects) ~= "table" then
		objects = {}
	end
	local usage = {}
	for _, o in ipairs(objects) do
		if o.kind == "skill" then
			usage[o.tag] = o
		end
	end
	for _, e in ipairs(all) do
		local u = usage[e.name]
		e.touches = tonumber(u and u.n) or 0
		e.last_used = u and u.last or nil
	end
	return all
end

--- Rows: name · scope · tier · touches · last used · subjects.
--- @param items table[]
--- @return table[]
local function rows(items)
	local out = {}
	for i, e in ipairs(items) do
		local subs = #e.subject > 0 and table.concat(e.subject, ", ") or "—"
		out[i] = {
			item = e,
			text = string.format(
				"%-24s %-7s %-11s t=%-4s %-12s %s",
				e.name,
				e.scope,
				e.tier,
				tostring(e.touches or 0),
				fmt_when(e.last_used),
				subs
			),
			hl = TIER_HL[e.tier] or "ManageSkillDefault",
			col = 0,
		}
	end
	return out
end

--- Detail: metadata + note + usage + SKILL.md body preview.
--- @param e table
--- @return table
local function preview(e)
	local lines = {}
	lines[#lines + 1] = "name:      " .. e.name
	lines[#lines + 1] = "scope:     " .. e.scope
	lines[#lines + 1] = "tier:      " .. e.tier
	lines[#lines + 1] = "subjects:  " .. (#e.subject > 0 and table.concat(e.subject, ", ") or "—")
	lines[#lines + 1] = "note:      " .. (e.note or "—")
	lines[#lines + 1] = "manifest:  " .. short(e.file)
	lines[#lines + 1] = "path:      " .. short(e.path) .. (e.exists and "" or "   (missing on disk!)")
	lines[#lines + 1] = string.format(
		"touches:   %d  ·  last: %s   (this project's store)",
		tonumber(e.touches) or 0,
		fmt_when(e.last_used)
	)
	local ok, events = pcall(metrics.object_events, e.name, "skill", 8)
	if ok and type(events) == "table" and #events > 0 then
		lines[#lines + 1] = "recent:"
		for _, ev in ipairs(events) do
			lines[#lines + 1] = string.format(
				"  %s · %s · %s",
				fmt_when(ev.ts),
				tostring(ev.kind or "?"),
				tostring(ev.detail or "")
			)
		end
	end
	lines[#lines + 1] = string.rep("─", 48)
	lines[#lines + 1] = "lifecycle: t re-tier · n note · s subjects · D drop entry (file kept)"
	lines[#lines + 1] = "legacy retires without deletion · explicit never hints · emergency always"
	if e.exists then
		lines[#lines + 1] = string.rep("─", 48)
		lines[#lines + 1] = "SKILL.md (first 40 lines):"
		local body = vim.fn.readfile(e.path, "", 40)
		for _, l in ipairs(body) do
			lines[#lines + 1] = l
		end
	end
	return {
		left = {
			lines = lines,
			name = "SKILLS DETAIL",
			ft = "",
			modifiable = false,
			winbar = "SKILLS DETAIL",
		},
	}
end

--- t: re-tier via vim.ui.select.
--- @param e table
--- @param h table  console handle
local function select_tier(e, h)
	if not e then
		return
	end
	vim.ui.select(skills.TIERS, { prompt = "tier for '" .. e.name .. "' (current: " .. e.tier .. ")" }, function(choice)
		if not choice or choice == e.tier then
			return
		end
		if skills.set_tier(e.name, choice) then
			h.refresh()
			vim.notify("skills: " .. e.name .. " → " .. choice, vim.log.levels.INFO)
		end
	end)
end

--- n: edit the note (empty clears).
--- @param e table
--- @param h table  console handle
local function edit_note(e, h)
	if not e then
		return
	end
	vim.ui.input(
		{ prompt = "note for '" .. e.name .. "' (empty clears): ", default = e.note or "" },
		function(input)
			if input == nil then
				return
			end
			if skills.set_note(e.name, input) then
				h.refresh()
				vim.notify("skills: note updated for " .. e.name, vim.log.levels.INFO)
			end
		end
	)
end

--- s: edit subjects (comma-separated; at least one required).
--- @param e table
--- @param h table  console handle
local function edit_subjects(e, h)
	if not e then
		return
	end
	vim.ui.input(
		{ prompt = "subjects (comma-separated): ", default = table.concat(e.subject, ", ") },
		function(input)
			if input == nil then
				return
			end
			local subs = {}
			for part in input:gmatch("[^,]+") do
				local t = vim.trim(part)
				if t ~= "" then
					subs[#subs + 1] = t
				end
			end
			if #subs == 0 then
				vim.notify("❌ skills: at least one subject is required — routing needs it", vim.log.levels.WARN)
				return
			end
			if skills.set_subjects(e.name, subs) then
				h.refresh()
				vim.notify("skills: subjects updated for " .. e.name, vim.log.levels.INFO)
			end
		end
	)
end

--- D: drop the manifest entry (confirmed; the SKILL.md file stays on disk).
--- @param e table
--- @param h table  console handle
local function drop_entry(e, h)
	if not e then
		return
	end
	local choice = vim.fn.confirm(
		"Drop the manifest entry for '"
			.. e.name
			.. "'?\n\nThe SKILL.md file stays on disk — the skill stops being routed/hinted.\n"
			.. "Demote to 'legacy' instead to keep it visible in the manifest.",
		"&Drop\n&Cancel",
		2
	)
	if choice ~= 1 then
		return
	end
	if skills.drop(e.name) then
		h.refresh()
		vim.notify("skills: dropped " .. e.name .. " (file kept)", vim.log.levels.INFO)
	end
end

--- o: open the SKILL.md in the origin window.
--- @param e table
--- @param h table  console handle
local function open_in_origin(e, h)
	if not e then
		return
	end
	if not e.exists then
		vim.notify("❌ skills: no SKILL.md on disk at " .. e.path, vim.log.levels.WARN)
		return
	end
	local origin = h.state.origin_win
	if origin and vim.api.nvim_win_is_valid(origin) then
		local cur = vim.api.nvim_get_current_win()
		vim.api.nvim_set_current_win(origin)
		vim.cmd("edit " .. vim.fn.fnameescape(e.path))
		vim.api.nvim_set_current_win(cur)
		vim.notify("📍 Opened " .. short(e.path), vim.log.levels.INFO)
	end
end

function M.open()
	console.open({
		name = "Skills",
		layout = "detail",
		list = list,
		rows = rows,
		preview = preview,
		actions = {
			open = open_in_origin,
		},
		keys = {
			{
				key = "t",
				desc = "tier",
				fn = function(h)
					select_tier(h.state.items[h.state.idx], h)
				end,
			},
			{
				key = "n",
				desc = "note",
				fn = function(h)
					edit_note(h.state.items[h.state.idx], h)
				end,
			},
			{
				key = "s",
				desc = "subjects",
				fn = function(h)
					edit_subjects(h.state.items[h.state.idx], h)
				end,
			},
			{
				key = "D",
				desc = "drop entry",
				fn = function(h)
					drop_entry(h.state.items[h.state.idx], h)
				end,
			},
		},
		legend = function(h)
			return string.format("SKILLS · %d · merged global+project · j/k t tier n note s subjects D drop o open r Q", #h.state.items)
		end,
		empty_lines = {
			"— no skills in the manifests —",
			"  (emit_skill in a session, or check ~/.config/opencode/skills.policy.json)",
		},
		open_empty = true,
		keep_empty = true,
	})
end

return M
