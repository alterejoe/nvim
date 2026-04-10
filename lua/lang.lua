local M = {}

local function parse_yaml(path)
	local raw = vim.fn.system({ "yq", "-o=json", ".", path })
	if vim.v.shell_error ~= 0 then
		vim.notify("lang.lua: failed to parse " .. path, vim.log.levels.ERROR)
		return nil
	end
	local ok, result = pcall(vim.fn.json_decode, raw)
	if not ok then
		vim.notify("lang.lua: failed to decode json: " .. tostring(result), vim.log.levels.ERROR)
		return nil
	end
	return result
end

local function setup_lsp(name, config)
	local lsp_cfg = config.lsp
	if not lsp_cfg then
		return
	end

	local opts = {
		capabilities = vim.tbl_deep_extend(
			"force",
			vim.lsp.protocol.make_client_capabilities(),
			require("cmp_nvim_lsp").default_capabilities()
		),
	}

	if lsp_cfg.cmd then
		opts.cmd = lsp_cfg.cmd
	end
	if lsp_cfg.filetypes then
		opts.filetypes = lsp_cfg.filetypes
	end
	if lsp_cfg.settings then
		opts.settings = lsp_cfg.settings
	end

	vim.lsp.config(lsp_cfg.server, opts)
	vim.lsp.enable(lsp_cfg.server)

	-- handle additional servers under extras
	if config.extras and config.extras.additional_servers then
		for _, srv in ipairs(config.extras.additional_servers) do
			local extra_opts = {
				capabilities = opts.capabilities,
			}
			if srv.filetypes then
				extra_opts.filetypes = srv.filetypes
			end
			if srv.settings then
				extra_opts.settings = srv.settings
			end
			vim.lsp.config(srv.server, extra_opts)
			vim.lsp.enable(srv.server)
		end
	end
end

local function setup_filetype_register(extras)
	if not extras or not extras.filetype_register then
		return
	end
	local fr = extras.filetype_register
	vim.filetype.add({ extension = { [fr.extension] = fr.name } })
end

local function collect_grammars(languages)
	local grammars = {}
	for _, config in pairs(languages) do
		if config.treesitter then
			table.insert(grammars, config.treesitter)
		end
	end
	return grammars
end

local function collect_formatters(languages)
	local formatters_by_ft = {}
	for name, config in pairs(languages) do
		if config.formatter then
			if type(config.formatter) == "table" then
				formatters_by_ft[name] = config.formatter
			else
				formatters_by_ft[name] = { config.formatter }
			end
		end
	end
	return formatters_by_ft
end

local function collect_mason_packages(languages)
local packages = {}
for _, config in pairs(languages) do
if config.mason then
for _, pkg in ipairs(config.mason) do
table.insert(packages, pkg)
end
end
end
return packages
end

function M.setup()
	local config_path = vim.fn.stdpath("config") .. "/languages.yaml"
	local data = parse_yaml(config_path)
	if not data then
		return
	end
	local languages = data.languages

	-- Register filetypes first before anything else
	for _, config in pairs(languages) do
		setup_filetype_register(config.extras)
	end

	-- LSP
	for name, config in pairs(languages) do
		setup_lsp(name, config)
	end

	-- Treesitter
	require("nvim-treesitter").setup({
		install_dir = vim.fn.stdpath("data") .. "/site",
	})

    vim.api.nvim_create_autocmd("FileType", {
        callback = function()
            pcall(vim.treesitter.start)
        end,
    })

	-- Conform
	require("conform").setup({
		formatters_by_ft = collect_formatters(languages),
		format_on_save = function(bufnr)
			if vim.b[bufnr].disable_autoformat then
				return
			end
			return { timeout_ms = 500, lsp_format = "last" }
		end,
		log_level = vim.log.levels.ERROR,
		notify_on_error = true,
		notify_no_formatters = true,
	})
end

return M
