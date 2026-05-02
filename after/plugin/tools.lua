vim.keymap.set("n", "<leader>gg", "<cmd>LazyGit<cr>", { desc = "LazyGit" })

local bqf = require("bqf")

bqf.setup({ ft = "qf" })
