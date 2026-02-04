local M = {}

function M.check()
  vim.health.start("zdiff.nvim")

  -- Check Neovim version
  local nvim_version = vim.version()
  if nvim_version.major == 0 and nvim_version.minor < 9 then
    vim.health.error(
      string.format("Neovim 0.9+ required, found %d.%d.%d", nvim_version.major, nvim_version.minor, nvim_version.patch)
    )
  else
    vim.health.ok(string.format("Neovim version %d.%d.%d", nvim_version.major, nvim_version.minor, nvim_version.patch))
  end

  -- Check git is available
  local git_version = vim.fn.system("git --version")
  if vim.v.shell_error ~= 0 then
    vim.health.error("git not found in PATH")
  else
    vim.health.ok(git_version:gsub("\n", ""))
  end

  -- Check if in a git repository (informational)
  local git_root = vim.fn.systemlist("git rev-parse --show-toplevel 2>/dev/null")
  if vim.v.shell_error ~= 0 then
    vim.health.warn("Current directory is not inside a git repository")
  else
    vim.health.ok("Inside git repository: " .. git_root[1])
  end

  -- Check treesitter (optional, for syntax highlighting)
  local has_ts = pcall(require, "nvim-treesitter")
  if has_ts then
    vim.health.ok("nvim-treesitter is available (syntax highlighting in diffs)")
  else
    vim.health.info("nvim-treesitter not found (optional: enables syntax highlighting in expanded diffs)")
  end
end

return M
