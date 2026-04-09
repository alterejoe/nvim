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
	{
		"hrsh7th/cmp-nvim-lsp",
		commit = "a8912b8", -- needed for capabilities
	},
}
