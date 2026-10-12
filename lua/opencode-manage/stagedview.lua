-- /home/altjoe/.config/nvim/lua/opencode-manage/stagedview.lua FINAL-1
-- opencode-manage.stagedview — staged workflow panel (console adapter, doc 18 S1).
-- Read-only in S1: shows the project's latest staged state + its slices and
-- recent events. Approvals, verification, and pruning are console actions in
-- later slices (S2/S3) — this panel only reads.
--   j/k move · r refresh · Q kill
-- List rows: [status] name, status colored.
-- Preview: stage/goal/group header, slice acceptance + digest, recent events.
-- The engine (opencode-manage.console) owns windows/keymaps/state; this file
-- owns the staged-specific rendering.

local console = require("opencode-manage.console")
local staged = require("opencode-manage.staged")

local M = {}

local STATUS_HL = {
	planned = nil,
	active = "ManageEdit",
	verified = "ManageNew",
}

-- Last state row read by list(); preview uses it for the header.
local last_state = nil

local function fmt_when(ts)
	if not ts or ts == 0 then
		return "?"
	end
	return os.date("%m-%d %H:%M", math.floor(ts / 1000))
end

--- Acceptance text for a slice, from the recorded plan JSON (nil if absent).
--- @param name string
--- @return string|nil
local function acceptance_for(name)
	if not last_state or not last_state.plan_json or last_state.plan_json == "" then
		return nil
	end
	local ok, plan = pcall(vim.json.decode, last_state.plan_json)
	if not ok or type(plan) ~= "table" or type(plan.slices) ~= "table" then
		return nil
	end
	for _, s in ipairs(plan.slices) do
		if s.name == name then
			return s.acceptance
		end
	end
	return nil
end

--- Latest staged state's slices (empty when no workflow recorded).
--- @return table[]
local function list()
	last_state = staged.state()
	if not last_state then
		return {}
	end
	return staged.slices(last_state.session_id)
end

--- Rows: [status] name.
--- @param items table[]
--- @return table[]
local function rows(items)
	local out = {}
	for i, s in ipairs(items) do
		out[i] = {
			item = s,
			text = string.format("[%-8s] %s", s.status or "?", s.name or "?"),
			hl = STATUS_HL[s.status],
		}
	end
	return out
end

--- Detail: workflow header, slice info, recent events.
--- @param s table|nil
--- @return table
local function preview(s)
	local lines = {}
	if last_state then
		lines[#lines + 1] = "stage:    "
			.. (last_state.stage or "?")
			.. "  ·  session: "
			.. ((last_state.session_id or "?"):sub(1, 8))
		lines[#lines + 1] = "goal:     " .. (last_state.goal or "—")
		lines[#lines + 1] = "group:    " .. (last_state.group_name or "—")
	else
		lines[#lines + 1] = "— no staged workflow —"
	end
	lines[#lines + 1] = ""
	if not s then
		lines[#lines + 1] = "— nothing selected —"
	else
		lines[#lines + 1] = "slice:    " .. (s.name or "?")
		lines[#lines + 1] = "status:   "
			.. (s.status or "?")
			.. (s.ts_verified and ("  ·  verified: " .. fmt_when(s.ts_verified)) or "")
		local acceptance = acceptance_for(s.name)
		if acceptance then
			lines[#lines + 1] = "accept:   " .. acceptance
		end
		if s.digest and s.digest ~= "" then
			lines[#lines + 1] = "digest:   " .. s.digest
		end
	end
	if last_state then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "— recent events —"
		local events = staged.events(last_state.session_id, 8)
		if #events == 0 then
			lines[#lines + 1] = "  (none)"
		end
		for _, e in ipairs(events) do
			lines[#lines + 1] = string.format(
				"  %s  %-4s %s%s",
				fmt_when(e.ts),
				e.actor or "?",
				e.action or "?",
				e.detail and (" — " .. e.detail) or ""
			)
		end
	end
	return {
		left = {
			lines = lines,
			name = "STAGED DETAIL",
			ft = "",
			modifiable = false,
			winbar = "STAGED DETAIL",
			hl = {},
		},
	}
end

function M.open()
	console.open({
		name = "Staged",
		layout = "detail",
		list = list,
		rows = rows,
		preview = preview,
		legend = function(h)
			local stage = last_state and last_state.stage or "none"
			return string.format("STAGED · stage=%s · %d slice(s) · j/k r Q", stage, #h.state.items)
		end,
		empty_lines = function()
			return {
				"— no staged workflow yet —",
				"  the AI records a plan with the workflow tool; this view is read-only (S1)",
			}
		end,
		open_empty = true,
		keep_empty = true,
	})
end

return M
