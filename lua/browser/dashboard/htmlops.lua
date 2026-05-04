-- browser/dashboard/htmlops.lua
-- HTML source panel: open, body/head toggle, UUID jump.

local M = {}

local util = require("browser.dashboard.util")

local UUID_PATTERN = [[\v[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}]]

local function send_cmd(cmd)
	return require("browser.session").send_cmd(cmd)
end

-- ============================================================
-- open_html
-- Fetches the body innerHTML for meta.tab_id, formats it, and
-- loads it into buf. Updates html panel state.
-- ============================================================
function M.open_html(meta, buf, state)
	local body = send_cmd("page-source-body " .. meta.tab_id)
	if not body or vim.startswith(body, "err:") then
		vim.notify("browser: " .. (body or "no response"), vim.log.levels.WARN)
		return
	end
	local html_lines = vim.split(util.format_html(body), "\n", { plain = true })
	state.html_body_lines = html_lines
	state.html_full_lines = nil
	state.html_show_full = false
	state.html_source_meta = meta
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, html_lines)
	vim.bo[buf].filetype = "html"
	vim.bo[buf].modifiable = false
	vim.bo[buf].modified = false
	state.view_mode = "html"
	vim.notify("browser: html body - b=head  U=uuid  A=+pat  ?=patterns  H/r/<C-o>=back")
end

-- ============================================================
-- toggle_body_head
-- Toggles the primary pane between body innerHTML and the full
-- page source. Fetches full source on first toggle.
-- ============================================================
function M.toggle_body_head(buf, state)
	local lines
	if state.html_show_full then
		state.html_show_full = false
		lines = state.html_body_lines or { "-- no body --" }
		vim.notify("browser: html body view")
	else
		if not state.html_full_lines and state.html_source_meta then
			local full = send_cmd("page-source " .. state.html_source_meta.tab_id)
			if full and not vim.startswith(full, "err:") then
				state.html_full_lines = vim.split(util.format_html(full), "\n", { plain = true })
			end
		end
		state.html_show_full = true
		lines = state.html_full_lines or { "-- no full html --" }
		vim.notify("browser: html full page - b=back to body")
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].modified = false
end

-- ============================================================
-- next_uuid
-- Jumps to the next UUID match in the current buffer.
-- ============================================================
function M.next_uuid()
	local found = vim.fn.search(UUID_PATTERN, "w")
	if found == 0 then
		vim.notify("browser: no UUID found", vim.log.levels.INFO)
	end
end

return M
