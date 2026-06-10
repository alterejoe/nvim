local tmux = require("tmux_projects")

tmux.setup({
	project_order = { "election", "work" },
	projects = {
		election = {
			{ name = "TN/2026G", path = "/mnt/g/Tennessee/!Tennessee - 2026G" },
			{ name = "TN/2026G/workflow", path = "/mnt/g/Tennessee/!Tennessee - 2026G/Workflow" },
			{ name = "TN/2026G/proofing", path = "/mnt/g/Tennessee/!Tennessee - 2026G/Proofing" },
			{ name = "TN/2026G/databases", path = "/mnt/g/Tennessee/!Tennessee - 2026G/Databases" },
			{ name = "TN/2026P", path = "/mnt/g/Tennessee/2026P" },
			{ name = "AccTest/Drop", path = "/mnt/c/Users/jmeyer/Documents/Hotfolders/export-handler/Kentucky" },
			{
				name = "AccTest/AdditionalText",
				path = "/mnt/c/Users/jmeyer/Documents/Hotfolders/export-handler/additionaltext",
			},
			{
				name = "AccTest/DuoReport",
				path = "/mnt/c/Users/jmeyer/Documents/Hotfolders/export-handler/duoreport",
			},
		},
		work = {
			{ name = "portal", path = "~/projects/portal/" },
			{ name = "portal/admin", path = "~/projects/portal/adminserver/" },
			{ name = "portal/client", path = "~/projects/portal/clientserver/" },
			{ name = "portal/auth0", path = "~/projects/portal/auth0server/" },
			{ name = "tools/forge-templates-portal", path = "~/tools/forge_templates_portal" },
			{ name = "tools/primitive-templates", path = "~/tools/primitives-templates" },
			{ name = "tools/primitives", path = "~/tools/primitive" },
			{ name = "tools/forge-templates", path = "~/tools/forge_templates" },
			{ name = "portal/docs", path = "~/projects/portal/docs/" },
			{ name = "portal/static/form-behaviors", path = "~/projects/portal/static/js/form-behavior/" },
			{ name = "portal/static", path = "~/projects/portal/static/" },
			{ name = "portal/shared", path = "~/projects/portal/shared/" },
			{ name = "portal/gencomponents", path = "~/projects/portal/gencomponents/" },
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
		{ name = "ide/nvim-old", path = "~/.config/nvim-old" },
	},
})

vim.keymap.set("n", "<leader>tp", tmux.pick_project, { desc = "Tmux switch project" })
vim.keymap.set("n", "<leader>tP", tmux.recover_project, { desc = "Tmux recover project" })
