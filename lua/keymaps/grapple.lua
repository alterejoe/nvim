local scope_type = "cwd"

vim.keymap.set("n", "<leader>a", function()
    require("grapple").toggle({ scope = scope_type })
end, { desc = "Grapple toggle" })

vim.keymap.set("n", "<M-e>", function()
    require("telescope").extensions.grapple.tags({ scope = scope_type })
end, { desc = "Grapple telescope" })

vim.keymap.set("n", "<c-e>", function()
    require("grapple").toggle_tags({ scope = scope_type })
end, { desc = "Grapple toggle tags" })

vim.keymap.set("n", "<leader>j", function()
    require("grapple").select({ index = 1, scope = scope_type })
end, { desc = "Grapple tag 1" })

vim.keymap.set("n", "<leader>k", function()
    require("grapple").select({ index = 2, scope = scope_type })
end, { desc = "Grapple tag 2" })

vim.keymap.set("n", "<leader>l", function()
    require("grapple").select({ index = 3, scope = scope_type })
end, { desc = "Grapple tag 3" })

vim.keymap.set("n", "<leader>;", function()
    require("grapple").select({ index = 4, scope = scope_type })
end, { desc = "Grapple tag 4" })

vim.keymap.set("n", "<leader>J", function()
    require("grapple").select({ index = 5, scope = scope_type })
end, { desc = "Grapple tag 5" })

vim.keymap.set("n", "<leader>K", function()
    require("grapple").select({ index = 6, scope = scope_type })
end, { desc = "Grapple tag 6" })

vim.keymap.set("n", "<leader>L", function()
    require("grapple").select({ index = 7, scope = scope_type })
end, { desc = "Grapple tag 7" })

vim.keymap.set("n", "<leader>:", function()
    require("grapple").select({ index = 8, scope = scope_type })
end, { desc = "Grapple tag 8" })
