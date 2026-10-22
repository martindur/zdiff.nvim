# Development

## Review gallery

Run `make gallery` to open a disposable Git repository with your normal Neovim
configuration and the plugin from this checkout. The sample project has modified,
added, deleted, renamed, and untracked files, including a Lua change with separated
hunks. The help file rename also includes a small content change.

Use `<Tab>` to expand files, `<CR>` to open a source line, `<C-o>` to return,
and `R` to refresh. The gallery supplies these mappings when they are unmapped.
Changes you make stay in the temporary repository; the tracked snapshots are
in `tests/fixtures/review/before/` and `after/`.

To start with a file expanded:

```sh
nvim --cmd "set runtimepath^=$PWD" \
  -c "lua require('tests.gallery').open({ expanded = { 'lua/waypoint/init.lua' } })"
```

## README images

Run `make screenshots` to regenerate `doc/images/overview.png` and `expanded.png`.
The capture uses a clean Neovim configuration, the same sample project, fixed
dimensions, DejaVu Sans Mono at 16px, and
[Tokyo Night](https://github.com/folke/tokyonight.nvim)'s `tokyonight-night` style.
The theme revision is pinned in `tests/screenshots.py` and fetched into the
ignored `.artifacts/` directory on the first run.

Requires Python 3, Git, Chromium, DejaVu Sans Mono, and Neovim with its bundled
`nvim.tohtml` exporter and Lua Treesitter parser/query. Set `NVIM_BIN` or
`CHROMIUM_BIN` if your executables have different names.

These are images of Neovim's exported buffer contents, without terminal chrome.
`tests/screenshots.lua` defines the scenes and exports their highlights to HTML;
`tests/screenshots.py` renders them to PNG with headless Chromium. Inspect the
images after changing highlighting or updating capture dependencies.
