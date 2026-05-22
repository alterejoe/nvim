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
			cmdline = {
				view = "cmdline",
			},
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
	{
		"folke/trouble.nvim",
		opts = {}, -- for default options, refer to the configuration section for custom setup.
		cmd = "Trouble",
		keys = {
			{
				"<leader>xx",
				"<cmd>Trouble diagnostics toggle<cr>",
				desc = "Diagnostics (Trouble)",
			},
			{
				"<leader>xX",
				"<cmd>Trouble diagnostics toggle filter.buf=0<cr>",
				desc = "Buffer Diagnostics (Trouble)",
			},
			{
				"<leader>cs",
				"<cmd>Trouble symbols toggle focus=false<cr>",
				desc = "Symbols (Trouble)",
			},
			{
				"<leader>cl",
				"<cmd>Trouble lsp toggle focus=false win.position=right<cr>",
				desc = "LSP Definitions / references / ... (Trouble)",
			},
			{
				"<leader>xL",
				"<cmd>Trouble loclist toggle<cr>",
				desc = "Location List (Trouble)",
			},
			{
				"<leader>xQ",
				"<cmd>Trouble qflist toggle<cr>",
				desc = "Quickfix List (Trouble)",
			},
		},
	},
}
