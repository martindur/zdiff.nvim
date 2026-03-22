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
- Jump directly to source files at the correct line
- Add in-memory annotations for review feedback
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
| `c` | Add annotation on current line / visual selection |
| `d` | Delete annotation under cursor |
| `yc` | Yank annotations for the current diff target |
| `?` | Show help |

`gy` works in both normal mode (current line) and visual mode (selection). It outputs `file:line` / `file:start-end`, ignores deleted lines, and preserves multiple ranges across hunks such as `path:10-15, 1020-1025`.

Annotations are kept in memory for the current Neovim session and scoped by diff target. They reappear when reopening the same zdiff target later in the session, but they are not written to disk. `yc` exports concise lines like `path/to/file.lua:12-14 tighten this branch`, and uses `path/to/file.lua:12-13(deleted) ...` for deletion-only annotations.

You can wrap `yc` output with a configurable prefix/suffix, which is useful when pasting feedback straight into an AI prompt.

Pressing `c` opens a temporary floating editor for the annotation text. Use normal Vim editing inside the float, `<S-CR>` or `:w` to submit, and `q` or `<Esc>` to cancel.

Example `yc` output:

```text
Feedback for changes:
tests/zdiff_spec.lua:216-219 test comment
tests/zdiff_spec.lua:230-232 another one
lua/zdiff/init.lua:1429(deleted) commenting on a deleted line
```

Press `?` while in zdiff to see all available keymaps.

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
    comment = "c",
    delete_comment = "d",
    yank_comments = "yc",
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

  comments = {
    prefix = "Feedback for changes:\n",
    suffix = "",
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

#### AI feedback export

```lua
require("zdiff").setup({
  comments = {
    prefix = "Feedback for changes:\n",
    suffix = "\nPlease address these review comments.",
  },
})
```

#### Theme annotation highlights

You can override the annotation UI with standard highlight groups:

- `ZdiffAnnotationRail`
- `ZdiffAnnotationBorder`
- `ZdiffAnnotationNoteText`

Example:

```lua
vim.api.nvim_set_hl(0, "ZdiffAnnotationRail", { fg = "#e5a524" })
vim.api.nvim_set_hl(0, "ZdiffAnnotationBorder", { fg = "#e5a524" })
vim.api.nvim_set_hl(0, "ZdiffAnnotationNoteText", { fg = "#f5f1e8", italic = true })
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

## License

MIT
