local tmux = require("tmux_projects")

tmux.setup({
	project_order = { "work", "side" },
	projects = {
		work = {
			{ name = "portal/admin", path = "~/projects/portal/adminserver/" },
			{ name = "portal/client", path = "~/projects/portal/clientserver/" },
			{ name = "portal/auth0", path = "~/projects/portal/auth0server/" },
			{ name = "portal", path = "~/projects/portal/" },
			{ name = "tools/forge", path = "~/tools/forge" },
			{ name = "tools/forge-templates", path = "~/tools/forge_templates" },
			{ name = "tools/primitives", path = "~/tools/primitive-templates" },
			{ name = "tools/primitive-templates", path = "~/tools/primitives" },
			{ name = "tools/statey", path = "~/tools/statey" },
		},
		-- side = {
		-- 	{ name = "blog", path = "~/projects/blog" },
		-- },
	},
	default = {
		{ name = "ide/nvim", path = "~/.config/nvim" },
		{ name = "ide/nvim-old", path = "~/.config/nvim-old" },
	},
})

vim.keymap.set("n", "<leader>tp", tmux.pick_project, { desc = "Tmux switch project" })
vim.keymap.set("n", "<leader>tP", tmux.recover_project, { desc = "Tmux recover project" })
