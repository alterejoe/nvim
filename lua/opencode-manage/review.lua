-- opencode-manage.review — the UI.
-- Telescope pickers + side-by-side diff for proposals and the journal.
-- create/replace proposals: EDITABLE diff view, da accept (your version),
-- dr reject. delete proposals: confirm + move to _old/ (never deletes).
-- [ ] diff hunks. Proposals picker groups by `group`.
-- Journal picker: <CR> restore (peek first), dd delete entry, gr group
-- revert. Every row says what restoring WILL do.

local proposals = require("opencode-manage.proposals")
local journal = require("opencode-manage.journal")

local M = {}

--- Human-readable label for a journal op.
--- @param op string|nil
--- @return string
local function op_label(op)
	local labels = {
		create = "create",
		replace = "replace",
		edit_range = "edit",
		delete = "delete",
		move = "move-old",
		manual = "manual-y",
		restore = "restore",
	}
	return labels[op] or (op or "?")
end

--- Show a proposal as a side-by-side diff (old on disk vs proposed content).
--- New files (create) show only the proposed content, flagged [NEW FILE].
--- The proposal buffer is modifiable — edit it before accepting.
--- @param proposal table
function M.show(proposal)
	local path = proposal.path
	if path:sub(1, 1) ~= "/" then
		path = vim.fn.getcwd() .. "/" .. path
	end

	-- delete proposals: no diff view — confirm and move to _old/ directly
	if proposal.operation == "delete" then
		local choice = vim.fn.confirm(
			"Move to _old?\n  "
				.. path
				.. "\n\n"
				.. "File goes to: "
				.. vim.fn.fnamemodify(path, ":h")
				.. "/_old/\n\n"
				.. "Nothing is permanently deleted — reversible from the journal.",
			"&Yes\n&No",
			1
		)
		if choice == 1 then
			proposals.move_to_old(proposal)
		else
			proposals.reject(proposal)
		end
		return
	end

	local existing = vim.fn.filereadable(path) == 1
	local kind = existing and "EDIT" or "NEW FILE"

	-- Proposed content in an EDITABLE scratch buffer
	local buf = vim.api.nvim_create_buf(false, true)
	local lines = vim.split(proposal.content or "", "\n", { plain = true })
	if lines[#lines] == "" then
		table.remove(lines)
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = true -- user can tweak the proposal
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = vim.filetype.match({ filename = path }) or ""
	vim.api.nvim_buf_set_name(buf, kind .. ": " .. path)

	vim.cmd("vsplit")
	vim.api.nvim_win_set_buf(0, buf)

	-- Diff against the real file when it exists
	if existing then
		vim.cmd("vsplit " .. vim.fn.fnameescape(path))
		vim.cmd("windo diffthis")
	end

	-- Sticky winbar: indicator + keys
	local win = vim.api.nvim_get_current_win()
	vim.wo[win].winbar = string.format("%s %s  ·  da accept  dr reject  q close  [ ] hunks", kind, path)

	-- Review keymaps on the proposal buffer
	local opts = { buffer = buf, nowait = true, noremap = true }
	vim.keymap.set("n", "da", function()
		-- Accept the USER's version: read the (possibly edited) buffer
		local current = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		proposals.accept(proposal, table.concat(current, "\n"))
		vim.cmd("only")
	end, opts)
	vim.keymap.set("n", "dr", function()
		proposals.reject(proposal)
		vim.cmd("only")
	end, opts)
	vim.keymap.set("n", "q", function()
		vim.cmd("only")
	end, opts)

	-- Diff hunk navigation: [ ] as requested, plus native ]c/[c
	vim.keymap.set("n", "[", function()
		vim.cmd("normal! [c")
	end, opts)
	vim.keymap.set("n", "]", function()
		vim.cmd("normal! ]c")
	end, opts)

	vim.notify(
		string.format("Proposal: %s (%s) — da accept, dr reject, [ ] hunks", path, proposal.operation),
		vim.log.levels.INFO
	)
end

--- Telescope picker over pending proposals, grouped by `group`.
function M.pick_proposals()
	local items = proposals.list_pending()
	if #items == 0 then
		vim.notify("No pending proposals", vim.log.levels.INFO)
		return
	end

	-- Sort by group then ts, and count per group for the display
	table.sort(items, function(a, b)
		local ga, gb = a.group or "misc", b.group or "misc"
		if ga ~= gb then
			return ga < gb
		end
		return (a.ts or 0) < (b.ts or 0)
	end)
	local counts = {}
	for _, p in ipairs(items) do
		local g = p.group or "misc"
		counts[g] = (counts[g] or 0) + 1
	end

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	pickers
		.new({}, {
			prompt_title = "AI Proposals (grouped)",
			finder = finders.new_table({
				results = items,
				entry_maker = function(p)
					local g = p.group or "misc"
					return {
						value = p,
						display = string.format(
							"[%s x%d] %-35s %-10s %s",
							g,
							counts[g],
							p.path,
							p.operation,
							(p.reason or ""):sub(1, 30)
						),
						ordinal = g .. " " .. p.path .. " " .. p.operation .. " " .. (p.reason or ""),
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, _)
				actions.select_default:replace(function()
					local s = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if s and s.value then
						M.show(s.value)
					end
				end)
				return true
			end,
		})
		:find()
end

--- Telescope picker over the journal timeline.
--- <CR> restore (peek first) · dd delete entry · gr revert whole group.
--- EVERY ROW shows what restoring will do (describe_target), so you always
--- know what you're reverting to before you pick.
function M.pick_journal()
	local items = journal.list()
	if #items == 0 then
		vim.notify("Journal is empty", vim.log.levels.INFO)
		return
	end
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	pickers
		.new({}, {
			prompt_title = "Change Journal (<CR> restore, dd delete, gr group revert)",
			finder = finders.new_table({
				results = items,
				entry_maker = function(e)
					local when = os.date("%H:%M:%S", math.floor((e.ts or 0) / 1000))
					local g = e.group or "-"
					local target = journal.describe_target(e)
					local lineage = ""
					if e.op == "restore" and e.parent_ts then
						lineage = "  ↩ from " .. tostring(e.parent_ts)
					end
					return {
						value = e,
						display = string.format(
							"%s  [%-20s] %-30s %-9s %s  → %s%s",
							when,
							g,
							e.path,
							op_label(e.op),
							(e.reason or ""):sub(1, 20),
							target,
							lineage
						),
						ordinal = (e.group or "") .. " " .. e.path .. " " .. e.op .. " " .. (e.reason or ""),
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, _)
				actions.select_default:replace(function()
					local s = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if s and s.value then
						journal.restore(s.value)
					end
				end)
				-- dd: delete the entry under the cursor (confirmed in journal.delete)
				vim.keymap.set("n", "dd", function()
					local s = action_state.get_selected_entry()
					if s and s.value then
						journal.delete(s.value)
					end
					actions.close(prompt_bufnr)
					M.pick_journal()
				end, { buffer = prompt_bufnr, nowait = true, silent = true })
				-- gr: revert every accepted entry in the entry's group
				vim.keymap.set("n", "gr", function()
					local s = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if s and s.value then
						journal.restore_group(s.value.group)
					end
				end, { buffer = prompt_bufnr, nowait = true, silent = true })
				return true
			end,
		})
		:find()
end

--- Backup copy flow: pick a proposal → content yanked to clipboard →
--- navigate to the target file. For when the workspace review isn't
--- available or you just want the manual path. Notifies at every step.
function M.pick_copy()
	local items = proposals.list_all() -- all, not just pending: you may want old ones
	if #items == 0 then
		vim.notify("No proposals found", vim.log.levels.INFO)
		return
	end
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	pickers
		.new({}, {
			prompt_title = "Copy Proposal (yank + navigate)",
			finder = finders.new_table({
				results = items,
				entry_maker = function(p)
					local st = p.status or "?"
					return {
						value = p,
						display = string.format(
							"[%s] %-40s %-10s %s",
							st,
							p.path,
							p.operation,
							(p.reason or ""):sub(1, 30)
						),
						ordinal = p.path .. " " .. p.operation .. " " .. (p.reason or ""),
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, _)
				actions.select_default:replace(function()
					local s = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if not s or not s.value then
						return
					end
					local p = s.value
					-- 1. Yank the proposed content
					local content = p.content or ""
					vim.fn.setreg("+", content)
					vim.fn.setreg('"', content)
					vim.notify(
						string.format("📋 Copied %d chars (%s) to clipboard", #content, p.path),
						vim.log.levels.INFO
					)
					-- 2. Navigate to the target file (create dirs if needed)
					local target = p.path
					if target:sub(1, 1) ~= "/" then
						target = vim.fn.getcwd() .. "/" .. target
					end
					local parent = vim.fn.fnamemodify(target, ":h")
					if vim.fn.isdirectory(parent) ~= 1 then
						vim.fn.mkdir(parent, "p")
					end
					vim.cmd("edit " .. vim.fn.fnameescape(target))
					vim.notify(
						string.format(
							"📍 Opened %s — clipboard has the new content (proposal %s, %s). "
								.. "Paste + :w to apply, or use a to review properly.",
							target,
							tostring(p.ts),
							p.status or "?"
						),
						vim.log.levels.INFO
					)
				end)
				return true
			end,
		})
		:find()
end

return M
