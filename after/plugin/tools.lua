vim.keymap.set("n", "<leader>gg", "<cmd>LazyGit<cr>", { desc = "LazyGit" })

local bqf = require("bqf")

bqf.setup({ ft = "qf" })

vim.keymap.set("n", "<leader>z", function()
	if vim.wo.foldmethod == "manual" or vim.wo.foldmethod == "" then
		vim.wo.foldmethod = "indent"
		vim.wo.foldlevel = 99
	end
	vim.cmd("normal! za")
end, { desc = "Toggle fold (auto-enable)" })

vim.keymap.set("n", "Z", function()
	vim.wo.foldmethod = "indent"
	vim.wo.foldlevel = 99
	vim.cmd("normal! zR")
end, { desc = "Open all folds" })

vim.keymap.set("n", "C", function()
	vim.wo.foldmethod = "indent"
	vim.wo.foldlevel = 0
	vim.cmd("normal! zM")
end, { desc = "Close all folds" })
