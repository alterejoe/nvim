-- keymaps/forge.lua
local nav = require("forge_nav")
local map = vim.keymap.set

-- Toggle handler <-> templ
map("n", "gt", nav.toggle, { desc = "Forge: toggle handler/templ" })

-- Go to sqlc
map("n", "gs", nav.goto_sqlc, { desc = "Forge: goto sqlc" })

-- Pickers
map("n", "<leader>ff", nav.pick, { desc = "Forge: pick entry" })
map("n", "<leader>fh", function()
	nav.pick_type("handler")
end, { desc = "Forge: pick handler" })
map("n", "<leader>ft", function()
	nav.pick_type("templ")
end, { desc = "Forge: pick templ" })
map("n", "<leader>fs", function()
	nav.pick_type("sqlc")
end, { desc = "Forge: pick sqlc" })

-- Reload state
map("n", "<leader>fR", nav.reload, { desc = "Forge: reload state" })
