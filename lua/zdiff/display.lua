local M = {}

---@param status string
---@param icons table<string, string>
---@return string
function M.get_status_icon(status, icons)
  if status == "A" or status == "?" then
    return icons.added
  elseif status == "D" then
    return icons.deleted
  else
    return icons.modified
  end
end

return M
