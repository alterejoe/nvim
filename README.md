---

# Neovim Configuration Guide

## Overview

This is a powerful, developer-focused Neovim configuration designed for Linux (primarily used via WSL2 on Windows 10). It includes:

- **Modern dark theme** (Gruvbox Material)
- **File browsing** (Oil - a fast file explorer)
- **Fuzzy finding** (Telescope - find files, search text, switch buffers)
- **Git integration** (Lazygit panel, worktree management)
- **AI-powered code completion** (Neocodeium)
- **Language support** (LSP servers via Mason, Treesitter for syntax highlighting)
- **Database UI** (DadBod for SQL databases)
- **Tmux integration** (session management, project switching)
- **Go development** (Air for live-reload)

---

### Step 1: Install Prerequisites

#### Install brew if you don't have it already


Run these commands in your terminal:

```bash
# Install Neovim (version 0.10+ recommended)
brew install neovim

# Install Git (usually pre-installed)
brew install git

# Install Tmux (for session management)
brew install tmux

# Install ripgrep (required for searching)
brew install ripgrep

# Install fd (file finder - required by Telescope)
brew install fd

# Install lazygit (Git UI)
brew install lazygit

# Install Node.js (required for some LSP servers and formatters)
brew install node

# Install Go (required for Go development and some tools)
brew install go
```

### Step 2: Install This Config

```bash
# Backup your existing config (if any)
mv ~/.config/nvim ~/.config/nvim.backup

# Clone this config
git clone https://github.com/your-username/your-nvim-config.git ~/.config/nvim

# Open Neovim (plugins will install automatically on first launch)
nvim
```

**First launch will take 1-2 minutes** as it downloads and installs all plugins. You'll see progress in the status bar.

---

## WSL2 Special Setup (Windows 10)

Since you're using WSL2, there's one extra step for clipboard integration:

### Install win32yank (for clipboard between Windows and WSL)

```bash
# Download win32yank
curl -L -o /tmp/win32yank.zip https://github.com/equalsraf/win32yank/releases/download/v0.0.4/win32yank-x64.zip

# Unzip it
unzip -o /tmp/win32yank.zip -d /tmp/win32yank

# Move to a location in your PATH
sudo mv /tmp/win32yank/win32yank.exe /usr/local/bin/

# Make it executable
chmod +x /usr/local/bin/win32yank.exe
```

This enables copying/pasting between Neovim and Windows applications.

---

## Godot Integration

Godot game engine isn't natively integrated into this config, but here's how to set it up:

### Option 1: Godot with LSP Support (Recommended)

1. **Download Godot 4.x** from https://godotengine.org/download
2. **Install the Godot LSP add-on** in Godot:
   - In Godot: AssetLib → Search "LSP"
   - Install "Godot LSP"
3. **In Neovim**, install the Godot language server:

```bash
# Create a script for Godot LSP
cat > ~/.local/bin/godot-lsp << 'EOF'
#!/bin/bash
godot --headless --script-server
EOF
chmod +x ~/.local/bin/godot-lsp
```

4. **Add to your config** (create `~/.config/nvim/lua/plugins/godot.lua`):

```lua
-- lua/plugins/godot.lua
return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        gdscript = {
          cmd = { "godot-lsp" },
        },
      },
    },
  },
}
```

### Option 2: Quick Godot Workflow (Simpler)

Use Neovim as your code editor while running Godot:

1. Open Godot
2. In Neovim, navigate to your Godot project files
3. Edit `.gd` (GDScript) files - syntax highlighting works automatically
4. Switch back to Godot to run/test

---

## Keymaps Overview

The leader key is **Space** (configured as `vim.g.mapleader = " "`).

### Essential Navigation

| Key | Action |
|-----|--------|
| `Space` | Leader key (press before any command below) |
| `j/k/l/;` | Navigate tmux slots 1-4 (hold Shift for slots 5-8) |
| `Ctrl+f` | Open project picker (fuzzy search projects) |
| `-` | Open parent directory (Oil file explorer) |
| `Space e` | Open Oil file explorer at current directory |
| `Space ff` | Find files in current project |
| `Space fg` | Search for text (live grep) |
| `Space fb` | Switch between open buffers |
| `Space rf` | Recently opened files |

### Editing

| Key | Action |
|-----|--------|
| `jk` | Escape from insert mode (fast!) |
| `nm` | Escape from visual mode |
| `Q` | Smart close (closes window/buffer intelligently) |
| `W` | Force save |
| `Space ww` | Toggle word wrap |

### Git

| Key | Action |
|-----|--------|
| `Space gc` | Create new Git worktree |
| `Space gs` | Switch between worktrees |

### Terminal

| Key | Action |
|-----|--------|
| `Space st` | Open terminal in vertical split |
| `Space sh` | Open terminal in horizontal split |

### Quick File Tags (Grapple)

| Key | Action |
|-----|--------|
| `Space a` | Toggle tag on current file |
| `Alt+e` | Show all tags (pick with Telescope) |
| `Ctrl+e` | Toggle tags menu |
| `Space j/k/l/;` | Jump to tag 1/2/3/4 |
| `Space J/K/L/:` | Jump to tag 5/6/7/8 |

### Tmux Session Management

| Key | Action |
|-----|--------|
| `Space ts` | Edit tmux sessions (reorder, group) |
| `Space tr` | Rename current session |
| `Space t|` | Split vertically in current directory |
| `Space t-` | Split horizontally in current directory |
| `Space ta` | Join pane from another session |
| `Space tb` | Break current pane to its own session |
| `Space tT` | Kill ALL tmux sessions |

### Air (Go Live-Reload)

| Key | Action |
|-----|--------|
| `Space ra` | Start Air (requires `.air.toml` in project) |
| `Space ro` | Toggle Air log viewer |
| `Space rr` | Restart Air |
| `Space rq` | Stop Air |

### Tools

| Key | Action |
|-----|--------|
| `Space hh` | Reload current buffer |
| `Space mh` | View message history |
| `Space mm` | View all messages |

---

## Installed Plugins

### Core Plugins

| Plugin | Purpose |
|--------|---------|
| **lazy.nvim** | Plugin manager (automatically installs everything) |
| **gruvbox-material** | Dark theme with warm colors |
| **oil.nvim** | Fast file explorer (replaces Netrw) |
| **telescope.nvim** | Fuzzy finder (files, text, buffers) |
| **nvim-cmp** | Code completion engine |
| **nvim-lspconfig** | Language Server Protocol support |
| **nvim-treesitter** | Advanced syntax highlighting |
| **mason.nvim** | Install LSP servers, formatters, debuggers |

### Specialized Plugins

| Plugin | Purpose |
|--------|---------|
| **lazygit.nvim** | Git UI panel |
| **git-worktree.nvim** | Manage Git worktrees |
| **neocodeium** | AI-powered code completion |
| **vim-dadbod-ui** | Database UI (PostgreSQL, MySQL, SQLite) |
| **grapple.nvim** | Quick file tagging/bookmarks |
| **nvim-dap** | Debug adapter protocol (debug code) |
| **conform.nvim** | Code formatting on save |
| **noice.nvim** | Better messages and popups |

---

## Language Support

This config automatically supports:

- **Go** (via gopls - install with `:LspInstall gopls`)
- **TypeScript/JavaScript** (via typescript-language-server)
- **Python** (via pyright)
- **Rust** (via rust-analyzer)
- **HTML/CSS** (via emmet-ls)
- **SQL** (via sqls)
- And many more...

### Installing Language Servers

Inside Neovim, run:

```vim
:Mason
```

This opens a UI where you can install:
- LSP servers (for code completion, diagnostics)
- Formatters (prettier, gofmt, black)
- Debuggers (delve for Go, debugpy for Python)

---

## Daily Workflow Examples

### Starting Your Day

1. Open terminal → `tmux` → `nvim`
2. Press `Ctrl+f` → type project name → Enter
3. You're in your project with all sessions ready

### Working on a File

1. `Space ff` → type filename → Enter
2. Edit code (AI completion works automatically)
3. `Space w` to save (or `W` to force save)
4. `Space ra` to start Go live-reload (if Go project)

### Searching for Code

1. `Space fg` → type search term → Enter
2. Results appear in Telescope picker
3. Press Enter to open, `Ctrl+j/k` to navigate

### Using Git

1. `Space gs` (in telescope) or type `lazygit` in terminal
2. See all changes, stage, commit, push
3. `Space gc` to create a new worktree for a feature branch

### Database Work

```vim
:DBUI
```

Opens database browser. Add connection with `:DBUIAddConnection`

---

## Troubleshooting

### Plugins won't install

```vim
:Lazy
```

Check for errors. Try `:Lazy restore` to reset.

### Language server not working

```vim
:Mason
```

Make sure the language server is installed. If not, select it and press Enter to install.

### Slow startup

First launch is slow. Subsequent launches should be <1 second.

### Clipboard not working (WSL)

Make sure win32yank.exe is installed (see WSL2 setup above).

---

## Customization

To add your own settings, create:

- `~/.config/nvim/lua/custom.lua` - for custom Lua code
- `~/.config/nvim/after/plugin/` - for plugin configurations

---

## Summary for Your Friend

**In short, this config gives you:**

1. A beautiful dark theme
2. Fast file navigation (Oil + Telescope)
3. AI-powered code completion
4. Great Git integration
5. Easy tmux session management
6. Language support for most programming languages
7. Database browsing
8. Go development with live-reload

**The most important keys to remember:**
- `Space` = leader key
- `Ctrl+f` = pick a project
- `Space ff` = find files
- `Space fg` = search in files
- `jk` = escape (in insert mode)

Everything else you'll pick up naturally as you use it!
