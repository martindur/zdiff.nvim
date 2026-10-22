local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local theme = assert(arg[1], "expected Tokyo Night checkout path")
local output = assert(arg[2], "expected HTML output directory")
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(theme)
vim.o.swapfile = false
vim.o.termguicolors = true
vim.o.background = "dark"
vim.o.columns = 100
vim.o.lines = 48
vim.o.number = false
vim.o.relativenumber = false
vim.o.signcolumn = "no"
vim.o.foldcolumn = "0"
vim.o.wrap = false
vim.o.laststatus = 0
vim.o.ruler = false
vim.o.showmode = false
vim.o.list = false
vim.o.cursorline = false
vim.o.cursorcolumn = false

require("tokyonight").setup({ cache = false, plugins = { all = false, auto = false } })
vim.cmd("colorscheme tokyonight-night")
vim.cmd("packadd nvim.tohtml")

-- Lua is bundled with Neovim: never silently publish a plain-diff screenshot.
assert(vim.treesitter.get_string_parser("local saved = true", "lua"))
assert(vim.treesitter.query.get("lua", "highlights"), "missing Lua highlight query")

local scenes = {
  { name = "overview", expanded = {} },
  { name = "expanded", expanded = { "lua/waypoint/init.lua" } },
}

vim.fn.mkdir(output, "p")
for _, scene in ipairs(scenes) do
  require("tests.gallery").open({ expanded = scene.expanded })
  if #scene.expanded > 0 then
    local namespace = vim.api.nvim_get_namespaces()["zdiff.syntax"]
    assert(
      namespace and #vim.api.nvim_buf_get_extmarks(0, namespace, 0, -1, {}) > 0,
      "the expanded scene has no syntax highlighting"
    )
  end
  local html = require("tohtml").tohtml(0, {
    title = false,
    font = { "DejaVu Sans Mono" },
    width = 100,
  })
  for index, line in ipairs(html) do
    if line == "</head>" then
      table.insert(
        html,
        index,
        "<style>"
          .. "html, body { margin: 0; }"
          .. "body { padding: 24px; box-sizing: border-box; }"
          .. "pre { margin: 0; font-size: 16px; line-height: 24px; }"
          .. "</style>"
      )
      break
    end
  end
  assert(vim.fn.writefile(html, output .. "/" .. scene.name .. ".html") == 0)
end
