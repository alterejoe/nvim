-- /home/altjoe/.config/nvim/lua/opencode-manage/vaultview.lua FINAL
-- opencode-manage.vaultview — the vault viewer (global references, CV1).
-- Persistent two-pane viewer, same shape as the other manage viewers:
--   j/k move · d prune (with reason) · o open path · i re-index vault ·
--   x show/hide pruned · r refresh · Q kill
-- The vault is the GLOBAL ref store (~/.config/opencode/state.db,
-- scope='global') — folders approved as "common" land here, so a component
-- lives once and is visible from every project (doc 20 CV1).
-- Reads come from opencode-manage.refs; actions route through
-- refs.prune_global / refs.index(root, { global = true }).

local refs = require("opencode-manage.refs")

local M = {}

local VAULT_ROOT = (vim.env.HOME or "") .. "/projects/shared"

local state = {
	items = {},
	idx = 1,
	show_pruned = false,
	list_buf = nil,
	detail_buf = nil,
	list_win = nil,
	detail_win = nil,
	outer_win = nil,
	origin_win = nil,
	autocmd = nil,
}

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

local function load_items()
	local all = refs.list_global()
	local out = {}
	for _, r in ipairs(all) do
		if state.show_pruned or not r.pruned_ts then
			out[#out + 1] = r
		end
	end
	state.items = out
	state.idx = math.max(1, math.min(state.idx, #out))
end

local function render_list()
	if not state.list_buf or not vim.api.nvim_buf_is_valid(state.list_buf) then
		return
	end
	local lines = {}
	local cursor_line = 1
	for i, r in ipairs(state.items) do
		local marker = (i == state.idx) and ">" or " "
		local target = r.path or r.symbol or ""
		local pruned = r.pruned_ts and " [pruned]" or ""
		table.insert(
			lines,
			string.format(
				"%s #%-4s %-4s u=%-3s %-20s %s%s",
				marker,
				tostring(r.id),
				tostring(r.kind or "?"),
				tostring(r.uses or 0),
				(tostring(r.subject or "")):sub(1, 20),
				short(target),
				pruned
			)
		)
		if i == state.idx then
			cursor_line = #lines
		end
	end
	if #lines == 0 then
		if state.show_pruned then
			table.insert(lines, "— no vault references at all — :ManageVault to index ~/projects/shared")
		else
			table.insert(lines, "— no vault references yet — approve a common folder or :ManageVault")
		end
	end
	if vim.bo[state.list_buf].modifiable == false then
		vim.bo[state.list_buf].modifiable = true
	end
	vim.api.nvim_buf_set_lines(state.list_buf, 0, -1, false, lines)
	vim.bo[state.list_buf].modifiable = false

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
	local r = state.items[state.idx]
	local lines = {}
	if not r then
		lines = { "— nothing selected —" }
	else
		lines[#lines + 1] = "id:       #" .. tostring(r.id)
		lines[#lines + 1] = "scope:    global (vault)  ·  kind: " .. tostring(r.kind or "?")
		lines[#lines + 1] = "subject:  " .. tostring(r.subject or "—")
		lines[#lines + 1] = "uses:     " .. tostring(r.uses or 0) .. "  ·  last used: " .. fmt_when(r.last_used)
		lines[#lines + 1] = "path:     " .. (r.path or "—")
		if r.symbol then
			lines[#lines + 1] = "symbol:   " .. tostring(r.symbol)
		end
		if r.pruned_ts then
			lines[#lines + 1] = "pruned:   " .. fmt_when(r.pruned_ts)
			lines[#lines + 1] = "reason:   " .. tostring(r.prune_reason or "—")
		end
		lines[#lines + 1] = string.rep("─", 40)
		lines[#lines + 1] = "actions:  d prune (reason) · o open · i re-index vault · x pruned · r refresh"
	end
	if vim.bo[state.detail_buf].modifiable == false then
		vim.bo[state.detail_buf].modifiable = true
	end
	vim.api.nvim_buf_set_lines(state.detail_buf, 0, -1, false, lines)
	vim.bo[state.detail_buf].modifiable = false
	vim.api.nvim_buf_set_name(state.detail_buf, "VAULT DETAIL")
end

local function set_legend()
	if not state.list_win or not vim.api.nvim_win_is_valid(state.list_win) then
		return
	end
	vim.wo[state.list_win].winbar = string.format(
		"VAULT · %d global ref(s) · pruned: %s · j/k d o i x r Q",
		#state.items,
		state.show_pruned and "shown" or "hidden"
	)
end

local function move(delta)
	if #state.items == 0 then
		return
	end
	state.idx = math.max(1, math.min(#state.items, state.idx + delta))
	render_list()
	render_detail()
end

local function toggle_pruned()
	state.show_pruned = not state.show_pruned
	state.idx = 1
	load_items()
	render_list()
	render_detail()
	set_legend()
	vim.notify("vault pruned: " .. (state.show_pruned and "shown" or "hidden"), vim.log.levels.INFO)
end

local function prune_current()
	local r = state.items[state.idx]
	if not r then
		return
	end
	if r.pruned_ts then
		vim.notify("vault: already pruned (reason: " .. tostring(r.prune_reason or "?") .. ")", vim.log.levels.INFO)
		return
	end
	local reason = vim.fn.input("prune reason for vault #" .. tostring(r.id) .. ": ")
	if reason == nil or reason == "" then
		vim.notify("vault: prune cancelled (a reason is required)", vim.log.levels.INFO)
		return
	end
	refs.prune_global(tonumber(r.id), reason)
	load_items()
	render_list()
	render_detail()
	set_legend()
end

local function reindex()
	refs.index(VAULT_ROOT, { global = true })
	load_items()
	render_list()
	render_detail()
	set_legend()
end

local function open_in_origin()
	local r = state.items[state.idx]
	if not r or not r.path then
		return
	end
	local origin = state.origin_win
	if origin and vim.api.nvim_win_is_valid(origin) then
		local cur = vim.api.nvim_get_current_win()
		vim.api.nvim_set_current_win(origin)
		vim.cmd("edit " .. vim.fn.fnameescape(r.path))
		vim.api.nvim_set_current_win(cur)
		vim.notify("📍 Opened " .. short(r.path), vim.log.levels.INFO)
	end
end

local function refresh()
	load_items()
	render_list()
	render_detail()
	set_legend()
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
	vim.notify("🗑️ Vault viewer closed", vim.log.levels.INFO)
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
	vim.keymap.set("n", "d", prune_current, opts)
	vim.keymap.set("n", "o", open_in_origin, opts)
	vim.keymap.set("n", "i", reindex, opts)
	vim.keymap.set("n", "x", toggle_pruned, opts)
	vim.keymap.set("n", "r", refresh, opts)
	vim.keymap.set("n", "Q", kill_viewer, opts)
end

function M.open()
	load_items()

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
