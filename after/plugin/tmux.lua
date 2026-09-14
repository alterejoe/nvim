-- after/plugin/tmux.lua FINAL-2
local tmux = require("tmux_projects")

tmux.setup({
	project_order = { "hookit", "volleyball" },
	projects = {
		hookit = {
			{ name = "hookit", path = "~/projects/hookit/" },
		},
		volleyball = {
			{ name = "volleyall", path = "~/projects/volleyball/" },
		},
	},
	default = {
		{ name = "ide/nvim", path = "~/.config/nvim" },
	},
})

-- tp: saved palette (projects + workspaces)
-- ts: live workspace board (active sessions + virtual folders)
vim.keymap.set("n", "<leader>tp", tmux.pick_project, { desc = "Palette (saved)" })
vim.keymap.set("n", "<leader>ts", tmux.open_workboard, { desc = "Workspace board (live)" })
vim.keymap.set("n", "<leader>tP", tmux.recover_project, { desc = "Tmux recover project" })
