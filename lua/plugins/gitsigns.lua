# /home/jmeyer/.config/nvim/lua/plugins/gitsigns.lua FINAL
return {
  "lewis6991/gitsigns.nvim",
  config = function()
    require("gitsigns").setup({
      signs = {
        add = { text = "┃" },
        change = { text = "┃" },
        delete = { text = "_" },
        topdelete = { text = "‾" },
        changedelete = { text = "~" },
        untracked = { text = "┆" },
      },
      current_line_blame = true,
      current_line_blame_opts = {
        virt_text = true,
        virt_text_pos = "eol",
        delay = 500,
        ignore_whitespace = false,
      },
      current_line_blame_formatter = "<author>, <author_time:%Y-%m-%d> - <summary>",
      on_attach = function(bufnr)
        local gitsigns = require("gitsigns")

        local function map(mode, lhs, rhs, opts)
          opts = opts or {}
          opts.buffer = bufnr
          vim.keymap.set(mode, lhs, rhs, opts)
        end

        -- Navigation (use ]h/[h to avoid clashing with octo ]c/[c for comments)
        map("n", "]h", function()
          if vim.wo.diff then
            return vim.cmd.normal({ "]c", bang = true })
          end
          gitsigns.nav_hunk("next")
        end)
        map("n", "[h", function()
          if vim.wo.diff then
            return vim.cmd.normal({ "[c", bang = true })
          end
          gitsigns.nav_hunk("prev")
        end)

        -- Actions
        map("n", "<leader>hb", function()
          gitsigns.blame_line({ full = true })
        end)
        map("n", "<leader>hp", gitsigns.preview_hunk)
        map("n", "<leader>hs", gitsigns.stage_hunk)
        map("n", "<leader>hr", gitsigns.reset_hunk)
        map("v", "<leader>hs", function()
          gitsigns.stage_hunk({ vim.fn.line("."), vim.fn.line("v") })
        end)
        map("v", "<leader>hr", function()
          gitsigns.reset_hunk({ vim.fn.line("."), vim.fn.line("v") })
        end)
        map("n", "<leader>hS", gitsigns.stage_buffer)
        map("n", "<leader>hR", gitsigns.reset_buffer)
        map("n", "<leader>hd", gitsigns.diffthis)

        -- Toggles
        map("n", "<leader>hB", gitsigns.toggle_current_line_blame)
        map("n", "<leader>tw", gitsigns.toggle_word_diff)

        -- Text object
        map({ "o", "x" }, "ih", gitsigns.select_hunk)
      end,
    })
  end,
}
