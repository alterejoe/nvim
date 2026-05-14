-- lua/opencode-ext/model.lua
-- Builds conversation tree from raw DB data.
-- All functions are stateless — just takes data in, returns data out.

local M = {}

-- model.lua:7
local function extract_code_blocks(lines)
	local blocks = {}
	local i = 1
	while i <= #lines do
		local open_lang = lines[i]:match("^```(.+)")
		local is_bare_open = lines[i]:match("^```%s*$")
		if open_lang or is_bare_open then
			local lang = open_lang or ""
			local code = {}
			i = i + 1
			-- Close only on bare ``` — ```lang inside content is not a close
			while i <= #lines and not lines[i]:match("^```%s*$") do
				table.insert(code, lines[i])
				i = i + 1
			end
			i = i + 1
			table.insert(blocks, { lang = lang, lines = code })
		else
			i = i + 1
		end
	end
	return blocks
end

local function render_part(part)
	local lines = {}
	if part.type == "text" and part.text and part.text ~= "" then
		if not part.synthetic then
			for _, tl in ipairs(vim.split(part.text, "\n", { plain = true })) do
				table.insert(lines, tl)
			end
		end
	elseif part.type == "reasoning" and part.text and part.text ~= "" then
		for _, rl in ipairs(vim.split(part.text, "\n", { plain = true })) do
			table.insert(lines, rl)
		end
	elseif part.type == "tool" then
		table.insert(lines, "> Tool: " .. (part.tool or "unknown"))
		local st = part.state
		if st then
			if st.status == "completed" then
				if st.output then
					table.insert(lines, "```")
					for _, ol in ipairs(vim.split(st.output, "\n", { plain = true })) do
						table.insert(lines, ol)
					end
					table.insert(lines, "```")
				elseif st.input and st.input.description then
					table.insert(lines, "  " .. st.input.description)
				end
			elseif st.status == "error" then
				table.insert(lines, "  ! " .. (st.error or "error"))
			elseif st.status == "running" then
				table.insert(lines, "  ... running")
			elseif st.status == "pending" then
				table.insert(lines, "  ... pending")
			end
		end
	elseif part.type == "subtask" then
		table.insert(lines, "> Subtask: " .. (part.description or part.prompt or ""))
	elseif part.type == "file" then
		table.insert(lines, "  [file] " .. (part.filename or "attachment"))
		if part.url and not part.url:match("^data:") then
			table.insert(lines, "    " .. part.url)
		end
	end
	return lines, extract_code_blocks(lines)
end

local function group_parts(raw_parts)
	local by_msg = {}
	for _, p in ipairs(raw_parts or {}) do
		local mid = p.message_id
		by_msg[mid] = by_msg[mid] or {}
		table.insert(by_msg[mid], p)
	end
	return by_msg
end

function M.build(raw)
	local parts_by_msg = group_parts(raw.parts)
	local conversations = {}
	local current_user = nil

	for _, msg in ipairs(raw.messages or {}) do
		local role = msg.role
		if role ~= "user" and role ~= "assistant" then
			goto next
		end
		local msg_parts = parts_by_msg[msg.id] or {}
		local all_lines = {}
		local text_lines = {}
		local code_blocks = {}
		local has_tool = false

		for _, part in ipairs(msg_parts) do
			local plines, cblocks = render_part(part)
			for _, l in ipairs(plines) do
				table.insert(all_lines, l)
			end
			if part.type == "tool" then
				has_tool = true
				for _, l in ipairs(plines) do
					table.insert(text_lines, l)
				end
			else
				for _, l in ipairs(plines) do
				end
				for _, cb in ipairs(cblocks) do
					table.insert(code_blocks, cb)
				end
				local i = 1
				while i <= #plines do
					if plines[i]:match("^```") then
						i = i + 1
						while i <= #plines and not plines[i]:match("^```%s*$") do
							i = i + 1
						end
						i = i + 1
					else
						table.insert(text_lines, plines[i])
						i = i + 1
					end
				end
			end
		end

		if #all_lines == 0 then
			goto next
		end
		local label = ""
		for _, l in ipairs(all_lines) do
			local t = vim.trim(l)
			if t ~= "" then
				label = t:sub(1, 70)
				break
			end
		end

		if role == "user" then
			current_user = { idx = #conversations + 1, label = label, user_lines = all_lines, asst_sections = {} }
			table.insert(conversations, current_user)
		elseif role == "assistant" and current_user then
			local asst_label = ""
			for _, tl in ipairs(text_lines) do
				local t = vim.trim(tl)
				if t ~= "" then
					asst_label = t:sub(1, 70)
					break
				end
			end
			if asst_label == "" and #code_blocks > 0 then
				asst_label = "(" .. #code_blocks .. " blocks)"
			end
			local kind = (#code_blocks > 0) and "code" or (has_tool and "tool" or "summary")
			table.insert(
				current_user.asst_sections,
				{ label = asst_label, text_lines = text_lines, code_blocks = code_blocks, kind = kind }
			)
		end
		::next::
	end
	return conversations
end

function M.build_lines(convs)
	local lines = {}
	local line_map = {}
	local function emit(text, entry)
		line_map[#lines + 1] = entry
		lines[#lines + 1] = text
	end

	emit(string.format("Opencode Viewer -- %d conversations", #convs), { type = "header" })
	emit(string.rep("=", 60), { type = "sep" })
	emit("", { type = "blank" })

	for ci, conv in ipairs(convs) do
		emit(string.format("---[%d]-- User: %s", conv.idx, conv.label), { type = "user", conv_idx = ci })
		for _, cl in ipairs(conv.user_lines) do
			lines[#lines + 1] = "  " .. cl
			line_map[#line_map + 1] = { type = "text", conv_idx = ci }
		end

		for ai, asst in ipairs(conv.asst_sections) do
			emit(string.format("---[%s] %s", asst.kind, asst.label), { type = "asst", conv_idx = ci, asst_idx = ai })
			for _, tl in ipairs(asst.text_lines) do
				lines[#lines + 1] = "  " .. tl
				line_map[#line_map + 1] = { type = "text", conv_idx = ci }
			end
			for bi, cb in ipairs(asst.code_blocks) do
				local fname = (cb.lines[1] or "") ~= "" and " " .. vim.trim(cb.lines[1]) or ""
				local lang_tag = (cb.lang ~= "") and (" (" .. cb.lang .. ")") or ""
				emit(
					string.format("  -- [code]%s%s --", fname, lang_tag),
					{ type = "code", conv_idx = ci, asst_idx = ai, block_idx = bi }
				)
				for _, cl in ipairs(cb.lines) do
					lines[#lines + 1] = "    " .. cl
					line_map[#line_map + 1] = { type = "code_line", conv_idx = ci }
				end
			end
		end
		lines[#lines + 1] = ""
		line_map[#line_map + 1] = { type = "blank" }
	end
	lines[#lines + 1] = ""
	line_map[#line_map + 1] = { type = "blank" }
	emit(string.rep("-", 60), { type = "sep" })
	return lines, line_map
end

function M.search_text(conv)
	local parts = { conv.label or "" }
	for _, l in ipairs(conv.user_lines) do
		table.insert(parts, l)
	end
	for _, asst in ipairs(conv.asst_sections) do
		table.insert(parts, asst.label or "")
		for _, tl in ipairs(asst.text_lines) do
			table.insert(parts, tl)
		end
		for _, cb in ipairs(asst.code_blocks) do
			for _, cl in ipairs(cb.lines) do
				table.insert(parts, cl)
			end
		end
	end
	return table.concat(parts, " "):lower()
end

function M.match(query, text)
	local t = type(text) == "string" and text or text:lower()
	if type(text) ~= "string" then
		t = text
	end
	local words = vim.split(query:lower(), "%s+")
	for _, word in ipairs(words) do
		if word ~= "" then
			local pos = 1
			for j = 1, #word do
				pos = t:find(word:sub(j, j), pos, true)
				if not pos then
					return false
				end
				pos = pos + 1
			end
		end
	end
	return true
end

return M
