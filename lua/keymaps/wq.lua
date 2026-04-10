local function force_delete(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
end

vim.keymap.set("n", "Q", function()
    local buf = vim.api.nvim_get_current_buf()
    local buftype = vim.bo.buftype
    local bufname = vim.fn.expand("%:t")
    local filetype = vim.bo.filetype

    -- Special named buffers to force delete
    local delete_by_name = { output = true }
    local delete_by_ft = { ["kulala://ui"] = true }

    if delete_by_name[bufname] then
        return force_delete(buf)
    end
    if delete_by_ft[filetype] then
        return force_delete(buf)
    end

    if buftype == "terminal" then
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-c>", true, true, true), "i", false)
        return force_delete(buf)
    end

    if buftype == "prompt" or buftype == "acwrite" then
        return vim.cmd("q!")
    end

    if buftype == "" then
        local ok = pcall(vim.cmd, "wq")
        if not ok then
            vim.cmd(bufname == "" and "q!" or "q")
        end
        return
    end

    vim.cmd("q!")
end, { desc = "Smart buffer close" })

vim.keymap.set("n", "W", function()
    local buftype = vim.bo.buftype
    if buftype == "" or buftype == "acwrite" then
        vim.cmd("w!")
    end
end, { desc = "Force save" })
