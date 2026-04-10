-- ── air.lua ─────────────────────────────────────────────────────────────────
-- Manages Air (Go live-reload) in dedicated tmux sessions.
-- Sessions are named `air-<project>` and never appear in the session switcher.
--
-- Keymaps:
--   <leader>ra  Start Air for current project (requires .air.toml in cwd)
--   <leader>ro  Toggle Air log buffer (vsplit, live, navigable)
--   <leader>rr  Restart Air session
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

local function log_path()
    return "/tmp/air-" .. project_name() .. ".log"
end

local function session_exists(name)
    vim.fn.system("tmux has-session -t=" .. vim.fn.shellescape(name) .. " 2>/dev/null")
    return vim.v.shell_error == 0
end

local function has_air_toml()
    return vim.fn.filereadable(vim.fn.getcwd() .. "/.air.toml") == 1
end

local function open_log_buffer()
    local log = log_path()
    local bufname = "air-log-" .. project_name()

    local attempts = 0
    local function try_open()
        attempts = attempts + 1
        if vim.fn.filereadable(log) == 0 and attempts < 20 then
            vim.defer_fn(try_open, 100)
            return
        end
        vim.cmd("vsplit")
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(0, buf)
        vim.fn.termopen("tail -f " .. vim.fn.shellescape(log))
        vim.api.nvim_buf_set_name(buf, bufname)
        vim.bo[buf].bufhidden = "hide"
        vim.cmd("stopinsert")
    end
    try_open()
end

local function close_log_buffer()
    local bufname = "air-log-" .. project_name()
    local was_open = false
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):find(bufname, 1, true) then
            was_open = #vim.fn.win_findbuf(buf) > 0
            vim.api.nvim_buf_delete(buf, { force = true })
            break
        end
    end
    return was_open
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

    local log = log_path()
    local cwd = vim.fn.shellescape(vim.fn.getcwd())

    vim.fn.system("rm -f " .. vim.fn.shellescape(log))
    tmux("new-session -ds " .. vim.fn.shellescape(name) .. " -c " .. cwd .. " 'air'")
    tmux("pipe-pane -t " .. vim.fn.shellescape(name) .. " 'cat >> " .. log .. "'")

    vim.notify("air: started [" .. name .. "]")
end, { desc = "Air: start" })

-- ── toggle log ───────────────────────────────────────────────────────────────

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

    local bufname = "air-log-" .. project_name()

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
            for _, win in ipairs(wins) do
                vim.api.nvim_win_close(win, true)
            end
        else
            vim.cmd("vsplit")
            vim.api.nvim_win_set_buf(0, existing_buf)
        end
        return
    end

    open_log_buffer()
end, { desc = "Air: toggle log" })

-- ── restart ───────────────────────────────────────────────────────────────────

vim.keymap.set("n", "<leader>rr", function()
    if not in_tmux() then
        return
    end

    local name = session_name()
    if not session_exists(name) then
        vim.notify("air: no session for this project", vim.log.levels.WARN)
        return
    end

    local log = log_path()
    local was_open = close_log_buffer()

    tmux("pipe-pane -t " .. vim.fn.shellescape(name))
    tmux("kill-session -t " .. vim.fn.shellescape(name))
    vim.fn.system("rm -f " .. vim.fn.shellescape(log))

    local cwd = vim.fn.shellescape(vim.fn.getcwd())
    tmux("new-session -ds " .. vim.fn.shellescape(name) .. " -c " .. cwd .. " 'air'")
    tmux("pipe-pane -t " .. vim.fn.shellescape(name) .. " 'cat >> " .. log .. "'")

    vim.notify("air: restarted [" .. name .. "]")

    if was_open then
        open_log_buffer()
    end
end, { desc = "Air: restart" })

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

    close_log_buffer()
    tmux("pipe-pane -t " .. vim.fn.shellescape(name))
    vim.fn.system("rm -f " .. vim.fn.shellescape(log_path()))
    tmux("kill-session -t " .. vim.fn.shellescape(name))
    vim.notify("air: killed [" .. name .. "]")
end, { desc = "Air: kill" })

return M
