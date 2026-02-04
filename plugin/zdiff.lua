-- zdiff.nvim - A minimal git diff viewer for Neovim
-- This file provides commands without requiring explicit setup()

if vim.g.loaded_zdiff then
  return
end
vim.g.loaded_zdiff = true

-- Git ref completion function
local function complete_git_refs(arg_lead, _, _)
  -- Get branches and tags
  local refs = {}

  -- Local branches
  local branches = vim.fn.systemlist("git branch --format='%(refname:short)' 2>/dev/null")
  if vim.v.shell_error == 0 then
    for _, branch in ipairs(branches) do
      if branch:find(arg_lead, 1, true) == 1 then
        table.insert(refs, branch)
      end
    end
  end

  -- Remote branches (without origin/ prefix for convenience)
  local remote_branches = vim.fn.systemlist("git branch -r --format='%(refname:short)' 2>/dev/null")
  if vim.v.shell_error == 0 then
    for _, branch in ipairs(remote_branches) do
      -- Strip origin/ prefix for easier typing
      local short = branch:gsub("^origin/", "")
      if short:find(arg_lead, 1, true) == 1 and not vim.tbl_contains(refs, short) then
        table.insert(refs, short)
      end
      -- Also include full ref
      if branch:find(arg_lead, 1, true) == 1 then
        table.insert(refs, branch)
      end
    end
  end

  -- Tags
  local tags = vim.fn.systemlist("git tag 2>/dev/null")
  if vim.v.shell_error == 0 then
    for _, tag in ipairs(tags) do
      if tag:find(arg_lead, 1, true) == 1 then
        table.insert(refs, tag)
      end
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
