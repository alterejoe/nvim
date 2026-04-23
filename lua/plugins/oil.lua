return {
	"stevearc/oil.nvim",
	lazy = false,
	opts = {
		default_file_explorer = true,
		view_options = { show_hidden = true },
		cleanup_delay_ms = 0,
		buf_options = {
			buflisted = false,
		},
	},
	keys = {
		{ "-", "<CMD>Oil<CR>", desc = "Open parent directory" },
	},
}
