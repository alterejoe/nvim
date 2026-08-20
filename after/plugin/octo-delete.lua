-- /home/jmeyer/.config/nvim/after/plugin/octo-delete.lua FINAL
local api = vim.api

function OctoDeleteIssue()
	local bufname = api.nvim_buf_get_name(0)
	local number, owner, repo

	number = bufname:match(":(%d+)$")
	owner = bufname:match("gh:([%w-]+)/")
	repo = bufname:match("gh:[%w-]+/([%w-.-]+)")

	if not number then
		local lines = api.nvim_buf_get_lines(0, 0, 100, false)
		for _, line in ipairs(lines) do
			local url = line:match("https://github%.com/([%w-]+)/([%w-.-]+)/issues/(%d+)")
				or line:match("https://github%.com/([%w-]+)/([%w-.-]+)/pull/(%d+)")
			if url then
				owner, repo, number = url:match("https://github%.com/([%w-]+)/([%w-.-]+)/(%w+)/(%d+)")
				break
			end
		end
	end

	if not (number and owner and repo) then
		vim.ui.input({ prompt = "Issue number: " }, function(n)
			if not n or n == "" then
				return
			end
			vim.ui.input({ prompt = "Owner (e.g. Glass6444): " }, function(o)
				if not o or o == "" then
					return
				end
				vim.ui.input({ prompt = "Repo (e.g. portal-adminserver): " }, function(r)
					if not r or r == "" then
						return
					end
					confirm_and_delete(n, o, r)
				end)
			end)
		end)
		return
	end

	confirm_and_delete(number, owner, repo)
end

function confirm_and_delete(number, owner, repo)
	vim.ui.input(
		{ prompt = string.format("Type 'confirm' to delete issue #%s from %s/%s: ", number, owner, repo) },
		function(input)
			if input ~= "confirm" then
				vim.notify("Cancelled", vim.log.levels.INFO)
				return
			end

			local cmd = string.format("gh issue delete %s -R %s/%s 2>&1", number, owner, repo)
			local handle = io.popen(cmd)
			local result = handle and handle:read("*a") or "error"
			if handle then
				handle:close()
			end

			if result == "" or result:match("Deleted issue") then
				vim.notify("Issue #" .. number .. " deleted", vim.log.levels.INFO)
				vim.cmd("bdelete!")
			else
				vim.notify("Delete failed: " .. result, vim.log.levels.ERROR)
			end
		end
	)
end

api.nvim_create_user_command("OctoIssueDelete", OctoDeleteIssue, {})
