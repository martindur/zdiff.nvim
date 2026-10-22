local M = {}
local locations = {}

function M.add(path)
  locations[path] = { path = path }
end

function M.remove(path)
  locations[path] = nil
end

function M.clear()
  locations = {}
end

function M.count()
  return vim.tbl_count(locations)
end

function M.list()
  return vim.tbl_values(locations)
end

return M
