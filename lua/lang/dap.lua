local M = {}

local function setup_adapters(dap)
	dap.adapters.dlv_spawn = function(callback)
		local stdout = vim.loop.new_pipe(false)
		local port = 38697
		local handle
		handle = vim.loop.spawn("dlv", {
			stdio = { nil, stdout },
			args = { "dap", "-l", "127.0.0.1:" .. port },
			detached = true,
		}, function(code)
			stdout:close()
			handle:close()
			if code ~= 0 then
				print("dlv exited with code", code)
			end
		end)
		assert(handle, "Error running dlv")
		stdout:read_start(function(err, chunk)
			assert(not err, err)
			if chunk then
				vim.schedule(function()
					require("dap.repl").append(chunk)
				end)
			end
		end)
		vim.defer_fn(function()
			callback({ type = "server", host = "127.0.0.1", port = port })
		end, 100)
	end

	dap.adapters.python = {
		type = "executable",
		command = "python",
		args = { "-m", "debugpy.adapter" },
	}

	dap.adapters.godot = {
		type = "server",
		host = "127.0.0.1",
		port = 6006,
	}

	dap.adapters.gdb = {
		type = "executable",
		command = "gdb",
		args = { "--interpreter=dap", "--eval-command", "set print pretty on", "--quiet" },
	}

	-- pwa-chrome adapter (for js/ts browser debugging via vscode-js-debug)
	dap.adapters["pwa-chrome"] = {
		type = "server",
		host = "localhost",
		port = "${port}",
		executable = {
			command = "node",
			args = {
				vim.fn.stdpath("data") .. "/mason/packages/js-debug-adapter/js-debug/src/dapDebugServer.js",
				"${port}",
			},
		},
	}
end

local function make_go_configs()
	local function get_test_names(filepath)
		local tests = {}
		for _, line in ipairs(vim.fn.readfile(filepath)) do
			local name = line:match("Test[%w_]+")
			if name then
				table.insert(tests, name)
			end
		end
		if #tests > 0 then
			return { "-test.v", "-test.run", "^(" .. table.concat(tests, "|") .. ")$" }
		end
		return { "-test.v" }
	end

	return {
		{
			type = "dlv_spawn",
			name = "Debug current cmd package",
			request = "launch",
			mode = "debug",
			program = function()
				local filepath = vim.fn.expand("%:p:h")
				return filepath:match("(.*cmd/[^/]+)") or (vim.fn.getcwd() .. "/cmd/")
			end,
			cwd = vim.fn.getcwd,
			args = { "-v" },
		},
		{
			type = "dlv_spawn",
			name = "Test current file",
			request = "launch",
			mode = "test",
			program = function()
				return vim.fn.expand("%:p:h")
			end,
			args = function()
				return get_test_names(vim.fn.expand("%:p"))
			end,
		},
		{
			type = "dlv_spawn",
			name = "Run from cwd",
			request = "launch",
			mode = "debug",
			program = function()
				return vim.fn.getcwd() .. "/"
			end,
			cwd = function()
				return vim.fn.expand("%:p:h")
			end,
		},
	}
end

local function make_chrome_configs(ft)
	return {
		{
			type = "pwa-chrome",
			request = "launch",
			name = "Launch Chrome (" .. ft .. ")",
			url = function()
				return vim.fn.input("URL: ", "http://localhost:3000")
			end,
			webRoot = "${workspaceFolder}",
			sourceMaps = true,
		},
		{
			type = "pwa-chrome",
			request = "attach",
			name = "Attach to Chrome (" .. ft .. ")",
			port = 9222,
			webRoot = "${workspaceFolder}",
			sourceMaps = true,
		},
	}
end

---@param languages table
function M.setup(languages)
	local ok, dap = pcall(require, "dap")
	if not ok then
		return
	end

	setup_adapters(dap)

	for _, config in pairs(languages) do
		local dap_cfg = config.dap
		if not dap_cfg then
			goto continue
		end

		local adapter = dap_cfg.adapter

		if adapter == "dlv_spawn" then
			dap.configurations.go = make_go_configs()
			dap.configurations.templ = {
				{
					type = "dlv_spawn",
					name = "Debug",
					request = "launch",
					mode = "debug",
					program = function()
						return vim.g.dap_path or "./cmd/"
					end,
					args = { "-v" },
				},
			}
		elseif adapter == "python" then
			local pypath = dap_cfg.python_path or "python"
			dap.configurations.python = {
				{
					type = "python",
					request = "launch",
					name = "Launch file",
					program = "${file}",
					pythonPath = function()
						return pypath
					end,
				},
				{
					type = "python",
					request = "launch",
					name = "Launch main.py",
					program = function()
						return vim.fn.getcwd() .. "/main.py"
					end,
					pythonPath = function()
						return pypath
					end,
				},
			}
		elseif adapter == "godot" then
			dap.configurations.gdscript = {
				{ type = "godot", request = "launch", name = "Launch scene", project = "${workspaceFolder}" },
			}
		elseif adapter == "pwa-chrome" then
			local ft = dap_cfg.type or "javascript"
			local configs = make_chrome_configs(ft)
			dap.configurations.javascript = configs
			dap.configurations.javascriptreact = configs
			dap.configurations.typescript = configs
			dap.configurations.typescriptreact = configs
		end

		::continue::
	end
end

return M
