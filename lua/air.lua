-- ── air.lua ─────────────────────────────────────────────────────────────────
-- Manages Air (Go live-reload) in dedicated tmux sessions.
-- Sessions are named `air-<project>` and never appear in the session switcher.
--
-- Keymaps:
--   <leader>ra  Start Air for current project (requires .air.toml in cwd)
--   <leader>ro  Open Air output in a vsplit terminal (live, full nvim controls)
--   <leader>rq  Kill Air session for current project

local M = {}

local AIR_PREFIX = "air-"

local function in_tmux()
    return vim.env.TMUX ~= nil
end

local function tmux(cmd)
    return vim.fn.system("tmux " .. cmd)
end

local function project_name()
    return vim.fn.fnamemodify(vim.fn.getcwd(), ":t"):gsub("%.", "_")
end

local function session_name()
    return AIR_PREFIX .. project_name()
end

local function session_exists(name)
    vim.fn.system("tmux has-session -t=" .. vim.fn.shellescape(name) .. " 2>/dev/null")
    return vim.v.shell_error == 0
end

local function has_air_toml()
    return vim.fn.filereadable(vim.fn.getcwd() .. "/.air.toml") == 1
end

-- ── start ────────────────────────────────────────────────────────────────────

vim.keymap.set("n", "<leader>ra", function()
    if not in_tmux() then
        vim.notify("air: not in tmux", vim.log.levels.WARN)
        return
    end
    if not has_air_toml() then
        vim.notify("air: no .air.toml in " .. vim.fn.getcwd(), vim.log.levels.WARN)
        return
    end

    local name = session_name()
    if session_exists(name) then
        vim.notify("air: session [" .. name .. "] already running", vim.log.levels.INFO)
        return
    end

    local cwd = vim.fn.shellescape(vim.fn.getcwd())
    tmux("new-session -ds " .. vim.fn.shellescape(name) .. " -c " .. cwd .. " 'air'")
    vim.notify("air: started [" .. name .. "]")
end, { desc = "Air: start" })

-- ── open output ──────────────────────────────────────────────────────────────

vim.keymap.set("n", "<leader>ro", function()
    if not in_tmux() then
        vim.notify("air: not in tmux", vim.log.levels.WARN)
        return
    end

    local name = session_name()
    if not session_exists(name) then
        vim.notify("air: no session for this project — run <leader>ra first", vim.log.levels.WARN)
        return
    end

    local bufname = "air-attach-" .. project_name()

    -- Find existing buffer
    local existing_buf = nil
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):find(bufname, 1, true) then
            existing_buf = buf
            break
        end
    end

    if existing_buf then
        local wins = vim.fn.win_findbuf(existing_buf)
        if #wins > 0 then
            -- Visible — close it (toggle off)
            for _, win in ipairs(wins) do
                vim.api.nvim_win_close(win, true)
            end
        else
            -- Exists but hidden — show it
            vim.cmd("vsplit")
            vim.api.nvim_win_set_buf(0, existing_buf)
        end
        return
    end

    -- Doesn't exist — create it
    vim.cmd("vsplit")
    vim.cmd("terminal tmux attach-session -t " .. vim.fn.shellescape(name) .. " -r")
    vim.cmd("file " .. bufname)
    vim.cmd("startinsert")
end, { desc = "Air: toggle output" })

-- ── kill ─────────────────────────────────────────────────────────────────────

vim.keymap.set("n", "<leader>rq", function()
    if not in_tmux() then
        return
    end

    local name = session_name()
    if not session_exists(name) then
        vim.notify("air: no session for this project", vim.log.levels.WARN)
        return
    end

    -- Close any terminal buffers attached to this session
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) then
            local bname = vim.api.nvim_buf_get_name(buf)
            if bname:find("air%-attach%-" .. project_name(), 1, true) then
                vim.api.nvim_buf_delete(buf, { force = true })
            end
        end
    end

    tmux("kill-session -t " .. vim.fn.shellescape(name))
    vim.notify("air: killed [" .. name .. "]")
end, { desc = "Air: kill" })

return M
