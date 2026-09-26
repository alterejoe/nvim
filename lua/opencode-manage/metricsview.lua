-- /home/altjoe/.config/nvim/lua/opencode-manage/metricsview.lua FINAL
-- opencode-manage.metricsview — metrics panel (console adapter, doc 19 C1/C2/O1).
-- Persistent two-pane viewer, same shape as the other manage viewers:
--   j/k move · t mode (turns <-> objects) · r refresh · Q kill
-- TURNS mode: one row per assistant turn — time · in · out · cache · delta ·
-- badge (compaction, proposal, tool burst), detail = its context events.
-- OBJECTS mode (O1): named objects (files, dirs, patterns, symbols, skills,
-- groups) with touch counts and last-seen; detail = verdict outcomes for
-- file objects plus the recent events under that tag.
-- Data comes from opencode-manage.metrics — reads only, never writes.
-- The engine (opencode-manage.console) owns windows/keymaps/state; this
-- file owns the metrics-specific rendering and the mode toggle.

local metrics = require("opencode-manage.metrics")
local console = require("opencode-manage.console")

local M = {}

local adapter = { mode = "turns" } -- "turns" | "objects"

-- One cache per refresh: turns + events + objects + prune flag. The detail
-- panes read from here — never re-query the store per keystroke.
local cache = { turns = {}, events = {}, objects = {}, prune_pending = false }

local function fmt_ts(ts)
	if not ts or ts == 0 then
		return "?"
	end
	return os.date("%m-%d %H:%M:%S", math.floor(ts / 1000))
end

local function fmt_clock(ts)
	if not ts or ts == 0 then
		return "?"
	end
	return os.date("%H:%M:%S", math.floor(ts / 1000))
end

local function fmt_short(ts)
	if not ts or ts == 0 then
		return "?"
	end
	return os.date("%m-%d %H:%M", math.floor(ts / 1000))
end

local function num(v)
	return tonumber(v) or 0
end

--- Refresh source: loads the shared cache, returns the mode's list.
--- @return table[]
local function list()
	cache.events = metrics.events(1000)
	local s = metrics.stats()
	cache.prune_pending = s.prune_pending == true
	if adapter.mode == "objects" then
		cache.objects = metrics.objects(300)
		return cache.objects
	end
	cache.turns = metrics.turns(300)
	return cache.turns
end

--- Context events whose ts falls inside turn i's window (exclusive of the
--- older turn's ts, inclusive of this turn's).
--- @param items table[]
--- @param i number
--- @return table[]
local function window_events(items, i)
	local turn = items[i]
	if not turn then
		return {}
	end
	local hi = num(turn.ts)
	local lo = items[i + 1] and num(items[i + 1].ts) or 0
	local out = {}
	for _, e in ipairs(cache.events) do
		local ts = num(e.ts)
		if ts > lo and ts <= hi then
			out[#out + 1] = e
		end
	end
	return out
end

--- Cache delta vs the previous (older) turn.
--- @param items table[]
--- @param i number
--- @return number|nil
local function cache_delta(items, i)
	local cur = items[i]
	local older = items[i + 1]
	if not cur or not older then
		return nil
	end
	return num(cur.cache_read) - num(older.cache_read)
end

local function fmt_delta(d)
	if d == nil then
		return ""
	end
	if d >= 0 then
		return string.format("+%d", d)
	end
	return tostring(d)
end

--- Badge for a turn: compaction (big input or big negative delta), proposal
--- (any proposal event in the window), tool burst (>= 5 tool calls).
--- @param items table[]
--- @param i number
--- @param d number|nil
--- @return string
local function turn_badge(items, i, d)
	local t = items[i]
	if not t then
		return ""
	end
	if num(t.tokens_input) >= 20000 or (d ~= nil and d <= -50000) then
		return "⚙ compaction"
	end
	local evs = window_events(items, i)
	local tools, proposals = 0, 0
	for _, e in ipairs(evs) do
		if e.kind == "tool_call" then
			tools = tools + 1
		elseif e.kind == "proposal" then
			proposals = proposals + 1
		end
	end
	if proposals > 0 then
		return "📝 proposal"
	end
	if tools >= 5 then
		return string.format("🔧 %d tools", tools)
	end
	return ""
end

--- Rows per mode.
--- @param items table[]
--- @return table[]
local function rows(items)
	local out = {}
	for i, it in ipairs(items) do
		if adapter.mode == "objects" then
			out[i] = {
				item = it,
				text = string.format(
					"%-8s %5d  %-12s %s",
					tostring(it.kind or "?"),
					num(it.n),
					fmt_short(it.last),
					tostring(it.tag or "?")
				),
			}
		else
			local d = cache_delta(items, i)
			out[i] = {
				item = it,
				text = string.format(
					"%s  in %-7s out %-6s cache %-8s %-9s %s",
					fmt_clock(it.ts),
					tostring(num(it.tokens_input)),
					tostring(num(it.tokens_output)),
					tostring(num(it.cache_read)),
					fmt_delta(d),
					turn_badge(items, i, d)
				),
			}
		end
	end
	return out
end

--- Detail per mode.
--- @param it table
--- @param h table  console handle
--- @return table
local function preview(it, h)
	local lines
	if adapter.mode == "objects" then
		lines = {}
		lines[#lines + 1] = "object:   " .. tostring(it.tag or "?")
		lines[#lines + 1] = "kind:     " .. tostring(it.kind or "?")
		lines[#lines + 1] = string.format("touches:  %d", num(it.n))
		lines[#lines + 1] = "last:     " .. fmt_ts(it.last)
		if it.kind == "file" then
			local vs = metrics.object_verdicts(it.tag)
			if #vs > 0 then
				local parts = {}
				for _, v in ipairs(vs) do
					parts[#parts + 1] = string.format("%s=%d", v.verdict or "?", num(v.n))
				end
				lines[#lines + 1] = "verdicts: " .. table.concat(parts, " · ")
			else
				lines[#lines + 1] = "verdicts: — none yet"
			end
		end
		lines[#lines + 1] = string.rep("─", 40)
		local evs = metrics.object_events(it.tag, it.kind, 80)
		if #evs == 0 then
			lines[#lines + 1] = "— no events under this object —"
		else
			lines[#lines + 1] = string.format("recent events (%d):", #evs)
			for _, e in ipairs(evs) do
				lines[#lines + 1] = string.format("  %s  %-16s %s", fmt_clock(e.ts), e.kind or "?", e.detail or "")
			end
		end
	else
		local i = h.state.idx
		local d = cache_delta(h.state.items, i)
		local evs = window_events(h.state.items, i)
		local badge = turn_badge(h.state.items, i, d)
		lines = {}
		lines[#lines + 1] = "turn:     " .. fmt_ts(it.ts)
		lines[#lines + 1] = "message:  " .. (it.message_id or "?")
		lines[#lines + 1] = "kind:     " .. (badge ~= "" and badge or "chat")
		lines[#lines + 1] = string.format(
			"tokens:   in %s · out %s · reasoning %s · cache r/w %s/%s",
			tostring(num(it.tokens_input)),
			tostring(num(it.tokens_output)),
			tostring(num(it.tokens_reasoning)),
			tostring(num(it.cache_read)),
			tostring(num(it.cache_write))
		)
		lines[#lines + 1] = "context:  " .. (fmt_delta(d) ~= "" and (fmt_delta(d) .. " vs previous turn") or "no previous turn")
		lines[#lines + 1] = "model:    " .. (it.model or "?") .. "  ·  agent: " .. (it.agent or "?")
		lines[#lines + 1] = string.rep("─", 40)
		if #evs == 0 then
			lines[#lines + 1] = "— no context events in this window —"
		else
			lines[#lines + 1] = string.format("events in this turn's window (%d):", #evs)
			for _, e in ipairs(evs) do
				lines[#lines + 1] = string.format("  %s  %-16s %s", fmt_clock(e.ts), e.kind or "?", e.detail or "")
			end
		end
	end
	return {
		left = {
			lines = lines,
			name = "METRICS DETAIL",
			ft = "",
			modifiable = false,
			winbar = "METRICS DETAIL",
		},
	}
end

--- t: toggle turns <-> objects mode.
--- @param h table  console handle
local function toggle_mode(h)
	if adapter.mode == "turns" then
		adapter.mode = "objects"
	else
		adapter.mode = "turns"
	end
	h.state.idx = 1
	h.refresh()
	vim.notify("metrics mode: " .. adapter.mode, vim.log.levels.INFO)
end

function M.open()
	console.open({
		name = "Metrics",
		layout = "detail",
		list = list,
		rows = rows,
		preview = preview,
		keys = {
			{ key = "t", desc = "mode", fn = toggle_mode },
		},
		legend = function(h)
			return string.format(
				"METRICS · %s · %d turns · %d events · %d objects · prune: %s · t mode · j/k r Q",
				adapter.mode,
				#cache.turns,
				#cache.events,
				#cache.objects,
				cache.prune_pending and "requested" or "—"
			)
		end,
		empty_lines = function()
			if adapter.mode == "objects" then
				return { "— no objects yet — tags record from tool calls (files, dirs, patterns, symbols)" }
			end
			return { "— no turns yet — they record on every assistant message" }
		end,
		open_empty = true,
		keep_empty = true,
	})
end

return M
