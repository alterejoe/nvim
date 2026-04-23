vim.keymap.set("n", "<leader>hh", function()
	vim.cmd("edit!")
	print("Buffer reloaded")
end, { desc = "Reload buffer" })

vim.keymap.set("n", "<leader>nh", "<cmd>Noice history<CR>", { desc = "Notification history" })
