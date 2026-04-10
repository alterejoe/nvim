local function open_terminal(split_cmd)
    local pwd = vim.fn.getcwd()
    vim.cmd(split_cmd .. " | terminal")
    vim.cmd("startinsert")
    vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("cd " .. pwd .. "<CR>", true, false, true),
        "n",
        true
    )
end

vim.keymap.set("n", "<leader>st", function()
    open_terminal("rightbelow vsplit")
end, { desc = "Terminal vertical split" })

vim.keymap.set("n", "<leader>sh", function()
    open_terminal("botright split")
end, { desc = "Terminal horizontal split" })
