-- keymaps/scratchbuf.lua
-- Defines key bindings used inside scratchbuf windows.
-- Edit lhs strings here to remap. scratchbuf.lua reads this at open time.
-- which-key descriptions are registered buffer-locally when a scratchbuf opens.
local M = {}
M.keys = {
	close = { "Q", "<Esc>" },
	open = "<CR>",
	new_below = "o",
	new_above = "O",
	cut = "dd",
	paste_below = "gp",
	paste_above = "gP",
	filter = "/",
	save = "W",
	focus_next = "<C-Tab>",
	focus_prev = "<C-S-Tab>",
	refresh = "r",
}
function M.register_which_key(buf)
	local ok, wk = pcall(require, "which-key")
	if not ok then
		return
	end
	local k = M.keys
	wk.add({
		{ k.open, buffer = buf, desc = "Open entry" },
		{ k.save, buffer = buf, desc = "Save changes" },
		{ k.new_below, buffer = buf, desc = "New entry below" },
		{ k.new_above, buffer = buf, desc = "New entry above" },
		{ k.cut, buffer = buf, desc = "Cut entry" },
		{ k.paste_below, buffer = buf, desc = "Paste below" },
		{ k.paste_above, buffer = buf, desc = "Paste above" },
		{ k.filter, buffer = buf, desc = "Fuzzy filter" },
		{ k.refresh, buffer = buf, desc = "Refresh" },
		{ k.close[1], buffer = buf, desc = "Close" },
		{ k.close[2], buffer = buf, desc = "Close" },
		{ k.focus_next, buffer = buf, desc = "Focus next pane" },
		{ k.focus_prev, buffer = buf, desc = "Focus prev pane" },
	})
end
return M
