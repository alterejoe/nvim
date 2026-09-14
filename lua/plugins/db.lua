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

    -- SQLite for the opencode-manage verdict store (T2 + T2.5).
    -- sqlite.lua's FFI is pointed at the system library explicitly because
    -- this system has libsqlite3.so.0 but not necessarily libsqlite3.so.
    {
        "kkharji/sqlite.lua",
        lazy = true,
        init = function()
            vim.g.sqlite_clib_path = "/usr/lib/x86_64-linux-gnu/libsqlite3.so.0"
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
