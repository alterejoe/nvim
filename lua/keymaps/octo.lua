# /home/jmeyer/.config/nvim/lua/keymaps/octo.lua FINAL
-- Global keymaps for octo.nvim issue workflow
vim.keymap.set("n", "<leader>ii", "<cmd>Octo issue list<cr>", { desc = "List issues" })
vim.keymap.set("n", "<leader>iI", "<cmd>Octo issue list assignee=@me<cr>", { desc = "My issues" })
vim.keymap.set("n", "<leader>ia", "<cmd>Octo issue create<cr>", { desc = "New issue" })
vim.keymap.set("n", "<leader>ic", "<cmd>Octo issue close<cr>", { desc = "Close issue" })
vim.keymap.set("n", "<leader>io", "<cmd>Octo issue reopen<cr>", { desc = "Reopen issue" })
vim.keymap.set("n", "<leader>iC", "<cmd>Octo comment add<cr>", { desc = "Add comment" })
vim.keymap.set("n", "<leader>ir", "<cmd>Octo issue reload<cr>", { desc = "Reload issue" })
vim.keymap.set("n", "<leader>ib", "<cmd>Octo issue browser<cr>", { desc = "Open in browser" })
vim.keymap.set("n", "<leader>iy", "<cmd>Octo issue url<cr>", { desc = "Copy issue URL" })
vim.keymap.set("n", "<leader>iA", "<cmd>Octo issue add assignee<cr>", { desc = "Add assignee" })
vim.keymap.set("n", "<leader>il", "<cmd>Octo issue add label<cr>", { desc = "Add label" })

-- Open a specific issue by URL or number
vim.keymap.set("n", "<leader>io", function()
  local url = vim.fn.input("Issue URL or number: ")
  if url and url ~= "" then
    vim.cmd("Octo " .. url)
  end
end, { desc = "Open issue by URL/number" })
