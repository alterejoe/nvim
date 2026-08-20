-- /home/jmeyer/.config/nvim/lua/csvgen/init.lua FINAL
-- csvgen/init.lua — Entry point. Requires submodules, exposes public API.

local M = {}

M.config = {
	prefix = "<leader>s",
}

M.registered = {}
M.util = require("csvgen.util")

-- =========================================================================
-- Internal helpers
-- =========================================================================

local function resolve_lhs(spec)
	return spec.lhs or (M.config.prefix .. spec.key)
end

local function map(mode, lhs, fn, desc)
	vim.keymap.set(mode, lhs, fn, {
		desc = desc,
		noremap = true,
		silent = true,
	})
	M.registered[lhs] = M.registered[lhs] or { desc = desc, modes = {} }
	table.insert(M.registered[lhs].modes, mode)
end

local function make_formatter(spec)
	local fmt = spec.format
	if fmt == nil then
		fmt = "%d,%d"
	end
	if type(fmt) == "string" then
		local f = fmt
		return function(a, b)
			return string.format(f, a, b)
		end
	end
	return fmt
end

-- Attach registration functions (injecting dependencies)
require("csvgen.registration").attach(M, map, resolve_lhs, make_formatter)

-- =========================================================================
-- PUBLIC API
-- =========================================================================

function M.list()
	local keys = {}
	for lhs in pairs(M.registered) do
		table.insert(keys, lhs)
	end
	table.sort(keys)
	for _, lhs in ipairs(keys) do
		local r = M.registered[lhs]
		print(string.format("%-14s [%s]  %s", lhs, table.concat(r.modes, ","), r.desc))
	end
end

--- Auto-register builtins on require()
require("csvgen.builtins").register(M)

--- setup() — re-register with custom options
function M.setup(opts)
	opts = opts or {}
	if opts.prefix then
		M.config.prefix = opts.prefix
	end
	-- Clear and re-register everything
	M.registered = {}
	require("csvgen.builtins").register(M)

	for _, spec in ipairs(opts.mappings or {}) do
		M.register_mapping(spec)
	end
	for _, spec in ipairs(opts.pattern_generators or {}) do
		M.register_pattern_generator(spec)
	end
	for _, spec in ipairs(opts.transforms or {}) do
		M.register_transform(spec)
	end
	for _, spec in ipairs(opts.custom or {}) do
		M.register_custom(spec)
	end

	return M
end

return M
