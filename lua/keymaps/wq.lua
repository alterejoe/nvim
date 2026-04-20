-- ---------------------------------------------------------------------------
-- Buffer classification config
-- ---------------------------------------------------------------------------
local DELETE_BY_NAME = { output = true }
local DELETE_BY_FT = { ["kulala://ui"] = true }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function force_delete(buf)
	vim.api.nvim_buf_delete(buf, { force = true })
end

local function close_window()
	-- If we're in a floating window, just close it
	if vim.api.nvim_win_get_config(0).relative ~= "" then
		vim.cmd("q!")
		return
	end

	local non_floating = 0
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_config(win).relative == "" then
			non_floating = non_floating + 1
		end
	end

	if non_floating <= 1 then
		vim.cmd("qa!")
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
-- Q: smart close
-- ---------------------------------------------------------------------------
vim.keymap.set("n", "Q", function()
	local buf = vim.api.nvim_get_current_buf()
	local kind = classify_buffer()

	if kind == "terminal" then
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-c>", true, true, true), "i", false)
		force_delete(buf)
	elseif kind == "special" then
		force_delete(buf)
	else
		-- normal and other: close the window
		close_window()
	end
end, { desc = "Smart window close" })

-- ---------------------------------------------------------------------------
-- W: force save (silent on success, loud on failure)
-- ---------------------------------------------------------------------------
vim.keymap.set("n", "W", function()
	local kind = classify_buffer()

	if kind == "normal" then
		local ok, err = pcall(vim.cmd, "write!")
		if not ok then
			vim.notify(err, vim.log.levels.ERROR)
		end
	elseif kind == "special" then
		-- acwrite buffers (oil) use plain :write to trigger their save handler
		local ok, err = pcall(vim.cmd, "write")
		if not ok then
			vim.notify(err, vim.log.levels.ERROR)
		end
	end
	-- terminal/other: silently do nothing
end, { desc = "Force save" })
