local M = {}

function M.load()
  return vim.g.waypoint_locations or {}
end

return M
