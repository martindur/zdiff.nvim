local fixtures = require("tests.helpers.syntax_fixtures")

local M = {}

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
