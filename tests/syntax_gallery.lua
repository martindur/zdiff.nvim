local fixtures = require("tests.helpers.syntax_fixtures")

local M = {}

function M.open()
  local repo = fixtures.create_repo()
  vim.cmd("cd " .. vim.fn.fnameescape(repo))

  require("zdiff").setup({
    default_expanded = true,
    syntax = {
      mode = "projection",
      max_lines = 0,
    },
  })

  require("zdiff").open()
  vim.notify("[zdiff] syntax gallery repo: " .. repo, vim.log.levels.INFO)
end

return M
