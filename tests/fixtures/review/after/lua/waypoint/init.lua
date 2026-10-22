local storage = require("waypoint.storage")
local M = {}
local locations = storage.load()

function M.add(path, label)
  locations[path] = { path = path, label = label or vim.fn.fnamemodify(path, ":t") }
  storage.save(locations)
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
  local items = vim.tbl_values(locations)
  table.sort(items, function(a, b)
    return a.label < b.label
  end)
  return items
end

return M
