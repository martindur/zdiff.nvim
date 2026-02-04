-- Minimal init for running tests
-- Usage: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

-- Find plenary.nvim in common locations
local plenary_paths = {
  vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim"),
  vim.fn.expand("~/.local/share/nvim/plugged/plenary.nvim"),
  vim.fn.expand("~/.local/share/nvim/site/pack/vendor/start/plenary.nvim"),
  vim.fn.expand("~/.local/share/nvim/site/pack/packer/start/plenary.nvim"),
}

for _, path in ipairs(plenary_paths) do
  if vim.fn.isdirectory(path) == 1 then
    vim.opt.rtp:prepend(path)
    break
  end
end

-- Add this plugin to runtimepath
vim.opt.rtp:prepend(vim.fn.getcwd())

-- Basic settings
vim.cmd("runtime plugin/plenary.vim")
vim.o.swapfile = false
vim.o.backup = false
