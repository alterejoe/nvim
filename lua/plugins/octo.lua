# /home/jmeyer/.config/nvim/lua/plugins/octo.lua FINAL-2
return {
  "pwntester/octo.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-telescope/telescope.nvim",
    "nvim-tree/nvim-web-devicons",
  },
  config = function()
    require("octo").setup({
      default_remote = { "origin" },
      picker = "telescope",
      default_merge_method = "merge",
      use_local_fs = false,
      enable_builtin = false,
      mappings_disable_default = false,
    })
  end,
}
