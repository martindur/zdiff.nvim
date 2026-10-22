local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
for name in pairs(package.loaded) do
  if name == "zdiff" or name:match("^zdiff%.") then
    package.loaded[name] = nil
  end
end

local fixture = require("tests.helpers.review_fixture")

local M = {}

---Open a disposable sample project using the current Neovim configuration.
---@param opts? {expanded?: string[]}
---@return string repository_path
function M.open(opts)
  local repo = fixture.create_repo()
  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  require("zdiff").open()
  assert(vim.bo.filetype == "zdiff", "could not open the review fixture")

  local mappings = {
    ["<CR>"] = "ZdiffOpen",
    ["<Tab>"] = "ZdiffToggle",
    R = "ZdiffRefresh",
    q = "bdelete",
  }
  for key, command in pairs(mappings) do
    if vim.fn.maparg(key, "n") == "" then
      vim.keymap.set(
        "n",
        key,
        "<cmd>" .. command .. "<cr>",
        { buffer = true, silent = true }
      )
    end
  end

  for _, path in ipairs(opts and opts.expanded or {}) do
    local found = false
    for row, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if
        line:find("  " .. path .. "  ", 1, true)
        or line:find(" -> " .. path .. "  ", 1, true)
      then
        vim.api.nvim_win_set_cursor(0, { row, 0 })
        vim.cmd("ZdiffToggle")
        found = true
        break
      end
    end
    assert(found, "no fixture file: " .. path)
  end
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  return repo
end

return M
