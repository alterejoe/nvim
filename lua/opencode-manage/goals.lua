-- /home/altjoe/.config/nvim/lua/opencode-manage/goals.lua FINAL-7
-- Thin Nvim client for the Go manage daemon work-item API.
-- Nvim is the user mutation surface; it does not own a second SQLite model.
local M = {}

local socket = vim.fn.expand("~/.local/share/opencode-manage/manage.sock")
local binary = vim.env.MANAGE_BIN or vim.fn.expand("~/projects/opencode-manage/bin/manage")
local base_url = "http://localhost"

local function ensure_daemon()
  if vim.fn.filereadable(socket) == 1 then
    return true
  end
  vim.fn.jobstart({ binary }, { detach = true, stdio = "ignore" })
  vim.wait(3000, function()
    return vim.fn.filereadable(socket) == 1
  end, 20)
  return vim.fn.filereadable(socket) == 1
end

local function request(method, path, body)
  if not ensure_daemon() then
    return nil, "manage daemon is unavailable"
  end

  local args = {
    "curl",
    "--silent",
    "--show-error",
    "--fail-with-body",
    "--unix-socket",
    socket,
    "-X",
    method,
    base_url .. path,
  }
  if body ~= nil then
    table.insert(args, "--header")
    table.insert(args, "Content-Type: application/json")
    table.insert(args, "--data-raw")
    table.insert(args, vim.json.encode(body))
  end

  local result = vim.system(args, { text = true }):wait()
  if result.code ~= 0 then
    return nil, result.stderr ~= "" and result.stderr or "daemon request failed"
  end
  if result.stdout == "" then
    return {}, nil
  end
  local ok, decoded = pcall(vim.json.decode, result.stdout)
  if not ok then
    return nil, "daemon returned invalid JSON"
  end
  return decoded, nil
end

local function directory_query()
  return vim.uri_encode(vim.fn.getcwd(), true)
end

local function apply(action, item_id, payload)
  local suggestion, err = request("POST", "/v1/work-items/suggest", {
    directory = vim.fn.getcwd(),
    session_id = "nvim",
    item_id = item_id,
    action = action,
    payload = payload or {},
    rationale = "User action from the Goals/Milestones panel",
  })
  if not suggestion then
    return nil, err
  end
  local suggestion_id = suggestion.id or (suggestion.suggestion and suggestion.suggestion.id)
  if not suggestion_id then
    return nil, "daemon did not return a suggestion id"
  end
  local applied, apply_err = request(
    "POST",
    "/v1/work-items/suggestions/" .. tostring(suggestion_id) .. "/apply",
    { directory = vim.fn.getcwd(), applied_by = "nvim" }
  )
  if not applied then
    return nil, apply_err
  end
  return applied, nil
end

local function notify_error(err)
  if err then
    vim.notify("[manage] " .. err, vim.log.levels.ERROR)
  end
end

function M.list()
  local data, err = request("GET", "/v1/work-items?directory=" .. directory_query())
  if not data then
    notify_error(err)
    return {}
  end
  return type(data.items) == "table" and data.items or {}
end

function M.active_id()
  local data, err = request("GET", "/v1/work-items?directory=" .. directory_query())
  if not data then
    notify_error(err)
    return nil
  end
  return type(data.active_id) == "number" and data.active_id or nil
end

function M.suggestions()
  local data, err = request(
    "GET",
    "/v1/work-items/suggestions?directory=" .. directory_query() .. "&status=pending"
  )
  if not data then
    notify_error(err)
    return {}
  end
  if type(data) ~= "table" then
    return {}
  end
  local suggestions = type(data.suggestions) == "table" and data.suggestions or data
  return type(suggestions) == "table" and suggestions or {}
end

function M.accept_suggestion(id)
  local data, err = request(
    "POST",
    "/v1/work-items/suggestions/" .. tostring(id) .. "/apply",
    { directory = vim.fn.getcwd(), applied_by = "nvim" }
  )
  return data ~= nil, err
end

function M.reject_suggestion(id, reason)
  local data, err = request(
    "POST",
    "/v1/work-items/suggestions/" .. tostring(id) .. "/reject",
    { directory = vim.fn.getcwd(), applied_by = "nvim", reason = reason or "" }
  )
  return data ~= nil, err
end

function M.create(kind, name, description, parent_id)
  local data, err = apply("create", nil, {
    kind = kind,
    name = name,
    description = description or "",
    parent_id = parent_id,
  })
  if not data then
    return nil, err
  end
  return data.id or (data.item and data.item.id), nil
end

function M.update(id, name, description)
  local data, err = apply("update", id, {
    name = name,
    description = description or "",
  })
  return data ~= nil, err
end

function M.set_status(id, status, reason)
  local data, err = apply("set_status", id, {
    status = status,
    reason = reason or "",
  })
  return data ~= nil, err
end

function M.set_active(id)
  local data, err = apply("set_active", id, {})
  return data ~= nil, err
end

function M.move(id, delta)
  local data, err = apply("move", id, { delta = delta })
  return data ~= nil, err
end

function M.indent(id)
  local data, err = apply("indent", id, {})
  return data ~= nil, err
end

function M.outdent(id)
  local data, err = apply("outdent", id, {})
  return data ~= nil, err
end

return M
