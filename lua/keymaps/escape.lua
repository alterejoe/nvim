vim.keymap.set("i", "jk", "<Esc>", { noremap = true, silent = true, desc = "Escape insert mode" })
vim.keymap.set("v", "nm", "<Esc>", { noremap = true, silent = true, desc = "Escape visual mode" })
vim.keymap.set("t", "jk", "<C-\\><C-n>", { noremap = true, silent = true, desc = "Escape terminal mode" })
