-- zdiff.nvim - A minimal git diff viewer for Neovim
-- This file provides commands without requiring explicit setup()

if vim.g.loaded_zdiff then
  return
end
vim.g.loaded_zdiff = true

-- Git ref completion function
local function complete_git_refs(arg_lead, _, _)
  local refs_raw = vim.fn.systemlist({
    "git",
    "for-each-ref",
    "--format=%(refname:short)",
    "refs/heads",
    "refs/remotes",
    "refs/tags",
  })
  if vim.v.shell_error ~= 0 then
    return {}
  end

  local refs = {}
  for _, ref in ipairs(refs_raw) do
    local short = ref:gsub("^origin/", "")
    if short:find(arg_lead, 1, true) == 1 and not vim.tbl_contains(refs, short) then
      table.insert(refs, short)
    end
    if ref:find(arg_lead, 1, true) == 1 and not vim.tbl_contains(refs, ref) then
      table.insert(refs, ref)
    end
  end

  return refs
end

-- Create user command
vim.api.nvim_create_user_command("Zdiff", function(opts)
  local ref = opts.args ~= "" and opts.args or nil
  require("zdiff").open(ref)
end, {
  nargs = "?",
  complete = complete_git_refs,
  desc = "Open zdiff (optionally against a git ref)",
})

vim.api.nvim_create_user_command("ZdiffReview", function()
  require("zdiff.review").open()
end, {
  desc = "Open zdiff review pull request browser",
})
