local telescope = require("telescope")
local builtin = require("telescope.builtin")

vim.keymap.set("n", "<leader>rf", function()
    telescope.extensions.recent_files.recent_files({ cwd = vim.fn.getcwd() })
end, { desc = "Telescope find recent files" })

vim.keymap.set("n", "<leader>ff", function()
    builtin.find_files({ cwd = vim.fn.getcwd(), hidden = true, max_depth = 3 })
end, { desc = "Telescope find files" })

vim.keymap.set("n", "<leader>fg", function()
    telescope.extensions.egrepify.egrepify({ cwd = vim.fn.getcwd() })
end, { desc = "Telescope live grep" })

vim.keymap.set("n", "<leader>fG", function()
    telescope.extensions.egrepify.egrepify({ search_dirs = { vim.fn.expand("%:p") }, qflist = true })
end, { desc = "Telescope grep current file" })

vim.keymap.set("n", "<leader>mm", function()
    telescope.extensions.messages.messages({ cwd = vim.fn.getcwd() })
end, { desc = "Telescope messages" })

vim.keymap.set("n", "<leader>fw", function()
    builtin.live_grep({ default_text = vim.fn.expand("<cword>"), qflist = true })
end, { desc = "Telescope grep word under cursor" })

vim.keymap.set("v", "<leader>fs", function()
    local save_reg = vim.fn.getreg("v")
    vim.cmd('silent! normal! "vy')
    local text = vim.fn.getreg("v"):gsub("\n", " ")
    vim.fn.setreg("v", save_reg)
    builtin.live_grep({ default_text = text, qflist = true })
end, { desc = "Telescope grep visual selection" })

vim.keymap.set("n", "<leader>fb", builtin.buffers, { desc = "Telescope buffers" })
vim.keymap.set("n", "<leader>fp", builtin.pickers, { desc = "Telescope pickers" })
