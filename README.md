# zdiff.nvim

A minimal, fast git diff viewer for Neovim with treesitter syntax highlighting.

Inspired by [Zed's](https://zed.dev) multi-buffer diff view - a clean, collapsible interface for reviewing changes across multiple files in a single view.

<img width="50%" height="50%" alt="image" src="https://github.com/user-attachments/assets/cb03976a-3d0c-4554-8d05-f712e030c52c" /><img width="50%" height="50%" alt="image" src="https://github.com/user-attachments/assets/f38c871a-3ca6-490a-8727-26f8275a0bf1" />

Easily yank changes without including git markers or hunk headers

<img width="50%" height="50%" alt="image" src="https://github.com/user-attachments/assets/7b274b5d-db18-4e02-b277-03b633bf9d04" />

## Features

- View uncommitted changes or changes compared to any git ref
- Expand/collapse files to see inline diffs
- Treesitter syntax highlighting in diff views
- Sticky file headers while scrolling expanded diffs
- Jump directly to source files at the correct line
- Auto-refresh when returning to zdiff buffer
- Tab completion for branch/tag names
- Configurable keymaps and icons

## Requirements

- Neovim >= 0.9.0
- git
- (Optional) nvim-treesitter for syntax highlighting in diffs

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "martindur/zdiff.nvim",
  cmd = "Zdiff",
  keys = {
    { "<leader>zd", "<cmd>Zdiff<cr>", desc = "Zdiff (uncommitted)" },
    { "<leader>zD", "<cmd>Zdiff main<cr>", desc = "Zdiff (vs main)" },
  },
  opts = {},
}
```

Or with lua function keymaps:

```lua
{
  "martindur/zdiff.nvim",
  cmd = "Zdiff",
  keys = {
    { "<leader>zd", function() require("zdiff").open() end, desc = "Zdiff (uncommitted)" },
    { "<leader>zD", function() require("zdiff").open("main") end, desc = "Zdiff (vs main)" },
  },
  opts = {},
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "martindur/zdiff.nvim",
  config = function()
    require("zdiff").setup()

    vim.keymap.set("n", "<leader>zd", function() require("zdiff").open() end, { desc = "Zdiff (uncommitted)" })
    vim.keymap.set("n", "<leader>zD", function() require("zdiff").open("main") end, { desc = "Zdiff (vs main)" })
  end,
}
```

### [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'martindur/zdiff.nvim'
```

```lua
-- In your init.lua or after/plugin/zdiff.lua:
require("zdiff").setup()

vim.keymap.set("n", "<leader>zd", function() require("zdiff").open() end, { desc = "Zdiff (uncommitted)" })
vim.keymap.set("n", "<leader>zD", function() require("zdiff").open("main") end, { desc = "Zdiff (vs main)" })
```

## Usage

### Command

```vim
:Zdiff [ref]
```

| Example | Description |
|---------|-------------|
| `:Zdiff` | Uncommitted changes (diff vs HEAD) |
| `:Zdiff main` | Changes compared to `main` branch |
| `:Zdiff develop` | Changes compared to `develop` branch |
| `:Zdiff v1.0.0` | Changes compared to tag `v1.0.0` |
| `:Zdiff HEAD~5` | Changes compared to 5 commits ago |
| `:Zdiff origin/feature` | Changes compared to remote branch |

Tab completion is available for branch and tag names.

### Keymaps (in zdiff buffer)

| Key | Action |
|-----|--------|
| `<CR>` | Go to file/line under cursor |
| `<Tab>` | Toggle expand/collapse file |
| `m` | Toggle between uncommitted and branch mode |
| `R` | Refresh diff |
| `q` | Close zdiff |
| `gy` | Yank file:line reference |
| `?` | Show help |

`gy` works in both normal mode (current line) and visual mode (selection). Outputs file:line or file:start-end for ranges. Deletion lines are ignored; selections spanning multiple hunks produce multiple ranges (e.g., `path:10-15, 1020-1025`).

Press `?` while in zdiff to see all available keymaps.

## Pull Request Reviews (opt-in)

`zdiff.review` provides an API-backed GitHub PR browser without checking out
branches or creating worktrees. It requires the
[GitHub CLI](https://cli.github.com/) to be installed and authenticated.
PR diff views show the PR description above the files with markdown syntax
highlighting when available.

For lazy.nvim, include `ZdiffReview` in `cmd` and call its separate setup:

```lua
{
  "martindur/zdiff.nvim",
  cmd = { "Zdiff", "ZdiffReview" },
  config = function()
    require("zdiff").setup()
    require("zdiff.review").setup()
  end,
}
```

Open it with:

```vim
:ZdiffReview
```

PR list keymaps:

| Key | Action |
|-----|--------|
| `<CR>` | Open the selected PR |
| `a` | Approve, request changes, or leave a general comment |
| `R` | Refresh the PR list |
| `q` | Close zdiff.review |

PR diff keymaps:

| Key | Action |
|-----|--------|
| `<Tab>` | Toggle the file under the cursor |
| `d` | Toggle the PR description |
| `c` | Comment on the diff line under the cursor |
| `r` | Reply to the top-level comment under the cursor |
| `]t` / `[t` | Jump to the next or previous thread |
| `R` | Refresh the PR diff and comments |
| `q` | Return to the PR list |

## Configuration

```lua
require("zdiff").setup({
  -- Whether files are expanded by default
  default_expanded = false,

  -- Default branch for toggle_mode (m key)
  default_branch = "main",

  -- Keymap bindings (defaults)
  keymaps = {
    goto_file = "<CR>",
    toggle = "<Tab>",
    close = "q",
    refresh = "R",
    toggle_mode = "m",
    help = "?",
    yank_ref = "gy",
  },

  -- Icons for UI elements
  icons = {
    collapsed = "",
    expanded = "",
    added = "+",
    deleted = "-",
    modified = "~",
  },

  -- Syntax highlighting strategy
  syntax = {
    -- "projection" parses old/new full-file snapshots and projects
    -- captures onto unified diff lines. "hunk" keeps legacy behavior.
    mode = "projection",
    -- Skip projection when either old/new source exceeds this many lines.
    -- 0 means unlimited.
    max_lines = 8000,
  },
})
```

### Examples

#### Set default branch to develop

```lua
require("zdiff").setup({
  default_branch = "develop",
})
```

#### Custom keymaps

All keymaps can be customized or disabled (set to `false`).

```lua
require("zdiff").setup({
  keymaps = {
    goto_file = "o",
    toggle = "<Space>",
    yank_ref = "Y",  -- or false to disable
  },
})
```

#### Limit projection on very large files

```lua
require("zdiff").setup({
  syntax = {
    -- Files above this line count skip projection and use
    -- hunk-based syntax highlighting for performance.
    max_lines = 12000,
  },
})
```

## Health Check

Run `:checkhealth zdiff` to verify your setup.

## Development

### Running Tests

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim):

```bash
make test
```

Stress test (async refresh + repeated open/close memory baseline check + open-time load benchmark):

```bash
make stress-test
```

Open a generated fixture repo with many file types and expanded diffs for manual syntax highlighting checks. The default target uses your normal Neovim config and installed parsers, while the clean target uses `tests/minimal_init.lua`:

```bash
make syntax-gallery
make syntax-gallery-clean
```

Format tracked Lua files with `stylua`:

```bash
make format
```

Lint Lua sources with `luacheck`:

```bash
make lint
```

## License

MIT
