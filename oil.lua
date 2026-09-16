-- /home/jmeyer/.config/nvim/oil.lua FINAL
return {
	{
		"stevearc/oil.nvim",
		lazy = false,
		opts = {
			default_file_explorer = true,
			-- Icon-only columns: permissions/size/mtime each cost a stat per file,
			-- the slowest possible op on a drvfs mount.
			columns = { "icon" },
			-- inotify does not work on drvfs; watching is wasted work.
			watch_for_changes = false,
			-- Trash on a mounted drive is slow; hard delete is instant.
			delete_to_trash = false,
			-- Skip the confirm popup for simple single-file edits.
			skip_confirm_for_simple_edits = true,
			view_options = { show_hidden = true },
		},
		keys = {
			{ "-", "<CMD>Oil<CR>", desc = "Open parent directory" },
		},
	},
}
