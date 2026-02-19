# zdiff.nvim

A minimal, fast git diff viewer for Neovim with treesitter syntax highlighting.

Inspired by [Zed's](https://zed.dev) multi-buffer diff view - a clean, collapsible interface for reviewing changes across multiple files in a single view.

<img width="50%" height="50%" alt="image" src="https://github.com/user-attachments/assets/cb03976a-3d0c-4554-8d05-f712e030c52c" /><img width="50%" height="50%" alt="image" src="https://github.com/user-attachments/assets/f38c871a-3ca6-490a-8727-26f8275a0bf1" />



## Features

- View uncommitted changes or changes compared to any git ref
- Expand/collapse files to see inline diffs
- Treesitter syntax highlighting in diff views
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
| `?` | Show help |

Press `?` while in zdiff to see all available keymaps.

## Configuration

```lua
require("zdiff").setup({
  -- Whether files are expanded by default
  default_expanded = false,

  -- Default branch for toggle_mode (m key)
  default_branch = "main",

  -- Keymap bindings
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

  -- Git diff command preferences
  git = {
    -- "three_dot" => base...HEAD, "two_dot" => base..HEAD
    diff_mode = "three_dot",
    -- "none" | "eol" | "change" | "all"
    ignore_whitespace = "none",
  },

  -- Diff rendering preferences
  diff = {
    -- nil uses git default context, number maps to -U<number>
    context_lines = nil,
    -- "none" | "new" | "old" | "both"
    show_line_numbers = "none",
    -- 0 = unlimited
    max_file_preview_lines = 0,
  },

  -- Changed file list preferences
  files = {
    include_untracked = true,
    -- "path" | "status" | "changed_lines"
    sort = "path",
    -- 0 = unlimited
    max_files = 0,
  },

  -- UI preferences
  ui = {
    -- "relative" | "filename_only" | "shortened"
    path_style = "relative",
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

#### Ignore whitespace and compare tips directly

```lua
require("zdiff").setup({
  git = {
    diff_mode = "two_dot",
    ignore_whitespace = "all",
  },
})
```

#### Show line numbers and limit large previews

```lua
require("zdiff").setup({
  diff = {
    show_line_numbers = "both",
    max_file_preview_lines = 300,
  },
})
```

#### Sort biggest diffs first and hide untracked files

```lua
require("zdiff").setup({
  files = {
    include_untracked = false,
    sort = "changed_lines",
  },
})
```

#### Custom keymaps and path display

```lua
require("zdiff").setup({
  keymaps = {
    goto_file = "o",
    toggle = "<Space>",
  },
  ui = {
    path_style = "shortened",
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

Stress test (async refresh + repeated open/close memory baseline check):

```bash
make stress-test
```

## License

MIT
