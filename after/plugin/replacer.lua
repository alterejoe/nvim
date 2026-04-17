function StandardReplacer()
	local opts = { save_on_write = false, rename_files = true }
	local replacer = require("replacer")
	return opts, replacer
end
local opts, replacer = StandardReplacer()
vim.keymap.set("n", "i", function()
	if vim.bo.buftype == "quickfix" then
		local qflist = vim.fn.getqflist()
		if #qflist == 0 then
			vim.notify("Quickfix list is empty", vim.log.levels.WARN)
			return
		end
		replacer.run(opts)
	else
		vim.cmd("startinsert")
	end
end, { silent = true })
vim.keymap.set("n", "<leader>R", function()
	replacer.save(opts)
end, { silent = true })
