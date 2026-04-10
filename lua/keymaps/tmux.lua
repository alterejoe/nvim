--[[
Keymaps:
  <C-f>       Sessionizer - telescope project picker, create or attach session
  <leader>ts  Edit tmux sessions (oil-style scratch buffer)
  <leader>tr  Rename current session
  <leader>t|  Vertical split pane in cwd
  <leader>t-  Horizontal split pane in cwd

Scratchbuf keymaps (inside <leader>ts):
  <CR>  switch to session
  o     new session below
  O     new session above
  dd    kill session
  W     save renames/deletes/creates
  /     fuzzy filter
  r     refresh list
  q     close
--]]

local scratchbuf = require("scratchbuf")

local function in_tmux()
    return vim.env.TMUX ~= nil
end

local function tmux(cmd)
    vim.fn.system("tmux " .. cmd)
end

local function get_sessions()
    return vim.fn.systemlist("tmux list-sessions -F '#S'")
end

local function sessionize(path)
    local name = vim.fn.fnamemodify(path, ":t"):gsub("%.", "_")
    if vim.fn.system("tmux has-session -t=" .. name .. " 2>/dev/null; echo $?"):gsub("%s+", "") == "0" then
        tmux("switch-client -t " .. vim.fn.shellescape(name))
    else
        tmux("new-session -ds " .. vim.fn.shellescape(name) .. " -c " .. vim.fn.shellescape(path))
        tmux("switch-client -t " .. vim.fn.shellescape(name))
    end
end

-- Sessionizer
vim.keymap.set("n", "<C-f>", function()
    if not in_tmux() then
        vim.notify("Not in tmux", vim.log.levels.WARN)
        return
    end

    local scan = require("plenary.scandir")
    local search_dirs = {
        vim.fn.expand("~/Projects"),
        vim.fn.expand("~/personal"),
    }

    local dirs = {}
    for _, base in ipairs(search_dirs) do
        if vim.fn.isdirectory(base) == 1 then
            local found = scan.scan_dir(base, { depth = 1, only_dirs = true, silent = true })
            for _, d in ipairs(found) do
                table.insert(dirs, d)
            end
        end
    end
    table.insert(dirs, 1, vim.fn.getcwd())

    require("telescope.pickers").new({}, {
        prompt_title = "Tmux Sessionizer",
        finder = require("telescope.finders").new_table({
            results = dirs,
            entry_maker = function(entry)
                return {
                    value   = entry,
                    display = vim.fn.fnamemodify(entry, ":~"),
                    ordinal = entry,
                }
            end,
        }),
        sorter = require("telescope.config").values.generic_sorter({}),
        attach_mappings = function(prompt_bufnr)
            require("telescope.actions").select_default:replace(function()
                local sel = require("telescope.actions.state").get_selected_entry()
                require("telescope.actions").close(prompt_bufnr)
                if sel then sessionize(sel.value) end
            end)
            return true
        end,
    }):find()
end, { desc = "Tmux sessionizer" })

-- Oil-style session editor
vim.keymap.set("n", "<leader>ts", function()
    if not in_tmux() then return end
    scratchbuf.open({
        title   = "Tmux Sessions",
        lines   = get_sessions(),
        refresh = get_sessions,
        on_open = function(entry)
            tmux("switch-client -t " .. vim.fn.shellescape(entry))
        end,
        on_save = function(changes)
            for _, r in ipairs(changes.renamed) do
                tmux("rename-session -t " .. vim.fn.shellescape(r.old)
                    .. " " .. vim.fn.shellescape(r.new))
            end
            for _, d in ipairs(changes.deleted) do
                tmux("kill-session -t " .. vim.fn.shellescape(d))
            end
            for _, c in ipairs(changes.created) do
                local path = vim.fn.input(
                    "Path for [" .. c .. "]: ",
                    vim.fn.getcwd(),
                    "dir"
                )
                if path and path ~= "" then
                    tmux("new-session -ds " .. vim.fn.shellescape(c)
                        .. " -c " .. vim.fn.shellescape(path))
                    tmux("switch-client -t " .. vim.fn.shellescape(c))
                end
            end
        end,
    })
end, { desc = "Tmux sessions (edit)" })

-- Rename current session inline
vim.keymap.set("n", "<leader>tr", function()
    if not in_tmux() then return end
    local current = vim.fn.system("tmux display-message -p '#S'"):gsub("%s+", "")
    local name = vim.fn.input("Rename session [" .. current .. "]: ")
    if name and name ~= "" then
        tmux("rename-session " .. vim.fn.shellescape(name))
        vim.notify("Session renamed to: " .. name)
    end
end, { desc = "Tmux rename session" })

-- Splits
vim.keymap.set("n", "<leader>t|", function()
    if not in_tmux() then return end
    tmux("split-window -h -c " .. vim.fn.shellescape(vim.fn.getcwd()))
end, { desc = "Tmux vertical split" })

vim.keymap.set("n", "<leader>t-", function()
    if not in_tmux() then return end
    tmux("split-window -v -c " .. vim.fn.shellescape(vim.fn.getcwd()))
end, { desc = "Tmux horizontal split" })
