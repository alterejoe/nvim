-- clipboard.lua
-- Unified clipboard: environment detection, history ring, register viewer.
--
-- Usage: require("clipboard").setup()
--
-- Keymaps (set in setup):
--   <leader>ch   toggle clipboard history viewer
--
-- Viewer keymaps:
--   <CR>         paste entry at cursor (after)
--   P            paste entry at cursor (before)
--   y            copy entry into + and " without pasting
--   R            raw view — show escaped bytes for entry (spot invisible chars)
--   d            delete entry from history
--   q / <Esc>    close

local M = {}

-- ── constants ────────────────────────────────────────────────────────────────

local HISTORY_MAX = 50

local TYPE_LABELS = {
	v = "char ",
	V = "line ",
	["\22"] = "block",
}

local function strip_icons(text)
	-- Remove common icon characters and their associated whitespace
	return text:gsub("[\xE2\x80\x94\xE2\x81\x83\xE2\x88\xA9\xC3\xBF\xC2\xA1\xC2\xA7]+%s*", "")
end

local function strip_whitespace(text)
	-- Remove leading/trailing whitespace from each line and the whole text
	text = text:gsub("^%s+", ""):gsub("%s+$", "") -- trim start/end
	text = text:gsub("\n%s+", "\n"):gsub("%s+\n", "\n") -- trim each line
	return text
end

-- ── suspicious content scanning ──────────────────────────────────────────────
--
-- Three distinct threat classes are tracked here:
--
--   1. INVISIBLE / BIDI CHARACTERS
--      Unicode characters that are invisible or that make text *look* different
--      from what it actually contains. Common in AI output, web pages, and
--      intentional supply-chain / prompt-injection attacks.
--
--   2. VIM MODELINE INJECTION
--      Patterns that exploit Vim's modeline feature to execute arbitrary code
--      when a file is opened. Relevant CVEs from 2026:
--        CVE-2026-34714 — tabpanel %{expr} injection + autocmd_add() sandbox escape
--        CVE-2026-34982 — complete/guitabtooltip/printheader missing P_MLE/P_SECURE flags
--      Modelines are enabled by default; modelineexpr does NOT need to be on.
--      If you paste one of these into a file and someone opens it, it fires.
--
--   3. UNICODE LOOKALIKE CHARACTERS (UTS#39 "confusables")
--      "Confusables" is the Unicode Consortium's official term (UTS#39: Unicode
--      Security Mechanisms) for characters that are visually identical or nearly
--      identical to other characters. Think Cyrillic 'е' vs Latin 'e'. The term
--      itself is jargon — what it means in practice is: characters that look like
--      ASCII but aren't, used to sneak past code review or fool humans reading
--      identifiers. M.update_confusables() downloads the full authoritative list.
--
-- We never silently strip — we flag and let you decide.

local SUSPICIOUS_PATTERNS = {
	-- ── invisible / zero-width characters ──────────────────────────────────
	{ bytes = "\xE2\x80\x8B", label = "zero-width space", codepoint = "U+200B" },
	{ bytes = "\xE2\x80\x8C", label = "zero-width non-joiner", codepoint = "U+200C" },
	{ bytes = "\xE2\x80\x8D", label = "zero-width joiner", codepoint = "U+200D" },
	{ bytes = "\xEF\xBB\xBF", label = "BOM / zero-width no-break", codepoint = "U+FEFF" },
	{ bytes = "\xC2\xAD", label = "soft hyphen", codepoint = "U+00AD" },
	{ bytes = "\xE2\x81\xA0", label = "word joiner", codepoint = "U+2060" },
	{ bytes = "\xE1\xA0\x8E", label = "mongolian vowel sep", codepoint = "U+180E" },
	-- ── bidi overrides — the "display != content" attack ───────────────────
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
	-- ── terminal sequences ──────────────────────────────────────────────────
	-- Dangerous if the text is ever re-pasted into a shell
	{ bytes = "\x1b%[", label = "ANSI escape sequence", codepoint = "ESC[" },
	{ bytes = "\x1b]", label = "ANSI OSC sequence", codepoint = "ESC]" },
}

-- ── vim modeline injection patterns ──────────────────────────────────────────
--
-- These are Lua patterns (not plain strings) matched against full text.
-- Each entry also carries a cve field for display in the viewer.
--
-- Matching strategy: we look for a modeline directive on any line, then check
-- whether it sets one of the known-dangerous options. A bare "vim:" line is
-- not flagged — only dangerous option combinations are.
--
-- Reference: `:help modeline`, CVE-2019-12735, CVE-2026-34714, CVE-2026-34982

local VIM_INJECTION_PATTERNS = {
	{
		-- tabpanel + %{expr}: the CVE-2026-34714 vector.
		-- tabpanel lacks P_MLE so expressions eval without modelineexpr.
		-- autocmd_add() then lets sandboxed code escape post-sandbox.
		pattern = "[^\n]*vim?%s*:[^\n]*tabpanel[^\n]*%%{",
		label = "vim modeline: tabpanel %{expr} injection (CVE-2026-34714)",
	},
	{
		-- complete= with a lambda/funcref: CVE-2026-34982 vector.
		-- complete lacks P_SECURE and P_MLE, so lambda expressions are accepted.
		pattern = "[^\n]*vim?%s*:[^\n]*complete%s*=[^\n]*[{F]",
		label = "vim modeline: complete= lambda expression (CVE-2026-34982)",
	},
	{
		-- guitabtooltip or printheader via modeline — same missing-flag class.
		pattern = "[^\n]*vim?%s*:[^\n]*gui[Tt]ab[Tt]ool[Tt]ip",
		label = "vim modeline: guitabtooltip option (CVE-2026-34982)",
	},
	{
		pattern = "[^\n]*vim?%s*:[^\n]*print[Hh]eader",
		label = "vim modeline: printheader option (CVE-2026-34982)",
	},
	{
		-- mapset() abuse via modeline — allows arbitrary key mapping injection.
		pattern = "[^\n]*vim?%s*:[^\n]*mapset",
		label = "vim modeline: mapset() call (CVE-2026-34982 chain)",
	},
	{
		-- Classic CVE-2019-12735 style: foldexpr / fde= in a modeline.
		-- Patched long ago but still worth flagging — sandbox escapes recur.
		pattern = "[^\n]*vim?%s*:[^\n]*f[od][el][de]?%s*=",
		label = "vim modeline: fold expression option (CVE-2019-12735 class)",
	},
	{
		-- Any modeline setting an expr-capable option with a system()/call().
		-- Catches improvised variants not covered by the specific CVEs above.
		pattern = "[^\n]*vim?%s*:[^\n]*system%s*(",
		label = "vim modeline: system() call",
	},
	{
		pattern = "[^\n]*vim?%s*:[^\n]*libcall%s*(",
		label = "vim modeline: libcall() — arbitrary library execution",
	},
	{
		-- autocmd_add inside any modeline expression context.
		pattern = "[^\n]*vim?%s*:[^\n]*autocmd_add",
		label = "vim modeline: autocmd_add() — sandbox escape (CVE-2026-34714)",
	},
}

-- Built-in fallback homoglyph table — used when the UTS#39 cache hasn't been
-- fetched yet. Call M.update_confusables() to download the full authoritative
-- set (~7 000 entries) from unicode.org/Public/security/latest/confusables.txt
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

-- Live table — replaced wholesale by load_confusables_cache / update_confusables
local homoglyph_map = BUILTIN_HOMOGLYPHS

-- ── confusables cache (UTS#39) ────────────────────────────────────────────────

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

-- Parse the raw text of confusables.txt into a utf8_bytes→description map.
-- Only retains entries where a non-ASCII source maps to a single printable
-- ASCII target — the only case that matters for visual deception in code.
local function parse_confusables_txt(raw)
	local map = {}
	for line in raw:gmatch("[^\n]+") do
		if not line:match("^%s*#") then
			-- format: source_hex ; target_hex ; type  # comment
			local src_hex, tgt_hex = line:match("^%s*(%x+)%s*;%s*(%x+)%s*;")
			if src_hex and tgt_hex then
				local src_cp = tonumber(src_hex, 16)
				local tgt_cp = tonumber(tgt_hex, 16)
				if
					src_cp
					and tgt_cp
					and src_cp > 0x7F -- source is non-ASCII
					and tgt_cp >= 0x21 -- target is printable ASCII
					and tgt_cp <= 0x7E
				then
					local src_utf8 = cp_to_utf8(src_cp)
					local tgt_char = string.char(tgt_cp)
					map[src_utf8] = string.format("looks like '%s' (U+%04X)", tgt_char, src_cp)
				end
			end
		end
	end
	return map
end

-- Save map to a tab-separated cache file. Bytes are hex-encoded for safety.
local function save_confusables_cache(map)
	local f = io.open(CACHE_PATH, "w")
	if not f then
		vim.notify("clipboard: could not write confusables cache to " .. CACHE_PATH, vim.log.levels.ERROR)
		return false
	end
	f:write("# clipboard.lua UTS#39 confusables cache — do not edit manually\n")
	for utf8_bytes, desc in pairs(map) do
		local hex = utf8_bytes:gsub(".", function(c)
			return string.format("%02X", c:byte())
		end)
		f:write(hex .. "\t" .. desc .. "\n")
	end
	f:close()
	return true
end

-- Load the cache file. Returns a map or nil if no cache exists yet.
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

-- Try to load cache at startup; fall back to built-ins silently.
do
	local cached = load_confusables_cache()
	if cached then
		homoglyph_map = cached
	end
end

---Scan text for suspicious characters. Returns a list of finding strings,
---empty if clean.
---
---Homoglyph check walks the text once (O(n)) and does a table lookup per
---UTF-8 sequence — safe even with the full ~7 000-entry UTS#39 map loaded.
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

	-- pattern-based checks (invisible chars, bidi overrides, ANSI sequences)
	for _, p in ipairs(SUSPICIOUS_PATTERNS) do
		if text:find(p.bytes, 1, true) or text:find(p.bytes) then
			flag(p.codepoint .. " " .. p.label)
		end
	end

	-- vim modeline injection checks (CVE-2026-34714, CVE-2026-34982, CVE-2019-12735 class)
	for _, p in ipairs(VIM_INJECTION_PATTERNS) do
		if text:find(p.pattern) then
			flag("⚡ " .. p.label)
		end
	end

	-- homoglyph check — single pass through text, O(1) lookup per sequence
	do
		local i = 1
		while i <= #text do
			local b = text:byte(i)
			if b < 0x80 then
				i = i + 1
			else
				local seqlen = b >= 0xF0 and 4 or b >= 0xE0 and 3 or b >= 0xC0 and 2 or 1
				local seq = text:sub(i, i + seqlen - 1)
				local desc = homoglyph_map[seq]
				if desc then
					flag("homoglyph: " .. desc)
				end
				i = i + seqlen
			end
		end
	end

	-- raw control characters (except tab 0x09 and newline 0x0a which are normal in code)
	for i = 1, #text do
		local b = text:byte(i)
		if b ~= 0x09 and b ~= 0x0a and b < 0x20 and b ~= 0x1b then
			-- 0x1b (ESC) is already caught by the ANSI pattern above
			flag("raw control character (non-printable byte 0x" .. string.format("%02X", b) .. ")")
			break
		end
	end

	return findings
end

---Produce an escaped representation of text suitable for visual inspection.
---Non-printable and non-ASCII bytes are shown as <U+XXXX> or <0xXX>.
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
			table.insert(out, "↵\n")
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
				-- homoglyph map is the authoritative source for labelling
				local desc = homoglyph_map[seq]
				if desc then
					table.insert(out, "<" .. desc .. ">")
				else
					-- check invisible/bidi patterns
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

-- ── environment detection ────────────────────────────────────────────────────

local function is_wsl()
	return vim.fn.has("wsl") == 1
end

local function is_ssh()
	return vim.env.SSH_CLIENT ~= nil or vim.env.SSH_TTY ~= nil
end

local function is_mac()
	return vim.fn.has("mac") == 1
end

local function has_nvim_010()
	return vim.fn.has("nvim-0.10") == 1
end

-- ── provider setup ───────────────────────────────────────────────────────────

local function setup_wsl()
	vim.g.clipboard = {
		name = "WSLClipboard",
		copy = {
			["+"] = "clip.exe",
			["*"] = "clip.exe",
		},
		paste = {
			-- strip \r\n at source so ^M never reaches nvim
			["+"] = 'powershell.exe -NoProfile -c [Console]::Out.Write($(Get-Clipboard -Raw).ToString().Replace("`r`n","`n").Replace("`r","`n"))',
			["*"] = 'powershell.exe -NoProfile -c [Console]::Out.Write($(Get-Clipboard -Raw).ToString().Replace("`r`n","`n").Replace("`r","`n"))',
		},
		cache_enabled = 0,
	}
end

local function setup_osc52()
	-- Neovim 0.10+ ships vim.ui.clipboard.osc52 — works over any SSH session
	-- as long as the terminal supports OSC 52 (WezTerm, iTerm2, kitty, foot, etc.)
	local osc = require("vim.ui.clipboard.osc52")
	vim.g.clipboard = {
		name = "OSC52",
		copy = { ["+"] = osc.copy("+"), ["*"] = osc.copy("*") },
		paste = { ["+"] = osc.paste("+"), ["*"] = osc.paste("*") },
		cache_enabled = 0,
	}
end

local function detect_linux_tool()
	-- Wayland first, then X11
	if vim.fn.executable("wl-copy") == 1 then
		return "wl-clipboard"
	elseif vim.fn.executable("xclip") == 1 then
		return "xclip"
	elseif vim.fn.executable("xsel") == 1 then
		return "xsel"
	end
	return nil
end

local function setup_provider()
	if is_wsl() then
		setup_wsl()
	elseif is_ssh() then
		if has_nvim_010() then
			setup_osc52()
		else
			-- Older nvim over SSH: we still track yanks internally.
			-- No system clipboard provider available; viewer still works.
			vim.notify(
				"clipboard: SSH + nvim < 0.10 — no OSC 52 support. Upgrade for clipboard sync.",
				vim.log.levels.WARN
			)
		end
	elseif is_mac() then
		-- pbcopy/pbpaste: neovim picks them up automatically, nothing to set
	else
		local tool = detect_linux_tool()
		if not tool then
			vim.notify(
				"clipboard: no clipboard tool found (install wl-clipboard, xclip, or xsel).",
				vim.log.levels.WARN
			)
		end
	end

	-- Do NOT set unnamedplus globally. That forces a provider sync check on
	-- every p/P keypress to see if the OS clipboard changed — that's where
	-- the WSL/SSH delay comes from. Instead we manage the two directions
	-- independently below (see TextYankPost and pull_from_os).
	vim.opt.clipboard = ""
end

-- ── clipboard direction management ───────────────────────────────────────────
--
-- Two directions, two latency budgets:
--
--   nvim → OS  (on every yank, async fire-and-forget)
--     Happens in the background. Never blocks. If it fails, nvim is unaffected.
--
--   OS → nvim  (only when you explicitly ask, or on FocusGained)
--     <leader>p / <leader>P  — pull OS clipboard then paste. Delay is expected.
--     FocusGained            — async background sync so that by the time you
--                              press p after switching windows, it's already ready.
--
--   p / P  — always instant. reads " register which is in-memory only.
--            normalization (strip \r, fix linewise) is pure Lua, zero I/O.

local _last_internal_text = nil -- tracks last text yanked inside nvim
local _os_cache = { text = nil, type = nil } -- last successfully pulled OS content

-- Push the current " register to the OS clipboard asynchronously.
-- Called from TextYankPost — never blocks the editor.
local function push_to_os(text, regtype)
	if is_wsl() then
		-- clip.exe reads from stdin, so pipe via shell
		local job = vim.fn.jobstart({ "clip.exe" }, {
			on_exit = function() end,
		})
		if job > 0 then
			vim.fn.chansend(job, text)
			vim.fn.chanclose(job, "stdin")
		end
	elseif is_ssh() and has_nvim_010() then
		-- OSC 52: write the escape sequence directly to the terminal.
		-- The terminal handles the Windows clipboard — zero process spawns.
		local encoded = vim.base64 and vim.base64.encode(text) or vim.fn.system("base64 -w0", text):gsub("\n", "")
		io.write("\x1b]52;c;" .. encoded .. "\x1b\\")
		io.flush()
	elseif is_mac() then
		local job = vim.fn.jobstart({ "pbcopy" }, { on_exit = function() end })
		if job > 0 then
			vim.fn.chansend(job, text)
			vim.fn.chanclose(job, "stdin")
		end
	else
		local tool = detect_linux_tool()
		if tool == "wl-clipboard" then
			local job = vim.fn.jobstart({ "wl-copy" }, { on_exit = function() end })
			if job > 0 then
				vim.fn.chansend(job, text)
				vim.fn.chanclose(job, "stdin")
			end
		elseif tool == "xclip" then
			local job = vim.fn.jobstart({ "xclip", "-selection", "clipboard" }, { on_exit = function() end })
			if job > 0 then
				vim.fn.chansend(job, text)
				vim.fn.chanclose(job, "stdin")
			end
		elseif tool == "xsel" then
			local job = vim.fn.jobstart({ "xsel", "--clipboard", "--input" }, { on_exit = function() end })
			if job > 0 then
				vim.fn.chansend(job, text)
				vim.fn.chanclose(job, "stdin")
			end
		end
	end
	-- mirror into internal " so p/P always have it without a provider call
	_os_cache = { text = text, type = regtype }
end

-- Pull OS clipboard into " register. Has latency — only call explicitly.
local function pull_from_os(callback)
	local function normalize(text, regtype)
		text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
		local without_trail = text:match("^(.*)\n$")
		if without_trail and not without_trail:match("\n$") then
			text = without_trail
		end
		if regtype == "V" and not text:find("\n") then
			regtype = "v"
		end
		return text, regtype
	end

	if is_wsl() then
		vim.fn.jobstart({
			"powershell.exe",
			"-NoProfile",
			"-c",
			'[Console]::Out.Write($(Get-Clipboard -Raw).ToString().Replace("`r`n","`n").Replace("`r","`n"))',
		}, {
			stdout_buffered = true,
			on_stdout = function(_, data)
				if not data then
					return
				end
				local text, regtype = normalize(table.concat(data, "\n"), "v")
				if text ~= "" then
					_os_cache = { text = text, type = regtype }
					vim.fn.setreg('"', text, regtype)
					if callback then
						callback(text, regtype)
					end
				end
			end,
		})
	elseif is_mac() then
		vim.fn.jobstart({ "pbpaste" }, {
			stdout_buffered = true,
			on_stdout = function(_, data)
				if not data then
					return
				end
				local text, regtype = normalize(table.concat(data, "\n"), "v")
				if text ~= "" then
					_os_cache = { text = text, type = regtype }
					vim.fn.setreg('"', text, regtype)
					if callback then
						callback(text, regtype)
					end
				end
			end,
		})
	else
		local tool = detect_linux_tool()
		local cmd = tool == "wl-clipboard" and { "wl-paste", "--no-newline" }
			or tool == "xclip" and { "xclip", "-o", "-selection", "clipboard" }
			or tool == "xsel" and { "xsel", "--clipboard", "--output" }
			or nil
		if not cmd then
			return
		end
		vim.fn.jobstart(cmd, {
			stdout_buffered = true,
			on_stdout = function(_, data)
				if not data then
					return
				end
				local text, regtype = normalize(table.concat(data, "\n"), "v")
				if text ~= "" then
					_os_cache = { text = text, type = regtype }
					vim.fn.setreg('"', text, regtype)
					if callback then
						callback(text, regtype)
					end
				end
			end,
		})
	end
end

-- ── history ring ─────────────────────────────────────────────────────────────

local history = {} ---@type {text:string, register:string, type:string, time:integer}[]

local function add_history(entry)
	-- skip operator-pending/internal yanks into special registers
	local skip = { ["/"] = true, [":"] = true, ["."] = true, ["%"] = true, ["#"] = true }
	if skip[entry.register] then
		return
	end
	-- deduplicate consecutive identical text
	if history[1] and history[1].text == entry.text then
		return
	end
	table.insert(history, 1, entry)
	if #history > HISTORY_MAX then
		table.remove(history)
	end
end

local _in_setreg = false -- re-entry guard

vim.api.nvim_create_autocmd("TextYankPost", {
	desc = "Clipboard: record yank + async push to OS",
	callback = function()
		if _in_setreg then
			return
		end
		local ev = vim.v.event
		local text = table.concat(ev.regcontents, "\n")
		text = strip_icons(text)
		text = strip_whitespace(text)
		if text == "" then
			return
		end
		local warnings = scan_suspicious(text)
		local reg = (ev.regname == "" or ev.regname == nil) and '"' or ev.regname
		_last_internal_text = text
		add_history({
			text = text,
			register = reg,
			type = ev.regtype,
			time = os.time(),
			warnings = warnings,
		})
		-- Push to OS clipboard asynchronously ΓÇö fire and forget, never blocks.
		-- Delay is acceptable here; you're copying, not waiting to paste.
		push_to_os(text, ev.regtype)
	end,
})

-- Sync OS → " on FocusGained so external clipboard content is ready
-- before you press p, not after.
vim.api.nvim_create_autocmd("FocusGained", {
	desc = "Clipboard: background sync from OS on focus",
	callback = function()
		pull_from_os(nil) -- no callback — just warm the cache silently
	end,
})

-- ── paste normalization ───────────────────────────────────────────────────────
--
-- p / P  — instant. reads " (in-memory). normalization is pure Lua, zero I/O.
-- <leader>p / <leader>P — pull OS clipboard first (has latency), then paste.
--
-- This separation is why p/P feel instant: they never touch the OS clipboard
-- provider. The OS sync happens either on FocusGained (background) or when
-- you explicitly use <leader>p.

local function normalize_reg()
	local text = vim.fn.getreg('"')
	local regtype = vim.fn.getregtype('"')

	local normalized = text:gsub("\r\n", "\n"):gsub("\r", "\n")

	local without_trail = normalized:match("^(.*)\n$")
	if without_trail and not without_trail:match("\n$") then
		normalized = without_trail
	end

	if regtype == "V" and not normalized:find("\n") then
		regtype = "v"
	end

	if normalized ~= text or regtype ~= vim.fn.getregtype('"') then
		_in_setreg = true
		vim.fn.setreg('"', normalized, regtype)
		_in_setreg = false
	end
end

-- Add padded_paste HERE, after normalize_reg
local function padded_paste()
	normalize_reg()
	local text = vim.fn.getreg('"')
	local regtype = vim.fn.getregtype('"')

	if regtype == "V" then
		text = "\n" .. text .. "\n"
	else
		text = text .. "\n"
	end

	vim.fn.setreg('"', text, regtype)
	vim.cmd("normal! p")
end
-- Instant paste — reads " only, never invokes OS clipboard provider.
vim.keymap.set({ "n", "x" }, "p", function()
	normalize_reg()
	return "p"
end, { expr = true, desc = "Paste after (instant)", noremap = true })

vim.keymap.set({ "n", "x" }, "P", function()
	normalize_reg()
	return "P"
end, { expr = true, desc = "Paste before (instant)", noremap = true })

vim.keymap.set("n", "]p", padded_paste, { desc = "Paste with padding" })

-- OS clipboard paste — pulls from OS first, then pastes. Delay is expected.
vim.keymap.set("n", "<leader>p", function()
	pull_from_os(function()
		normalize_reg()
		vim.cmd("normal! p")
	end)
end, { desc = "Paste from OS clipboard (after)" })

vim.keymap.set("n", "<leader>P", function()
	pull_from_os(function()
		normalize_reg()
		vim.cmd("normal! P")
	end)
end, { desc = "Paste from OS clipboard (before)" })

-- ── viewer ───────────────────────────────────────────────────────────────────

local viewer_state = { buf = nil, win = nil }

local function age_str(t)
	local s = os.difftime(os.time(), t)
	if s < 60 then
		return s .. "s"
	end
	if s < 3600 then
		return math.floor(s / 60) .. "m"
	end
	return math.floor(s / 3600) .. "h"
end

-- Returns { lines, map } where map[line_number] = history_index
local function render_history()
	if #history == 0 then
		return { "  (no yanks recorded yet)" }, {}
	end

	local lines = {}
	local map = {}

	for i, entry in ipairs(history) do
		local type_label = TYPE_LABELS[entry.type] or "?    "
		local reg_label = entry.register == '"' and '""' or ('"' .. entry.register)
		local warn_flag = (entry.warnings and #entry.warnings > 0) and "  ⚠" or ""
		-- header line
		local header =
			string.format(" %2d  reg %-3s  %s  %s%s", i, reg_label, type_label, age_str(entry.time), warn_flag)
		table.insert(lines, header)
		map[#lines] = i

		-- warning detail lines
		if entry.warnings and #entry.warnings > 0 then
			for _, w in ipairs(entry.warnings) do
				table.insert(lines, "     ⚠ " .. w)
				map[#lines] = i
			end
		end

		-- preview lines (up to 3)
		local preview_lines = vim.split(entry.text, "\n", { plain = true })
		for j = 1, math.min(3, #preview_lines) do
			local pline = "     " .. preview_lines[j]:gsub("\t", "  "):sub(1, 74)
			table.insert(lines, pline)
			map[#lines] = i
		end
		if #preview_lines > 3 then
			table.insert(lines, "     …(" .. (#preview_lines - 3) .. " more lines)")
			map[#lines] = i
		end

		table.insert(lines, "") -- spacer
	end

	return lines, map
end

local function viewer_close()
	if viewer_state.win and vim.api.nvim_win_is_valid(viewer_state.win) then
		vim.api.nvim_win_close(viewer_state.win, true)
	end
	viewer_state.win = nil
	viewer_state.buf = nil
end

local function viewer_redraw(map_ref)
	local lines, new_map = render_history()
	-- update map in place so keymaps still reference it
	for k in pairs(map_ref) do
		map_ref[k] = nil
	end
	for k, v in pairs(new_map) do
		map_ref[k] = v
	end

	vim.bo[viewer_state.buf].modifiable = true
	vim.api.nvim_buf_set_lines(viewer_state.buf, 0, -1, false, lines)
	vim.bo[viewer_state.buf].modifiable = false
end

local function viewer_open()
	if viewer_state.win and vim.api.nvim_win_is_valid(viewer_state.win) then
		viewer_close()
		return
	end

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "ClipboardHistory"
	vim.bo[buf].swapfile = false
	viewer_state.buf = buf

	local width = math.min(84, vim.o.columns - 4)
	local height = math.min(32, vim.o.lines - 4)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = "rounded",
		title = " Clipboard History ",
		title_pos = "center",
	})
	viewer_state.win = win
	vim.wo[win].cursorline = true
	vim.wo[win].wrap = false
	vim.wo[win].number = false

	-- highlight groups (set once)
	vim.api.nvim_set_hl(0, "ClipboardHeader", { link = "Title", default = true })
	vim.api.nvim_set_hl(0, "ClipboardPreview", { link = "Comment", default = true })

	local map = {}
	viewer_redraw(map)

	-- ── viewer keymaps ──────────────────────────────────────────────────────

	local function km(key, fn, desc)
		vim.keymap.set("n", key, fn, { buffer = buf, desc = desc, nowait = true, silent = true })
	end

	local function entry_at_cursor()
		local lnum = vim.api.nvim_win_get_cursor(win)[1]
		local idx = map[lnum]
		if idx then
			return history[idx], idx
		end
	end

	km("<CR>", function()
		local entry = entry_at_cursor()
		if not entry then
			return
		end
		vim.fn.setreg('"', entry.text, entry.type)
		vim.fn.setreg("+", entry.text, entry.type)
		viewer_close()
		vim.schedule(function()
			vim.cmd("normal! p")
		end)
	end, "Paste after cursor")

	km("P", function()
		local entry = entry_at_cursor()
		if not entry then
			return
		end
		vim.fn.setreg('"', entry.text, entry.type)
		vim.fn.setreg("+", entry.text, entry.type)
		viewer_close()
		vim.schedule(function()
			vim.cmd("normal! P")
		end)
	end, "Paste before cursor")

	km("y", function()
		local entry = entry_at_cursor()
		if not entry then
			return
		end
		vim.fn.setreg('"', entry.text, entry.type)
		vim.fn.setreg("+", entry.text, entry.type)
		vim.notify("clipboard: pulled to + register — " .. entry.text:sub(1, 48))
	end, "Copy to clipboard without pasting")

	km("d", function()
		local _, idx = entry_at_cursor()
		if not idx then
			return
		end
		table.remove(history, idx)
		viewer_redraw(map)
	end, "Delete entry from history")

	km("R", function()
		local entry = entry_at_cursor()
		if not entry then
			return
		end

		-- open a small secondary float showing the escaped raw content
		local raw = to_raw_view(entry.text)
		local raw_lines = vim.split(raw, "\n", { plain = true })

		-- prefix each line so it's obvious this is the raw view
		local display = { " RAW VIEW — suspicious chars shown as <U+XXXX>", " " }
		for _, l in ipairs(raw_lines) do
			table.insert(display, " " .. l)
		end

		local rbuf = vim.api.nvim_create_buf(false, true)
		vim.bo[rbuf].buftype = "nofile"
		vim.bo[rbuf].bufhidden = "wipe"
		vim.api.nvim_buf_set_lines(rbuf, 0, -1, false, display)
		vim.bo[rbuf].modifiable = false

		local rwidth = math.min(84, vim.o.columns - 8)
		local rheight = math.min(20, #display + 2)
		local rwin = vim.api.nvim_open_win(rbuf, true, {
			relative = "editor",
			width = rwidth,
			height = rheight,
			row = math.floor((vim.o.lines - rheight) / 2),
			col = math.floor((vim.o.columns - rwidth) / 2),
			style = "minimal",
			border = "rounded",
			title = " Raw Bytes ",
			title_pos = "center",
		})
		vim.wo[rwin].wrap = true

		-- close with q/Esc, return focus to history viewer
		for _, k in ipairs({ "q", "<Esc>", "R" }) do
			vim.keymap.set("n", k, function()
				vim.api.nvim_win_close(rwin, true)
				if viewer_state.win and vim.api.nvim_win_is_valid(viewer_state.win) then
					vim.api.nvim_set_current_win(viewer_state.win)
				end
			end, { buffer = rbuf, nowait = true, silent = true })
		end
	end, "Raw view — inspect escaped bytes")

	km("q", viewer_close, "Close")
	km("<Esc>", viewer_close, "Close")
end

-- ── public API ───────────────────────────────────────────────────────────────

---Download the latest UTS#39 confusables.txt from unicode.org, parse it,
---save a local cache, and hot-swap the live homoglyph map.
---Run once after install, then again whenever you want to update.
---Requires curl. Async — does not block the editor.
function M.update_confusables()
	if vim.fn.executable("curl") ~= 1 then
		vim.notify("clipboard: curl not found — cannot fetch confusables.txt", vim.log.levels.ERROR)
		return
	end
	vim.notify("clipboard: fetching UTS#39 confusables.txt from unicode.org…", vim.log.levels.INFO)
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
				vim.notify("clipboard: no entries parsed — response may be malformed", vim.log.levels.WARN)
				return
			end
			-- keep built-ins for anything the official list doesn't cover
			for k, v in pairs(BUILTIN_HOMOGLYPHS) do
				if not new_map[k] then
					new_map[k] = v
				end
			end
			save_confusables_cache(new_map)
			homoglyph_map = new_map
			vim.notify(
				string.format("clipboard: %d confusable entries loaded and cached (%s)", count, CACHE_PATH),
				vim.log.levels.INFO
			)
		end,
		on_stderr = function(_, data)
			if data and data[1] and data[1] ~= "" then
				vim.notify("clipboard: curl error — " .. table.concat(data, " "), vim.log.levels.ERROR)
			end
		end,
	})
end

function M.setup(opts)
	opts = opts or {}

	setup_provider()

	local key = (opts.history_key ~= nil) and opts.history_key or "<leader>ch"
	if key and key ~= "" then
		vim.keymap.set("n", key, viewer_open, { desc = "Clipboard history" })
	end
end

-- Expose internals for power users / testing
M.history = history
M.open_viewer = viewer_open
M.homoglyph_map = homoglyph_map -- current live map (read-only reference)
M.confusables_cache = CACHE_PATH

return M
