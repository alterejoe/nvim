-- lua/browser.lua
--
-- Console and network pickers backed by devproxy's chromedp capture.

local M = {}

local SOCKET      = "/tmp/devproxy.sock"
local STATIC_ROOT = "/home/jmeyer/projects/portal/static"

local function send(cmd)
  if vim.fn.filereadable(SOCKET) == 0 then
    vim.notify("browser: devproxy not running", vim.log.levels.WARN)
    return nil
  end
  return vim.trim(vim.fn.system(
    "echo " .. vim.fn.shellescape(cmd) ..
    " | socat -t 5 - UNIX-CONNECT:" .. SOCKET .. " 2>/dev/null"
  ))
end

local function is_empty(raw)
  return not raw or raw == "" or raw == "[]" or raw == "null"
end

local function resolve_url(url)
  if not url or url == "" then return nil end
  url = url:gsub("%?.*", ""):gsub("#.*", "")
  local rel = url:match("/static/(.*)")
  if rel then return STATIC_ROOT .. "/" .. rel end
  local fpath = url:match("^file://(.*)")
  if fpath then return fpath end
  return nil
end

local function detect_filetype(req)
  local ct = (req.res_headers or {})["Content-Type"]
              or (req.res_headers or {})["content-type"]
              or ""
  ct = ct:lower()
  if ct:find("json")       then return "json" end
  if ct:find("html")       then return "html" end
  if ct:find("xml")        then return "xml" end
  if ct:find("css")        then return "css" end
  if ct:find("javascript") then return "javascript" end
  return "text"
end

local _log_bufs = {}

local function get_or_create_log_buf(name, filetype)
  local existing = _log_bufs[name]
  if existing and vim.api.nvim_buf_is_valid(existing) then
    return existing
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].filetype  = filetype or "text"
  vim.bo[buf].bufhidden = "hide"
  _log_bufs[name] = buf
  return buf
end

local function sanitize_lines(lines)
  local out = {}
  for _, line in ipairs(lines) do
    for _, l in ipairs(vim.split(line:gsub("\r", ""), "\n", { plain = true })) do
      table.insert(out, l)
    end
  end
  return out
end

local function update_log_buf(name, lines, filetype)
  local buf = get_or_create_log_buf(name, filetype)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, sanitize_lines(lines))
  vim.bo[buf].modifiable = false
  return buf
end

local function open_buf_in_split(buf)
  local wins = vim.fn.win_findbuf(buf)
  if #wins > 0 then
    vim.api.nvim_set_current_win(wins[1])
  else
    vim.cmd("vsplit")
    vim.api.nvim_win_set_buf(0, buf)
  end
end

local function jump_to_line_in_buf(buf, lnum)
  local wins = vim.fn.win_findbuf(buf)
  local win
  if #wins > 0 then
    win = wins[1]
  else
    vim.cmd("vsplit")
    vim.api.nvim_win_set_buf(0, buf)
    win = vim.api.nvim_get_current_win()
  end
  local line_count = vim.api.nvim_buf_line_count(buf)
  lnum = math.max(1, math.min(lnum, line_count))
  vim.api.nvim_win_set_cursor(win, { lnum, 0 })
end

-- 컴 console 컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴�
local level_icons = {
  log     = "[log]  ",
  info    = "[info] ",
  warn    = "[warn] ",
  warning = "[warn] ",
  error   = "[err]  ",
  dir     = "[dir]  ",
  table   = "[tbl]  ",
}

local function console_entries()
  local raw = send("consolelog")
  if is_empty(raw) then return nil end
  local ok, entries = pcall(vim.json.decode, raw)
  if not ok or type(entries) ~= "table" or #entries == 0 then return nil end
  local reversed = {}
  for i = #entries, 1, -1 do table.insert(reversed, entries[i]) end
  return reversed
end

local function build_console_lines(entries)
  local lines = {}
  for _, e in ipairs(entries) do
    local icon = level_icons[e.level] or "       "
    local loc  = ""
    if e.url and e.url ~= "" then
      local path = e.url:match("/([^/]+)$") or e.url
      loc = "  " .. path .. ":" .. (e.line or 0)
    end
    table.insert(lines, string.format("%s%s%s", icon, e.text or "", loc))
  end
  return lines
end

function M.show_console_log()
  local entries = console_entries()
  if not entries then
    vim.notify("browser: no console entries yet", vim.log.levels.WARN)
    return
  end
  local lines = build_console_lines(entries)
  local buf = update_log_buf("console-log", lines, "text")
  open_buf_in_split(buf)
end

function M.pick_console()
  local entries = console_entries()
  if not entries then
    vim.notify("browser: no console entries yet", vim.log.levels.WARN)
    return
  end

  local lines = build_console_lines(entries)
  local log_buf = update_log_buf("console-log", lines, "text")

  local pickers      = require("telescope.pickers")
  local finders      = require("telescope.finders")
  local conf         = require("telescope.config").values
  local actions      = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  -- build indexed results so we can jump to the right line
  local indexed = {}
  for i, e in ipairs(entries) do
    table.insert(indexed, { entry = e, idx = i })
  end

  pickers.new({}, {
    prompt_title = "Browser Console  [CR=jump to log  o=open source file  x=clear]",
    finder = finders.new_table({
      results = indexed,
      entry_maker = function(item)
        local e    = item.entry
        local icon = level_icons[e.level] or "       "
        local loc  = ""
        if e.url and e.url ~= "" then
          local path = e.url:match("/([^/]+)$") or e.url
          loc = "  " .. path .. ":" .. (e.line or 0)
        end
        local display = string.format("%s%s%s", icon, e.text or "", loc)
        return { value = item, display = display, ordinal = display }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local sel = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if not sel then return end
        jump_to_line_in_buf(log_buf, sel.value.idx)
      end)
      map("n", "o", function()
        local sel = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if not sel then return end
        local e    = sel.value.entry
        local path = resolve_url(e.url)
        if path and vim.fn.filereadable(path) == 1 then
          vim.cmd("edit " .. vim.fn.fnameescape(path))
          if e.line then
            vim.api.nvim_win_set_cursor(0, { e.line + 1, e.col or 0 })
          end
        else
          vim.notify("browser: cannot resolve: " .. (e.url or "?"), vim.log.levels.WARN)
        end
      end)
      map("n", "x", function()
        actions.close(prompt_bufnr)
        M.clear_console()
      end)
      return true
    end,
  }):find()
end

function M.clear_console()
  local r = send("consoleclear")
  local buf = _log_bufs["console-log"]
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    vim.bo[buf].modifiable = false
  end
  vim.notify(r or "browser: consoleclear failed")
end

-- 컴 network 컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴�
local function net_entries()
  local raw = send("netlog")
  if is_empty(raw) then return nil end
  local ok, entries = pcall(vim.json.decode, raw)
  if not ok or type(entries) ~= "table" or #entries == 0 then return nil end
  local reversed = {}
  for i = #entries, 1, -1 do table.insert(reversed, entries[i]) end
  return reversed
end

local function req_to_lines(req)
  local lines = {}
  table.insert(lines, string.format("%-8s %s", req.method or "?", req.url or "?"))
  table.insert(lines, string.format("Status: %s", tostring(req.status or "?")))
  table.insert(lines, "")
  table.insert(lines, "--- Request Headers ---")
  for k, v in pairs(req.req_headers or {}) do
    table.insert(lines, string.format("  %s: %s", k, v))
  end
  table.insert(lines, "")
  table.insert(lines, "--- Response Headers ---")
  for k, v in pairs(req.res_headers or {}) do
    table.insert(lines, string.format("  %s: %s", k, v))
  end
  if req.res_body and req.res_body ~= "" then
    table.insert(lines, "")
    table.insert(lines, "--- Response Body ---")
    for _, l in ipairs(vim.split(req.res_body, "\n")) do
      table.insert(lines, l)
    end
  end
  return lines
end

local function build_net_log_lines(entries)
  local lines = {}
  local entry_start_lines = {}
  for i, req in ipairs(entries) do
    local url      = req.url or "?"
    local path     = url:match("https?://[^/]+(/.*)") or url
    local status   = tostring(req.status or "?")
    local has_body = req.res_body and req.res_body ~= "" and " [body]" or ""
    local hx       = (req.req_headers or {})["HX-Request"]
    local hx_label = (hx and hx ~= "") and " [htmx]" or ""
    entry_start_lines[i] = #lines + 1
    table.insert(lines, string.format("[%s] %-6s %s%s%s", status, req.method or "?", path, has_body, hx_label))
    table.insert(lines, string.format("  url: %s", url))
    for k, v in pairs(req.req_headers or {}) do
      table.insert(lines, string.format("  req> %s: %s", k, v))
    end
    for k, v in pairs(req.res_headers or {}) do
      table.insert(lines, string.format("  res> %s: %s", k, v))
    end
    if req.res_body and req.res_body ~= "" then
      table.insert(lines, "  body:")
      for _, l in ipairs(vim.split(req.res_body, "\n")) do
        table.insert(lines, "    " .. l)
      end
    end
    table.insert(lines, "")
  end
  return lines, entry_start_lines
end

function M.pick_network()
  local entries = net_entries()
  if not entries then
    vim.notify("browser: no network entries yet", vim.log.levels.WARN)
    return
  end

  local log_lines, entry_start_lines = build_net_log_lines(entries)
  local log_buf = update_log_buf("network-log", log_lines, "text")

  local pickers      = require("telescope.pickers")
  local finders      = require("telescope.finders")
  local conf         = require("telescope.config").values
  local actions      = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local indexed = {}
  for i, req in ipairs(entries) do
    table.insert(indexed, { req = req, idx = i })
  end

  pickers.new({}, {
    prompt_title = "Browser Network  [CR=jump to log  t=body  x=clear]",
    finder = finders.new_table({
      results = indexed,
      entry_maker = function(item)
        local req      = item.req
        local status   = tostring(req.status or "?")
        local url      = req.url or "?"
        local path     = url:match("https?://[^/]+(/.*)") or url
        local has_body = req.res_body and req.res_body ~= "" and " [body]" or ""
        local hx       = (req.req_headers or {})["HX-Request"]
        local hx_label = (hx and hx ~= "") and " [htmx]" or ""
        local display  = string.format("[%s] %-6s %s%s%s", status, req.method or "?", path, has_body, hx_label)
        return { value = item, display = display, ordinal = display }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local sel = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if not sel then return end
        local lnum = entry_start_lines[sel.value.idx] or 1
        jump_to_line_in_buf(log_buf, lnum)
      end)
      map("n", "t", function()
        local sel = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if not sel then return end
        local req = sel.value.req
        if not req.res_body or req.res_body == "" then
          vim.notify("browser: no response body for this request", vim.log.levels.WARN)
          return
        end
        local ft    = detect_filetype(req)
        local url   = req.url or "?"
        local fname = url:match("([^/?]+)/?$") or "body"
        local title = string.format("response-%s.%s", fname, ft)
        local body  = req.res_body
        if ft == "json" then
          local ok2, decoded = pcall(vim.json.decode, body)
          if ok2 then
            local pretty = vim.fn.system("echo " .. vim.fn.shellescape(vim.fn.json_encode(decoded)) .. " | python3 -m json.tool 2>/dev/null")
            if vim.v.shell_error == 0 and pretty ~= "" then body = pretty end
          end
        end
        local buf = update_log_buf(title, vim.split(body, "\n"), ft)
        open_buf_in_split(buf)
      end)
      map("n", "x", function()
        actions.close(prompt_bufnr)
        M.clear_network()
      end)
      return true
    end,
  }):find()
end

function M.show_network_log()
  local entries = net_entries()
  if not entries then
    vim.notify("browser: no network entries yet", vim.log.levels.WARN)
    return
  end
  local lines, _ = build_net_log_lines(entries)
  local buf = update_log_buf("network-log", lines, "text")
  open_buf_in_split(buf)
end

function M.clear_network()
  local r = send("netclear")
  local buf = _log_bufs["network-log"]
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    vim.bo[buf].modifiable = false
  end
  vim.notify(r or "browser: netclear failed")
end

-- 컴 dom dump 컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴
function M.dom_dump()
  local raw = send("dom-dump")
  if not raw or raw == "" or vim.startswith(raw, "err:") then
    vim.notify("browser: " .. (raw or "no response"), vim.log.levels.WARN)
    return
  end
  -- try prettier first, fallback to raw
  local formatted = raw
  local prettier = vim.fn.system("which prettier 2>/dev/null")
  if vim.v.shell_error == 0 and prettier ~= "" then
    local result = vim.fn.system("echo " .. vim.fn.shellescape(raw) .. " | prettier --parser html 2>/dev/null")
    if vim.v.shell_error == 0 and result ~= "" then
      formatted = result
    end
  end
  local buf = update_log_buf("dom-dump.html", vim.split(formatted, "\n"), "html")
  open_buf_in_split(buf)
end

-- 컴 compat 컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴컴
function M.start()
  vim.notify("browser: CDP is handled by devproxy automatically", vim.log.levels.INFO)
end

function M.stop() end

return M
