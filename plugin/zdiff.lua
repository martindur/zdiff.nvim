-- zdiff.nvim - A minimal git diff viewer for Neovim
-- This file provides commands without requiring explicit setup()

if vim.g.loaded_zdiff then
  return
end
vim.g.loaded_zdiff = true

-- Create user commands (these work even without setup())
vim.api.nvim_create_user_command("Zdiff", function()
  require("zdiff").open("uncommitted")
end, { desc = "Open zdiff for uncommitted changes" })

vim.api.nvim_create_user_command("ZdiffBranch", function()
  require("zdiff").open("branch")
end, { desc = "Open zdiff comparing to base branch" })

-- Backward compatibility alias
vim.api.nvim_create_user_command("ZdiffMain", function()
  require("zdiff").open("branch")
end, { desc = "Open zdiff comparing to base branch (alias for ZdiffBranch)" })
