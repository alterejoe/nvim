local function force_delete(buf)
	vim.api.nvim_buf_delete(buf, { force = true })
end

vim.keymap.set("i", "jk", "<Esc>", { noremap = true, silent = true, desc = "Escape insert mode" })
vim.keymap.set("v", "nm", "<Esc>", { noremap = true, silent = true, desc = "Escape visual mode" })
vim.keymap.set("t", "jk", "<C-\\><C-n>", { noremap = true, silent = true, desc = "Escape terminal mode" })
vim.keymap.set("c", "jk", "<C-c>", { noremap = true, silent = true, desc = "Escape cmdline" })

vim.keymap.set("n", "Q", function()
	local buf = vim.api.nvim_get_current_buf()
	local buftype = vim.bo.buftype
	local bufname = vim.fn.expand("%:t")
	local filetype = vim.bo.filetype
	-- Special named buffers to force delete
	local delete_by_name = { output = true }
	local delete_by_ft = { ["kulala://ui"] = true }
	if delete_by_name[bufname] or delete_by_ft[filetype] then
		return force_delete(buf)
	end
	-- Terminal: send Ctrl-C then close
	if buftype == "terminal" then
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-c>", true, true, true), "i", false)
		return force_delete(buf)
	end
	-- Oil and other special buffers: force delete
	if buftype == "acwrite" or filetype == "oil" then
		return force_delete(buf)
	end
	-- Normal buffers: close without saving
	if buftype == "" then
		vim.cmd("q!")
		return
	end
	-- Fallback: just close
	vim.cmd("q!")
end, { desc = "Smart buffer close" })

vim.keymap.set("n", "W", function()
	local buftype = vim.bo.buftype
	if buftype == "" or buftype == "acwrite" then
		vim.cmd("w!")
	end
end, { desc = "Force save" })
