-- opencode-manage.reviewview.state — shared viewer state.
-- Single source of truth for the review viewer; every module reads and
-- mutates this table. Kept separate so render/actions/diff never require
-- each other's internals.

local M = {
	items = {},
	idx = 1,
	filter = "all", -- "all" | "session" | "files" | "neither"
	row_states = {}, -- item index -> derived state, computed at refresh
	list_buf = nil,
	cur_buf = nil,
	after_buf = nil,
	list_win = nil,
	cur_win = nil,
	after_win = nil,
	outer_win = nil,
	origin_win = nil,
	origin_buf = nil,
	autocmd = nil,
}

return M
