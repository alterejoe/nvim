-- /home/altjoe/.config/nvim/lua/opencode-manage/skillsview.lua FINAL
-- opencode-manage.skillsview — the skills lifecycle viewer (doc 22, SL2).
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

local skills = require("opencode-manage.skills")
local metrics = require("opencode-manage.metrics")

local M = {}

local state = {
	items = {},
	idx = 1,
	list_buf = nil,
	detail_buf = nil,
	list_win = nil,
	detail_win = nil,
	outer_win = nil,
	origin_win = nil,
	autocmd = nil,
}

local TIER_HL = {
	default = "ManageSkillDefault",
	conditional = "ManageSkillConditional",
	emergency = "ManageSkillEmergency",
	explicit = "ManageSkillExplicit",
	legacy = "ManageSkillLegacy",
}

local function define_hls()
	local hl = vim.api.nvim_set_hl
	hl(0, "ManageSkillDefault", { fg = "#4ec9b0" }) -- green: routed by subject
	hl(0, "ManageSkillConditional", { fg = "#569cd6" }) -- blue: exact subject only
	hl(0, "ManageSkillEmergency", { fg = "#c586c0", bold = true }) -- magenta: always hinted
	hl(0, "ManageSkillExplicit", { fg = "#808080" }) -- dim: never hinted
	hl(0, "ManageSkillLegacy", { fg = "#808080", italic = true, strikethrough = true }) -- retired
end

local function short(path)
	if not path or path == "" then
		return ""
	end
	return (path:gsub("^" .. vim.pesc(vim.env.HOME or ""), "~"))
end

--- Epoch millis (or seconds) -> seconds.
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

local function load_items()
	local all = skills.list()
	-- Usage: one scan of this project's object aggregates (fail-open).
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
	state.items = all
	state.idx = math.max(1, math.min(state.idx, #all))
end

local function render_list()
	if not state.list_buf or not vim.api.nvim_buf_is_valid(state.list_buf) then
		return
	end
	local lines = {}
	local row_tier = {}
	local cursor_line = 1
	for i, e in ipairs(state.items) do
		local marker = (i == state.idx) and ">" or " "
		local subs = #e.subject > 0 and table.concat(e.subject, ", ") or "—"
		table.insert(
			lines,
			string.format(
				"%s %-24s %-7s %-11s t=%-4s %-12s %s",
				marker,
				e.name,
				e.scope,
				e.tier,
				tostring(e.touches or 0),
				fmt_when(e.last_used),
				subs
			)
		)
		row_tier[#lines] = e.tier
		if i == state.idx then
			cursor_line = #lines
		end
	end
	if #lines == 0 then
		table.insert(lines, "— no skills in the manifests —")
		table.insert(lines, "  (emit_skill in a session, or check ~/.config/opencode/skills.policy.json)")
	end
	if vim.bo[state.list_buf].modifiable == false then
		vim.bo[state.list_buf].modifiable = true
	end
	vim.api.nvim_buf_set_lines(state.list_buf, 0, -1, false, lines)
	vim.bo[state.list_buf].modifiable = false

	-- Tier colors: green routed · blue exact-only · magenta always ·
	-- dim never · dim-struck retired.
	local ns = vim.api.nvim_create_namespace("manage-skills")
	vim.api.nvim_buf_clear_namespace(state.list_buf, ns, 0, -1)
	for ln, tier in pairs(row_tier) do
		local hl = TIER_HL[tier] or "ManageSkillDefault"
		vim.api.nvim_buf_add_highlight(state.list_buf, ns, hl, ln - 1, 0, -1)
	end

	if state.list_win and vim.api.nvim_win_is_valid(state.list_win) then
		local total = vim.api.nvim_buf_line_count(state.list_buf)
		local target = math.max(1, math.min(cursor_line, total))
		pcall(vim.api.nvim_win_set_cursor, state.list_win, { target, 0 })
	end
end

local function render_detail()
	if not state.detail_buf or not vim.api.nvim_buf_is_valid(state.detail_buf) then
		return
	end
	local e = state.items[state.idx]
	local lines = {}
	if not e then
		lines = { "— nothing selected —" }
	else
		lines[#lines + 1] = "name:      " .. e.name
		lines[#lines + 1] = "scope:     " .. e.scope
		lines[#lines + 1] = "tier:      " .. e.tier
		lines[#lines + 1] = "subjects:  " .. (#e.subject > 0 and table.concat(e.subject, ", ") or "—")
		lines[#lines + 1] = "note:      " .. (e.note or "—")
		lines[#lines + 1] = "manifest:  " .. short(e.file)
		lines[#lines + 1] = "path:      "
			.. short(e.path)
			.. (e.exists and "" or "   (missing on disk!)")
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
	end
	if vim.bo[state.detail_buf].modifiable == false then
		vim.bo[state.detail_buf].modifiable = true
	end
	vim.api.nvim_buf_set_lines(state.detail_buf, 0, -1, false, lines)
	vim.bo[state.detail_buf].modifiable = false
	vim.api.nvim_buf_set_name(state.detail_buf, "SKILLS DETAIL")
end

local function set_legend()
	if not state.list_win or not vim.api.nvim_win_is_valid(state.list_win) then
		return
	end
	vim.wo[state.list_win].winbar = string.format(
		"SKILLS · %d · merged global+project · j/k t tier n note s subjects D drop o open r Q",
		#state.items
	)
end

local function refresh()
	load_items()
	render_list()
	render_detail()
	set_legend()
end

local function move(delta)
	if #state.items == 0 then
		return
	end
	state.idx = math.max(1, math.min(#state.items, state.idx + delta))
	render_list()
	render_detail()
end

local function select_tier()
	local e = state.items[state.idx]
	if not e then
		return
	end
	vim.ui.select(skills.TIERS, { prompt = "tier for '" .. e.name .. "' (current: " .. e.tier .. ")" }, function(choice)
		if not choice or choice == e.tier then
			return
		end
		if skills.set_tier(e.name, choice) then
			refresh()
			vim.notify("skills: " .. e.name .. " → " .. choice, vim.log.levels.INFO)
		end
	end)
end

local function edit_note()
	local e = state.items[state.idx]
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
				refresh()
				vim.notify("skills: note updated for " .. e.name, vim.log.levels.INFO)
			end
		end
	)
end

local function edit_subjects()
	local e = state.items[state.idx]
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
				refresh()
				vim.notify("skills: subjects updated for " .. e.name, vim.log.levels.INFO)
			end
		end
	)
end

local function drop_entry()
	local e = state.items[state.idx]
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
		refresh()
		vim.notify("skills: dropped " .. e.name .. " (file kept)", vim.log.levels.INFO)
	end
end

local function open_in_origin()
	local e = state.items[state.idx]
	if not e then
		return
	end
	if not e.exists then
		vim.notify("❌ skills: no SKILL.md on disk at " .. e.path, vim.log.levels.WARN)
		return
	end
	local origin = state.origin_win
	if origin and vim.api.nvim_win_is_valid(origin) then
		local cur = vim.api.nvim_get_current_win()
		vim.api.nvim_set_current_win(origin)
		vim.cmd("edit " .. vim.fn.fnameescape(e.path))
		vim.api.nvim_set_current_win(cur)
		vim.notify("📍 Opened " .. short(e.path), vim.log.levels.INFO)
	end
end

local function kill_viewer()
	for _, b in ipairs({ state.list_buf, state.detail_buf }) do
		if b and vim.api.nvim_buf_is_valid(b) then
			pcall(vim.keymap.del, "n", "Q", { buffer = b })
		end
	end
	if state.autocmd then
		pcall(vim.api.nvim_del_autocmd, state.autocmd)
		state.autocmd = nil
	end
	local seen = {}
	for _, w in ipairs({ state.list_win, state.detail_win, state.outer_win }) do
		if w and not seen[w] then
			seen[w] = true
			if vim.api.nvim_win_is_valid(w) then
				vim.api.nvim_win_close(w, true)
			end
		end
	end
	state.items = {}
	state.list_buf = nil
	state.detail_buf = nil
	state.list_win = nil
	state.detail_win = nil
	state.outer_win = nil
	state.origin_win = nil
	vim.notify("🗑️ Skills viewer closed", vim.log.levels.INFO)
end

local function make_window(buf, split, ref_win)
	local opts = { relative = "", split = split }
	if ref_win then
		opts.win = ref_win
	end
	return vim.api.nvim_open_win(buf, false, opts)
end

local function map_keys(buf)
	local opts = { buffer = buf, nowait = true, noremap = true, silent = true }
	vim.keymap.set("n", "j", function()
		move(1)
	end, opts)
	vim.keymap.set("n", "k", function()
		move(-1)
	end, opts)
	vim.keymap.set("n", "t", select_tier, opts)
	vim.keymap.set("n", "n", edit_note, opts)
	vim.keymap.set("n", "s", edit_subjects, opts)
	vim.keymap.set("n", "D", drop_entry, opts)
	vim.keymap.set("n", "o", open_in_origin, opts)
	vim.keymap.set("n", "r", refresh, opts)
	vim.keymap.set("n", "Q", kill_viewer, opts)
end

function M.open()
	load_items()
	define_hls()

	state.origin_win = vim.api.nvim_get_current_win()

	state.list_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[state.list_buf].bufhidden = "wipe"
	state.outer_win = make_window(state.list_buf, "right")
	state.list_win = state.outer_win
	set_legend()

	state.detail_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[state.detail_buf].bufhidden = "wipe"
	vim.bo[state.detail_buf].modifiable = false
	state.detail_win = make_window(state.detail_buf, "below", state.list_win)

	vim.api.nvim_set_current_win(state.list_win)
	map_keys(state.list_buf)
	map_keys(state.detail_buf)

	state.autocmd = vim.api.nvim_create_autocmd("WinEnter", {
		callback = function()
			local cur = vim.api.nvim_get_current_win()
			if
				state.list_win
				and vim.api.nvim_win_is_valid(state.list_win)
				and (cur == state.detail_win or cur == state.list_win)
			then
				vim.schedule(function()
					if state.list_win and vim.api.nvim_win_is_valid(state.list_win) then
						vim.api.nvim_set_current_win(state.list_win)
					end
				end)
			end
		end,
	})

	render_list()
	render_detail()
end

return M
