-- Modern color scheme with better visibility
local hl_active = {
	cwd = { fg = "#1e293b", bg = "#93c5fd", style = "bold" },
	root = { fg = "#1e293b", bg = "#c4b5fd", style = "NONE" },
	file = { fg = "#1e293b", bg = "#6ee7b7", style = "bold" },
	gowork = { fg = "#1e293b", bg = "#fde047", style = "NONE" },
}
local hl_inactive = {
	cwd = { fg = "#6b7280", bg = "#374151" },
	root = { fg = "#6b7280", bg = "#374151" },
	file = { fg = "#6b7280", bg = "#374151" },
	gowork = { fg = "#6b7280", bg = "#374151" },
}
local function hl_pick(a, b)
	local this = vim.fn.win_getid()
	local active = vim.api.nvim_get_current_win()
	return (this == active) and a or b
end
-- Find "project root" for the *open buffer*
-- Rule: nearest parent containing `cmd/` or `config.lua`
local function find_buffer_root(filepath, is_directory)
	local dir = is_directory and filepath or vim.fn.fnamemodify(filepath, ":h")
	while dir ~= "/" do
		-- Preferred patterns
		if vim.fn.isdirectory(dir .. "/cmd") == 1 then
			return dir
		end
		if vim.fn.filereadable(dir .. "/config.lua") == 1 then
			return dir
		end
		-- Fallback: .git/
		if vim.fn.isdirectory(dir .. "/.git") == 1 then
			return dir
		end
		local parent = vim.fn.fnamemodify(dir, ":h")
		if parent == dir then
			break
		end
		dir = parent
	end
	return nil
end
-- Find go.work root
local function find_go_work_root(start)
	local dir = start
	while dir ~= "/" do
		if vim.fn.filereadable(dir .. "/go.work") == 1 then
			return dir
		end
		local parent = vim.fn.fnamemodify(dir, ":h")
		if parent == dir then
			break
		end
		dir = parent
	end
	return nil
end
-- Modern separators with icons
local sep_style = {
	left = " ",
	right = " ",
}
-- Components used for BOTH active + inactive
local left_components = {
	-- 1. CWD - just the folder name
	{
		provider = function()
			return " 󰉋 " .. vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
		end,
		hl = function()
			return hl_pick(hl_active.cwd, hl_inactive.cwd)
		end,
		left_sep = sep_style.left,
		right_sep = sep_style.right,
	},
	-- 2. Path from CWD to buffer's project root
	{
		provider = function()
			local buf_path
			if vim.bo.filetype == "oil" then
				buf_path = vim.fn.expand("%"):gsub("^oil://", "")
			else
				buf_path = vim.fn.expand("%:p")
			end
			if buf_path == "" or buf_path == "about:blank" then
				return ""
			end
			local is_oil = vim.bo.filetype == "oil"
			local root = find_buffer_root(buf_path, is_oil)
			if not root then
				return ""
			end
			local cwd = vim.fn.getcwd()
			cwd = cwd:gsub("/$", "")
			root = root:gsub("/$", "")
			local result
			if vim.startswith(root, cwd .. "/") then
				result = root:sub(#cwd + 2)
			elseif root == cwd then
				result = "."
			else
				result = vim.fn.fnamemodify(root, ":t")
			end
			return result ~= "" and ("  " .. result) or ""
		end,
		hl = function()
			return hl_pick(hl_active.root, hl_inactive.root)
		end,
		left_sep = sep_style.left,
		right_sep = sep_style.right,
	},
	-- 3. Current file
	{
		provider = function()
			local filename
			if vim.bo.filetype == "oil" then
				filename = vim.fn.fnamemodify(vim.fn.expand("%:p:h"), ":t")
			else
				filename = vim.fn.expand("%:t")
			end
			return filename ~= "" and ("  " .. filename) or ""
		end,
		hl = function()
			return hl_pick(hl_active.file, hl_inactive.file)
		end,
		left_sep = sep_style.left,
		right_sep = sep_style.right,
	},
}
local right_components = {
	-- 4. Go.work root
	{
		provider = function()
			local root = find_go_work_root(vim.fn.getcwd())
			return root and (" 󰟓 " .. vim.fn.fnamemodify(root, ":t") .. " ") or ""
		end,
		hl = function()
			return hl_pick(hl_active.gowork, hl_inactive.gowork)
		end,
		left_sep = sep_style.left,
		right_sep = sep_style.right,
	},
}
require("feline").setup({
	components = {
		active = { left_components, {}, right_components },
		inactive = { left_components, {}, right_components },
	},
	force_inactive = {
		filetypes = {},
		buftypes = {},
		bufnames = {},
	},
})
