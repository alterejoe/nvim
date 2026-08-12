-- /home/jmeyer/.config/nvim/lua/plugins/lang.lua FINAL
return {
	{
		"neovim/nvim-lspconfig",
		commit = "c588db3",
	},
	{
		"nvim-treesitter/nvim-treesitter",
		lazy = false,
		build = function(plugin)
			local luapath = plugin.dir .. "/lua"
			package.path = package.path .. ";" .. luapath .. "/?.lua;" .. luapath .. "/?/init.lua"

			local install = require("nvim-treesitter.install")

			local langs = {}
			local ok, lang_mod = pcall(require, "lang")
			if ok and lang_mod.grammars then
				langs = lang_mod.grammars()
			end
			if #langs == 0 then
				-- Fallback: common languages
				langs =
					{ "python", "lua", "go", "javascript", "typescript", "html", "css", "json", "yaml", "toml", "sql" }
			end

			local task = install.install(langs)
			if task and task.wait then
				task:wait(180000)
			end
		end,
	},
	{
		"stevearc/conform.nvim",
		commit = "086a40d",
		event = "BufWritePre",
	},
	{ "mfussenegger/nvim-dap" },
	{ "nvim-neotest/nvim-nio" },
	{ "igorlfs/nvim-dap-view" },
}
