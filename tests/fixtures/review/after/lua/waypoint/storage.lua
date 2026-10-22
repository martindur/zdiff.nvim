local M = {}
local path = vim.fn.stdpath("state") .. "/waypoint.json"

function M.load()
  if vim.fn.filereadable(path) == 0 then
    return {}
  end
  return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
end

function M.save(locations)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ vim.json.encode(locations) }, path)
end

return M
