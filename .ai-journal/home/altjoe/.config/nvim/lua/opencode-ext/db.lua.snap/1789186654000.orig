-- /home/jmeyer/.config/nvim/lua/opencode-ext/db.lua FINAL-6
local DB_PATH = vim.fn.expand("~/.local/share/opencode/opencode.db")
local M = {}

local function db_query(sql)
	local ok, chk = pcall(vim.fn.executable, "sqlite3")
	if not ok or chk ~= 1 then
		return nil, "sqlite3 not installed"
	end
	if #vim.fn.glob(DB_PATH, false, true) == 0 then
		return nil, "No DB"
	end
	local ok, res = pcall(vim.fn.system, { "sqlite3", "-readonly", DB_PATH, sql })
	if not ok or vim.v.shell_error ~= 0 then
		return nil, res
	end
	if type(res) ~= "string" or res == "" then
		return nil, "empty"
	end
	return res
end

local function db_query_write(sql)
	local ok, chk = pcall(vim.fn.executable, "sqlite3")
	if not ok or chk ~= 1 then
		return nil, "sqlite3 not installed"
	end
	if #vim.fn.glob(DB_PATH, false, true) == 0 then
		return nil, "No DB"
	end
	local ok, res = pcall(vim.fn.system, { "sqlite3", DB_PATH, sql })
	if not ok or vim.v.shell_error ~= 0 then
		return nil, res
	end
	return true
end

function M.fetch_sessions()
	local sql = [[
		SELECT json_group_array(json_object(
			'id', s.id,
			'title', s.title,
			'project', p.worktree,
			'time_created', s.time_created,
			'time_updated', s.time_updated,
			'msg_count', (SELECT COUNT(*) FROM message m WHERE m.session_id = s.id),
			'preview', (SELECT json_extract(pr.data, '$.text')
			            FROM part pr
			            JOIN message ms ON ms.id = pr.message_id
			            WHERE ms.session_id = s.id
			              AND json_extract(pr.data, '$.type') = 'text'
			              AND json_extract(ms.data, '$.role') = 'user'
			            ORDER BY ms.time_created ASC, pr.id ASC
			            LIMIT 1)
		) ORDER BY s.time_updated DESC)
		FROM session s
		JOIN project p ON p.id = s.project_id
	]]
	local res, err = db_query(sql)
	if not res then
		return nil, err
	end
	local ok, data = pcall(vim.fn.json_decode, res)
	if not ok then
		return nil, "json parse failed"
	end
	return data
end

function M.fetch_session(sid)
	if not sid or not sid:match("^[%w_]+$") then
		return nil, "invalid session id"
	end
	local esc = sid:gsub("'", "''")

	local sql = [[
		SELECT json_object(
			'sid', ']] .. esc .. [[',
			'label', (SELECT title FROM session WHERE id = ']] .. esc .. [['),
			'messages', (SELECT json_group_array(
			                  json_set(json(m.data), '$.id', m.id)
			             )
			    FROM message m
			    WHERE m.session_id = ']] .. esc .. [['
			    ORDER BY m.time_created ASC
			),
			'parts', (SELECT json_group_array(
			                  json_set(json(p.data), '$.message_id', p.message_id, '$.id', p.id)
			                 )
			    FROM part p
			    WHERE p.session_id = ']] .. esc .. [['
			    ORDER BY p.message_id ASC, p.id ASC
			)
		)
	]]

	local res, err = db_query(sql)
	if not res then
		return nil, err
	end
	if res == "null" or res == "" then
		return nil, "session not found"
	end
	local ok, data = pcall(vim.fn.json_decode, res)
	if not ok then
		return nil, "json parse failed"
	end
	return data
end

function M.fetch_all(cwd_override)
	local cwd = cwd_override or vim.fn.getcwd()
	local esc_cwd = cwd:gsub("'", "''")

	local sql = [[
		WITH current_project AS (
		    SELECT id FROM project
		    WHERE instr(']] .. esc_cwd .. [[', worktree) = 1
		    ORDER BY length(worktree) DESC
		    LIMIT 1
		),
		current_session AS (
		    SELECT id, title, time_updated FROM session
		    WHERE project_id = (SELECT id FROM current_project)
		    ORDER BY time_updated DESC LIMIT 1
		)
		SELECT json_object(
		    'sid',          (SELECT id    FROM current_session),
		    'label',        (SELECT title FROM current_session),
		    'time_updated', (SELECT time_updated FROM current_session),
		    'messages', (SELECT json_group_array(
		                      json_set(json(m.data), '$.id', m.id)
		                 )
		        FROM message m
		        WHERE m.session_id = (SELECT id FROM current_session)
		        ORDER BY m.time_created ASC
		    ),
		    'parts', (SELECT json_group_array(
		                      json_set(json(p.data), '$.message_id', p.message_id, '$.id', p.id)
		                 )
		        FROM part p
		        WHERE p.session_id = (SELECT id FROM current_session)
		        ORDER BY p.message_id ASC, p.id ASC
		    )
		)
	]]

	local res, err = db_query(sql)
	if not res then
		return nil, err
	end
	local ok, data = pcall(vim.fn.json_decode, res)
	if not ok then
		return nil, "json parse failed"
	end
	return data
end

function M.fetch_by_worktree(dir)
	if not dir or dir == "" then
		return nil, "no directory"
	end
	local esc = dir:gsub("'", "''")
	local sql = [[
		WITH current_project AS (
		    SELECT id FROM project
		    WHERE worktree = ']] .. esc .. [['
		    LIMIT 1
		),
		current_session AS (
		    SELECT id, title, time_updated FROM session
		    WHERE project_id = (SELECT id FROM current_project)
		    ORDER BY time_updated DESC LIMIT 1
		)
		SELECT json_object(
		    'sid',          (SELECT id    FROM current_session),
		    'label',        (SELECT title FROM current_session),
		    'time_updated', (SELECT time_updated FROM current_session),
		    'messages', (SELECT json_group_array(
		                      json_set(json(m.data), '$.id', m.id)
		                 )
		        FROM message m
		        WHERE m.session_id = (SELECT id FROM current_session)
		        ORDER BY m.time_created ASC
		    ),
		    'parts', (SELECT json_group_array(
		                      json_set(json(p.data), '$.message_id', p.message_id, '$.id', p.id)
		                 )
		        FROM part p
		        WHERE p.session_id = (SELECT id FROM current_session)
		        ORDER BY p.message_id ASC, p.id ASC
		    )
		)
	]]
	local res, err = db_query(sql)
	if not res then
		return nil, err
	end
	local ok, data = pcall(vim.fn.json_decode, res)
	if not ok then
		return nil, "json parse failed"
	end
	return data
end

function M.fetch_global_by_directory(dir)
	if not dir or dir == "" then
		return nil, "no directory"
	end
	local esc = dir:gsub("'", "''")
	local sql = [[
		WITH global_session AS (
		    SELECT id, title, time_updated FROM session
		    WHERE project_id = 'global'
		      AND directory IS NOT NULL
		      AND instr(']] .. esc .. [[', directory) = 1
		    ORDER BY length(directory) DESC, time_updated DESC
		    LIMIT 1
		)
		SELECT json_object(
		    'sid',          (SELECT id    FROM global_session),
		    'label',        (SELECT title FROM global_session),
		    'time_updated', (SELECT time_updated FROM global_session),
		    'messages', (SELECT json_group_array(
		                      json_set(json(m.data), '$.id', m.id)
		                 )
		        FROM message m
		        WHERE m.session_id = (SELECT id FROM global_session)
		        ORDER BY m.time_created ASC
		    ),
		    'parts', (SELECT json_group_array(
		                      json_set(json(p.data), '$.message_id', p.message_id, '$.id', p.id)
		                 )
		        FROM part p
		        WHERE p.session_id = (SELECT id FROM global_session)
		        ORDER BY p.message_id ASC, p.id ASC
		    )
		)
	]]
	local res, err = db_query(sql)
	if not res then
		return nil, err
	end
	if res == "null" or res == "" then
		return nil, "no global session for this directory"
	end
	local ok, data = pcall(vim.fn.json_decode, res)
	if not ok then
		return nil, "json parse failed"
	end
	return data
end

function M.fetch_session_project(sid)
	if not sid or not sid:match("^[%w_]+$") then
		return nil
	end
	local esc = sid:gsub("'", "''")
	local sql = "SELECT p.worktree FROM session s JOIN project p ON p.id = s.project_id WHERE s.id = '" .. esc .. "'"
	local res, _ = db_query(sql)
	if not res or vim.trim(res) == "" then
		return nil
	end
	return vim.trim(res)
end

function M.reassign_session(sid, new_worktree)
	if not sid or not sid:match("^[%w_]+$") then
		return nil, "invalid session id"
	end
	if not new_worktree or new_worktree == "" then
		return nil, "no worktree provided"
	end

	local esc_wt = new_worktree:gsub("'", "''")
	local esc_sid = sid:gsub("'", "''")

	local find_sql = "SELECT id FROM project WHERE worktree = '" .. esc_wt .. "' LIMIT 1"
	local res, _ = db_query(find_sql)
	if not res or vim.trim(res) == "" then
		return nil, "no project found for " .. new_worktree .. " — start opencode there first to create the project"
	end
	local project_id = vim.trim(res)

	local sql = "UPDATE session SET project_id = '" .. project_id .. "' WHERE id = '" .. esc_sid .. "'"
	local _, err = db_query_write(sql)
	if err then
		return nil, "session update failed: " .. tostring(err)
	end

	return true
end

return M
