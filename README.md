# zdiff.nvim

A minimal, fast git diff viewer for Neovim with treesitter syntax highlighting.

Inspired by [Zed's](https://zed.dev) multi-buffer diff view - a clean, collapsible interface for reviewing changes across multiple files in a single view.

## Features

- View uncommitted changes or changes compared to a base branch
- Expand/collapse files to see inline diffs
- Treesitter syntax highlighting in diff views
- Jump directly to source files at the correct line
- Auto-refresh when returning to zdiff buffer
- Configurable keymaps and icons

## Requirements

- Neovim >= 0.9.0
- git
- (Optional) nvim-treesitter for syntax highlighting in diffs

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "yourusername/zdiff.nvim",
  cmd = { "Zdiff", "ZdiffBranch" },
  keys = {
    { "<leader>dz", "<cmd>Zdiff<cr>", desc = "Git diff (uncommitted)" },
    { "<leader>dZ", "<cmd>ZdiffBranch<cr>", desc = "Git diff (vs branch)" },
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
  end,
}
```

### [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'martindur/zdiff.nvim'

" In your init.vim or after/plugin:
lua require("zdiff").setup()
```

## Usage

### Commands

| Command | Description |
|---------|-------------|
| `:Zdiff` | Open zdiff for uncommitted changes (vs HEAD) |
| `:ZdiffBranch` | Open zdiff comparing HEAD to base branch |
| `:ZdiffMain` | Alias for `:ZdiffBranch` |

### Keymaps (in zdiff buffer)

| Key | Action |
|-----|--------|
| `<CR>` | Go to file/line under cursor |
| `<Tab>` | Toggle expand/collapse file |
| `m` | Toggle mode (uncommitted/branch) |
| `R` | Refresh diff |
| `q` | Close zdiff |
| `?` | Show help |

Press `?` while in zdiff to see all available keymaps.

## Configuration

```lua
require("zdiff").setup({
  -- Whether files are expanded by default
  default_expanded = false,

  -- Explicit base branch for comparison, or nil for auto-detect
  -- Auto-detect tries: origin/HEAD, then fallback_branches in order
  base_branch = nil,

  -- Branches to try when auto-detecting (in order)
  fallback_branches = { "main", "master", "develop" },

  -- Keymap bindings (set to false to disable)
  keymaps = {
    goto_file = "<CR>",
    toggle = "<Tab>",
    close = "q",
    refresh = "R",
    toggle_mode = "m",
    help = "?",
  },

  -- Icons for UI elements
  icons = {
    collapsed = "",
    expanded = "",
    added = "+",
    deleted = "-",
    modified = "~",
  },
})
```

### Examples

#### Use a specific base branch

```lua
require("zdiff").setup({
  base_branch = "develop",
})
```

#### Custom keymaps

```lua
require("zdiff").setup({
  keymaps = {
    goto_file = "o",
    toggle = "<Space>",
  },
})
```

#### Expand all files by default

```lua
require("zdiff").setup({
  default_expanded = true,
})
```

## Health Check

Run `:checkhealth zdiff` to verify your setup.

## License

MIT
