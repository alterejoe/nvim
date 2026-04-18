return {
	{ "feline-nvim/feline.nvim" }, -- status bar
	{ "gabrielpoca/replacer.nvim" },
	{ "mbbill/undotree" },
	{
		"folke/noice.nvim",
		event = "VeryLazy",
		dependencies = {
			"MunifTanjim/nui.nvim",
		},
		opts = {
			lsp = { progress = { enabled = false } },
			presets = {
				bottom_search = true,
				command_palette = true,
			},
			routes = {
				{
					filter = { event = "notify", find = "No information available" },
					opts = { skip = true },
				},
			},
		},
	},
}
