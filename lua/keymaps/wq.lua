-- ---------------------------------------------------------------------------
-- Buffer classification config
-- ---------------------------------------------------------------------------
local DELETE_BY_NAME = { output = true }
local DELETE_BY_FT = { ["kulala://ui"] = true }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

<<<<<<< HEAD
local function close_window()
	-- floating window: just close it
	if vim.api.nvim_win_get_config(0).relative ~= "" then
		vim.api.nvim_win_close(0, true)
		return
	end

	local non_floating = 0
=======
-- Count non-floating windows
local function non_floating_wins()
	local count = 0
>>>>>>> 4c7c28b3a7e28049ab3d8909b5035d15b8ed75e1
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_config(win).relative == "" then
			count = count + 1
		end
	end
<<<<<<< HEAD

	if non_floating <= 1 then
		-- last window: delete the buffer instead of quitting
		-- this lets your dashboard or empty state take over
		vim.cmd("bd!")
	else
		vim.cmd("close!")
	end
end

-- Returns one of: "terminal", "special", "normal", "other"
local function classify_buffer()
	local buftype = vim.bo.buftype
	local filetype = vim.bo.filetype
	local bufname = vim.fn.expand("%:t")

	if buftype == "terminal" then
		return "terminal"
	end
	if DELETE_BY_NAME[bufname] or DELETE_BY_FT[filetype] then
		return "special"
	end
	if filetype == "oil" or buftype == "acwrite" then
		return "special"
	end
	if buftype == "" then
		return "normal"
	end
	return "other"
=======
	return count
>>>>>>> 4c7c28b3a7e28049ab3d8909b5035d15b8ed75e1
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

<<<<<<< HEAD
	-- floating windows: always just close the window
	if vim.api.nvim_win_get_config(0).relative ~= "" then
		vim.api.nvim_win_close(0, true)
		return
	end

	if kind == "terminal" then
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-c>", true, true, true), "i", false)
		force_delete(buf)
	elseif kind == "special" then
		force_delete(buf)
	else
		close_window()
=======
	-- floating window: just close it
	if vim.api.nvim_win_get_config(0).relative ~= "" then
		vim.cmd("close!")
		return
>>>>>>> 4c7c28b3a7e28049ab3d8909b5035d15b8ed75e1
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
<<<<<<< HEAD
vim.keymap.set("n", "Q", function()
	local buf = vim.api.nvim_get_current_buf()
	local kind = classify_buffer()

	-- floating windows: always just close the window
	if vim.api.nvim_win_get_config(0).relative ~= "" then
		vim.api.nvim_win_close(0, true)
		return
	end

	-- count how many non-floating windows show this buffer
	local wins_with_buf = 0
	local non_floating = 0
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_config(win).relative == "" then
			non_floating = non_floating + 1
			if vim.api.nvim_win_get_buf(win) == buf then
				wins_with_buf = wins_with_buf + 1
			end
		end
	end

	-- multiple windows open: just close this pane regardless of buffer type
	if non_floating > 1 then
		vim.cmd("close!")
		return
	end

	-- last window standing
	if kind == "terminal" then
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-c>", true, true, true), "i", false)
		force_delete(buf)
	elseif kind == "special" then
		force_delete(buf)
	else
		if vim.fn.expand("%") == "" and not vim.bo.modified then
			vim.cmd("qa!")
		else
			vim.cmd("bd!")
		end
	end
end, { desc = "Smart window close" })
=======
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
>>>>>>> 4c7c28b3a7e28049ab3d8909b5035d15b8ed75e1
