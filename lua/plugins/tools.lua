return {
	{ "mbbill/undotree" },
	{
		"folke/noice.nvim",
		event = "VeryLazy",
		dependencies = {
			"MunifTanjim/nui.nvim",
		},
		opts = {
			lsp = {
				override = {
					["vim.lsp.util.convert_input_list_to_statements"] = true,
					["vim.lsp.util.stylize_markdown"] = true,
					["cmp.entry.get_documentation"] = true,
				},
			},
			routes = {
				{
					filter = {
						event = "notify",
						find = "No information available",
					},
					opts = { skip = true },
				},
			},
			presets = {
				bottom_search = true,
				command_palette = true,
				long_message_to_split = true,
			},
		},
		config = function(_, opts)
			require("noice").setup(opts)
			-- View history with :Noice history
			-- Copy from history, see messages clearly
			vim.keymap.set("n", "<leader>nh", "<cmd>Noice history<CR>", { desc = "Notification history" })
		end,
	},
}
