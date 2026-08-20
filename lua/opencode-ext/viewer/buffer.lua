-- /home/jmeyer/.config/nvim/lua/opencode-ext/viewer/buffer.lua FINAL
-- Chat buffer rendering and keymap setup.
-- Extracted from viewer.lua to keep files small and changes safe.

local M = {}

local pick = require("opencode-ext.viewer.pick")

-- Help float state (shared across all buffers)
local help_win = nil

local HELP_LINES = {
	"── Keymaps ────────────────────────────────────────────────",
	"",
	"[               previous code block",
	"]               next code block",
	"<A-[>           previous conversation",
	"<A-]>           next conversation",
	"c               copy code block",
	"C               copy + navigate (to func decl if cursor on one)",
	"m               copy markdown file",
	"M               copy markdown + navigate to file",
	"r               refresh (re-read session)",
	"Y               yank all conversation text",
	"?               toggle this help",
	"s               open session picker",
	"q / <Esc>       close viewer",
	"",
	"Press ? or q to close",
}

local function close_help()
	if help_win and vim.api.nvim_win_is_valid(help_win) then
		vim.api.nvim_win_close(help_win, true)
		help_win = nil
	end
end

local function open_help()
	close_help()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, HELP_LINES)
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"
	local width = 52
	local height = #HELP_LINES
	local ui = vim.api.nvim_list_uis()[1]
	local row = math.floor((ui.height - height) / 2)
	local col = math.floor((ui.width - width) / 2)
	help_win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
	})
	local opts = { buffer = buf, nowait = true, noremap = true, silent = true }
	vim.keymap.set("n", "q", close_help, opts)
	vim.keymap.set("n", "?", close_help, opts)
	vim.keymap.set("n", "<Esc>", close_help, opts)
end

local function toggle_help()
	if help_win and vim.api.nvim_win_is_valid(help_win) then
		close_help()
	else
		open_help()
	end
end

--- Main viewer: open a full-chat buffer with winbar and keymaps.
-- raw is the DB fetch result — needed for `r` refresh keymap.
function M.open(conv, project_path, all_convs, conv_idx, raw)
	if not conv then
		return
	end

	local content_lines, blocks, block_positions = conv._content, conv._blocks, conv._block_positions
	if #content_lines == 0 then
		vim.notify("No content in this conversation", vim.log.levels.WARN)
		return
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, content_lines)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = "markdown"

	vim.cmd("vsplit")
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, buf)
	vim.cmd("stopinsert")

	local title = (conv.label or ""):sub(1, 70):gsub("%%", "%%%%")
	vim.wo[win].winbar = "─── " .. (title ~= "" and title or "User") .. " ───"
	vim.wo[win].statusline = "c copy C nav m md M md+nav [ ] <A-[> <A-]> conv ? help"

	local km = { buffer = buf, nowait = true, noremap = true }

	local function close_view()
		close_help()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	-- Block navigation
	vim.keymap.set("n", "]", function()
		local lnum = vim.fn.line(".")
		local bi = block_positions[lnum]
		local target_bi = bi and (bi + 1) or 1
		if target_bi <= #blocks then
			vim.api.nvim_win_set_cursor(0, { blocks[target_bi].start_line, 0 })
		end
	end, km)

	vim.keymap.set("n", "[", function()
		local lnum = vim.fn.line(".")
		local bi = block_positions[lnum]
		local target_bi = bi and (bi - 1) or #blocks
		if target_bi >= 1 then
			vim.api.nvim_win_set_cursor(0, { blocks[target_bi].start_line, 0 })
		end
	end, km)

	-- Conversation navigation
	if all_convs then
		vim.keymap.set("n", "<A-[>", function()
			if conv_idx > 1 then
				close_view()
				M.open(all_convs[conv_idx - 1], project_path, all_convs, conv_idx - 1, nil)
			end
		end, km)
		vim.keymap.set("n", "<A-]>", function()
			if conv_idx < #all_convs then
				close_view()
				M.open(all_convs[conv_idx + 1], project_path, all_convs, conv_idx + 1, nil)
			end
		end, km)
	end

	-- Copy code block under cursor
	vim.keymap.set("n", "c", function()
		local bi = block_positions[vim.fn.line(".")]
		if not bi then
			vim.notify("Not inside a code block", vim.log.levels.WARN)
			return
		end
		local text = table.concat(blocks[bi].lines, "\n")
		vim.fn.setreg("+", text)
		vim.fn.setreg('"', text)
		vim.notify(string.format("Copied block %d (%d chars)", bi, #text), vim.log.levels.INFO)
	end, km)

	-- Copy + navigate
	vim.keymap.set("n", "C", function()
		local bi = block_positions[vim.fn.line(".")]
		if not bi then
			vim.notify("Not inside a code block", vim.log.levels.WARN)
			return
		end
		local b = blocks[bi]
		local text = table.concat(b.lines, "\n")
		vim.fn.setreg("+", text)
		vim.fn.setreg('"', text)
		local raw_path, lineno = b._path, b._lineno
		if raw_path then
			local resolved = raw_path:sub(1, 1) == "/" and raw_path or vim.fn.resolve(project_path .. "/" .. raw_path)
			if vim.fn.filereadable(resolved) ~= 1 then
				-- Try basename search or create prompt (simplified — full logic in init.lua)
			end
		end
	end, km)

	-- Close / help / picker
	vim.keymap.set("n", "?", toggle_help, km)
	vim.keymap.set("n", "q", close_view, km)
	vim.keymap.set("n", "<Esc>", close_view, km)
	vim.keymap.set("n", "s", function()
		close_view()
		pick.pick()
	end, km)

	-- Refresh
	vim.keymap.set("n", "r", function()
		if not raw then
			return
		end
		close_view()
		local model = require("opencode-ext.model")
		local fresh = model.build(raw)
		if #fresh == 0 then
			return
		end
		local idx = math.min(conv_idx or 1, #fresh)
		M.open(fresh[idx], project_path, fresh, idx, raw)
	end, km)

	-- Yank all
	vim.keymap.set("n", "Y", function()
		local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
		vim.fn.setreg("+", text)
		vim.fn.setreg('"', text)
		vim.notify(string.format("Yanked conversation (%d chars)", #text), vim.log.levels.INFO)
	end, km)
end

return M
