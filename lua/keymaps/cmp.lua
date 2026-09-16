local cmp_enabled = true

vim.keymap.set("n", "<leader>ct", function()
	cmp_enabled = not cmp_enabled
	require("cmp").setup.buffer({ enabled = cmp_enabled })
	vim.notify("cmp " .. (cmp_enabled and "enabled" or "disabled"), vim.log.levels.INFO)
end, { desc = "Toggle nvim-cmp" })
