local tmux = require("tmux_projects")

tmux.setup({
	project_order = { "work", "workWtools", "side" },
	projects = {
		work = {
			{ name = "portal", path = "~/projects/portal/" },
			{ name = "portal/admin", path = "~/projects/portal/adminserver/" },
			{ name = "portal/client", path = "~/projects/portal/clientserver/" },
			{ name = "portal/auth0", path = "~/projects/portal/auth0server/" },
		},
		workWtools = {
			{ name = "portal/admin", path = "~/projects/portal/adminserver/" },
			{ name = "portal/client", path = "~/projects/portal/clientserver/" },
			{ name = "portal/auth0", path = "~/projects/portal/auth0server/" },
			{ name = "portal", path = "~/projects/portal/" },
			{ name = "tools/forge", path = "~/tools/forge" },
			{ name = "tools/forge-templates-portal", path = "~/tools/forge_templates_portal" },
			{ name = "tools/primitive-templates", path = "~/tools/primitives" },
			{ name = "tools/statey", path = "~/tools/statey" },
			{ name = "tools/forge-templates", path = "~/tools/forge_templates" },
		},

		trading = {
			{ name = "trading/kraken", path = "~/projects/trading/kraken/" },
			{ name = "trading/migrations", path = "~/projects/trading/migrations/" },
			{ name = "trading/cli", path = "~/projects/trading/strat-cli/" },
			{ name = "trading/sdk", path = "~/projects/trading/strat-sdk/" },
			{ name = "trading/terraform", path = "~/projects/trading/terraform/" },
			{ name = "trading/trading", path = "~/projects/trading/trading/" },
			{ name = "trading/web", path = "~/projects/trading/web/" },
			{ name = "tools/forge", path = "~/tools/forge" },
			{ name = "tools/forge-templates", path = "~/tools/forge_templates" },
			{ name = "tools/primitives", path = "~/tools/primitives" },
			{ name = "tools/primitive-templates", path = "~/tools/primitives-templates" },
			{ name = "tools/statey", path = "~/tools/statey" },
		},
		-- side = {
		-- 	{ name = "blog", path = "~/projects/blog" },
		-- },
	},
	default = {
		{ name = "ide/nvim", path = "~/.config/nvim" },
	},
})

vim.keymap.set("n", "<leader>tp", tmux.pick_project, { desc = "Tmux switch project" })
vim.keymap.set("n", "<leader>tP", tmux.recover_project, { desc = "Tmux recover project" })
