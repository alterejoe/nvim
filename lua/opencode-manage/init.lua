-- /home/altjoe/.config/nvim/lua/opencode-manage/init.lua FINAL-2
-- opencode-manage — the review console for the opencode manage plugin.
-- Proposal review + change journal + registry review + verdict store/viewer
-- + metrics interface + references + skills lifecycle + permissions folders
-- + handoff catalogue viewer.
-- Completely separate from opencode-ext (the chat viewer) — no overlap.
--
-- VIEWERS: proposals (<leader>ap / <leader>ac), journal (<leader>aj),
-- registry (<leader>ar), verdicts (<leader>av), metrics (<leader>at),
-- references (<leader>af), vault (<leader>ag), skills (<leader>ak), folders (<leader>aa),
-- handoff (<leader>ah) —
-- all persistent two-pane viewers with live previews, no bland pickers.
-- COMMANDS: :ManageMetrics (summary), :ManagePrune [note] (shaped prune),
-- :ManageFolders (permissions memory + sync + verify),
-- :ManageIndex [root] / :ManageVault [root] / :ManageRef [path] /
-- :ManageRefs / :ManageRefPrune <id> <why> (references, doc 20),
-- :ManageHandoff (handoff catalogue + pending proposals).
-- Focus: BufEnter writes the active file so refs can route by what you work on.

local review = require("opencode-manage.review")
local reviewview = require("opencode-manage.reviewview")
local journalview = require("opencode-manage.journalview")
local registryview = require("opencode-manage.registryview")
local verdictview = require("opencode-manage.verdictview")
local metrics = require("opencode-manage.metrics")
local metricsview = require("opencode-manage.metricsview")
local refs = require("opencode-manage.refs")
local refsview = require("opencode-manage.refsview")
local vaultview = require("opencode-manage.vaultview")
local skills = require("opencode-manage.skills")
local skillsview = require("opencode-manage.skillsview")
local folders = require("opencode-manage.folders")
local foldersview = require("opencode-manage.foldersview")
local handoffview = require("opencode-manage.handoffview")

-- Keymaps
vim.keymap.set("n", "<leader>ap", reviewview.open, { desc = "Manage: review proposals" })
vim.keymap.set("n", "<leader>ac", reviewview.open, { desc = "Manage: review proposals (merged)" })
vim.keymap.set("n", "<leader>aj", journalview.open, { desc = "Manage: journal viewer" })
vim.keymap.set("n", "<leader>ar", registryview.open, { desc = "Manage: registry entries" })
vim.keymap.set("n", "<leader>av", verdictview.open, { desc = "Manage: verdict viewer" })
vim.keymap.set("n", "<leader>at", metricsview.open, { desc = "Manage: metrics viewer (turns + objects)" })
vim.keymap.set("n", "<leader>af", refsview.open, { desc = "Manage: references viewer" })
vim.keymap.set("n", "<leader>ak", skillsview.open, { desc = "Manage: skills lifecycle" })
vim.keymap.set("n", "<leader>aa", foldersview.open, { desc = "Manage: folder permissions" })
vim.keymap.set("n", "<leader>ag", vaultview.open, { desc = "Manage: vault (global references)" })
vim.keymap.set("n", "<leader>ah", handoffview.open, { desc = "Manage: handoff catalogue" })

-- Stable commands (path resolution lives in code, not in pasted one-liners)
vim.api.nvim_create_user_command("ManageMetrics", function()
	metrics.summary()
end, { desc = "Manage: metrics store summary" })

vim.api.nvim_create_user_command("ManagePrune", function(opts)
	metrics.request_prune(opts.args ~= "" and opts.args or nil)
end, { nargs = "*", desc = "Manage: request a shaped context prune (next opencode message)" })

vim.api.nvim_create_user_command("ManageFolders", function()
	folders.summary()
end, { desc = "Manage: folder permissions memory (approve/avoid/sync/verify)" })

vim.api.nvim_create_user_command("ManageIndex", function(opts)
	refs.index(opts.args ~= "" and opts.args or vim.fn.getcwd())
end, { nargs = "?", complete = "dir", desc = "Manage: index references under a root" })

vim.api.nvim_create_user_command("ManageVault", function(opts)
	local root = opts.args ~= "" and opts.args or ((vim.env.HOME or "") .. "/projects/shared")
	refs.index(root, { global = true })
end, { nargs = "?", complete = "dir", desc = "Manage: index the shared vault into the GLOBAL ref store" })

vim.api.nvim_create_user_command("ManageRef", function(opts)
	local path = opts.args ~= "" and opts.args or vim.api.nvim_buf_get_name(0)
	if path == "" then
		vim.notify("❌ refs: no path given and the buffer has no file", vim.log.levels.WARN)
		return
	end
	refs.pin(path)
end, { nargs = "?", complete = "file", desc = "Manage: pin a reference" })

vim.api.nvim_create_user_command("ManageRefs", function()
	refs.summary()
end, { desc = "Manage: list references" })

vim.api.nvim_create_user_command("ManageRefPrune", function(opts)
	local id, reason = opts.args:match("^(%d+)%s+(.+)$")
	if not id then
		vim.notify("❌ usage: :ManageRefPrune <id> <reason>", vim.log.levels.WARN)
		return
	end
	refs.prune(tonumber(id), reason)
end, { nargs = "+", desc = "Manage: prune a reference, keeping the reason" })

vim.api.nvim_create_user_command("ManageHandoff", function()
	handoffview.open()
end, { desc = "Manage: show the handoff catalogue + pending proposals" })

-- R1: focus routing — write the active file so refs match what you work on.
vim.api.nvim_create_autocmd("BufEnter", {
	callback = function()
		local buf = vim.api.nvim_get_current_buf()
		if vim.bo[buf].buftype ~= "" then
			return
		end
		local name = vim.api.nvim_buf_get_name(buf)
		if name ~= "" then
			refs.request_focus(name)
		end
	end,
})

-- API surface for scripting / later integration
return {
	review = review,
	reviewview = reviewview,
	journalview = journalview,
	registryview = registryview,
	verdictview = verdictview,
	metrics = metrics,
	metricsview = metricsview,
	refs = refs,
	refsview = refsview,
	vaultview = vaultview,
	skills = skills,
	skillsview = skillsview,
	folders = folders,
	foldersview = foldersview,
	handoffview = handoffview,
	proposals = require("opencode-manage.proposals"),
	journal = require("opencode-manage.journal"),
	registry = require("opencode-manage.registry"),
	verdicts = require("opencode-manage.verdicts"),
}
