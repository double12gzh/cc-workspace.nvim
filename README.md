# cc-workspace.nvim

> **Personal Plugin Notice**: `cc-workspace.nvim` is a personal Neovim workspace, Git worktree, and multi-agent chrome extension built specifically against **`olimorris/codecompanion.nvim` `v20.1.0`** (with `ravitemer/codecompanion-history.nvim`). Internal monkey-patches target `v20.1.0` ACP, HTTP tool runtime, session serializer, and history UI internals.

An Orca / Herdr-inspired multi-project, Git-worktree-aware AI Agent Workspace for [CodeCompanion.nvim](https://github.com/olimorris/codecompanion.nvim).

## Features

- **Dedicated 2-Pane AI Workspace Tab (`:CodeCompanionWorkspace`)**:
  - Left `cc-workspace` tree sidebar grouping active & saved conversations under **Projects -> Git Worktrees -> Conversations**, with ancestor-aware name disambiguation, keyword filtering (`f` / `F`), and live 250ms spinner rollups.
  - Right main chat pane with automatic window-local `lcd` isolation so simultaneously open chats across different repositories or worktrees never collide.
- **Non-Blocking Git Worktree Engine (`cc_workspace.worktree`)**:
  - Zero-subprocess pure-Lua/libuv `.git` & linked worktree discovery for instant sidebar/winbar rendering, paired with bounded async `git worktree list --porcelain` + `git status --porcelain` refreshes.
  - Interactive worktree branch picker (`w` / `:CodeCompanionWorkspaceWorktree`) creating clean worktrees under `stdpath("data")/cc-worktrees/<repo>-<hash6>/<branch>` and spawning an agent chat directly inside.
- **Unified Agent Lifecycle & Notifications**:
  - Tracks `thinking` (`⠋`), `streaming` (`⚡`), `waiting` (``), `unread` (`✓`), `error` (`✗`), `active` (`◆`), and `idle` (`○`) states across all open chats with background completion/approval/error toasts (`:CodeCompanionNotificationsToggle`) and one-key jump-to-attention (`u`).
- **Standalone High-Contrast Chat Winbar (`cc_workspace.winbar`)**:
  - Clickable multi-chat pills (width-safe `<= 7` pagination with off-screen attention rollups), `[+]` new chat, ` project ·  branch` badge, and `󰕮 WS` / `󰌍 Code` toggle — decoupled from `lualine.nvim`.
- **Reusable Lualine Component & Floating Switcher (`cc_workspace.statusline`, `cc_workspace.switcher`)**:
  - Drop-in `lualine` statusline component + `cc-workspace` sidebar extension, plus a live-updating floating agent switcher (`<leader>cl`).
- **Per-Chat CWD & Session Safety Patches**:
  - Scopes CodeCompanion ACP jobs/RPCs, HTTP tool execution, system prompts, and `codecompanion-history` saves to each chat's `chat.opts.cwd`, and guards `persisted.nvim` against saving transient workspace/chat layouts.

## Installation (`lazy.nvim`)

Supports conditional local development directory fallback alongside the GitHub repository spec (safe in headless/Docker environments without `dev = true`):

```lua
local cc_ws_dir = vim.fn.expand("~/Documents/code/cc-workspace.nvim")

return {
	{
		"double12gzh/cc-workspace.nvim",
		dir = vim.uv.fs_stat(cc_ws_dir) and cc_ws_dir or nil,
		lazy = true,
		cmd = {
			"CodeCompanionWorkspace",
			"CodeCompanionWorkspaceAddProject",
			"CodeCompanionWorkspaceWorktree",
			"CodeCompanionNotificationsToggle",
		},
		opts = {},
	},
	{
		"olimorris/codecompanion.nvim",
		dependencies = {
			"nvim-lua/plenary.nvim",
			"ravitemer/codecompanion-history.nvim",
			"double12gzh/cc-workspace.nvim",
		},
		opts = {
			extensions = {
				workspace = {
					enabled = true,
					callback = "codecompanion._extensions.workspace",
					opts = {
						sidebar_width = 38,
						notifications = true,
					},
				},
			},
		},
	},
}
```

### Lualine Integration

```lua
local cc_status = require("cc_workspace.statusline")
table.insert(opts.sections.lualine_x, 1, cc_status.component())
table.insert(opts.extensions, cc_status.extension())
```

## Commands

| Command | Description |
| :--- | :--- |
| `:CodeCompanionWorkspace [dir]` | Toggle the AI Workspace tab (or add & open `[dir]`) |
| `:CodeCompanionWorkspaceAddProject [dir]` | Add a project directory via picker or path argument |
| `:CodeCompanionWorkspaceWorktree [dir]` | Create/select a Git worktree and start a chat in it |
| `:CodeCompanionNotificationsToggle` | Toggle background agent toast notifications |

## Default Keymaps

### Sidebar (`filetype = "cc-workspace"`)

| Key | Action |
| :--- | :--- |
| `<CR>` / `l` | Open chat, start chat on empty leaf, or expand group |
| `p` / `<Space>` | Peek conversation in right pane while keeping sidebar focus |
| `h` / `za` / `zM` / `zR` | Collapse/jump to parent, toggle fold, collapse all, expand all |
| `n` / `N` | New chat in cursor Worktree/Project / multi-project picker |
| `a` / `+` / `A` | Add Project(s) via Telescope (`<Tab>` multi-select) / path input |
| `w` | Create Git Worktree and spawn an Agent Chat inside it |
| `u` | Jump to highest-priority waiting / error / unread / running chat |
| `o` | Open Worktree or Project in a dedicated code tab (`tcd`) |
| `r` / `d` / `x` | Rename chat or Project alias / close chat or remove Worktree/Project |
| `y` / `Y` / `K` | Copy item path / copy all repo+worktree paths / inspect item |
| `f` / `F` / `s` / `gh` | Filter sidebar by keyword / clear filter / full-text history search |
| `1`-`9` / `<Tab>` / `<S-Tab>` | Jump to active chat `1`-`9` / step actionable rows |
| `q` / `Q` / `?` | Return to code tab / close Workspace tab / floating help |

### Chat Buffer (`codecompanion`)

| Key | Action |
| :--- | :--- |
| `q` | Stop active request, focus sidebar (in Workspace), or hide side chat |
| `<C-c>` | Safely close chat buffer without breaking Workspace layout |
| `}` / `{` | Cycle next / previous open chat buffer |

## Persistence Paths

- Pinned & hidden projects: `vim.fn.stdpath("data") .. "/cc-workspace-projects.json"`
- Managed Git worktrees: `vim.fn.stdpath("data") .. "/cc-worktrees/<repo>-<hash6>/<branch>"`
