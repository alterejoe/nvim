-- opencode-manage.reviewview.actions — accept/reject/apply/copy/open.
-- User actions on the selected proposal. Takes the shared state table.

local proposals = require("opencode-manage.proposals")
local render = require("opencode-manage.reviewview.render")

local M = {}

--- @param target string
--- @return boolean
function M.ensure_dirs(target)
	local parent = vim.fn.fnamemodify(target, ":h")
	if vim.fn.isdirectory(parent) ~= 1 then
		local create = vim.fn.confirm(
			"Directory doesn't exist:\n  " .. parent .. "\n\nCreate it and open the file?",
			"&Yes\n&No",
			1
		)
		if create ~= 1 then
			vim.notify("❌ Cancelled — target not opened", vim.log.levels.INFO)
			return false
		end
		vim.fn.mkdir(parent, "p")
	end
	return true
end

--- Shared delete handling: confirm Move to _old? then route.
--- @param p table
function M.handle_delete(p)
	local target = render.resolve_path(p)
	local choice = vim.fn.confirm(
		"Move to _old?\n  "
			.. target
			.. "\n\n"
			.. "File goes to: "
			.. vim.fn.fnamemodify(target, ":h")
			.. "/_old/\n\n"
			.. "Nothing is permanently deleted — reversible from the journal.",
		"&Yes\n&No",
		1
	)
	if choice == 1 then
		proposals.move_to_old(p)
	else
		proposals.reject(p)
	end
end

--- o / <CR>: open target in the origin window WITHOUT moving the cursor.
--- @param state table
function M.open_in_origin(state)
	local p = state.items[state.idx]
	if not p then
		return
	end
	local target = render.resolve_path(p)
	if not M.ensure_dirs(target) then
		return
	end
	local origin = state.origin_win
	if origin and vim.api.nvim_win_is_valid(origin) then
		local cur = vim.api.nvim_get_current_win()
		vim.api.nvim_set_current_win(origin)
		vim.cmd("edit " .. vim.fn.fnameescape(target))
		vim.api.nvim_set_current_win(cur)
		vim.notify("📍 Opened " .. target .. " in your buffer (picker stays focused)", vim.log.levels.INFO)
	end
end

--- rr: re-evaluation path — the proposal predates file changes, so open the
--- file in origin and let the user re-ask the AI against current state.
--- Status unchanged; this is a context flag, not a verdict.
--- @param state table
function M.rerun_open(state)
	local p = state.items[state.idx]
	if not p then
		return
	end
	vim.notify(
		string.format("🔄 %s — proposal predates file changes; re-ask the AI against current state", p.path),
		vim.log.levels.WARN
	)
	M.open_in_origin(state)
end

--- da: accept the selected proposal. Writes the RIGHT pane verbatim —
--- for edit_range that pane is the full file with the range applied, so
--- partials are safe. Rerun guard confirms before clobbering newer work.
--- @param state table
function M.accept_current(state)
	local p = state.items[state.idx]
	if not p then
		return
	end
	if state.row_states[state.idx] == "applied" then
		vim.notify("ℹ️ Already applied: " .. p.path, vim.log.levels.INFO)
		return
	end
	if p.operation == "delete" then
		M.handle_delete(p)
	else
		if state.row_states[state.idx] == "rerun" then
			local choice = vim.fn.confirm(
				"⚠️ File changed since this proposal was written.\n\n"
					.. "Accepting will OVERWRITE newer work on:\n  "
					.. render.resolve_path(p)
					.. "\n\n"
					.. "Continue?",
				"&Yes\n&No",
				2
			)
			if choice ~= 1 then
				return
			end
		end
		local current = vim.api.nvim_buf_get_lines(state.after_buf, 0, -1, false)
		-- Baseline for the verdict: for edit_range it is the full after-content
		-- (never the replacement fragment); other ops keep proposal.content.
		local baseline = nil
		if p.operation == "edit_range" then
			baseline = render.after_content(p, render.resolve_path(p))
		end
		proposals.accept(p, table.concat(current, "\n"), baseline)
	end
	render.refresh_items(state)
end

--- dr: reject the selected proposal (status + verdict only).
--- @param state table
function M.reject_current(state)
	local p = state.items[state.idx]
	if not p then
		return
	end
	proposals.reject(p)
	render.refresh_items(state)
end

--- ga: apply EVERY pending row in the current group, in display order.
--- Each row is computed against the file state at apply time (fresh read),
--- so a multi-file group applies cleanly in one pass. Delete rows prompt.
--- @param state table
function M.apply_group(state)
	local p = state.items[state.idx]
	if not p then
		return
	end
	local group = p.group or "misc"
	local applied, skipped = 0, 0
	for _, it in ipairs(state.items) do
		if (it.group or "misc") == group then
			if render.row_state(it) == "applied" then
				skipped = skipped + 1
			elseif it.operation == "delete" then
				M.handle_delete(it)
			else
				local path = render.resolve_path(it)
				local content = render.after_content(it, path)
				-- Group-apply never edits: baseline == applied.
				proposals.accept(it, content, content)
				applied = applied + 1
			end
		end
	end
	render.refresh_items(state)
	vim.notify(
		string.format("✅ Group %s: %d applied, %d already applied", group, applied, skipped),
		vim.log.levels.INFO
	)
end

--- y: on DELETE rows, prompt Move to _old? like da. Otherwise SNAPSHOT the
--- current file (journaled — manual pastes are revertible), copy content,
--- and open the target in origin.
--- @param state table
function M.copy_and_open(state)
	local p = state.items[state.idx]
	if not p then
		return
	end
	if p.operation == "delete" then
		M.handle_delete(p)
		render.refresh_items(state)
		return
	end
	local content = p.content or ""
	vim.fn.setreg("+", content)
	vim.fn.setreg('"', content)

	-- Snapshot the CURRENT file BEFORE the user pastes — the manual path
	-- is now journaled and revertible, same as da.
	proposals.snapshot_only(p)

	vim.notify(string.format("📋 Copied %d chars (%s) to clipboard", #content, p.path), vim.log.levels.INFO)
	local target = render.resolve_path(p)
	if not M.ensure_dirs(target) then
		return
	end
	local origin = state.origin_win
	if origin and vim.api.nvim_win_is_valid(origin) then
		vim.api.nvim_set_current_win(origin)
		vim.cmd("edit " .. vim.fn.fnameescape(target))
	end
	vim.notify(
		string.format("📍 Opened %s — clipboard has the new content. Paste + :w to apply.", target),
		vim.log.levels.INFO
	)
end

return M
