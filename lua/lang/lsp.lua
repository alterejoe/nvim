local M = {}

local function get_capabilities()
	-- Start with Neovim's default capabilities
	local caps = vim.lsp.protocol.make_client_capabilities()

	-- Merge blink.cmp capabilities if blink is loaded
	-- This is safe to call after blink initializes (lazy loading)
	local ok, blink = pcall(require, "blink.cmp")
	if ok and blink.get_lsp_capabilities then
		caps = vim.tbl_deep_extend("force", caps, blink.get_lsp_capabilities())
	end

	return caps
end

local function enable_server(server, opts)
	vim.lsp.config(server, opts)
	vim.lsp.enable(server)
end

local function base_opts(lsp_cfg)
	local opts = {
		capabilities = get_capabilities(),
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
	return opts
end

---@param languages table
function M.setup(languages)
	for _, config in pairs(languages) do
		local lsp_cfg = config.lsp
		if not lsp_cfg then
			goto continue
		end
		local opts = base_opts(lsp_cfg)
		enable_server(lsp_cfg.server, opts)
		-- additional servers declared under extras
		local additional = config.extras and config.extras.additional_servers
		if additional then
			for _, srv in ipairs(additional) do
				local extra = { capabilities = opts.capabilities }
				if srv.filetypes then
					extra.filetypes = srv.filetypes
				end
				if srv.settings then
					extra.settings = srv.settings
				end
				enable_server(srv.server, extra)
			end
		end
		::continue::
	end
end

return M
