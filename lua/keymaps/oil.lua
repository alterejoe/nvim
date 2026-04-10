vim.keymap.set("n", "-", "<CMD>Oil<CR>", { desc = "Open parent directory" })

vim.keymap.set("n", "<leader>e", function()
    vim.cmd("Oil")
end, { desc = "Oil file explorer" })

vim.keymap.set("n", "<leader><leader>e", function()
    vim.cmd("Oil " .. vim.fn.getcwd())
end, { desc = "Oil cwd" })
