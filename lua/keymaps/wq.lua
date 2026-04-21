-- ---------------------------------------------------------------------------
-- Buffer classification config
-- ---------------------------------------------------------------------------
local DELETE_BY_NAME = { output = true }
local DELETE_BY_FT = { ["kulala://ui"] = true }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Count non-floating windows
local function non_floating_wins()
	local count = 0
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_config(win).relative == "" then
			count = count + 1
		end
	end
	return count
end

-- ---------------------------------------------------------------------------
-- Escape mappings
-- ---------------------------------------------------------------------------
vim.keymap.set("i", "jk", "<Esc>", { noremap = true, silent = true, desc = "Escape insert mode" })
vim.keymap.set("v", "nm", "<Esc>", { noremap = true, silent = true, desc = "Escape visual mode" })
vim.keymap.set("c", "jk", "<C-c>", { noremap = true, silent = true, desc = "Escape cmdline" })

vim.api.nvim_create_autocmd("TermOpen", {
	pattern = "*",
	callback = function()
		local bufname = vim.fn.bufname()
		if string.find(bufname, "lazygit") then
			vim.keymap.set(
				"t",
				"nm",
				"<C-\\><C-n>",
				{ buffer = true, noremap = true, silent = true, desc = "Escape lazygit" }
			)
		else
			vim.keymap.set(
				"t",
				"jk",
				"<C-\\><C-n>",
				{ buffer = true, noremap = true, silent = true, desc = "Escape terminal" }
			)
		end
	end,
})

-- ---------------------------------------------------------------------------
-- Q: close the current window. period.
-- ---------------------------------------------------------------------------
vim.keymap.set("n", "Q", function()
	local buf = vim.api.nvim_get_current_buf()
	local ft = vim.bo[buf].filetype
	local bt = vim.bo[buf].buftype
	local bufname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")

	-- floating window: just close it
	if vim.api.nvim_win_get_config(0).relative ~= "" then
		vim.cmd("close!")
		return
	end

	-- oil: use its own close so it restores the parent buffer
	if ft == "oil" then
		require("oil").close()
		return
	end

	-- last non-floating window: quit neovim
	if non_floating_wins() <= 1 then
		vim.cmd("qa!")
		return
	end

	-- terminal: kill the buffer (closing the window alone leaves a dead term)
	if bt == "terminal" then
		vim.api.nvim_buf_delete(buf, { force = true })
		return
	end

	-- disposable buffers: kill them so they don't linger
	if DELETE_BY_NAME[bufname] or DELETE_BY_FT[ft] or vim.b[buf]._scratchbuf then
		vim.api.nvim_buf_delete(buf, { force = true })
		return
	end

	-- everything else: close the window, leave the buffer alive
	vim.cmd("close!")
end, { desc = "Close window" })

-- ---------------------------------------------------------------------------
-- W: force save (silent on success, loud on failure)
-- ---------------------------------------------------------------------------
vim.keymap.set("n", "W", function()
	local buf = vim.api.nvim_get_current_buf()
	local bt = vim.bo[buf].buftype

	if bt == "" then
		local ok, err = pcall(vim.cmd, "write!")
		if not ok then
			vim.notify(err, vim.log.levels.ERROR)
		end
	elseif bt == "acwrite" then
		local ok, err = pcall(vim.cmd, "write")
		if not ok then
			vim.notify(err, vim.log.levels.ERROR)
		end
	end
end, { desc = "Force save" })
