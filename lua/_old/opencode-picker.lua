-- opencode-picker.lua
-- Telescope picker for code blocks from OpenCode session exports.
--
-- Keymaps:
--   <leader>ay  Pick code block from exports
--                <CR>   = yank code + open telescope file search
--                <C-p>  = yank filepath only
--   <leader>ae  Toggle vsplit of last picked export, jumped to the block

local M = {}
local last_picked = { file = nil, line = nil }

vim.keymap.set("n", "<leader>ay", function()
	local cwd = vim.fn.getcwd()
	local tmp_dir = cwd .. "/.opencode/tmp"
	vim.fn.mkdir(tmp_dir, "p")

	-- Move any session exports from cwd to tmp
	local cwd_exports = vim.fn.glob(cwd .. "/session-ses_*.md", false, true)
	for _, f in ipairs(cwd_exports) do
		vim.fn.rename(f, tmp_dir .. "/" .. vim.fn.fnamemodify(f, ":t"))
	end

	-- Gather all exports from tmp
	local files = vim.fn.glob(tmp_dir .. "/session-ses_*.md", false, true)
	if #files == 0 then
		vim.notify("No exports found - run /export in opencode first", vim.log.levels.WARN)
		return
	end

	table.sort(files, function(a, b)
		return vim.fn.getftime(a) > vim.fn.getftime(b)
	end)

	local function first_meaningful(lines)
		for _, l in ipairs(lines) do
			local t = vim.trim(l)
			if
				t ~= ""
				and not t:match("^//")
				and not t:match("^#")
				and not t:match("^%-%-")
				and not t:match("^/%*")
				and not t:match("^%*")
			then
				return t:sub(1, 60)
			end
		end
		return (lines[1] or ""):sub(1, 60)
	end

	local function find_filepath(context_lines)
		for i = #context_lines, 1, -1 do
			local line = context_lines[i]
			local fp = line:match("([%w_%-/%.]+%.%w+)")
			if
				fp
				and (
					fp:match("%.go$")
					or fp:match("%.templ$")
					or fp:match("%.js$")
					or fp:match("%.ts$")
					or fp:match("%.sql$")
					or fp:match("%.py$")
					or fp:match("%.md$")
					or fp:match("%.yaml$")
					or fp:match("%.json$")
					or fp:match("%.lua$")
					or fp:match("%.css$")
					or fp:match("%.html$")
				)
			then
				return fp
			end
		end
		return nil
	end

	local all_blocks = {}

	for _, filepath in ipairs(files) do
		local file_lines = vim.fn.readfile(filepath)
		local in_block = false
		local block_lines = {}
		local block_lang = ""
		local block_start_idx = 0

		for idx, line in ipairs(file_lines) do
			if not in_block and line:match("^```(%w+)") then
				in_block = true
				block_lang = line:match("^```(%w+)")
				block_lines = {}
				block_start_idx = idx
			elseif not in_block and line:match("^```$") then
				in_block = true
				block_lang = "txt"
				block_lines = {}
				block_start_idx = idx
			elseif in_block and line:match("^```$") then
				in_block = false
				if #block_lines > 0 then
					local content = table.concat(block_lines, "\n")
					local meaningful = first_meaningful(block_lines)

					local context_start = math.max(1, block_start_idx - 15)
					local context = {}
					for i = context_start, block_start_idx - 1 do
						table.insert(context, file_lines[i])
					end

					local fp = find_filepath(context)
					local fp_display = fp and fp:sub(1, 40) or ""

					table.insert(all_blocks, {
						lang = block_lang,
						content = content,
						context = context,
						line_count = #block_lines,
						filepath_hint = fp,
						source_file = filepath,
						source_line = block_start_idx,
						text = string.format(
							"%-5s³ %3dL ³ %-40s³ %s",
							block_lang,
							#block_lines,
							fp_display,
							meaningful
						),
					})
				end
			elseif in_block then
				table.insert(block_lines, line)
			end
		end
	end

	if #all_blocks == 0 then
		vim.notify("No code blocks found in exports", vim.log.levels.WARN)
		return
	end

	-- Reverse so newest blocks appear first
	local reversed = {}
	for i = #all_blocks, 1, -1 do
		table.insert(reversed, all_blocks[i])
	end

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local previewers = require("telescope.previewers")

	pickers
		.new({}, {
			prompt_title = "Opencode Code Blocks  <CR>=yank+find  <C-p>=yank path",
			finder = finders.new_table({
				results = reversed,
				entry_maker = function(item)
					return {
						value = item,
						display = item.text,
						ordinal = item.text .. " " .. item.content .. " " .. (item.filepath_hint or ""),
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = previewers.new_buffer_previewer({
				define_preview = function(self, entry)
					local item = entry.value
					local preview = {}

					if #item.context > 0 then
						table.insert(
							preview,
							"ÄÄ Context ÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄ"
						)
						for _, cl in ipairs(item.context) do
							table.insert(preview, cl)
						end
						table.insert(preview, "")
					end

					if item.filepath_hint then
						table.insert(preview, "ÄÄ Path: " .. item.filepath_hint .. " ÄÄÄÄÄ")
						table.insert(preview, "")
					end

					table.insert(
						preview,
						"ÄÄ Code ÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄÄ"
					)
					for _, cl in ipairs(vim.split(item.content, "\n")) do
						table.insert(preview, cl)
					end

					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, preview)
					vim.bo[self.state.bufnr].filetype = item.lang
				end,
			}),
			attach_mappings = function(prompt_bufnr, map)
				-- Enter = yank code block + open file search
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if selection then
						vim.fn.setreg("+", selection.value.content)
						vim.fn.setreg('"', selection.value.content)

						-- Save for <leader>ae toggle
						last_picked.file = selection.value.source_file
						last_picked.line = selection.value.source_line

						vim.notify(
							'Yanked "' .. selection.value.lang .. '" block (' .. selection.value.line_count .. " lines)",
							vim.log.levels.INFO
						)

						-- Determine file extension filter
						local ext = nil
						local lang = selection.value.lang
						local fp = selection.value.filepath_hint

						if fp then
							ext = fp:match("%.(%w+)$")
						end
						if not ext then
							local lang_map = {
								go = "go",
								templ = "templ",
								sql = "sql",
								js = "js",
								javascript = "js",
								lua = "lua",
								python = "py",
								py = "py",
								json = "json",
								yaml = "yaml",
								css = "css",
								html = "html",
							}
							ext = lang_map[lang]
						end

						-- Open telescope find_files filtered to the right extension
						vim.schedule(function()
							local search_opts = {
								prompt_title = "Paste into file",
							}

							if fp then
								search_opts.default_text = vim.fn.fnamemodify(fp, ":t")
							end

							if ext then
								search_opts.find_command = { "rg", "--files", "--glob", "*." .. ext }
							end

							require("telescope.builtin").find_files(search_opts)
						end)
					end
				end)

				-- Ctrl-p = yank filepath only
				local function yank_path()
					local selection = action_state.get_selected_entry()
					if selection and selection.value.filepath_hint then
						vim.fn.setreg("+", selection.value.filepath_hint)
						vim.notify("Yanked path: " .. selection.value.filepath_hint, vim.log.levels.INFO)
					else
						vim.notify("No filepath found for this block", vim.log.levels.WARN)
					end
				end
				map("i", "<C-p>", yank_path)
				map("n", "<C-p>", yank_path)

				return true
			end,
		})
		:find()
end, { desc = "Yank code block from opencode exports" })

-- Toggle vsplit of last picked export, jumped to the block
vim.keymap.set("n", "<leader>ae", function()
	if not last_picked.file then
		vim.notify("No block picked yet - use <leader>ay first", vim.log.levels.WARN)
		return
	end

	local bufname = "opencode-export"

	-- Check if already open - toggle close
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		local buf = vim.api.nvim_win_get_buf(win)
		if vim.api.nvim_buf_get_name(buf):find(bufname, 1, true) then
			vim.api.nvim_win_close(win, true)
			return
		end
	end

	-- Read the file into a new buffer (don't edit the original)
	local lines = vim.fn.readfile(last_picked.file)
	if #lines == 0 then
		vim.notify("Export file empty or missing", vim.log.levels.WARN)
		return
	end

	vim.cmd("vsplit")
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(0, buf)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_name(buf, bufname .. "-" .. vim.fn.fnamemodify(last_picked.file, ":t"))
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = "markdown"

	-- Jump to the code block
	if last_picked.line then
		local target = math.min(last_picked.line, #lines)
		vim.api.nvim_win_set_cursor(0, { target, 0 })
		vim.cmd("normal! zz")
	end
end, { desc = "Toggle last picked opencode export" })

return M
