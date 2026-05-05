-- browser/session.lua
--
-- Devproxy session manager. Pure module - no keymaps.
-- All keymaps live in after/plugin/browser.lua.

local M = {}

-- ------------------------------------------------------------
-- devproxy dir discovery
-- ------------------------------------------------------------
local function find_devproxy_dir()
	local dir = vim.fn.getcwd()
	while dir ~= "/" do
		local candidate = dir .. "/.devproxy"
		if vim.fn.isdirectory(candidate) == 1 then
			return candidate
		end
		local parent = vim.fn.fnamemodify(dir, ":h")
		if parent == dir then
			break
		end
		dir = parent
	end
	return vim.fn.getcwd() .. "/.devproxy"
end

-- ------------------------------------------------------------
-- config
-- ------------------------------------------------------------
M.SOCKET = "/tmp/devproxy.sock"
M.DEVPROXY_BIN = "/usr/local/bin/devproxy"
M.LOG_PATH = "/tmp/devproxy.log"
M.DEVPROXY_DIR = find_devproxy_dir()
M.PROJECT_CFG = M.DEVPROXY_DIR .. "/config.yaml"
M.VIEWS_PATH = M.DEVPROXY_DIR .. "/views.yaml"
M.SIGNIN_PATH = M.DEVPROXY_DIR .. "/signin"
M.LAYOUTS_DIR = M.DEVPROXY_DIR .. "/layouts"
M.TESTS_DIR = M.DEVPROXY_DIR .. "/tests"
M._tab_paths = {} -- tab_id -> chi_path

-- Brave on Windows - isolated profile
M.BRAVE_EXE = "C:\\Program Files\\BraveSoftware\\Brave-Browser\\Application\\brave.exe"
M.BRAVE_ARGS =
	"--remote-debugging-port=9222 --remote-allow-origins=* --user-data-dir=C:\\temp\\devproxy-profile --no-first-run --no-default-browser-check --no-restore"

-- CSS dir: read from .devproxy/config.yaml active server, fallback to static
local function get_css_dir()
	local path = M.PROJECT_CFG
	if vim.fn.filereadable(path) == 0 then
		return "/home/jmeyer/projects/portal/static/css"
	end
	local raw = vim.fn.system("yq -o=json . " .. vim.fn.shellescape(path) .. " 2>/dev/null")
	local ok, data = pcall(vim.json.decode, raw)
	if not ok or not data then
		return "/home/jmeyer/projects/portal/static/css"
	end
	local active = data.active_server or "admin"
	local srv = data.servers and data.servers[active]
	if srv and srv.static_path then
		return srv.static_path .. "/css"
	end
	return "/home/jmeyer/projects/portal/static/css"
end

M.CSS_DIR = get_css_dir()

-- ------------------------------------------------------------
-- helpers
-- ------------------------------------------------------------
local function in_tmux()
	return vim.env.TMUX ~= nil
end

local function tmux(cmd)
	return vim.fn.system("tmux " .. cmd)
end

local function project_name()
	return vim.fn.fnamemodify(vim.fn.getcwd(), ":t"):gsub("%.", "_")
end

local function devproxy_session()
	return "devproxy-" .. project_name()
end

local function session_exists(name)
	vim.fn.system("tmux has-session -t=" .. vim.fn.shellescape(name) .. " 2>/dev/null")
	return vim.v.shell_error == 0
end

local function write_brave_prefs()
	vim.fn.system(
		'powershell.exe -NoProfile -Command "'
			.. "New-Item -ItemType Directory -Force -Path 'C:\\temp\\devproxy-profile\\Default' | Out-Null; "
			.. "[System.IO.File]::WriteAllText("
			.. "'C:\\temp\\devproxy-profile\\Default\\Preferences',"
			.. '\'{\\"exit_type\\":\\"Normal\\",\\"exited_cleanly\\":true,'
			.. '\\"profile\\":{\\"exit_type\\":\\"Normal\\"}}\''
			.. ')"'
	)
end

local function clear_brave_session()
	vim.fn.system(
		'powershell.exe -NoProfile -Command "'
			.. "Remove-Item -Force -ErrorAction SilentlyContinue 'C:\\temp\\devproxy-profile\\Default\\Sessions\\*'; "
			.. "Remove-Item -Force -ErrorAction SilentlyContinue 'C:\\temp\\devproxy-profile\\Default\\Session Storage\\*'; "
			.. "Remove-Item -Force -ErrorAction SilentlyContinue 'C:\\temp\\devproxy-profile\\Default\\Current Session'; "
			.. "Remove-Item -Force -ErrorAction SilentlyContinue 'C:\\temp\\devproxy-profile\\Default\\Current Tabs'"
			.. '"'
	)
end

local function launch_brave()
	write_brave_prefs()
	clear_brave_session()
	local cmd = string.format(
		"powershell.exe -NoProfile -WindowStyle Hidden -Command \"Start-Process -FilePath '%s' -ArgumentList '%s'\"",
		M.BRAVE_EXE,
		M.BRAVE_ARGS
	)
	vim.fn.system(cmd)
end

local function kill_brave()
	vim.fn.system(
		'powershell.exe -NoProfile -Command "'
			.. "Stop-Process -Id "
			.. "(Get-NetTCPConnection -LocalPort 9222 -ErrorAction SilentlyContinue | "
			.. "Select-Object -ExpandProperty OwningProcess -Unique) "
			.. '-Force -ErrorAction SilentlyContinue"'
	)
end

-- ------------------------------------------------------------
-- socket command
-- ------------------------------------------------------------
function M.send_cmd(cmd)
	local waited = 0
	while vim.fn.filereadable(M.SOCKET) == 0 and waited < 5000 do
		vim.fn.system("sleep 0.1")
		waited = waited + 100
	end
	if vim.fn.filereadable(M.SOCKET) == 0 then
		vim.notify("browser: devproxy not running -- start with <leader>wb", vim.log.levels.WARN)
		return nil
	end
	local result = vim.fn.system(
		"echo " .. vim.fn.shellescape(cmd) .. " | socat -t 5 - UNIX-CONNECT:" .. M.SOCKET .. " 2>/dev/null"
	)
	return vim.trim(result)
end

-- ------------------------------------------------------------
-- active_tab_id
--
-- Returns the id of the currently active Brave tab (or nil if no
-- tabs / devproxy is down). Used by callers that intend to operate
-- on whatever the user is looking at right now.
--
-- Phase 1 of the navigate strict-mode migration: every navigate call
-- needs an explicit --tab=<id>. Sites that previously relied on
-- "navigate operates on active" now call this helper and pass the
-- returned id explicitly. The strictness on the wire stays - the
-- helper just makes the active-tab lookup cheap and consistent at
-- the call site.
--
-- Round-trip: one socket call per invocation. Cheap; not cached.
-- Don't loop-call this in a fan-out - look it up once outside the
-- loop and pass the id in.
-- ------------------------------------------------------------
function M.active_tab_id()
	local raw = M.send_cmd("tabs")
	if not raw or raw:sub(1, 1) ~= "[" then
		return nil
	end
	local ok, tabs = pcall(vim.json.decode, raw)
	if not ok then
		return nil
	end
	for _, t in ipairs(tabs) do
		if t.active then
			return t.id
		end
	end
	return nil
end

-- ------------------------------------------------------------
-- session lifecycle
-- ------------------------------------------------------------
function M.start()
	if not in_tmux() then
		vim.notify("browser: not in tmux", vim.log.levels.WARN)
		return
	end
	launch_brave()
	vim.notify("browser: launching Brave on Windows...")
	local dname = devproxy_session()
	if not session_exists(dname) then
		vim.fn.system("rm -f " .. M.SOCKET)
		vim.fn.mkdir(M.DEVPROXY_DIR, "p")
		local proxy_cmd = string.format(
			"%s -devproxy-dir %s 2>&1 | tee %s",
			M.DEVPROXY_BIN,
			vim.fn.shellescape(M.DEVPROXY_DIR),
			M.LOG_PATH
		)
		tmux("new-session -ds " .. vim.fn.shellescape(dname) .. " " .. vim.fn.shellescape(proxy_cmd))
		vim.notify("browser: started devproxy [" .. dname .. "]")
		vim.defer_fn(function()
			require("browser.cdp").start()
			vim.notify("browser: ready")
		end, 6000)
	else
		vim.notify("browser: devproxy already running [" .. dname .. "]")
	end
end

function M.stop()
	if not in_tmux() then
		return
	end
	M.send_cmd("stop")
	vim.fn.system("sleep 0.5")
	for _, name in ipairs({ devproxy_session() }) do
		if session_exists(name) then
			tmux("kill-session -t " .. vim.fn.shellescape(name))
		end
	end
	vim.fn.system("rm -f " .. M.SOCKET)
	kill_brave()
	require("browser.cdp").stop()
	vim.notify("browser: stopped")
end

function M.kill()
	vim.fn.system("pkill -f devproxy 2>/dev/null")
	vim.fn.system("pkill socat 2>/dev/null")
	vim.fn.system("sleep 0.3")
	vim.fn.system("rm -f " .. M.SOCKET)
	kill_brave()
	for _, name in ipairs({ devproxy_session() }) do
		if session_exists(name) then
			tmux("kill-session -t " .. vim.fn.shellescape(name))
		end
	end
	require("browser.cdp").stop()
	vim.notify("browser: killed everything")
end

function M.restart()
	if not in_tmux() then
		return
	end
	local dname = devproxy_session()
	M.send_cmd("stop")
	if session_exists(dname) then
		tmux("kill-session -t " .. vim.fn.shellescape(dname))
	end
	vim.fn.system("rm -f " .. M.SOCKET .. " " .. M.LOG_PATH)
	vim.fn.system("sleep 0.3")
	local proxy_cmd = string.format(
		"%s -devproxy-dir %s 2>&1 | tee %s",
		M.DEVPROXY_BIN,
		vim.fn.shellescape(M.DEVPROXY_DIR),
		M.LOG_PATH
	)
	tmux("new-session -ds " .. vim.fn.shellescape(dname) .. " " .. vim.fn.shellescape(proxy_cmd))
	vim.notify("browser: devproxy restarted [" .. dname .. "]")
end

function M.toggle_log()
	if not in_tmux() then
		return
	end
	local bufname = "devproxy-log"
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):find(bufname, 1, true) then
			local wins = vim.fn.win_findbuf(buf)
			if #wins > 0 then
				for _, win in ipairs(wins) do
					vim.api.nvim_win_close(win, true)
				end
			else
				vim.cmd("vsplit")
				vim.api.nvim_win_set_buf(0, buf)
			end
			return
		end
	end
	vim.cmd("vsplit")
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(0, buf)
	vim.fn.termopen("tail -f " .. M.LOG_PATH)
	vim.api.nvim_buf_set_name(buf, bufname)
	vim.bo[buf].bufhidden = "hide"
	vim.cmd("stopinsert")
end

-- ------------------------------------------------------------
-- navigation helpers
-- ------------------------------------------------------------
function M.tab_picker()
	local raw = M.send_cmd("sync-tabs")
	if not raw or raw:sub(1, 1) ~= "[" then
		vim.notify("browser: " .. (raw or "no response"), vim.log.levels.WARN)
		return
	end
	local ok, tabs = pcall(vim.json.decode, raw)
	if not ok or #tabs == 0 then
		vim.notify("browser: no open tabs")
		return
	end
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	pickers
		.new({}, {
			prompt_title = "Browser Tabs",
			finder = finders.new_table({
				results = tabs,
				entry_maker = function(tab)
					local active = tab.active and " *" or "  "
					return { value = tab, display = active .. (tab.path or tab.id), ordinal = tab.path or tab.id }
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local sel = action_state.get_selected_entry()
					if not sel then
						return
					end
					local r = M.send_cmd("switch " .. sel.value.id)
					if r then
						vim.notify(r)
					end
				end)
				return true
			end,
		})
		:find()
end

function M.hard_refresh()
	local r = M.send_cmd("refresh")
	if r then
		vim.notify(r)
	end
end

function M.auto_refresh()
	vim.ui.input({ prompt = "Auto-refresh every N seconds (0 to stop): ", default = "3" }, function(input)
		if not input then
			return
		end
		local r = M.send_cmd("autorefresh " .. input)
		if r then
			vim.notify(r)
		end
	end)
end

function M.mobile_partial()
	vim.ui.input({ prompt = "URL: ", default = "http://localhost:3333/" }, function(url)
		if not url or url == "" then
			return
		end
		local r = M.send_cmd("mobile " .. url)
		if r then
			vim.notify(r)
		end
	end)
end

function M.mobile_full()
	vim.ui.input({ prompt = "URL: ", default = "http://localhost:3333/" }, function(url)
		if not url or url == "" then
			return
		end
		local r = M.send_cmd("mobile-full " .. url)
		if r then
			vim.notify(r)
		end
	end)
end

function M.desktop()
	local r = M.send_cmd("desktop")
	if r then
		vim.notify(r)
	end
end

function M.inject_css()
	local r = M.send_cmd("css-inject")
	if r then
		vim.notify(r)
	end
end

function M.pick_tab_then(callback)
	local raw = M.send_cmd("sync-tabs")
	if not raw or raw:sub(1, 1) ~= "[" then
		return
	end
	local ok, tabs = pcall(vim.json.decode, raw)
	if not ok or #tabs == 0 then
		return
	end
	if #tabs == 1 then
		callback(tabs[1].id)
		return
	end
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	pickers
		.new({}, {
			prompt_title = "Select Tab",
			finder = finders.new_table({
				results = tabs,
				entry_maker = function(t)
					local label = M._tab_paths[t.id] or t.path or t.id
					local active = t.active and " *" or "  "
					return { value = t.id, display = active .. label, ordinal = label }
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					local sel = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if sel then
						callback(sel.value)
					end
				end)
				return true
			end,
		})
		:find()
end

return M
