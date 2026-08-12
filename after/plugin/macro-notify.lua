-- /home/altjoe/.config/nvim/after/plugin/macro-notify.lua
-- Macro recording status via vim.notify -> noice notify view.
-- Polls reg_recording() because RecordingLeave alone is unreliable
-- (it can miss stops from mappings/errors/aborts).

local timer = nil
local active = false

local function stop_timer()
	if timer then
		timer:stop()
		timer = nil
	end
end

local function show_stopped()
	if not active then
		return
	end
	active = false
	stop_timer()
	vim.notify("Recording stopped", vim.log.levels.INFO, { title = "Macro" })
end

vim.api.nvim_create_autocmd("RecordingEnter", {
	callback = function()
		local reg = vim.fn.reg_recording()
		active = true
		stop_timer()
		vim.notify("Recording @" .. reg, vim.log.levels.INFO, { title = "Macro" })
		timer = vim.uv.new_timer()
		timer:start(250, 250, function()
			vim.schedule(function()
				if active and vim.fn.reg_recording() == "" then
					show_stopped()
				end
			end)
		end)
	end,
})

-- Fast path when the leave event does fire; the poll catches the rest.
vim.api.nvim_create_autocmd("RecordingLeave", {
	callback = function()
		vim.schedule(show_stopped)
	end,
})
