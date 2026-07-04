-- /home/jmeyer/.config/nvim/lua/keymaps/terminal.lua FINAL

-- Project root detection (same markers as autoroot.lua)
local patterns = { ".git", ".env", "Makefile", "go.mod", "go.work", "_config.lua", "config.lua" }

local function find_project_root(start_dir)
	local function search(cwd, depth)
		if depth > 10 or cwd == "/" or cwd == "" then
			return nil
		end
		local files = vim.fn.readdir(cwd)
		for _, pattern in ipairs(patterns) do
			for _, file in ipairs(files) do
				if file == pattern then
					return cwd
				end
			end
		end
		return search(vim.fn.fnamemodify(cwd, ":h"), depth + 1)
	end
	return search(start_dir, 0)
end

local function open_terminal(split_cmd, target_dir)
	target_dir = target_dir or vim.fn.getcwd()
	vim.cmd(split_cmd .. " | terminal")
	vim.cmd("startinsert")
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("cd " .. target_dir .. "<CR>", true, false, true), "n", true)
end

vim.keymap.set("n", "<leader>st", function()
	open_terminal("rightbelow vsplit")
end, { desc = "Terminal vertical split" })

vim.keymap.set("n", "<leader>sh", function()
	open_terminal("botright split")
end, { desc = "Terminal horizontal split" })

vim.keymap.set("n", "<leader>T", function()
	local file_path = vim.api.nvim_buf_get_name(0)
	local file_dir = vim.fn.fnamemodify(file_path, ":h"):gsub("^oil://", "")
	local root = find_project_root(file_dir)
	if root then
		open_terminal("rightbelow vsplit", root)
	else
		vim.notify("No project root found", vim.log.levels.WARN)
		open_terminal("rightbelow vsplit", file_dir)
	end
end, { desc = "Terminal at project root" })
