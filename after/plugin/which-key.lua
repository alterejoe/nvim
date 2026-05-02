-- after/plugin/which-key.lua
-- Group labels and descriptions for all keymaps.

local wk = require("which-key")

wk.add({
	-- top-level groups
	{ "<leader>b", group = "browser" },
	{ "<leader>f", group = "find" },
	{ "<leader>g", group = "git" },
	{ "<leader>r", group = "air / reload" },
	{ "<leader>s", group = "split / shell" },
	{ "<leader>t", group = "tmux" },
	{ "<leader>w", group = "browser session" },
	{ "<leader>c", group = "ai" },
	{ "<leader>x", group = "emmet" },

	-- grapple slots
	{ "<leader>j", desc = "Grapple slot 1" },
	{ "<leader>k", desc = "Grapple slot 2" },
	{ "<leader>l", desc = "Grapple slot 3" },
	{ "<leader>;", desc = "Grapple slot 4" },
	{ "<leader>J", desc = "Grapple slot 5" },
	{ "<leader>K", desc = "Grapple slot 6" },
	{ "<leader>L", desc = "Grapple slot 7" },
	{ "<leader>:", desc = "Grapple slot 8" },
	{ "<leader>a", desc = "Grapple add/toggle" },

	-- autoroot project slots
	{ "<leader>1", desc = "Project root 1" },
	{ "<leader>2", desc = "Project root 2" },
	{ "<leader>3", desc = "Project root 3" },
	{ "<leader>4", desc = "Project root 4" },
	{ "<leader>5", desc = "Project root 5" },

	-- find
	{ "<leader>ff", desc = "Find files" },
	{ "<leader>fg", desc = "Live grep" },
	{ "<leader>fG", desc = "Live grep (all)" },
	{ "<leader>fb", desc = "Buffers" },
	{ "<leader>fh", desc = "Help tags" },
	{ "<leader>fr", desc = "Recent files" },
	{ "<leader>fp", desc = "Pickers" },
	{ "<leader>fw", desc = "Grep word under cursor" },
	{ "<leader>fs", desc = "Grep selection", mode = "v" },
	{ "<leader>rf", desc = "Resume last picker" },
	{ "<leader>mm", desc = "Marks" },

	-- git
	{ "<leader>gc", desc = "Git commits" },
	{ "<leader>gs", desc = "Git status" },
	{ "<leader>gg", desc = "LazyGit" },

	-- air
	{ "<leader>ra", desc = "Air: start" },
	{ "<leader>ro", desc = "Air: toggle log" },
	{ "<leader>rr", desc = "Air: restart" },
	{ "<leader>rq", desc = "Air: kill" },

	-- tmux
	{ "<leader>ts", desc = "Sessions (edit)" },
	{ "<leader>tS", desc = "All sessions (debug)" },
	{ "<leader>tr", desc = "Rename session" },
	{ "<leader>ta", desc = "Join pane from session" },
	{ "<leader>tb", desc = "Break pane to session" },
	{ "<leader>tT", desc = "Kill ALL sessions" },
	{ "<leader>t|", desc = "Vertical split" },
	{ "<leader>t-", desc = "Horizontal split" },
	{ "<leader>tp", desc = "Pick project" },
	{ "<leader>tP", desc = "Recover project" },
	{ "<leader>tj", desc = "Tmux slot 1" },
	{ "<leader>tk", desc = "Tmux slot 2" },
	{ "<leader>tl", desc = "Tmux slot 3" },
	{ "<leader>t;", desc = "Tmux slot 4" },
	{ "<leader>tJ", desc = "Tmux slot 5" },
	{ "<leader>tK", desc = "Tmux slot 6" },
	{ "<leader>tL", desc = "Tmux slot 7" },
	{ "<leader>t:", desc = "Tmux slot 8" },

	-- browser session
	{ "<leader>wb", desc = "Start devproxy + Brave" },
	{ "<leader>wq", desc = "Stop all" },
	{ "<leader>wk", desc = "Kill all (force)" },
	{ "<leader>wo", desc = "Toggle devproxy log" },
	{ "<leader>wR", desc = "Restart devproxy" },
	{ "<leader>wB", desc = "Open default tabs" },

	-- browser navigation
	{ "<leader>bv", desc = "View/route picker" },
	{ "<leader>bV", desc = "Reload views config" },
	{ "<leader>br", desc = "Recent navigations" },
	{ "<leader>bp", desc = "Toggle partial/full mode" },
	{ "<leader>be", desc = "Edit params for last navigation" },
	{ "<leader>bt", desc = "Tab picker" },
	{ "<leader>bS", desc = "Switch server" },
	{ "<leader>bx", desc = "Switch context" },
	{ "<leader>bX", desc = "Show active context params" },

	-- browser viewport
	{ "<leader>bm", desc = "Mobile partial" },
	{ "<leader>bM", desc = "Mobile full page" },
	{ "<leader>bd", desc = "Restore desktop" },
	{ "<leader>bR", desc = "Hard refresh (clear cache)" },
	{ "<leader>bA", desc = "Auto-refresh toggle" },

	-- browser CDP / inspection
	{ "<leader>bc", desc = "Console picker (tab)" },
	{ "<leader>bq", desc = "Network picker (tab)" },
	{ "<leader>bn", desc = "Network log buffer (tab)" },
	{ "<leader>bN", desc = "Clear network log" },
	{ "<leader>bl", desc = "Console log buffer (tab)" },
	{ "<leader>bC", desc = "Clear console log" },
	{ "<leader>bD", desc = "DOM dump (tab picker)" },
	{ "<leader>bi", desc = "Re-inject CSS (tab picker)" },
	{ "<leader>bP", desc = "Sign in (.signin)" },

	-- browser test editor
	{ "<leader>bT", desc = "Test editor for last navigation" },
	{ "<leader>bL", desc = "Load saved browser test" },

	-- browser layout
	{ "<leader>bH", desc = "Layout editor" },

	-- browser groups
	{ "<leader>bg", desc = "Group picker" },
	{ "<leader>bG", desc = "Manage groups for current path" },
	{ "<leader>b]", desc = "Next tab in active group" },
	{ "<leader>b[", desc = "Prev tab in active group" },
	{ "<leader>bQ", desc = "Close active group tabs" },

	-- browser views config
	{ "<leader>ve", desc = "Edit views.yaml" },
	{ "<leader>va", desc = "Quick-add view" },

	-- forge browser
	{ "<leader>fo", desc = "Open handler route (full)" },
	{ "<leader>fO", desc = "Open handler route (partial)" },
	{ "<leader>fB", desc = "Browse all forge routes" },

	-- tools
	{ "<leader>hh", desc = "Reload buffer" },
	{ "<leader>nh", desc = "Notification history" },
	{ "<leader>u", desc = "Undotree toggle" },
	{ "<leader>e", desc = "Oil (cwd)" },
	{ "<leader>R", desc = "Replacer" },
	{ "<leader>p", desc = "DBUI toggle" },
	{ "<leader>P", desc = "Clipboard history" },
	{ "<leader>O", desc = "Open in external app" },

	-- splits / shell
	{ "<leader>st", desc = "Terminal (tab)" },
	{ "<leader>sh", desc = "Terminal (horizontal)" },

	-- ai
	{ "<leader>cc", desc = "AI chat" },

	-- emmet
	{ "<leader>xe", desc = "Emmet wrap", mode = { "n", "v" } },
})
