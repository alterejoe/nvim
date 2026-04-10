--[[
  scratchbuf.lua
  Generic oil.nvim-style editable list buffer.

  opts:
    title    string        Window title
    lines    string[]      Initial entries
    refresh  fn()          Returns fresh string[]
    on_open  fn(entry)     Called on <CR>
    on_save  fn(changes)   Called on W
      changes.renamed   = { { old, new }, ... }
      changes.deleted   = { entry, ... }
      changes.created   = { entry, ... }
      changes.reordered = bool
      changes.order     = { entry, ... }  -- full current line order

  Keymaps (inside buffer):
    <CR>  open entry (on_open)
    W     save changes (on_save)
    o     new entry below
    O     new entry above
    dd    cut line into scratch register
    p     paste scratch register below cursor
    P     paste scratch register above cursor
    /     fuzzy filter
    r     refresh list
    q     close
    <Esc> close
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

    local reordered = false
    if #original == #current then
        local all_present = true
        for _, v in ipairs(original) do
            if not curr_idx[v] then
                all_present = false
                break
            end
        end
        if all_present then
            for i, v in ipairs(original) do
                if current[i] ~= v then
                    reordered = true
                    break
                end
            end
        end
    end

    return {
        renamed = renamed,
        deleted = deleted,
        created = created,
        reordered = reordered,
        order = current,
    }
end

local function fuzzy_filter(buf, win, lines)
    local ns = vim.api.nvim_create_namespace("scratchbuf_filter")
    local query = ""

    local function apply(q)
        local filtered = {}
        for _, l in ipairs(lines) do
            if q == "" or l:lower():find(q:lower(), 1, true) then
                table.insert(filtered, l)
            end
        end
        if #filtered == 0 then
            filtered = lines
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, filtered)
        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
            virt_text = { { "  /" .. q .. "▋", "Comment" } },
            virt_text_pos = "eol",
        })
        vim.api.nvim_win_set_cursor(win, { 1, 0 })
        vim.cmd("redraw")
        return filtered
    end

    local filtered = apply("")

    local function loop()
        while true do
            local ok, ch = pcall(vim.fn.getcharstr)
            if not ok then
                break
            end

            if ch == "\27" then -- Esc — cancel
                vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
                vim.cmd("redraw")
                break
            elseif ch == "\r" then -- CR — accept
                vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
                vim.cmd("redraw")
                break
                -- elseif ch ~= "\r" and ch ~= "\27" then
            elseif ch == "\8" or ch == "\127" or ch == "\x80\xfd-" or ch == "\x80kb" then -- BS
                -- vim.notify(string.format("key: %q len:%d byte:%d", ch, #ch, ch:byte(1)), vim.log.levels.INFO)
                if #query > 0 then
                    query = query:sub(1, -2)
                    filtered = apply(query)
                end
            elseif ch == "\14" or ch == "j" then -- ctrl-n or j — down
                local row = vim.api.nvim_win_get_cursor(win)[1]
                local total = vim.api.nvim_buf_line_count(buf)
                if row < total then
                    vim.api.nvim_win_set_cursor(win, { row + 1, 0 })
                    vim.cmd("redraw")
                end
            elseif ch == "\16" or ch == "k" then -- ctrl-p or k — up
                local row = vim.api.nvim_win_get_cursor(win)[1]
                if row > 1 then
                    vim.api.nvim_win_set_cursor(win, { row - 1, 0 })
                    vim.cmd("redraw")
                end
            elseif #ch == 1 and ch:byte() >= 32 then -- printable
                query = query .. ch
                filtered = apply(query)
            end
        end
    end

    loop()
end

local function get_lines(buf)
    local result = {}
    for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        local t = vim.trim(l)
        if t ~= "" then
            table.insert(result, t)
        end
    end
    return result
end

local function open_float(buf, title, line_count)
    local width = math.floor(vim.o.columns * 0.5)
    local height = math.min(math.max(line_count + 2, 5), math.floor(vim.o.lines * 0.6))
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    return vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = "rounded",
        title = " " .. title .. " ",
        title_pos = "center",
    })
end

local function set_win_opts(win)
    vim.wo[win].cursorline = true
    vim.wo[win].number = true
    vim.wo[win].signcolumn = "no"
    vim.wo[win].wrap = false
end

function M.open(opts)
    assert(opts.title, "scratchbuf: title required")
    assert(opts.lines, "scratchbuf: lines required")
    assert(opts.on_save, "scratchbuf: on_save required")

    local original = vim.deepcopy(opts.lines)

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

    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = opts.filetype or "scratchbuf"
    vim.bo[buf].modified = false

    local win = open_float(buf, opts.title, #opts.lines)
    set_win_opts(win)

    if opts.current then
        local hl_ns = vim.api.nvim_create_namespace("scratchbuf_current")
        for i, line in ipairs(opts.lines) do
            if vim.trim(line) == opts.current then
                vim.api.nvim_buf_add_highlight(buf, hl_ns, "CursorLine", i - 1, 0, -1)
                -- also position cursor on it
                vim.api.nvim_win_set_cursor(win, { i, 0 })
                break
            end
        end
    end

    local scratch_reg = nil

    -- noremap = true on everything so default operators never race
    local function map(lhs, rhs, desc, mode)
        vim.keymap.set(mode or "n", lhs, rhs, {
            buffer = buf,
            nowait = true,
            noremap = true,
            desc = desc,
        })
    end

    map("q", "<cmd>bwipeout!<CR>", "Close")
    map("<Esc>", "<cmd>bwipeout!<CR>", "Close")

    map("<CR>", function()
        if not opts.on_open then
            return
        end
        local line = vim.trim(vim.api.nvim_get_current_line())
        if line == "" then
            return
        end
        -- defer wipeout so it doesn't race with the current keymap handler
        vim.schedule(function()
            if vim.api.nvim_buf_is_valid(buf) then
                vim.api.nvim_buf_delete(buf, { force = true })
            end
            opts.on_open(line)
        end)
    end, "Open entry")

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

    -- block the d operator entirely so dd is unambiguous
    map("d", "<Nop>", "Block d operator")

    map("dd", function()
        local lnum = vim.api.nvim_win_get_cursor(win)[1]
        -- read via buf_get_lines, not get_current_line, to avoid timing issues
        local lines = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)
        local line = vim.trim(lines[1] or "")
        if line == "" then
            return
        end
        scratch_reg = line
        vim.api.nvim_buf_set_lines(buf, lnum - 1, lnum, false, {})
        vim.bo[buf].modified = true
        local total = vim.api.nvim_buf_line_count(buf)
        local new_row = math.min(lnum, math.max(total, 1))
        if total > 0 then
            vim.api.nvim_win_set_cursor(win, { new_row, 0 })
        end
        vim.notify("cut: " .. line, vim.log.levels.INFO)
    end, "Cut entry")

    map("p", function()
        if not scratch_reg then
            vim.notify("scratchbuf: register empty", vim.log.levels.WARN)
            return
        end
        local lnum = vim.api.nvim_win_get_cursor(win)[1]
        vim.api.nvim_buf_set_lines(buf, lnum, lnum, false, { scratch_reg })
        vim.bo[buf].modified = true
        vim.api.nvim_win_set_cursor(win, { lnum + 1, 0 })
    end, "Paste below")

    map("P", function()
        if not scratch_reg then
            vim.notify("scratchbuf: register empty", vim.log.levels.WARN)
            return
        end
        local lnum = vim.api.nvim_win_get_cursor(win)[1]
        vim.api.nvim_buf_set_lines(buf, lnum - 1, lnum - 1, false, { scratch_reg })
        vim.bo[buf].modified = true
        vim.api.nvim_win_set_cursor(win, { lnum, 0 })
    end, "Paste above")

    map("/", function()
        fuzzy_filter(buf, win, get_lines(buf))
    end, "Fuzzy filter")

    map("r", function()
        if opts.refresh then
            local fresh = opts.refresh()
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, fresh)
            original = vim.deepcopy(fresh)
            scratch_reg = nil
            vim.bo[buf].modified = false
            vim.notify("scratchbuf: refreshed", vim.log.levels.INFO)
        end
    end, "Refresh")

    map("W", function()
        vim.api.nvim_exec_autocmds("BufWriteCmd", { buffer = buf })
    end, "Save")

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
                if changes.reordered then
                    table.insert(parts, "reordered")
                end
                vim.notify(
                    "[" .. opts.title .. "] " .. (#parts > 0 and table.concat(parts, ", ") or "no changes"),
                    vim.log.levels.INFO
                )
                if opts.refresh then
                    local fresh = opts.refresh()
                    vim.api.nvim_buf_set_lines(buf, 0, -1, false, fresh)
                    original = vim.deepcopy(fresh)
                    scratch_reg = nil
                end
            else
                vim.notify("[" .. opts.title .. "] save failed: " .. tostring(err), vim.log.levels.ERROR)
            end
        end,
    })

    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = buf,
        once = true,
        callback = function()
            if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
                vim.notify("[" .. opts.title .. "] unsaved changes discarded", vim.log.levels.WARN)
            end
        end,
    })
end

return M
