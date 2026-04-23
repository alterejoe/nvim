local keymap_dir = vim.fn.stdpath("config") .. "/lua/keymaps"
local errors = {}

vim.notify("wq loaded: " .. tostring(package.loaded["keymaps.wq"] ~= nil), vim.log.levels.INFO)
local function load_dir(dir)
	local handle = vim.uv.fs_opendir(dir, nil, 100)
	if not handle then
		return
	end
	local entries = vim.uv.fs_readdir(handle)
	vim.uv.fs_closedir(handle)
	if not entries then
		return
	end

	for _, entry in ipairs(entries) do
		local path = dir .. "/" .. entry.name
		if entry.type == "directory" then
			load_dir(path)
		elseif entry.type == "file" and entry.name:match("%.lua$") and entry.name ~= "init.lua" then
			local module = path:gsub(vim.fn.stdpath("config") .. "/lua/", ""):gsub("/", "."):gsub("%.lua$", "")
			vim.notify("Loading: " .. module, vim.log.levels.INFO) -- ADD THIS
			local ok, err = pcall(require, module)
			if not ok then
				table.insert(errors, module .. ": " .. err)
			end
		end
	end
end

load_dir(keymap_dir)

if #errors > 0 then
	vim.notify("Keymap errors:\n" .. table.concat(errors, "\n"), vim.log.levels.ERROR)
end
