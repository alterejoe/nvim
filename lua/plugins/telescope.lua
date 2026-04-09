return {
	{
		"nvim-lua/plenary.nvim",
		commit = "857c5ac",
	},
	{
		"nvim-telescope/telescope-fzf-native.nvim",
		commit = "6fea601",
		build = "make",
	},
	{
		"nvim-telescope/telescope.nvim",
		commit = "48d2656",
		dependencies = {
			"nvim-lua/plenary.nvim",
			"nvim-telescope/telescope-fzf-native.nvim",
		},
		config = function()
			local telescope = require("telescope")
			telescope.setup({
				defaults = {
					mappings = {
						i = {
							["<C-h>"] = "which_key",
						},
					},
				},
				extensions = {
					fzf = {
						fuzzy = true,
						override_generic_sorter = true,
						override_file_sorter = true,
						case_mode = "smart_case",
					},
					tmux = {
						use_nvim_notify = false,
						create_session = {
							scan_paths = {
								"~/projects",
							},
							scan_depth = 1,
							respect_gitignore = true,
							include_hidden_dirs = false,
							only_dirs = true,
						},
					},
				},
			})
			telescope.load_extension("fzf")
			telescope.load_extension("tmux")
		end,
	},
	{
		"pre-z/telescope-tmuxing.nvim",
		commit = "97326b7",
		dependencies = {
			"nvim-telescope/telescope.nvim",
			"nvim-lua/plenary.nvim",
		},
		keys = {
			{
				"<leader>ts",
				"<cmd>lua require('telescope').extensions.tmux.switch_session({ list_sessions = 'simple'})<cr>",
				desc = "Switch Tmux session",
			},
			{
				"<leader>tS",
				"<cmd>lua require('telescope').extensions.tmux.switch_window()<cr>",
				desc = "Switch Tmux window",
			},
			{
				"<leader>ta",
				"<cmd>lua require('telescope').extensions.tmux.switch_session({ list_sessions = 'full'})<cr>",
				desc = "All Tmux sessions",
			},
			{
				"<leader>tc",
				"<cmd>lua require('telescope').extensions.tmux.create_session()<cr>",
				desc = "Create Tmux session",
			},
			{
				"<leader>tr",
				"<cmd>lua require('telescope').extensions.tmux.rename_current_session()<cr>",
				desc = "Rename Tmux session",
			},
			{
				"<leader>tk",
				"<cmd>lua require('telescope').extensions.tmux.kill_current_session()<cr>",
				desc = "Kill Tmux session",
			},
		},
	},
}
