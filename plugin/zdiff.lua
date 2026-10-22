if vim.g.loaded_zdiff then
  return
end
vim.g.loaded_zdiff = true

vim.api.nvim_create_user_command("Zdiff", function(command)
  require("zdiff").open(command.args ~= "" and command.args or nil)
end, { nargs = "?", desc = "Review changes, optionally against a Git ref" })
