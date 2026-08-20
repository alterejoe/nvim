-- /home/jmeyer/.config/nvim/lua/keymaps/wg.lua FINAL-4
-- Remount G: drive and refresh all active oil buffers under /mnt/g
vim.keymap.set("n", "<leader>mg", function()
	local function check_accessible()
		vim.fn.system("ls /mnt/g > /dev/null 2>&1")
		return vim.v.shell_error == 0
	end

	local function do_mount()
		local cmd = "sudo -n mount -t drvfs G: /mnt/g -o metadata,uid=1000,gid=1000,umask=022 2>&1"
		local out = vim.trim(vim.fn.system(cmd))
		if vim.v.shell_error ~= 0 then
			return false, out
		end
		return true, out
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

	-- Mount
	vim.fn.system("sudo -n umount -l /mnt/g 2>/dev/null")
	vim.fn.system("mkdir -p /mnt/g")
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

	if not check_accessible() then
		print("  Device stale, retrying...")
		vim.fn.system("sudo -n umount -l /mnt/g 2>/dev/null")
		vim.fn.system("sleep 0.5")
		ok, output = do_mount()
		if not ok then
			print("✗ Retry mount failed:")
			print("  " .. output)
			vim.cmd("redraw!")
			return
		end
		if not check_accessible() then
			print("✗ Mount point not accessible after retry")
			print("  Try: sudo umount -f /mnt/g && sudo mount -t drvfs G: /mnt/g")
			vim.cmd("redraw!")
			return
		end
	end

	-- Refresh oil
	local n = refresh_oil()
	if n > 0 then
		print("✓ G: mounted, refreshed " .. n .. " oil buffer(s)")
	else
		print("✓ G: mounted")
	end

	vim.cmd("redraw!")
end, { desc = "Remount G: drive and refresh oil buffers" })
