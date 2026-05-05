-- browser/dashboard/httpops/curl.lua
--
-- curl_preview: fires curl -siL against the request described by the
-- first context section in the http buffer, and pipes a stripped
-- response (headers only, no body) into the HTTP Preview pane.
--
-- The preview reverses the order of redirect-chain blocks so the final
-- response appears first, matching how a developer wants to read
-- "what did the server actually return?" before the redirects.

local M = {}

local parse = require("browser.dashboard.httpops.parse")

function M.curl_preview(state)
	local buf = state.primary_buf
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	if not (state.http_tab_meta and state.http_chi_path) then
		vim.notify("browser: no active http context", vim.log.levels.WARN)
		return
	end

	local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local sections = parse.parse_buffer(all_lines)
	local first = sections[1]
	if not first then
		vim.notify("browser: no context section", vim.log.levels.WARN)
		return
	end

	local views = require("browser.views")
	local base = views.get_active_base()
	local resolved = (first.path and first.path ~= "") and first.path or views.resolve_path(state.http_chi_path)

	-- Build query string from the section's params block.
	local q_map = {}
	for _, kv in ipairs(first.params) do
		if kv.key ~= "" then
			q_map[kv.key] = kv.val
		end
	end
	local qp = views.build_query_string(q_map)
	local full_url = base .. resolved .. qp

	-- HX-Request headers when the active tab is in htmx mode, so the
	-- server returns the partial fragment we'd actually navigate to.
	local hx_flag = state.http_tab_meta.htmx and (" -H 'HX-Request: true' -H 'HX-Current-URL: " .. full_url .. "'")
		or ""

	-- Reuse the dev session cookies if present so authenticated routes
	-- return the real response shape, not a redirect to /login.
	local cookie_file = require("browser.session").DEVPROXY_DIR .. "/cookies.txt"
	local cookie_flag = vim.fn.filereadable(cookie_file) == 1 and (" -b " .. vim.fn.shellescape(cookie_file)) or ""

	vim.notify("browser: GET " .. resolved .. qp)

	vim.fn.jobstart("curl -siL" .. hx_flag .. cookie_flag .. " " .. vim.fn.shellescape(full_url), {
		stdout_buffered = true,
		on_stdout = function(_, data)
			if not data then
				return
			end
			local all = {}
			for _, l in ipairs(data) do
				if l ~= nil then
					table.insert(all, (tostring(l):gsub("\r", "")))
				end
			end
			if #all == 0 then
				return
			end

			-- Split the curl output into per-response blocks (for redirect
			-- chains, curl emits multiple "HTTP/..." headers in sequence).
			local blocks, current = {}, {}
			for _, l in ipairs(all) do
				if l:match("^HTTP/") and #current > 0 then
					table.insert(blocks, current)
					current = {}
				end
				table.insert(current, l)
			end
			if #current > 0 then
				table.insert(blocks, current)
			end

			-- Reverse the block order so the final response leads, and
			-- drop the body (everything after the first blank line).
			local out = {}
			for i = #blocks, 1, -1 do
				local block = blocks[i]
				local in_body = false
				for _, l in ipairs(block) do
					if in_body then
						-- HTML body content is dropped.
					elseif l == "" then
						in_body = true
						table.insert(out, l)
					else
						table.insert(out, l)
					end
				end
				if i > 1 then
					table.insert(out, "")
				end
			end

			vim.schedule(function()
				if state.layout then
					state.layout.set(require("browser.dashboard.util").PREVIEW_TITLE, out)
				end
			end)
		end,
	})
end

return M
