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
:Zdiff main
```

`:Zdiff` opens uncommitted changes. Passing a Git ref opens changes since its
merge base with `HEAD`, including current staged, unstaged, and untracked work.
Each repository and comparison has one reusable buffer with independent
expansion and cursor state.

The plugin defines no keymaps. `:Zdiff` is global; the action commands exist
only inside a zdiff buffer:

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

These are examples rather than plugin defaults. Any omitted key retains its
normal Neovim behavior.

Every diff buffer exposes its comparison context for filetype configuration:

```lua
vim.b.zdiff.root -- repository root
vim.b.zdiff.base -- empty for uncommitted changes, otherwise the requested ref
```

## Syntax highlighting

Expanded hunks are syntax highlighted when Neovim can find a Treesitter parser
and highlight query for the changed file. This is a best-effort enhancement:
missing parsers, unsupported filetypes, and unusually large patches retain the
ordinary diff highlighting without an error.

Each hunk is parsed locally. This keeps highlighting independent from Git
loading and navigation, though a fragment beginning inside a larger language
construct may receive incomplete highlighting.

## Current scope

The rewrite uses synchronous Git commands, standard Neovim diff highlight
groups, and optional Treesitter highlighting from Neovim's built-in APIs.

There is currently no setup function, automatic refresh, sticky winbar, help
window, icon set, syntax configuration, or custom language integration.
Optional features will be evaluated individually after the core workflow has
been used.

## Development

```sh
make test
make format
make lint
```

Tests require Neovim and plenary.nvim. Linting additionally requires luacheck.
