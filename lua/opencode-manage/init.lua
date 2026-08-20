-- opencode-manage — the review console for the opencode manage plugin.
-- Proposal review (accept/reject with snapshots) + change journal timeline +
-- registry entry review (M1r).
-- Completely separate from opencode-ext (the chat viewer) — no overlap.
--
-- THREE viewers: proposals (<leader>ap / <leader>ac → reviewview), journal
-- (<leader>aj → journalview), registry (<leader>ar → registryview) — all
-- persistent two-pane viewers with live previews, no bland pickers.

local review = require("opencode-manage.review")
local reviewview = require("opencode-manage.reviewview")
local journalview = require("opencode-manage.journalview")
local registryview = require("opencode-manage.registryview")

-- Keymaps
vim.keymap.set("n", "<leader>ap", reviewview.open, { desc = "Manage: review proposals" })
vim.keymap.set("n", "<leader>ac", reviewview.open, { desc = "Manage: review proposals (merged)" })
vim.keymap.set("n", "<leader>aj", journalview.open, { desc = "Manage: journal viewer" })
vim.keymap.set("n", "<leader>ar", registryview.open, { desc = "Manage: registry entries" })

-- API surface for scripting / later integration
return {
	review = review,
	reviewview = reviewview,
	journalview = journalview,
	registryview = registryview,
	proposals = require("opencode-manage.proposals"),
	journal = require("opencode-manage.journal"),
	registry = require("opencode-manage.registry"),
}
