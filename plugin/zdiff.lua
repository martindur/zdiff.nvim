if vim.g.loaded_zdiff then
  return
end
vim.g.loaded_zdiff = true

vim.api.nvim_create_user_command("Zdiff", function()
  require("zdiff").open()
end, { desc = "Review uncommitted changes" })

vim.api.nvim_create_user_command("ZdiffRefresh", function()
  require("zdiff").refresh()
end, { desc = "Refresh uncommitted changes" })

vim.api.nvim_create_user_command("ZdiffToggle", function()
  require("zdiff").toggle()
end, { desc = "Expand or collapse the file at the cursor" })

vim.api.nvim_create_user_command("ZdiffOpen", function()
  require("zdiff").open_source()
end, { desc = "Open the source location at the cursor" })
