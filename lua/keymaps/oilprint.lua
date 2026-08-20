-- /home/jmeyer/.config/nvim/lua/keymaps/oilprint.lua FINAL
local PRINTER = "HP LaserJet Pro M501dn UPD PCL 6"
local MANUAL_FEED_PRINTER = "HP LaserJet Pro M501dn UPD PCL 6" -- change to your exact printer name
---------------------------------------------------------------------
-- Notifications
---------------------------------------------------------------------
local function info(msg)
	vim.notify(msg, vim.log.levels.INFO, { title = "PDF" })
end
local function warn(msg)
	vim.notify(msg, vim.log.levels.WARN, { title = "PDF" })
end
local function err(msg)
	vim.notify(msg, vim.log.levels.ERROR, { title = "PDF" })
end
local function exit_visual()
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", true)
end
---------------------------------------------------------------------
-- Printer selection
---------------------------------------------------------------------
local function select_printer()
	local output = vim.fn.system('powershell.exe -c "Get-Printer | Select-Object -ExpandProperty Name"')
	local printers = {}
	for line in output:gmatch("[^\r\n]+") do
		line = line:gsub("^%s+", ""):gsub("%s+$", "")
		if line ~= "" then
			table.insert(printers, line)
		end
	end
	if #printers == 0 then
		err("No printers found")
		return
	end
	vim.ui.select(printers, { prompt = "Select printer:" }, function(choice)
		if choice then
			PRINTER = choice
			info("Printer set to: " .. choice)
		end
	end)
end
---------------------------------------------------------------------
-- Oil + Visual helpers (ONLY visual range is used)
---------------------------------------------------------------------
local function get_visual_pdfs()
	local oil = require("oil")
	local dir = oil.get_current_dir()
	if not dir then
		return nil
	end
	local pos_start = vim.fn.getpos("'<")
	local pos_end = vim.fn.getpos("'>")
	local start_line, start_col = pos_start[2], pos_start[3]
	local end_line, end_col = pos_end[2], pos_end[3]
	local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
	if #lines == 0 then
		return nil
	end
	if #lines == 1 then
		lines[1] = lines[1]:sub(start_col, end_col)
	else
		lines[1] = lines[1]:sub(start_col)
		lines[#lines] = lines[#lines]:sub(1, end_col)
	end
	local paths = {}
	for _, line in ipairs(lines) do
		local name = line:match("([^/\\%s]+%.pdf)")
		if name then
			table.insert(paths, dir .. name)
		end
	end
	return #paths > 0 and paths or nil
end
local function get_current_pdf()
	local oil = require("oil")
	local dir = oil.get_current_dir()
	if not dir then
		return nil
	end
	local entry = oil.get_cursor_entry()
	if entry and entry.name:match("%.pdf$") then
		return { dir .. entry.name }
	end
	return nil
end
local function get_current_excel()
	local oil = require("oil")
	local dir = oil.get_current_dir()
	if not dir then
		return nil
	end
	local entry = oil.get_cursor_entry()
	if entry and entry.name:match("%.xlsx?$") then
		return dir .. entry.name
	end
	return nil
end
local function get_current_csv()
	local oil = require("oil")
	local dir = oil.get_current_dir()
	if not dir then
		return nil
	end
	local entry = oil.get_cursor_entry()
	if entry and (entry.name:match("%.csv$") or entry.name:match("%.txt$") or entry.name:match("%.tsv$")) then
		return dir .. entry.name
	end
	return nil
end
local function get_visual_csvs()
	local oil = require("oil")
	local dir = oil.get_current_dir()
	if not dir then
		return nil
	end
	local pos_start = vim.fn.getpos("'<")
	local pos_end = vim.fn.getpos("'>")
	local start_line, start_col = pos_start[2], pos_start[3]
	local end_line, end_col = pos_end[2], pos_end[3]
	local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
	if #lines == 0 then
		return nil
	end
	if #lines == 1 then
		lines[1] = lines[1]:sub(start_col, end_col)
	else
		lines[1] = lines[1]:sub(start_col)
		lines[#lines] = lines[#lines]:sub(1, end_col)
	end
	local paths = {}
	for _, line in ipairs(lines) do
		local name = line:match("([^/\\%s]+%.csv)") or line:match("([^/\\%s]+%.txt)") or line:match("([^/\\%s]+%.tsv)")
		if name then
			table.insert(paths, dir .. name)
		end
	end
	return #paths > 0 and paths or nil
end
---------------------------------------------------------------------
-- PDF operations
---------------------------------------------------------------------
local function quote_path(path)
	return '"' .. path:gsub('"', '\\"') .. '"'
end
local function extract_odd_pages(input)
	local out = "/tmp/odd_pages_" .. vim.fn.sha256(input) .. ".pdf"
	local input_quoted = quote_path(input)
	local out_quoted = quote_path(out)
	local cmd = string.format("qpdf --warning-exit-0 %s --pages . 1-z:odd -- %s", input_quoted, out_quoted)
	local result = vim.fn.system(cmd)
	local code = vim.v.shell_error
	if code ~= 0 then
		local lines = {}
		for l in result:gmatch("[^\r\n]+") do
			table.insert(lines, l)
			if #lines >= 10 then
				break
			end
		end
		vim.notify(
			"Failed to extract odd pages:\n" .. table.concat(lines, "\n"),
			vim.log.levels.ERROR,
			{ title = "PDF" }
		)
		return nil
	end
	return out
end
local function scale_to_letter(input)
	local tmp = "/tmp/scaled_tmp_" .. vim.fn.sha256(input) .. ".pdf"
	local out = "/tmp/scaled_letter_" .. vim.fn.sha256(input) .. ".pdf"
	-- step 1: fit content to smaller area (letter minus 0.25" margins each side)
	local cmd1 = string.format(
		"gs -q -dNOPAUSE -dBATCH -sDEVICE=pdfwrite -dCompatibilityLevel=1.4"
			.. " -dPDFFitPage -dFIXEDMEDIA"
			.. " -dDEVICEWIDTHPOINTS=576 -dDEVICEHEIGHTPOINTS=756"
			.. " -sOutputFile=%s %s",
		quote_path(tmp),
		quote_path(input)
	)
	local r1 = vim.fn.system(cmd1)
	if vim.v.shell_error ~= 0 then
		err("GS scale failed:\n" .. r1:sub(1, 300))
		return nil
	end
	-- step 2: place on full letter page with 18pt (0.25") offset so content is centered
	local cmd2 = string.format(
		"gs -q -dNOPAUSE -dBATCH -sDEVICE=pdfwrite -dCompatibilityLevel=1.4"
			.. " -dDEVICEWIDTHPOINTS=612 -dDEVICEHEIGHTPOINTS=792 -dFIXEDMEDIA"
			.. " -sOutputFile=%s"
			.. ' -c "<</BeginPage{18 18 translate}>> setpagedevice"'
			.. " -f %s",
		quote_path(out),
		quote_path(tmp)
	)
	local r2 = vim.fn.system(cmd2)
	if vim.v.shell_error ~= 0 then
		err("GS center failed:\n" .. r2:sub(1, 300))
		return nil
	end
	return out
end
---------------------------------------------------------------------
-- Printer media type (for labels, etc.)
---------------------------------------------------------------------
local function set_printer_media_type(printer_name, media_type, callback)
	local name = printer_name or PRINTER
	if not name then
		if callback then
			callback()
		end
		return
	end
	-- Modify PrintTicket XML to set PageMediaType
	local ps = string.format(
		[[powershell.exe -NoProfile -c "$c = Get-PrintConfiguration -PrinterName '%s'; $xml = $c.PrintTicketXML -replace 'name=\"psk:PageMediaType\"><psf:Option name=\"[^\"]*\"', 'name=\"psk:PageMediaType\"><psf:Option name=\"ns0000:%s\"'; Set-PrintConfiguration -PrinterName '%s' -PrintTicketXml $xml"]],
		name,
		media_type,
		name
	)
	vim.fn.jobstart(ps, {
		on_exit = function(_, code)
			if code ~= 0 then
				warn("Could not set media type to " .. media_type)
			end
			if callback then
				callback()
			end
		end,
	})
end
local function merge_pdfs(paths)
	if #paths == 1 then
		return paths[1]
	end
	local out = "/tmp/merged_print_" .. vim.fn.sha256(table.concat(paths)) .. ".pdf"
	local quoted = {}
	for _, p in ipairs(paths) do
		table.insert(quoted, '"' .. p .. '"')
	end
	local code = os.execute(string.format("pdfunite %s %s", table.concat(quoted, " "), out))
	return code == 0 and out or nil
end
---------------------------------------------------------------------
-- Printing
---------------------------------------------------------------------
local function to_windows_temp(path)
	os.execute("mkdir -p /mnt/c/Temp")
	local name = path:match("([^/]+)$")
	local win_path = "/mnt/c/Temp/oil-print-" .. name
	os.execute(string.format('cp "%s" "%s"', path, win_path))
	return win_path
end
local function print_pdfs(paths, odd_only, extra_settings, printer_override, scale_mode)
	extra_settings = extra_settings or "simplex"
	if not paths or #paths == 0 then
		warn("No PDFs selected")
		return
	end
	info(string.format("Preparing %d PDF(s)…", #paths))
	local merged = merge_pdfs(paths)
	if not merged then
		err("Failed to merge PDFs")
		return
	end
	if odd_only then
		local odd = extract_odd_pages(merged)
		if not odd then
			err("Failed to extract odd pages")
			return
		end
		merged = odd
	end
	if scale_mode == "fit" then
		local scaled = scale_to_letter(merged)
		if not scaled then
			err("Failed to scale PDF to letter")
			return
		end
		merged = scaled
	end
	local temp = to_windows_temp(merged)
	local win_path = vim.fn.system('wslpath -w "' .. temp .. '"'):gsub("\n", "")
	local printer = printer_override or PRINTER
	local printer_flag = printer and string.format('-print-to "%s"', printer) or "-print-to-default"
	-- build print-settings: always noscale since we pre-scale with gs
	local settings = "noscale"
	if extra_settings then
		settings = settings .. "," .. extra_settings
	end
	local cmd = string.format(
		'cmd.exe /c SumatraPDF.exe %s -silent -print-settings "%s" "%s"',
		printer_flag,
		settings,
		win_path
	)
	local label_parts = {}
	table.insert(label_parts, string.format("Sent %d PDF(s)", #paths))
	if odd_only then
		table.insert(label_parts, "odd pages")
	end
	if extra_settings then
		table.insert(label_parts, extra_settings)
	end
	if scale_mode and scale_mode ~= "noscale" then
		table.insert(label_parts, scale_mode)
	end
	if printer_override then
		table.insert(label_parts, "→ " .. printer_override)
	end
	vim.fn.jobstart(cmd, {
		on_exit = function(_, code)
			if code == 0 then
				info(table.concat(label_parts, ", "))
			else
				err("Print command failed")
			end
		end,
	})
end
---------------------------------------------------------------------
-- Label printing (fit + Labels media type, reset after)
---------------------------------------------------------------------
local function print_labels(paths, printer_override)
	if not paths or #paths == 0 then
		warn("No PDFs selected")
		return
	end
	local printer = printer_override or PRINTER
	info("Setting media type to Labels…")
	set_printer_media_type(printer, "LABELS", function()
		local merged = merge_pdfs(paths)
		if not merged then
			err("Failed to merge PDFs")
			set_printer_media_type(printer, "AUTO", nil)
			return
		end
		local scaled = scale_to_letter(merged)
		if not scaled then
			err("Failed to scale PDF to letter")
			set_printer_media_type(printer, "AUTO", nil)
			return
		end
		local temp = to_windows_temp(scaled)
		local win_path = vim.fn.system('wslpath -w "' .. temp .. '"'):gsub("\n", "")
		local printer_flag = printer and string.format('-print-to "%s"', printer) or "-print-to-default"
		local cmd = string.format(
			'cmd.exe /c SumatraPDF.exe %s -silent -print-settings "noscale,simplex,bin=Manual Feed" "%s"',
			printer_flag,
			win_path
		)
		info(string.format("Printing %d label PDF(s)…", #paths))
		vim.fn.jobstart(cmd, {
			on_exit = function(_, code)
				if code == 0 then
					info(string.format("Sent %d label PDF(s)", #paths))
				else
					err("Print command failed")
				end
				-- reset media type back to plain
				set_printer_media_type(printer, "AUTO", function()
					info("Media type reset to Auto")
				end)
			end,
		})
	end)
end
---------------------------------------------------------------------
-- Excel printing (VBScript COM - much faster than PowerShell)
---------------------------------------------------------------------
local function print_excel(path, odd_only, extra_settings)
	if not path then
		warn("No Excel file selected")
		return
	end
	info("Converting: " .. path:match("([^/]+)$"))
	local temp = to_windows_temp(path)
	local win_path = vim.fn.system({ "wslpath", "-w", temp }):gsub("%s+$", "")
	local basename = path:match("([^/]+)%..+$")
	local pdf_win = "C:\\Temp\\oil-print-" .. basename .. ".pdf"
	local pdf_wsl = "/mnt/c/Temp/oil-print-" .. basename .. ".pdf"

	local vbs_script = "/mnt/c/Temp/oil-print-excel.vbs"
	local f = io.open(vbs_script, "w")
	if not f then
		err("Could not write temp script")
		return
	end

	f:write(string.format(
		[[Set x = CreateObject("Excel.Application")
x.Visible = False
x.DisplayAlerts = False
x.ScreenUpdating = False
Set wb = x.Workbooks.Open("%s")
wb.ExportAsFixedFormat 0, "%s"
wb.Close False
x.Quit
]],
		win_path,
		pdf_win
	))
	f:close()

	vim.fn.jobstart('cmd.exe /c "cd /d C:\\Temp && cscript //nologo oil-print-excel.vbs"', {
		cwd = "/mnt/c/Temp",
		stderr_buffered = true,
		on_stderr = function(_, data)
			if data and data[1] ~= "" then
				err(table.concat(data, "\n"))
			end
		end,
		on_exit = function(_, code)
			if code ~= 0 then
				err("Excel PDF export failed (code " .. code .. ")")
				return
			end
			print_pdfs({ pdf_wsl }, odd_only, extra_settings)
		end,
	})
end
---------------------------------------------------------------------
-- CSV / TXT Table Printing
---------------------------------------------------------------------
----------------- Add this after print_csv, before the "Combine PDFs" section
local function print_txt(path, odd_only, extra_settings, printer_override, scale_mode)
	if not path then
		warn("No TXT file selected")
		return
	end
	local pdf_out = "/tmp/txt-print-" .. vim.fn.sha256(path) .. ".pdf"
	local py_script = "/tmp/txt_to_pdf.py"
	local f = io.open(py_script, "w")
	if not f then
		err("Could not write Python script")
		return
	end
	f:write([=[
import sys
from reportlab.lib.pagesizes import letter
from reportlab.lib.units import inch
from reportlab.platypus import SimpleDocTemplate, Paragraph
from reportlab.lib.styles import ParagraphStyle

with open(sys.argv[1], "r", encoding="utf-8-sig") as fh:
    lines = fh.read().splitlines()

doc = SimpleDocTemplate(sys.argv[2], pagesize=letter,
    leftMargin=0.5*inch, rightMargin=0.5*inch,
    topMargin=0.5*inch, bottomMargin=0.5*inch)
style = ParagraphStyle("m", fontName="Courier", fontSize=9, leading=12)
doc.build([Paragraph(l.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;") or " ", style) for l in lines])
]=])
	f:close()
	vim.fn.jobstart(string.format('~/miniconda3/bin/python %s "%s" "%s"', py_script, path, pdf_out), {
		stdout_buffered = true,
		stderr_buffered = true,
		on_exit = function(_, code)
			if code ~= 0 then
				err("TXT to PDF failed")
				return
			end
			print_pdfs({ pdf_out }, odd_only, extra_settings, printer_override, scale_mode)
		end,
	})
end
------------------------------------------------------
-- Combine PDFs (pattern-based, NOT visual)
---------------------------------------------------------------------
local function combine_selected_pdfs()
	local oil = require("oil")
	local dir = oil.get_current_dir()
	if not dir then
		err("Not in Oil buffer")
		return
	end
	local pattern = vim.fn.input("PDF pattern (empty = all): ")
	local selected = {}
	local handle = io.popen('ls -1 "' .. dir .. '"')
	if handle then
		for file in handle:lines() do
			if file:match("%.pdf$") and (pattern == "" or file:match(pattern)) then
				table.insert(selected, file)
			end
		end
		handle:close()
	end
	if #selected == 0 then
		warn("No PDFs matched")
		return
	end
	table.sort(selected)
	local default_output = dir .. "../Ballots.pdf"
	local output = vim.fn.input("Output path: ", default_output, "file")
	if output == "" then
		info("Cancelled")
		return
	end
	local quoted = {}
	for _, f in ipairs(selected) do
		table.insert(quoted, '"' .. dir .. f .. '"')
	end
	vim.fn.jobstart(string.format('pdfunite %s "%s"', table.concat(quoted, " "), output), {
		on_exit = function(_, code)
			if code == 0 then
				info(string.format("Combined %d PDFs → %s", #selected, output))
			else
				err("Failed to combine PDFs")
			end
		end,
	})
end
---------------------------------------------------------------------
-- Explorer (pure Lua path conversion, no shell)
---------------------------------------------------------------------
local function open_in_explorer()
	local oil = require("oil")
	local dir = oil.get_current_dir()
	if not dir then
		warn("Not in Oil buffer")
		return
	end
	dir = dir:gsub("/$", "")

	local win_path
	local drive, rest = dir:match("^/mnt/(%a)/(.*)")
	if drive then
		win_path = drive:upper() .. ":\\" .. rest:gsub("/", "\\")
	else
		local distro = os.getenv("WSL_DISTRO_NAME") or "Ubuntu"
		win_path = "\\\\wsl.localhost\\" .. distro .. dir:gsub("/", "\\")
	end

	vim.fn.jobstart({ "explorer.exe", win_path }, { detach = true })
end
---------------------------------------------------------------------
-- Print word docs
---------------------------------------------------------------------
local function get_current_doc()
	local oil = require("oil")
	local dir = oil.get_current_dir()
	if not dir then
		return nil
	end
	local entry = oil.get_cursor_entry()
	if entry and entry.name:match("%.docx?$") then
		return dir .. entry.name
	end
	return nil
end

local function print_doc(path, odd_only, extra_settings, printer_override)
	if not path then
		warn("No Word file selected")
		return
	end
	info("Converting: " .. path:match("([^/]+)$"))
	local temp = to_windows_temp(path)
	local win_path = vim.fn.system({ "wslpath", "-w", temp }):gsub("%s+$", "")
	local basename = path:match("([^/]+)%..+$")
	local pdf_win = "C:\\Temp\\oil-print-" .. basename .. ".pdf"
	local pdf_wsl = "/mnt/c/Temp/oil-print-" .. basename .. ".pdf"

	local ps_script = "/mnt/c/Temp/oil-print-word.ps1"
	local f = io.open(ps_script, "w")
	if not f then
		err("Could not write temp script")
		return
	end

	f:write(string.format(
		[[$w = New-Object -ComObject Word.Application
$w.Visible = $false
$w.DisplayAlerts = 0
$doc = $w.Documents.Open('%s')
$doc.SaveAs2('%s', 17)
$doc.Close($false)
$w.Quit()
[System.Runtime.InteropServices.Marshal]::ReleaseComObject($w) | Out-Null
]],
		win_path,
		pdf_win
	))
	f:close()

	vim.fn.jobstart('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\\Temp\\oil-print-word.ps1"', {
		stderr_buffered = true,
		on_stderr = function(_, data)
			if data and data[1] ~= "" then
				err(table.concat(data, "\n"))
			end
		end,
		on_exit = function(_, code)
			if code ~= 0 then
				err("Word PDF export failed (code " .. code .. ")")
				return
			end
			print_pdfs({ pdf_wsl }, odd_only, extra_settings, printer_override)
		end,
	})
end
---------------------------------------------------------------------
-- file display
---------------------------------------------------------------------
local function preview_file_in_terminal()
	local oil = require("oil")
	local dir = oil.get_current_dir()
	if not dir then
		warn("Not in Oil buffer")
		return
	end
	local entry = oil.get_cursor_entry()
	if not entry then
		warn("No file under cursor")
		return
	end
	local path = dir .. entry.name
	local escaped = vim.fn.shellescape(path)
	local ext = entry.name:match("%.(%w+)$")
	if not ext then
		warn("No file extension")
		return
	end
	ext = ext:lower()

	local cmd
	if ext == "pdf" then
		-- convert first page to png, then render
		local tmp = "/tmp/chafa-preview.png"
		cmd = string.format("pdftoppm -png -f 1 -singlefile %s /tmp/chafa-preview && chafa %s", escaped, tmp)
	elseif vim.tbl_contains({ "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "svg" }, ext) then
		cmd = "chafa " .. escaped
	else
		warn("Unsupported file type: " .. ext)
		return
	end

	vim.cmd("vsplit | terminal " .. cmd)
end
---------------------------------------------------------------------
-- Oil keymaps (NORMAL MODE)
---------------------------------------------------------------------
require("oil").setup({
	keymaps = {
		["<leader>op"] = {
			callback = preview_file_in_terminal,
			desc = "Preview file (chafa)",
		},
		["<leader>pd"] = {
			callback = function()
				print_doc(get_current_doc(), false)
			end,
			desc = "Print Word doc",
		},
		["<leader>pp"] = {
			callback = function()
				print_pdfs(get_current_pdf(), false, "simplex")
			end,
			desc = "Print PDF (single-sided)",
		},
		["<leader>pf"] = {
			callback = function()
				print_pdfs(get_current_pdf(), false, nil, nil, "fit")
			end,
			desc = "Print PDF (fit to page)",
		},
		["<leader>pl"] = {
			callback = function()
				print_labels(get_current_pdf(), MANUAL_FEED_PRINTER)
			end,
			desc = "Print labels (fit + Labels media)",
		},
		["<leader>po"] = {
			callback = function()
				print_pdfs(get_current_pdf(), true)
			end,
			desc = "Print odd pages",
		},
		-- /home/jmeyer/.config/nvim/lua/keymaps/oilprint.lua:677 FINAL
		["<leader>pD"] = {
			callback = function()
				print_pdfs(get_current_pdf(), false, "duplex")
			end,
			desc = "Print double-sided",
		},
		["<leader>pm"] = {
			callback = function()
				print_pdfs(get_current_pdf(), false, "simplex,bin=Manual Feed", MANUAL_FEED_PRINTER)
			end,
			desc = "Print PDF (manual feed)",
		},
		["<leader>pe"] = {
			callback = function()
				print_excel(get_current_excel(), false)
			end,
			desc = "Print Excel",
		},
		["<leader>pt"] = {
			callback = function()
				print_txt(get_current_csv(), false, nil, nil, "fit")
			end,
			desc = "Print CSV/TXT as table",
		},
		["<leader>pc"] = {
			callback = combine_selected_pdfs,
			desc = "Combine PDFs by pattern",
		},
		["<leader>wo"] = {
			callback = open_in_explorer,
			desc = "Open in Explorer",
		},
	},
})
---------------------------------------------------------------------
-- global keymaps
---------------------------------------------------------------------
vim.keymap.set("n", "<leader>ps", select_printer, { desc = "Select printer" })
vim.keymap.set("v", "<leader>pp", function()
	local paths = get_visual_pdfs()
	exit_visual()
	print_pdfs(paths, false, "simplex")
end, { desc = "Print visual PDFs (single-sided)" })
vim.keymap.set("v", "<leader>pf", function()
	local paths = get_visual_pdfs()
	exit_visual()
	print_pdfs(paths, false, nil, nil, "fit")
end, { desc = "Print visual PDFs (fit)" })
vim.keymap.set("v", "<leader>pl", function()
	local paths = get_visual_pdfs()
	exit_visual()
	print_labels(paths, MANUAL_FEED_PRINTER)
end, { desc = "Print visual labels (fit + Labels media)" })
-- /home/jmeyer/.config/nvim/lua/keymaps/oilprint.lua:729 FINAL
vim.keymap.set("v", "<leader>pD", function()
	local paths = get_visual_pdfs()
	exit_visual()
	print_pdfs(paths, false, "duplex")
end, { desc = "Print visual PDFs double-sided" })
vim.keymap.set("v", "<leader>po", function()
	local paths = get_visual_pdfs()
	exit_visual()
	print_pdfs(paths, true)
end, { desc = "Print visual odd pages" })
vim.keymap.set("v", "<leader>pm", function()
	local paths = get_visual_pdfs()
	exit_visual()
	print_pdfs(paths, false, "simplex,bin=Manual Feed", MANUAL_FEED_PRINTER)
end, { desc = "Print visual PDFs (manual feed)" })
vim.keymap.set("v", "<leader>tp", function()
	local paths = get_visual_csvs()
	exit_visual()
	if paths then
		for _, p in ipairs(paths) do
			print_txt(p, false, nil, nil, "fit")
		end
	end
end, { desc = "Print visual CSV/TXT as table" })
