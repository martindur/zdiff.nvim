# zdiff.nvim

An experimental, small Git diff viewer for Neovim.

This branch is a ground-up rewrite focused on one review loop:

1. See which uncommitted files changed and by how much.
2. Expand selected files to inspect their patches.
3. Open a changed source line and use `<C-o>` to return to the diff.

The rendered diff is ordinary text with real blank-line boundaries between
hunks, so native motions such as `{`, `}`, search, marks, and operators remain
useful without spacing out the file overview.

## Usage

```vim
:Zdiff
```

The plugin defines commands but no keymaps:

| Command | Action |
| --- | --- |
| `:ZdiffToggle` | Toggle the file under the cursor |
| `:ZdiffOpen` | Open the source location under the cursor |
| `:ZdiffRefresh` | Reload uncommitted changes |

Use a `FileType` autocmd to choose how the diff buffer behaves. For example,
these mappings reproduce the suggested defaults:

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "zdiff",
  callback = function(event)
    local opts = { buffer = event.buf, silent = true }

    vim.keymap.set("n", "<CR>", "<cmd>ZdiffOpen<cr>", opts)
    vim.keymap.set("n", "<Tab>", "<cmd>ZdiffToggle<cr>", opts)
    vim.keymap.set("n", "R", "<cmd>ZdiffRefresh<cr>", opts)
    vim.keymap.set("n", "q", "<cmd>bdelete<cr>", opts)
  end,
})
```

These are examples rather than plugin defaults. Any omitted key retains its
normal Neovim behavior.

## Current scope

The rewrite intentionally supports only uncommitted changes against `HEAD`.
It uses synchronous Git commands and standard Neovim diff highlight groups.

There is currently no configuration, automatic refresh, arbitrary-ref mode,
sticky winbar, help window, icon set, or Treesitter highlighting. Optional
features will be evaluated individually after the core workflow has been used.

## Development

```sh
make test
make format
make lint
```

Tests require Neovim and plenary.nvim. Linting additionally requires luacheck.
