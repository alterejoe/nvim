return {
    {
        "nvim-lua/plenary.nvim",
        commit = "857c5ac",
    },
    {
        "nvim-telescope/telescope-fzf-native.nvim",
        commit = "6fea601",
        build = "make",
    },
    {
        "fdschmidt93/telescope-egrepify.nvim",
    },
    {
        "nvim-telescope/telescope.nvim",
        commit = "48d2656",
        dependencies = {
            "nvim-lua/plenary.nvim",
            "nvim-telescope/telescope-fzf-native.nvim",
            "fdschmidt93/telescope-egrepify.nvim",
        },
        config = function()
            local telescope = require("telescope")
            telescope.setup({
                defaults = {
                    mappings = {
                        i = {
                            ["jk"] = false,
                            ["<C-h>"] = "which_key",
                        },
                    },
                },
                extensions = {
                    fzf = {
                        fuzzy = true,
                        override_generic_sorter = true,
                        override_file_sorter = true,
                        case_mode = "smart_case",
                    },
                    tmux = {
                        use_nvim_notify = false,
                        create_session = {
                            scan_paths = {
                                "~/projects",
                            },
                            scan_depth = 1,
                            respect_gitignore = true,
                            include_hidden_dirs = false,
                            only_dirs = true,
                        },
                    },
                },
            })
            telescope.load_extension("fzf")
            telescope.load_extension("tmux")
            telescope.load_extension("egrepify")
        end,
    },
    {
        "pre-z/telescope-tmuxing.nvim",
        commit = "97326b7",
        dependencies = {
            "nvim-telescope/telescope.nvim",
            "nvim-lua/plenary.nvim",
        },
    },
}
