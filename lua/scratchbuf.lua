--[[
  scratchbuf.lua
  Generic oil.nvim-style editable list buffer.

  opts:
    title    string        Window title
    lines    string[]      Initial entries
    refresh  fn()          Returns fresh string[] after save
    on_open  fn(entry)     Called on <CR> — switch, checkout, attach, etc
    on_save  fn(changes)   Called on W
      changes.renamed = { { old, new } }
      changes.deleted = { entry, ... }
      changes.created = { entry, ... }

  Keymaps (inside buffer):
    <CR>   open entry (on_open)
    W      save changes (on_save)
    o      new line below
    O      new line above
    dd     delete line
    /      fuzzy filter entries
    r      refresh from source
    q      close
    <Esc>  close (normal mode only)
--]]

local M = {}

local function diff(original, current)
    local orig_idx = {}
    for i, v in ipairs(original) do
        orig_idx[v] = i
    end

    local curr_idx = {}
    for i, v in ipairs(current) do
        curr_idx[v] = i
    end

    local renamed, deleted, created = {}, {}, {}

    for i, orig in ipairs(original) do
        if not curr_idx[orig] then
            local curr = current[i]
            if curr and curr ~= "" and not orig_idx[curr] then
                table.insert(renamed, { old = orig, new = curr })
            else
                table.insert(deleted, orig)
            end
        end
    end

    for i, curr in ipairs(current) do
        if curr ~= "" and not orig_idx[curr] then
            local orig = original[i]
            if not orig then
                table.insert(created, curr)
            end
        end
    end

    return { renamed = renamed, deleted = deleted, created = created }
end

local function get_lines(buf)
    local result = {}
    for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        local t = vim.trim(l)
        if t ~= "" then table.insert(result, t) end
    end
    return result
end

local function open_float(buf, title, line_count)
    local width  = math.floor(vim.o.columns * 0.5)
    local height = math.min(math.max(line_count + 2, 5), math.floor(vim.o.lines * 0.6))
    local row    = math.floor((vim.o.lines - height) / 2)
    local col    = math.floor((vim.o.columns - width) / 2)

    return vim.api.nvim_open_win(buf, true, {
        relative  = "editor",
        width     = width,
        height    = height,
        row       = row,
        col       = col,
        style     = "minimal",
        border    = "rounded",
        title     = " " .. title .. " ",
        title_pos = "center",
    })
end

local function set_win_opts(win)
    vim.wo[win].cursorline = true
    vim.wo[win].number     = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].wrap       = false
end

-- simple fuzzy filter: show only lines matching input
local function fuzzy_filter(buf, original_lines)
    local input = vim.fn.input("Filter: ")
    if input == "" then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, original_lines)
        return
    end
    local pattern = input:lower()
    local filtered = vim.tbl_filter(function(l)
        return l:lower():find(pattern, 1, true) ~= nil
    end, original_lines)
    if #filtered == 0 then
        vim.notify("scratchbuf: no matches for '" .. input .. "'", vim.log.levels.WARN)
        return
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, filtered)
end

function M.open(opts)
    assert(opts.title,   "scratchbuf: title required")
    assert(opts.lines,   "scratchbuf: lines required")
    assert(opts.on_save, "scratchbuf: on_save required")

    local original = vim.deepcopy(opts.lines)

    -- reuse if already open
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local b = vim.api.nvim_win_get_buf(win)
        if vim.b[b]._scratchbuf == opts.title then
            vim.api.nvim_set_current_win(win)
            return
        end
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.b[buf]._scratchbuf = opts.title

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines)

    vim.bo[buf].buftype   = "acwrite"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile  = false
    vim.bo[buf].filetype  = opts.filetype or "scratchbuf"
    vim.bo[buf].modified  = false

    local win = open_float(buf, opts.title, #opts.lines)
    set_win_opts(win)

    local function map(lhs, rhs, desc, mode)
        vim.keymap.set(mode or "n", lhs, rhs, { buffer = buf, nowait = true, desc = desc })
    end

    -- close
    map("q",     "<cmd>bwipeout!<CR>", "Close")
    map("<Esc>", "<cmd>bwipeout!<CR>", "Close")

    -- open entry
    map("<CR>", function()
        if not opts.on_open then return end
        local line = vim.trim(vim.api.nvim_get_current_line())
        if line ~= "" then
            vim.cmd("bwipeout!")
            opts.on_open(line)
        end
    end, "Open entry")

    -- new line below / above
    map("o", function()
        local lnum = vim.api.nvim_win_get_cursor(win)[1]
        vim.api.nvim_buf_set_lines(buf, lnum, lnum, false, { "" })
        vim.api.nvim_win_set_cursor(win, { lnum + 1, 0 })
        vim.cmd("startinsert")
    end, "New entry below")

    map("O", function()
        local lnum = vim.api.nvim_win_get_cursor(win)[1]
        vim.api.nvim_buf_set_lines(buf, lnum - 1, lnum - 1, false, { "" })
        vim.api.nvim_win_set_cursor(win, { lnum, 0 })
        vim.cmd("startinsert")
    end, "New entry above")

    -- delete line
    map("dd", function()
        local lnum = vim.api.nvim_win_get_cursor(win)[1]
        local line = vim.trim(vim.api.nvim_get_current_line())
        if line ~= "" then
            vim.api.nvim_buf_set_lines(buf, lnum - 1, lnum, false, {})
            vim.bo[buf].modified = true
        end
    end, "Delete entry")

    -- fuzzy filter
    map("/", function()
        fuzzy_filter(buf, original)
    end, "Fuzzy filter")

    -- refresh
    map("r", function()
        if opts.refresh then
            local fresh = opts.refresh()
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, fresh)
            original = vim.deepcopy(fresh)
            vim.bo[buf].modified = false
            vim.notify("scratchbuf: refreshed", vim.log.levels.INFO)
        end
    end, "Refresh")

    -- save
    map("W", function()
        vim.api.nvim_exec_autocmds("BufWriteCmd", { buffer = buf })
    end, "Save")

    -- BufWriteCmd handler
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        callback = function()
            local current = get_lines(buf)
            local changes = diff(original, current)
            local ok, err = pcall(opts.on_save, changes)
            if ok then
                vim.bo[buf].modified = false
                local parts = {}
                if #changes.renamed > 0 then
                    table.insert(parts, #changes.renamed .. " renamed")
                end
                if #changes.deleted > 0 then
                    table.insert(parts, #changes.deleted .. " deleted")
                end
                if #changes.created > 0 then
                    table.insert(parts, #changes.created .. " created")
                end
                local msg = #parts > 0 and table.concat(parts, ", ") or "no changes"
                vim.notify("[" .. opts.title .. "] " .. msg, vim.log.levels.INFO)

                if opts.refresh then
                    local fresh = opts.refresh()
                    vim.api.nvim_buf_set_lines(buf, 0, -1, false, fresh)
                    original = vim.deepcopy(fresh)
                end
            else
                vim.notify("[" .. opts.title .. "] save failed: " .. tostring(err), vim.log.levels.ERROR)
            end
        end,
    })

    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = buf,
        once   = true,
        callback = function()
            if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
                vim.notify("[" .. opts.title .. "] discarded unsaved changes", vim.log.levels.WARN)
            end
        end,
    })
end

return M
