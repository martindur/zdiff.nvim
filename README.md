# zdiff.nvim

A small Git diff viewer for Neovim, inspired by
[Zed's](https://zed.dev) multi-buffer diff view. Review changes across files
in one buffer, expand their patches, and jump to source lines. Native motions,
search, and operators work on the diff text, with optional Treesitter highlighting.

## Requirements

- Neovim >= 0.9.0
- Git
- Optional: Treesitter parsers and highlight queries for syntax highlighting.
  [treebox](https://github.com/martindur/treebox) is a simple CLI for managing parsers.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "martindur/zdiff.nvim",
  cmd = "Zdiff",
  keys = {
    { "<leader>zd", "<cmd>Zdiff<cr>", desc = "Zdiff (uncommitted)" },
    { "<leader>zD", "<cmd>Zdiff main<cr>", desc = "Zdiff (vs main)" },
  },
}
```

No `setup()` call is needed.

## Usage

```vim
:Zdiff
:Zdiff main
```

`:Zdiff` shows uncommitted changes. Pass any Git ref to compare from its merge
base with `HEAD`, including staged, unstaged, and untracked changes.

Inside the diff buffer:

| Command | Action |
| --- | --- |
| `:ZdiffToggle` | Toggle the file under the cursor |
| `:ZdiffOpen` | Open the source location under the cursor |
| `:ZdiffRefresh` | Reload the current comparison |

Use `<C-o>` to return after opening a source line.

## Keymaps

Choose your own buffer-local mappings. For example:

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "zdiff",
  callback = function(event)
    local opts = { buffer = event.buf, silent = true }

    vim.keymap.set("n", "<CR>", "<cmd>ZdiffOpen<cr>", opts)
    vim.keymap.set("n", "<Tab>", "<cmd>ZdiffToggle<cr>", opts)
    vim.keymap.set("n", "R", "<cmd>ZdiffRefresh<cr>", opts)
    vim.keymap.set("n", "q", "<cmd>bdelete<cr>", opts)

    -- Switch between uncommitted changes and comparison against main.
    vim.keymap.set("n", "m", function()
      if vim.b.zdiff.base == "" then
        vim.cmd("Zdiff main")
      else
        vim.cmd("Zdiff")
      end
    end, opts)
  end,
})
```

The plugin defines no default mappings. See `:help zdiff` for more configuration
examples, or the [migration guide](MIGRATION.md) when upgrading.

## Development

```sh
make test
make format
make lint
```

Requires plenary.nvim for tests, StyLua for formatting, and luacheck for linting.

## License

MIT
