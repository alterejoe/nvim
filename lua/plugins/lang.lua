return {
	{
		"neovim/nvim-lspconfig",
		commit = "c588db3",
	},
	{
		"nvim-treesitter/nvim-treesitter",
		branch = "master",
		commit = "4916d65",
		build = ":TSUpdate",
		lazy = false,
	},
	{
		"stevearc/conform.nvim",
		commit = "086a40d",
		event = "BufWritePre",
	},
	{ "mfussenegger/nvim-dap" },
	{ "nvim-neotest/nvim-nio" },
	{ "igorlfs/nvim-dap-view" }, -- your existing preference over dap-ui
}
