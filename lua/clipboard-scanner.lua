# /home/jmeyer/.config/nvim/lua/clipboard-scanner.lua FINAL
-- clipboard-scanner.lua
-- Standalone security scanner for clipboard contents.
--
-- Detects invisible Unicode, bidi overrides, ANSI escapes,
-- vim modeline injection, Unicode homoglyph confusables,
-- and raw control characters.
--
-- All scanning is done with a single byte-level pass (plus
-- separate vim modeline pattern checks) for efficiency on
-- large AI-generated code blocks.
--
-- Usage:
--   local scanner = require("clipboard-scanner")
--   local warnings = scanner.scan(text)
--   scanner.update_confusables()  -- download UTS#39 data
--
-- Exports:
--   scan(text) → string[]        warnings list (empty = clean)
--   to_raw_view(text) → string   escaped representation
--   update_confusables()         download latest UTS#39 list
--   homoglyph_map                live homoglyph lookup table
--   confusables_cache            cache file path

local M = {}

-- Three distinct threat classes are tracked here:
--
--   1. INVISIBLE / BIDI CHARACTERS
--      Unicode characters that are invisible or that make text look different
--      from what it actually contains. Common in AI output, web pages, and
--      intentional supply-chain / prompt-injection attacks.
--
--   2. VIM MODELINE INJECTION
--      Patterns that exploit Vim's modeline feature to execute arbitrary code.
--      Relevant CVEs: CVE-2026-34714 (tabpanel + autocmd_add()),
--      CVE-2026-34982 (complete/guitabtooltip/printheader).
--
--   3. UNICODE LOOKALIKE CHARACTERS (UTS#39 "confusables")
--      Characters that look identical to ASCII but aren't (Cyrillic 'а' vs
--      Latin 'a'). M.update_confusables() downloads the authoritative list.

-- Byte sequences to match (literal bytes, not Lua patterns)
local SUSPICIOUS_PATTERNS = {
	-- invisible / zero-width characters
	{ bytes = "\xE2\x80\x8B", label = "zero-width space", codepoint = "U+200B" },
	{ bytes = "\xE2\x80\x8C", label = "zero-width non-joiner", codepoint = "U+200C" },
	{ bytes = "\xE2\x80\x8D", label = "zero-width joiner", codepoint = "U+200D" },
	{ bytes = "\xEF\xBB\xBF", label = "BOM / zero-width no-break", codepoint = "U+FEFF" },
	{ bytes = "\xC2\xAD", label = "soft hyphen", codepoint = "U+00AD" },
	{ bytes = "\xE2\x81\xA0", label = "word joiner", codepoint = "U+2060" },
	{ bytes = "\xE1\xA0\x8E", label = "mongolian vowel sep", codepoint = "U+180E" },
	-- bidi overrides — "display != content" attack
	{ bytes = "\xE2\x80\xAA", label = "LTR embedding", codepoint = "U+202A" },
	{ bytes = "\xE2\x80\xAB", label = "RTL embedding", codepoint = "U+202B" },
	{ bytes = "\xE2\x80\xAC", label = "pop directional fmt", codepoint = "U+202C" },
	{ bytes = "\xE2\x80\xAD", label = "LTR override", codepoint = "U+202D" },
	{ bytes = "\xE2\x80\xAE", label = "RTL override", codepoint = "U+202E" },
	{ bytes = "\xE2\x80\x8E", label = "LTR mark", codepoint = "U+200E" },
	{ bytes = "\xE2\x80\x8F", label = "RTL mark", codepoint = "U+200F" },
	-- Unicode directional isolates (newer bidi attack surface)
	{ bytes = "\xE2\x81\xA6", label = "LTR isolate", codepoint = "U+2066" },
	{ bytes = "\xE2\x81\xA7", label = "RTL isolate", codepoint = "U+2067" },
	{ bytes = "\xE2\x81\xA8", label = "first strong isolate", codepoint = "U+2068" },
	{ bytes = "\xE2\x81\xA9", label = "pop directional isolate", codepoint = "U+2069" },
	-- terminal sequences (literal bytes — no Lua pattern escapes needed)
	{ bytes = "\x1b[", label = "ANSI escape sequence", codepoint = "ESC[" },
	{ bytes = "\x1b]", label = "ANSI OSC sequence", codepoint = "ESC]" },
}

-- Pre-build first-byte lookup table for O(1) candidate retrieval
-- during the single-pass scan. Keyed by first byte (integer 0-255),
-- value is list of { bytes, label } where bytes matches that prefix.
local suspicious_by_first_byte = {}
for _, p in ipairs(SUSPICIOUS_PATTERNS) do
	local b0 = p.bytes:byte(1)
	if not suspicious_by_first_byte[b0] then
		suspicious_by_first_byte[b0] = {}
	end
	table.insert(suspicious_by_first_byte[b0], p)
end

-- Vim modeline injection patterns (Lua patterns — need regex-like matching)
local VIM_INJECTION_PATTERNS = {
	{
		pattern = "[^\n]*vim?%s*:[^\n]*tabpanel[^\n]*%%{",
		label = "vim modeline: tabpanel %{expr} injection (CVE-2026-34714)",
	},
	{
		pattern = "[^\n]*vim?%s*:[^\n]*complete%s*=[^\n]*[{F]",
		label = "vim modeline: complete= lambda expression (CVE-2026-34982)",
	},
	{
		pattern = "[^\n]*vim?%s*:[^\n]*gui[Tt]ab[Tt]ool[Tt]ip",
		label = "vim modeline: guitabtooltip option (CVE-2026-34982)",
	},
	{
		pattern = "[^\n]*vim?%s*:[^\n]*print[Hh]eader",
		label = "vim modeline: printheader option (CVE-2026-34982)",
	},
	{
		pattern = "[^\n]*vim?%s*:[^\n]*mapset",
		label = "vim modeline: mapset() call (CVE-2026-34982 chain)",
	},
	{
		pattern = "[^\n]*vim?%s*:[^\n]*f[od][el][de]?%s*=",
		label = "vim modeline: fold expression option (CVE-2019-12735 class)",
	},
	{
		pattern = "[^\n]*vim?%s*:[^\n]*system%s*(",
		label = "vim modeline: system() call",
	},
	{
		pattern = "[^\n]*vim?%s*:[^\n]*libcall%s*(",
		label = "vim modeline: libcall() arbitrary library execution",
	},
	{
		pattern = "[^\n]*vim?%s*:[^\n]*autocmd_add",
		label = "vim modeline: autocmd_add() sandbox escape (CVE-2026-34714)",
	},
}

-- Built-in fallback homoglyph table — used when the UTS#39 cache
-- hasn't been fetched yet. Call update_confusables() to download
-- the full authoritative set (~7 000 entries).
local BUILTIN_HOMOGLYPHS = {
	["\xD0\xB0"] = "looks like 'a' (U+0430 Cyrillic)",
	["\xD0\x90"] = "looks like 'A' (U+0410 Cyrillic)",
	["\xD1\x81"] = "looks like 'c' (U+0441 Cyrillic)",
	["\xD0\xA1"] = "looks like 'C' (U+0421 Cyrillic)",
	["\xD0\xB5"] = "looks like 'e' (U+0435 Cyrillic)",
	["\xD0\x95"] = "looks like 'E' (U+0415 Cyrillic)",
	["\xD0\xBE"] = "looks like 'o' (U+043E Cyrillic)",
	["\xD0\x9E"] = "looks like 'O' (U+041E Cyrillic)",
	["\xD1\x80"] = "looks like 'p' (U+0440 Cyrillic)",
	["\xD0\xA0"] = "looks like 'P' (U+0420 Cyrillic)",
	["\xD1\x85"] = "looks like 'x' (U+0445 Cyrillic)",
	["\xD0\x98"] = "looks like 'N' (U+0418 Cyrillic)",
	["\xD0\xB8"] = "looks like 'u' (U+0438 Cyrillic)",
	["\xD0\xBD"] = "looks like 'H' (U+043D Cyrillic)",
	["\xCE\xBF"] = "looks like 'o' (U+03BF Greek)",
	["\xCE\x9F"] = "looks like 'O' (U+039F Greek)",
	["\xCE\xB1"] = "looks like 'a' (U+03B1 Greek)",
	["\xCE\x9A"] = "looks like 'K' (U+039A Greek)",
	["\xCE\xBD"] = "looks like 'v' (U+03BD Greek)",
	["\xCF\x81"] = "looks like 'p' (U+03C1 Greek)",
}

-- Live table — replaced by load_confusables_cache / update_confusables
local homoglyph_map = BUILTIN_HOMOGLYPHS

-- confusables cache (UTS#39)
local CACHE_PATH = vim.fn.stdpath("data") .. "/clipboard_confusables.tsv"

-- Encode a Unicode codepoint as a UTF-8 Lua string.
local function cp_to_utf8(cp)
	if cp < 0x80 then
		return string.char(cp)
	elseif cp < 0x800 then
		return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
	elseif cp < 0x10000 then
		return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor((cp % 0x1000) / 0x40), 0x80 + (cp % 0x40))
	else
		return string.char(
			0xF0 + math.floor(cp / 0x40000),
			0x80 + math.floor((cp % 0x40000) / 0x1000),
			0x80 + math.floor((cp % 0x1000) / 0x40),
			0x80 + (cp % 0x40)
		)
	end
end

-- Parse confusables.txt raw data into utf8_bytes → description map.
-- Only retains non-ASCII source mapping to single printable ASCII target.
local function parse_confusables_txt(raw)
	local map = {}
	for line in raw:gmatch("[^\n]+") do
		if not line:match("^%s*#") then
			local src_hex, tgt_hex = line:match("^%s*(%x+)%s*;%s*(%x+)%s*;")
			if src_hex and tgt_hex then
				local src_cp = tonumber(src_hex, 16)
				local tgt_cp = tonumber(tgt_hex, 16)
				if src_cp and tgt_cp and src_cp > 0x7F and tgt_cp >= 0x21 and tgt_cp <= 0x7E then
					local src_utf8 = cp_to_utf8(src_cp)
					local tgt_char = string.char(tgt_cp)
					map[src_utf8] = string.format("looks like '%s' (U+%04X)", tgt_char, src_cp)
				end
			end
		end
	end
	return map
end

-- Save map to tab-separated cache file (bytes hex-encoded).
local function save_confusables_cache(map)
	local f = io.open(CACHE_PATH, "w")
	if not f then
		vim.notify("clipboard: could not write confusables cache to " .. CACHE_PATH, vim.log.levels.ERROR)
		return false
	end
	f:write("# clipboard-scanner.lua UTS#39 confusables cache — do not edit\n")
	for utf8_bytes, desc in pairs(map) do
		local hex = utf8_bytes:gsub(".", function(c)
			return string.format("%02X", c:byte())
		end)
		f:write(hex .. "\t" .. desc .. "\n")
	end
	f:close()
	return true
end

-- Load cache file. Returns map or nil if no cache exists.
local function load_confusables_cache()
	local f = io.open(CACHE_PATH, "r")
	if not f then
		return nil
	end
	local map = {}
	local count = 0
	for line in f:lines() do
		if not line:match("^#") then
			local hex, desc = line:match("^(%x+)\t(.+)$")
			if hex and desc then
				local bytes = hex:gsub("%x%x", function(h)
					return string.char(tonumber(h, 16))
				end)
				map[bytes] = desc
				count = count + 1
			end
		end
	end
	f:close()
	return count > 0 and map or nil
end

-- Load cache at module init; fall back to built-ins silently.
do
	local cached = load_confusables_cache()
	if cached then
		homoglyph_map = cached
	end
end

--- Single-pass scan that combines suspicious bytes, homoglyph,
--- and control character detection into one traversal.
--- Vim modeline patterns run as a separate pass (9× text:find in C).
---
---@param text string
---@return string[]
local function scan_suspicious(text)
	local findings = {}
	local seen = {}
	local function flag(label)
		if not seen[label] then
			seen[label] = true
			table.insert(findings, label)
		end
	end

	local len = #text
	local i = 1
	while i <= len do
		local b = text:byte(i)

		-- Control character check (ASCII, not tab/newline/ESC)
		if b ~= 0x09 and b ~= 0x0a and b < 0x20 and b ~= 0x1b then
			flag("raw control character (non-printable byte 0x" .. string.format("%02X", b) .. ")")
			break
		end

		if b < 0x80 then
			-- ASCII — check ESC-based sequences
			if b == 0x1b then
				local candidates = suspicious_by_first_byte[0x1b]
				if candidates then
					local span = text:sub(i, math.min(i + 3, len))
					for _, pat in ipairs(candidates) do
						if #span >= #pat.bytes and span:sub(1, #pat.bytes) == pat.bytes then
							flag(pat.codepoint .. " " .. pat.label)
						end
					end
				end
			end
			i = i + 1
		else
			-- Non-ASCII: determine UTF-8 sequence length
			local seqlen = b >= 0xF0 and 4 or b >= 0xE0 and 3 or b >= 0xC0 and 2 or 1

			if i + seqlen - 1 <= len then
				-- Check suspicious patterns (pre-built first-byte lookup)
				local candidates = suspicious_by_first_byte[b]
				if candidates then
					local span = text:sub(i, math.min(i + 3, len))
					for _, pat in ipairs(candidates) do
						if #span >= #pat.bytes and span:sub(1, #pat.bytes) == pat.bytes then
							flag(pat.codepoint .. " " .. pat.label)
						end
					end
				end

				-- Check homoglyphs
				local seq = text:sub(i, i + seqlen - 1)
				local desc = homoglyph_map[seq]
				if desc then
					flag("homoglyph: " .. desc)
				end

				i = i + seqlen
			else
				i = i + 1
			end
		end
	end

	-- Vim modeline patterns — separate pass (Lua patterns, can't merge)
	for _, p in ipairs(VIM_INJECTION_PATTERNS) do
		if text:find(p.pattern) then
			flag("⚠ " .. p.label)
		end
	end

	return findings
end

--- Produce escaped representation for visual inspection.
--- Non-printable / non-ASCII bytes shown as <U+XXXX> or <0xXX>.
---@param text string
---@return string
local function to_raw_view(text)
	local out = {}
	local i = 1
	while i <= #text do
		local b = text:byte(i)
		if b == 0x09 then
			table.insert(out, "\\t")
			i = i + 1
		elseif b == 0x0a then
			table.insert(out, "?\n")
			i = i + 1
		elseif b == 0x0d then
			table.insert(out, "\\r")
			i = i + 1
		elseif b == 0x1b then
			table.insert(out, "<ESC>")
			i = i + 1
		elseif b < 0x20 or b == 0x7f then
			table.insert(out, string.format("<0x%02X>", b))
			i = i + 1
		elseif b < 0x80 then
			table.insert(out, string.char(b))
			i = i + 1
		else
			local seqlen = b >= 0xF0 and 4 or b >= 0xE0 and 3 or b >= 0xC0 and 2 or 1
			if i + seqlen - 1 <= #text then
				local seq = text:sub(i, i + seqlen - 1)
				local desc = homoglyph_map[seq]
				if desc then
					table.insert(out, "<" .. desc .. ">")
				else
					local flagged = false
					for _, p in ipairs(SUSPICIOUS_PATTERNS) do
						if seq == p.bytes then
							table.insert(out, "<" .. p.codepoint .. ">")
							flagged = true
							break
						end
					end
					if not flagged then
						table.insert(out, seq)
					end
				end
				i = i + seqlen
			else
				table.insert(out, string.format("<0x%02X>", b))
				i = i + 1
			end
		end
	end
	return table.concat(out)
end

--- Download the latest UTS#39 confusables.txt, parse it, save cache,
--- and hot-swap the live homoglyph map. Run once after install, then
--- again to update. Requires curl. Async — does not block the editor.
function M.update_confusables()
	if vim.fn.executable("curl") ~= 1 then
		vim.notify("clipboard-scanner: curl not found — cannot fetch confusables.txt", vim.log.levels.ERROR)
		return
	end
	vim.notify("clipboard-scanner: fetching UTS#39 confusables.txt from unicode.org.", vim.log.levels.INFO)
	vim.fn.jobstart({
		"curl",
		"--silent",
		"--fail",
		"--location",
		"https://unicode.org/Public/security/latest/confusables.txt",
	}, {
		stdout_buffered = true,
		on_stdout = function(_, data)
			if not data or #data == 0 then
				return
			end
			local raw = table.concat(data, "\n")
			local new_map = parse_confusables_txt(raw)
			local count = 0
			for _ in pairs(new_map) do
				count = count + 1
			end
			if count == 0 then
				vim.notify("clipboard-scanner: no entries parsed — response may be malformed", vim.log.levels.WARN)
				return
			end
			for k, v in pairs(BUILTIN_HOMOGLYPHS) do
				if not new_map[k] then
					new_map[k] = v
				end
			end
			save_confusables_cache(new_map)
			homoglyph_map = new_map
			vim.notify(
				string.format("clipboard-scanner: %d confusable entries loaded and cached (%s)", count, CACHE_PATH),
				vim.log.levels.INFO
			)
		end,
		on_stderr = function(_, data)
			if data and data[1] and data[1] ~= "" then
				vim.notify("clipboard-scanner: curl error " .. table.concat(data, " "), vim.log.levels.ERROR)
			end
		end,
	})
end

-- Public API
M.scan = scan_suspicious
M.to_raw_view = to_raw_view
M.update_confusables = M.update_confusables
M.homoglyph_map = homoglyph_map
M.confusables_cache = CACHE_PATH

return M
