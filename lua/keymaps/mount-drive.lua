-- /home/jmeyer/.config/nvim/lua/keymaps/mount-drive.lua FINAL
-- Mount G: drive if needed and refresh oil buffers under /mnt/g.
-- Idempotent: no-op when already mounted (prevents stacked duplicate mounts).
-- Presence is probed from the Windows side so a stale 9P mount can never block.
-- Mount options mirror /etc/wsl.conf automount (uid/gid/umask, no metadata) + noatime.

local function shell(cmd)
	local out = vim.trim(vim.fn.system(cmd))
	return vim.v.shell_error == 0, out
end

-- Windows-side probe: instant, never touches the (possibly stale) 9P mount.
local function drive_present()
	local out = vim.fn.system('cmd.exe /c "if exist G:\\NUL (echo ok) else (echo no)"')
	return out:match("ok") ~= nil
end

local function is_mounted()
	local ok, out = shell("findmnt -n -o TARGET /mnt/g 2>/dev/null")
	return ok and out == "/mnt/g"
end

-- Bounded accessibility probe: cannot hang longer than 3s on a stale mount.
local function is_accessible()
	return shell("timeout 3 ls /mnt/g > /dev/null 2>&1")
end

local function do_mount()
	return shell("sudo -n mount -t drvfs G: /mnt/g -o uid=1000,gid=1000,umask=022,noatime 2>&1")
end

local function refresh_oil()
	local count = 0
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.bo[buf].filetype == "oil" then
			local path = vim.api.nvim_buf_get_name(buf)
			if path:match("^/mnt/g/") or path:match("^oil:///mnt/g/") then
				vim.api.nvim_buf_call(buf, function()
					vim.cmd.edit({ bang = true })
				end)
				count = count + 1
			end
		end
	end
	return count
end

vim.keymap.set("n", "<leader>mg", function()
	-- Drive physically absent (switched to the other PC): say so, don't hang.
	if not drive_present() then
		print("✗ G: not present — switch the drive back first")
		vim.cmd("redraw!")
		return
	end

	-- Fast path: already mounted and accessible -> just refresh buffers.
	if is_mounted() and is_accessible() then
		local n = refresh_oil()
		if n > 0 then
			print("✓ G: already mounted, refreshed " .. n .. " oil buffer(s)")
		else
			print("✓ G: already mounted")
		end
		vim.cmd("redraw!")
		return
	end

	-- Stale or missing: unmount every stacked layer, then mount fresh.
	local guard = 0
	while is_mounted() and guard < 5 do
		shell("sudo -n umount -l /mnt/g 2>/dev/null")
		guard = guard + 1
	end
	shell("mkdir -p /mnt/g")

	local ok, output = do_mount()
	if not ok then
		if output:match("password") or output:match("no tty") or output:match("a terminal") then
			print("✗ sudo needs a password (no TTY)")
			print("  Fix: add to /etc/sudoers.d/wsl-mount:")
			print("  %sudo ALL=(ALL) NOPASSWD: /bin/mount, /bin/umount")
		else
			print("✗ Mount failed:")
			print("  " .. output)
		end
		vim.cmd("redraw!")
		return
	end

	if not is_accessible() then
		print("  Device stale, retrying...")
		shell("sudo -n umount -l /mnt/g 2>/dev/null")
		vim.fn.system("sleep 0.5")
		ok, output = do_mount()
		if not ok then
			print("✗ Retry mount failed:")
			print("  " .. output)
			vim.cmd("redraw!")
			return
		end
		if not is_accessible() then
			print("✗ Mount point not accessible after retry")
			print("  Try: sudo umount -f /mnt/g && sudo mount -t drvfs G: /mnt/g")
			vim.cmd("redraw!")
			return
		end
	end

	local n = refresh_oil()
	if n > 0 then
		print("✓ G: mounted, refreshed " .. n .. " oil buffer(s)")
	else
		print("✓ G: mounted")
	end
	vim.cmd("redraw!")
end, { desc = "Mount G: drive (idempotent) and refresh oil buffers" })
