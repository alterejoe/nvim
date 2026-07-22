-- /home/jmeyer/.config/nvim/lua/tmux_projects/init.lua FINAL
--[[
Entry point for the tmux session management system.
Splits the original 1377-line tmux_projects.lua into focused modules.

State files:
  tmux_session_slots        — session order
  tmux_active_project       — active project name
  tmux_project_overrides.json — edited project groups
--]]

local state = require("tmux_projects.state")
local M = {}

M.projects = {}
M.default = {}
M.nvim = false
M.project_order = {}

-- -----------------------------------------------------------------------
-- Persistence
-- -----------------------------------------------------------------------

local order_file = vim.fn.stdpath("data") .. "/tmux_session_slots"
local active_project_file = vim.fn.stdpath("data") .. "/tmux_active_project"
local overrides_file = vim.fn.stdpath("data") .. "/tmux_project_overrides.json"
local show_hidden = false

function M.load_order()
	local f = io.open(order_file, "r")
	if not f then
		return {}
	end
	local slots = {}
	for line in f:lines() do
		local t = vim.trim(line)
		if t ~= "" then
			table.insert(slots, t)
		end
	end
	f:close()
	return slots
end

function M.save_order(slots)
	local f = io.open(order_file, "w")
	if not f then
		vim.notify("tmux: could not write " .. order_file, vim.log.levels.ERROR)
		return
	end
	for _, s in ipairs(slots) do
		f:write(s .. "\n")
	end
	f:close()
end

function M.load_overrides()
	local f = io.open(overrides_file, "r")
	if not f then
		return {}
	end
	local raw = f:read("*a")
	f:close()
	if not raw or raw == "" then
		return {}
	end
	local ok, data = pcall(vim.fn.json_decode, raw)
	if not ok or type(data) ~= "table" then
		return {}
	end
	return data
end

function M.save_overrides()
	local data = {}
	for group, entries in pairs(M.projects) do
		data[group] = entries
	end
	local f = io.open(overrides_file, "w")
	if not f then
		vim.notify("tmux: could not write overrides", vim.log.levels.ERROR)
		return
	end
	f:write(vim.fn.json_encode(data))
	f:close()
end

function M.merge_overrides()
	local overrides = M.load_overrides()
	for group, entries in pairs(overrides) do
		M.projects[group] = entries
	end
	local in_order = {}
	for _, g in ipairs(M.project_order) do
		in_order[g] = true
	end
	for group in pairs(overrides) do
		if not in_order[group] then
			table.insert(M.project_order, group)
		end
	end
end

function M.get_show_hidden()
	return show_hidden
end

function M.set_show_hidden(v)
	show_hidden = v
end

-- -----------------------------------------------------------------------
-- Active project
-- -----------------------------------------------------------------------

function M.get_active_project()
	local f = io.open(active_project_file, "r")
	if not f then
		return nil
	end
	local name = vim.trim(f:read("*a"))
	f:close()
	return name ~= "" and name or nil
end

function M.set_active_project(name)
	local f = io.open(active_project_file, "w")
	if not f then
		return
	end
	f:write(name)
	f:close()
end

-- -----------------------------------------------------------------------
-- Setup
-- -----------------------------------------------------------------------

function M.setup(opts)
	M.projects = opts.projects or {}
	M.default = opts.default or {}
	M.nvim = opts.nvim or false
	M.project_order = opts.project_order or vim.tbl_keys(M.projects)
	M.merge_overrides()
end

require("tmux_projects.projects").setup(M)
require("tmux_projects.sessions").setup(M)
require("tmux_projects.groups").setup(M)

return M
