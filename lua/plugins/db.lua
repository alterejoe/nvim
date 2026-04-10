return {
    -- Database UI (latest confirmed commit: 4604323, April 2025)
    {
        "kristijanhusak/vim-dadbod-ui",
        commit = "4604323",
        dependencies = {
            -- Core dadbod backend (last updated Jan 7, 2026 -- no pinnable SHA available; tracking master)
            { "tpope/vim-dadbod", lazy = true },
            -- SQL autocompletion (rolling master, no releases)
            {
                "kristijanhusak/vim-dadbod-completion",
                ft = { "sql", "mysql", "plsql" },
                lazy = true,
            },
        },
        cmd = {
            "DBUI",
            "DBUIToggle",
            "DBUIAddConnection",
            "DBUIFindBuffer",
        },
        init = function()
            vim.g.db_ui_use_nerd_fonts = 1
        end,
    },

    -- Quick HTML/CSS templating via Emmet (requires emmet-language-server v2.2.0+)
    {
        "olrtg/nvim-emmet",
        config = function()
            vim.keymap.set({ "n", "v" }, "<leader>xe", require("nvim-emmet").wrap_with_abbreviation)
        end,
    },
}
