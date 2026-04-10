--[[
Keymaps:
  <C-f>    Sessionizer — telescope project picker
  <leader>ts  Edit tmux sessions (scratchbuf)
  <leader>tr  Rename current session
  <leader>t|  Vertical split in cwd
  <leader>t-  Horizontal split in cwd

  Slot switching (line order in scratchbuf = slot order):
  <M-j>  slot 1    <M-J>  slot 5
  <M-k>  slot 2    <M-K>  slot 6
  <M-l>  slot 3    <M-L>  slot 7
  <M-;>  slot 4    <M-:>  slot 8

Scratchbuf keymaps (inside <leader>ts):
  <CR>  switch to session
  o     new session below
  O     new session above
  dd    cut session
  p     paste below  (reorder)
  P     paste above  (reorder)
  W     save — persists slot order
  /     fuzzy filter
  r     refresh
  q     close
--]]

local scratchbuf = require("scratchbuf")

-- ── persistence ─────────────────────────────────────────────────────────────

local order_file = vim.fn.stdpath("data") .. "/tmux_session_slots"

local function load_order()
    local f = io.open(order_file, "r")
    if not f then
        return {}
    end
    local slots = {}
    for line in f:lines() do
        local t = vim.trim(line)
        if t ~= "" then
            table.insert(slots, t)
        end
    end
    f:close()
    return slots
end

local function save_order(slots)
    local f = io.open(order_file, "w")
    if not f then
        vim.notify("tmux: could not write " .. order_file, vim.log.levels.ERROR)
        return
    end
    for _, s in ipairs(slots) do
        f:write(s .. "\n")
    end
    f:close()
end

-- ── helpers ──────────────────────────────────────────────────────────────────

local function in_tmux()
    return vim.env.TMUX ~= nil
end

local function tmux(cmd)
    vim.fn.system("tmux " .. cmd)
end

-- Merge persisted order with live sessions.
-- Pinned live sessions keep their position; new sessions append at end.
local function ordered_sessions()
    local live = vim.fn.systemlist("tmux list-sessions -F '#S' 2>/dev/null")
    if vim.v.shell_error ~= 0 then
        return {}
    end

    local live_set = {}
    for _, s in ipairs(live) do
        live_set[s] = true
    end

    local result = {}
    local seen = {}

    -- 1. pinned sessions in file order (stable, session-independent)
    for _, s in ipairs(load_order()) do
        if live_set[s] then
            table.insert(result, s)
            seen[s] = true
        end
    end

    -- 2. new sessions not yet pinned — sort alphabetically so order
    --    is deterministic regardless of which session tmux lists first
    local unseen = {}
    for _, s in ipairs(live) do
        if not seen[s] and not s:find("^air%-") then
            table.insert(unseen, s)
        end
    end
    table.sort(unseen)
    for _, s in ipairs(unseen) do
        table.insert(result, s)
    end

    return result
end

local function sessionize(path)
    local name = vim.fn.fnamemodify(path, ":t"):gsub("%.", "_")
    local exists = vim.fn.system("tmux has-session -t=" .. vim.fn.shellescape(name) .. " 2>/dev/null; echo $?")
    exists = vim.trim(exists)
    if exists == "0" then
        tmux("switch-client -t " .. vim.fn.shellescape(name))
    else
        tmux("new-session -ds " .. vim.fn.shellescape(name) .. " -c " .. vim.fn.shellescape(path))
        tmux("switch-client -t " .. vim.fn.shellescape(name))
    end
end

-- ── slot switching ───────────────────────────────────────────────────────────

local function switch_slot(index)
    if not in_tmux() then
        vim.notify("Not in tmux", vim.log.levels.WARN)
        return
    end
    local sessions = ordered_sessions()
    local target = sessions[index]
    if not target then
        vim.notify("tmux: no session in slot " .. index, vim.log.levels.WARN)
        return
    end
    tmux("switch-client -t " .. vim.fn.shellescape(target))
end

-- j/k/l/; = slots 1-4, J/K/L/: = slots 5-8
-- In zsh + most terminals, <M-X> sends ESC+X (\eX).
for i, key in ipairs({ "j", "k", "l", ";", "u", "i", "o", "p" }) do
    vim.keymap.set("n", "<M-" .. key .. ">", function()
        switch_slot(i)
    end, { desc = "Tmux slot " .. i, noremap = true })
end
-- ── sessionizer ──────────────────────────────────────────────────────────────
vim.keymap.set("n", "<C-f>", function()
    if not in_tmux() then
        vim.notify("Not in tmux", vim.log.levels.WARN)
        return
    end

    local scan = require("plenary.scandir")
    local cwd = vim.fn.getcwd()
    local home_projects = vim.fn.expand("~/projects")

    local dirs = {}
    local seen = {}

    local function add(d)
        if not seen[d] then
            seen[d] = true
            table.insert(dirs, d)
        end
    end

    add(cwd)

    -- scan ~/projects one level deep for project roots
    if vim.fn.isdirectory(home_projects) == 1 then
        for _, d in ipairs(scan.scan_dir(home_projects, { depth = 1, only_dirs = true, silent = true })) do
            add(d)
        end
    end

    -- scan cwd fully for nested dirs
    for _, d in ipairs(scan.scan_dir(cwd, { only_dirs = true, silent = true })) do
        add(d)
    end

    require("telescope.pickers")
        .new({}, {
            prompt_title = "Tmux Sessionizer",
            finder = require("telescope.finders").new_table({
                results = dirs,
                entry_maker = function(entry)
                    return {
                        value = entry,
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
                    if sel then
                        sessionize(sel.value)
                    end
                end)
                return true
            end,
        })
        :find()
end, { desc = "Tmux sessionizer" }) -- ── session editor ───────────────────────────────────────────────────────────

vim.keymap.set("n", "<leader>ts", function()
    if not in_tmux() then
        return
    end
    local sessions = ordered_sessions()
    local current_session = vim.trim(vim.fn.system("tmux display-message -p '#S'"))

    vim.notify(table.concat(sessions, ", "), vim.log.levels.INFO)
    scratchbuf.open({
        title = "Tmux Sessions",
        lines = ordered_sessions(),
        refresh = ordered_sessions,
        current = current_session, -- <-- add this

        on_open = function(entry)
            tmux("switch-client -t " .. vim.fn.shellescape(entry))
        end,

        on_save = function(changes)
            for _, r in ipairs(changes.renamed) do
                tmux("rename-session -t " .. vim.fn.shellescape(r.old) .. " " .. vim.fn.shellescape(r.new))
            end
            for _, d in ipairs(changes.deleted) do
                tmux("kill-session -t " .. vim.fn.shellescape(d))
            end
            for _, c in ipairs(changes.created) do
                local path = vim.fn.input("Path for [" .. c .. "]: ", vim.fn.getcwd(), "dir")
                if path and path ~= "" then
                    tmux("new-session -ds " .. vim.fn.shellescape(c) .. " -c " .. vim.fn.shellescape(path))
                end
            end

            -- build final order directly from buffer lines, applying renames
            local rename_map = {}
            for _, r in ipairs(changes.renamed) do
                rename_map[r.old] = r.new
            end

            local deleted_set = {}
            for _, d in ipairs(changes.deleted) do
                deleted_set[d] = true
            end

            local final = {}
            for _, s in ipairs(changes.order) do
                if not deleted_set[s] then
                    table.insert(final, rename_map[s] or s)
                end
            end
            for _, c in ipairs(changes.created) do
                local already = false
                for _, s in ipairs(final) do
                    if s == c then
                        already = true
                        break
                    end
                end
                if not already then
                    table.insert(final, c)
                end
            end

            save_order(final)
        end,
    })
end, { desc = "Tmux sessions (edit)" })

vim.keymap.set("n", "<leader>tS", function()
    if not in_tmux() then
        return
    end
    local all = vim.fn.systemlist("tmux list-sessions -F '#S' 2>/dev/null")
    if vim.v.shell_error ~= 0 or #all == 0 then
        vim.notify("tmux: no sessions", vim.log.levels.WARN)
        return
    end
    scratchbuf.open({
        title = "All Tmux Sessions (incl. air)",
        lines = all,
        refresh = function()
            return vim.fn.systemlist("tmux list-sessions -F '#S' 2>/dev/null")
        end,
        on_open = function(entry)
            tmux("switch-client -t " .. vim.fn.shellescape(entry))
        end,
        on_save = function() end, -- read-only, no save logic
    })
end, { desc = "Tmux: all sessions (debug)" })

-- ── rename ───────────────────────────────────────────────────────────────────

vim.keymap.set("n", "<leader>tr", function()
    if not in_tmux() then
        return
    end
    local current = vim.trim(vim.fn.system("tmux display-message -p '#S'"))
    local name = vim.fn.input("Rename session [" .. current .. "]: ")
    if name and name ~= "" then
        tmux("rename-session " .. vim.fn.shellescape(name))
        -- patch slot file so the renamed session keeps its slot
        local slots = load_order()
        for i, s in ipairs(slots) do
            if s == current then
                slots[i] = name
                break
            end
        end
        save_order(slots)
        vim.notify("Session renamed to: " .. name)
    end
end, { desc = "Tmux rename session" })

-- ── splits ───────────────────────────────────────────────────────────────────

vim.keymap.set("n", "<leader>t|", function()
    if not in_tmux() then
        return
    end
    tmux("split-window -h -c " .. vim.fn.shellescape(vim.fn.getcwd()))
end, { desc = "Tmux vertical split" })

vim.keymap.set("n", "<leader>t-", function()
    if not in_tmux() then
        return
    end
    tmux("split-window -v -c " .. vim.fn.shellescape(vim.fn.getcwd()))
end, { desc = "Tmux horizontal split" })
