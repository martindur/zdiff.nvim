local M = {}

function M.for_line(buf, ns, row)
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  local found = {}
  for _, mark in ipairs(marks) do
    if mark[2] == row then
      table.insert(found, mark)
    end
  end
  return found
end

function M.has_group(marks, group)
  for _, mark in ipairs(marks) do
    local details = mark[4] or {}
    if details.hl_group == group then
      return true
    end
  end
  return false
end

function M.has_group_prefix(marks, prefix)
  for _, mark in ipairs(marks) do
    local details = mark[4] or {}
    if
      type(details.hl_group) == "string"
      and details.hl_group:find(prefix, 1, true) == 1
    then
      return true
    end
  end
  return false
end

return M
