# Migrating from the previous version

zdiff now focuses on a single diff buffer with collapsible files, source
navigation, and optional Treesitter highlighting. `:Zdiff` and `:Zdiff [ref]`
remain the commands. Lua calls such as `require("zdiff").open()` and
`require("zdiff").open("main")` also remain available.

## Keep the previous version

The `legacy` tag preserves the version before the rewrite. Pin it to keep
the previous configuration and behavior, including `setup()` and its options.

With lazy.nvim, add `tag` to your existing plugin specification and keep
your existing options:

```lua
{
  "martindur/zdiff.nvim",
  tag = "legacy",
  opts = {}, -- Keep your existing options here.
}
```

Update zdiff through your plugin manager after changing the specification.
Other plugin managers can pin the same tag. The preserved commit is
`6e2a105d7cc138b25e2907589ad2c5251e608424`; you can also pin it directly
(with `commit` instead of `tag` in lazy.nvim), including before the tag is
published.

## Use the current version

1. Remove `require("zdiff").setup(...)`. With lazy.nvim, remove `opts` and
   any `config` function that calls `setup()`.
2. Add the buffer-local mappings you want using the `FileType` autocmd in
   the [README](README.md#usage).
3. Use `:ZdiffRefresh` to reload a comparison after editing, or reopen it
   through `:Zdiff` or `:Zdiff [ref]`.

`setup(opts)` remains as a compatibility function so existing setup calls
do not fail. It ignores all options and warns once per Neovim session with
a link to this guide. It does not restore previous mappings or features.

| Previous behavior | Current behavior |
| --- | --- |
| Default or configured keymaps | No plugin-defined mappings; use a `FileType` autocmd |
| `default_branch` and the `m` mapping | Choose the ref in your own mapping; see the README example |
| `default_expanded` | Files start collapsed; expand them with `:ZdiffToggle` |
| Refresh on returning to the diff buffer | Refresh with `:ZdiffRefresh` or by reopening through `:Zdiff` |
| Configurable icons and sticky winbar | Plain file overview with standard Neovim diff highlight groups |
| `gy` file-reference yank and `?` help window | These mappings and actions have been removed; see `:help zdiff` for commands |
| Branch and tag completion for `:Zdiff` | Pass a Git ref explicitly |
| Syntax options, full-file projection, and custom language integrations | Best-effort highlighting of individual hunks using available Treesitter parsers and queries |
| `:checkhealth zdiff` | The plugin-specific health check has been removed |

Each repository and comparison has its own reusable buffer, expansion state,
and cursor position. `:ZdiffOpen`, `:ZdiffToggle`, and `:ZdiffRefresh` are
buffer-local commands available inside a zdiff buffer.
