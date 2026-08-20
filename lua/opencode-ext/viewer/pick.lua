-- /home/jmeyer/.config/nvim/lua/opencode-ext/viewer/pick.lua FINAL
-- Telescope session picker.
-- Extracted from viewer.lua to keep files small and changes safe.

local M = {}
local db = require("opencode-ext.db")
local model = require("opencode-ext.model")

function M.pick()
	local sessions, err = db.fetch_sessions()
	if not sessions then
		vim.notify(err or "No sessions", vim.log.levels.WARN)
		return
	end
	if #sessions == 0 then
		vim.notify("No opencode sessions found", vim.log.levels.WARN)
		return
	end

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	local function fmt_time(ts)
		if not ts then
			return "?"
		end
		local d = os.time() - ts
		if d < 60 then
			return "now"
		elseif d < 3600 then
			return math.floor(d / 60) .. "m"
		elseif d < 86400 then
			return math.floor(d / 3600) .. "h"
		elseif d < 604800 then
			return math.floor(d / 86400) .. "d"
		end
		return os.date("%b %d", ts)
	end

	pickers
		.new({}, {
			prompt_title = "Opencode Sessions",
			finder = finders.new_table({
				results = sessions,
				entry_maker = function(s)
					local title = (s.title or ""):gsub("\n", " "):sub(1, 60)
					if title == "" then
						title = "(untitled)"
					end
					local proj = s.project or ""
					local short = ""
					if proj ~= "" then
						local p = vim.split(proj, "/")
						short = #p >= 2 and p[#p - 1] .. "/" .. p[#p] or p[#p]
					end
					return {
						value = s,
						display = string.format(
							"%-60s %-28s %6s  %d msgs",
							title,
							short,
							fmt_time(s.time_updated),
							s.msg_count or 0
						),
						ordinal = title .. " " .. proj,
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					local s = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if s and s.value then
						local raw, err = db.fetch_session(s.value.id)
						if raw then
							local convs = model.build(raw)
							if #convs > 0 then
								local buf = require("opencode-ext.viewer.buffer")
								buf.open(convs[#convs], s.value.project or vim.fn.getcwd(), convs, #convs, raw)
							end
						else
							vim.notify(err or "Failed to load session", vim.log.levels.WARN)
						end
					end
				end)
				return true
			end,
		})
		:find()
end

return M
