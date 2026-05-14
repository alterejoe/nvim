local DB_PATH = vim.fn.expand("~/.local/share/opencode/opencode.db")
local M = {}

-- Execute a read-only sqlite3 query against the opencode DB.
-- Returns raw JSON string on success, or nil + error message on failure.
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

-- Fetch all sessions across all projects, newest first.
-- Returns a list of { id, title, project, time_created, time_updated, msg_count }.
function M.fetch_sessions()
	local sql = [[
		SELECT json_group_array(json_object(
			'id', s.id,
			'title', s.title,
			'project', p.worktree,
			'time_created', s.time_created,
			'time_updated', s.time_updated,
			'msg_count', (SELECT COUNT(*) FROM message m WHERE m.session_id = s.id)
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

-- Fetch full session data (messages + parts) for a single session.
-- Returns the same shape as fetch_all() but for a specific session ID.
-- Parts include $.message_id and $.id injected from relational columns.
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

-- Fetch the latest session for the current project (kept for compat).
function M.fetch_all()
	local cwd = vim.fn.getcwd()
	local esc_cwd = cwd:gsub("'", "''")

	local sql = [[
		WITH current_project AS (
		    SELECT id FROM project
		    WHERE instr(']] .. esc_cwd .. [[', worktree) = 1
		    ORDER BY length(worktree) DESC
		    LIMIT 1
		),
		current_session AS (
		    SELECT id, title FROM session
		    WHERE project_id = (SELECT id FROM current_project)
		    ORDER BY time_updated DESC LIMIT 1
		)
		SELECT json_object(
		    'sid',     (SELECT id    FROM current_session),
		    'label',   (SELECT title FROM current_session),
		    'messages', (SELECT json_group_array(
		                      json_set(json(m.data), '$.id', m.id)
		                 )
		        FROM message m
		        WHERE m.session_id = (SELECT id FROM current_session)
		        ORDER BY m.time_created ASC
		    ),
		    'parts',    (SELECT json_group_array(
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

return M
