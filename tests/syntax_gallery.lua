local fixtures = require("tests.helpers.syntax_fixtures")

local M = {}

local function plugin_root()
  local source = debug.getinfo(1, "S").source
  local file = source:sub(1, 1) == "@" and source:sub(2) or source
  return vim.fn.fnamemodify(file, ":p:h:h")
end

local function reload_zdiff()
  for name, _ in pairs(package.loaded) do
    if name == "zdiff" or name:match("^zdiff%.") then
      package.loaded[name] = nil
    end
  end
end

function M.open()
  local repo = fixtures.create_repo()
  vim.cmd("cd " .. vim.fn.fnameescape(repo))

  vim.opt.runtimepath:prepend(plugin_root())
  reload_zdiff()
  local zdiff = require("zdiff")

  zdiff.setup({
    default_expanded = false,
    syntax = {
      mode = "projection",
      max_lines = 0,
    },
  })

  zdiff.open()
  vim.notify("[zdiff] syntax gallery repo: " .. repo, vim.log.levels.INFO)
end

return M
