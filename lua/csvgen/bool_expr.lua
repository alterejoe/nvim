-- /home/jmeyer/.config/nvim/lua/csvgen/bool_expr.lua FINAL
-- csvgen/bool_expr.lua — Boolean expression parser for association match patterns.
--
-- Supports:  word, word|word, word&word, [group]
-- Precedence: & binds tighter than |, [...] overrides.
-- Matching is case-insensitive substring.

local M = {}

function M.parse(str)
	local pos = 1
	local len = #str

	local function skip_ws()
		while pos <= len and str:sub(pos, pos):match("%s") do
			pos = pos + 1
		end
	end

	local function parse_word()
		local start = pos
		while pos <= len and not str:sub(pos, pos):match("[|&%[%]%s]") do
			pos = pos + 1
		end
		return str:sub(start, pos - 1)
	end

	local function parse_term()
		skip_ws()
		if pos > len then
			return nil
		end
		if str:sub(pos, pos) == "[" then
			pos = pos + 1
			local node = parse_or()
			skip_ws()
			if pos <= len and str:sub(pos, pos) == "]" then
				pos = pos + 1
			end
			return node
		end
		local word = parse_word()
		if word == "" then
			return nil
		end
		return { op = "word", value = word }
	end

	local function parse_and()
		local left = parse_term()
		if not left then
			return nil
		end
		skip_ws()
		while pos <= len and str:sub(pos, pos) == "&" do
			pos = pos + 1
			local right = parse_term()
			if not right then
				break
			end
			left = { op = "and", children = { left, right } }
			skip_ws()
		end
		return left
	end

	local function parse_or()
		local left = parse_and()
		if not left then
			return nil
		end
		skip_ws()
		while pos <= len and str:sub(pos, pos) == "|" do
			pos = pos + 1
			local right = parse_and()
			if not right then
				break
			end
			left = { op = "or", children = { left, right } }
			skip_ws()
		end
		return left
	end

	return parse_or()
end

function M.eval(node, value)
	if not node then
		return false
	end
	local v = value:lower()
	if node.op == "word" then
		return v:find(node.value:lower(), 1, true) ~= nil
	elseif node.op == "or" then
		for _, child in ipairs(node.children) do
			if M.eval(child, value) then
				return true
			end
		end
		return false
	elseif node.op == "and" then
		for _, child in ipairs(node.children) do
			if not M.eval(child, value) then
				return false
			end
		end
		return true
	end
	return false
end

return M
