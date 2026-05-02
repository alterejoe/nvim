-- lua/plugins/which-key.lua
return {
	"folke/which-key.nvim",
	event = "VeryLazy",
	opts = {
		preset = "modern",
		delay = 400,
		notify = false,
		show_help = false,
		show_keys = false, -- noice owns cmdline echo

		win = {
			border = "rounded",
			padding = { 1, 2 },
			title = true,
			title_pos = "center",
			wo = { winblend = 0 },
		},
		layout = {
			width = { min = 20 },
			spacing = 3,
		},
		icons = {
			mappings = false,
			rules = false,
			separator = "->",
			group = "+ ",
			breadcrumb = ">",
			ellipsis = "...",
		},
		sort = { "local", "order", "group", "alphanum", "mod" },
		expand = 1,
	},
}
