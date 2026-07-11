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

Inside the diff buffer:

- `<Tab>` expands or collapses the file under the cursor.
- `<CR>` opens the source location under the cursor.

Manual actions are also available as commands and `<Plug>` mappings:

| Command | Mapping | Action |
| --- | --- | --- |
| `:ZdiffToggle` | `<Plug>(zdiff-toggle)` | Toggle a file |
| `:ZdiffOpen` | `<Plug>(zdiff-open)` | Open a source location |
| `:ZdiffRefresh` | `<Plug>(zdiff-refresh)` | Reload uncommitted changes |

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
