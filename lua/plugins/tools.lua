return {
	{ "feline-nvim/feline.nvim" }, -- status bar
	{ "gabrielpoca/replacer.nvim" },
	{ "kevinhwang91/nvim-bqf" }, -- better quickfix list search/replace/prettier
	{ "mbbill/undotree" },
	{ "lucamot/chrome-remote.nvim" },

	{
		"folke/noice.nvim",
		event = "VeryLazy",
		dependencies = {
			"MunifTanjim/nui.nvim",
		},
		opts = {
			lsp = { progress = { enabled = false } },
			messages = {
				enabled = true,
				view = "mini",
			},
			presets = {
				bottom_search = true,
				command_palette = true,
			},
			views = {
				mini = {
					position = {
						row = -2,
						col = 0,
					},
					border = {
						style = "rounded",
					},
					win_options = {
						winblend = 0,
						winhighlight = "Normal:NoiceMini,FloatBorder:NoiceMini",
					},
				},
			},
			routes = {
				{
					filter = { event = "notify", find = "No information available" },
					opts = { skip = true },
				},
				{
					filter = {
						event = "msg_show",
						kind = "",
						find = "lines yanked",
					},
					view = "mini",
				},
			},
		},
	},
}
