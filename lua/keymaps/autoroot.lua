-- /home/jmeyer/.config/nvim/lua/keymaps/autoroot.lua FINAL

local patterns = { ".git", ".env", "Makefile", "go.mod", "go.work", "_config.lua", "config.lua" }

local function find_root(cwd, times, max)
	if cwd == "/" or cwd == "." then
		return
	end
	local files = vim.fn.readdir(cwd)
	for _, pattern in ipairs(patterns) do
		for _, file in ipairs(files) do
			if file == pattern then
				vim.fn.chdir(cwd)
				vim.notify("Root: " .. cwd)
				return
			end
		end
	end
	if times < max then
		find_root(vim.fn.fnamemodify(cwd, ":h"), times + 1, max)
	end
end

local function current_dir()
	local path = vim.api.nvim_buf_get_name(0)
	local dir = vim.fn.fnamemodify(path, ":h")
	return dir:gsub("^oil://", "")
end

-- CD to home
vim.keymap.set("n", "<leader>1", function()
	vim.fn.chdir("~")
	vim.notify("Changed directory to ~")
end, { noremap = true, silent = true, desc = "CD to ~" })

-- CD to project root
vim.keymap.set("n", "<leader>2", function()
	local dir = current_dir()
	vim.fn.chdir(dir)
	find_root(dir, 0, 10)
end, { noremap = true, silent = true, desc = "CD to project root" })

-- CD to current file's dir
vim.keymap.set("n", "<leader>3", function()
	local dir = current_dir()
	vim.fn.chdir(dir)
	vim.notify("Changed directory to " .. dir)
end, { noremap = true, silent = true, desc = "CD to file's dir" })

-- CD up one dir
vim.keymap.set("n", "<leader>4", function()
	local up = vim.fn.fnamemodify(vim.fn.getcwd(), ":h")
	up = up:gsub("^oil://", "")
	vim.fn.chdir(up)
	vim.notify("Changed directory to " .. up)
end, { noremap = true, silent = true, desc = "CD up one dir" })

-- CD to go.work root
vim.keymap.set("n", "<leader>5", function()
	local function find_gowork(cwd, depth)
		if depth > 10 or cwd == "/" or cwd == "" then
			vim.notify("No go.work found", vim.log.levels.WARN)
			return
		end
		for _, file in ipairs(vim.fn.readdir(cwd)) do
			if file == "go.work" then
				vim.fn.chdir(cwd)
				vim.notify("Root: " .. cwd)
				return
			end
		end
		find_gowork(vim.fn.fnamemodify(cwd, ":h"), depth + 1)
	end
	find_gowork(vim.fn.getcwd(), 0)
end, { noremap = true, silent = true, desc = "CD to go.work root" })

-- CD to tmux session root
vim.keymap.set("n", "<leader>6", function()
	if not vim.env.TMUX then
		vim.notify("Not in tmux", vim.log.levels.WARN)
		return
	end
	local path = vim.trim(vim.fn.system("tmux display-message -p '#{session_path}' 2>/dev/null"))
	if vim.v.shell_error ~= 0 or path == "" then
		vim.notify("Could not get tmux session path", vim.log.levels.WARN)
		return
	end
	vim.fn.chdir(path)
	vim.notify("Root: " .. path)
end, { noremap = true, silent = true, desc = "CD to tmux root" })
