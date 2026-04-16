vim.keymap.set("n", "<leader>wo", function()
	local path = vim.fn.expand("%:p")
	if path:match("^oil://") then
		path = path:gsub("^oil://", "")
	end
	local is_dir = vim.fn.isdirectory(path) == 1
	-- Use wslpath to convert any Linux path to Windows path
	local win_path = vim.fn.system("wslpath -w '" .. path .. "'"):gsub("\n", "")
	vim.notify("opening: " .. win_path)
	if is_dir then
		vim.fn.system({ "explorer.exe", win_path })
	else
		vim.fn.system({ "explorer.exe", "/select,", win_path })
	end
end, { desc = "Open in Windows Explorer" })
