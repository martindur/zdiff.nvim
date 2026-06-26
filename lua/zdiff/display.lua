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

---@param line_type "context"|"add"|"del"|"header"
---@return string
function M.get_line_highlight(line_type)
  if line_type == "add" then
    return "DiffAdd"
  elseif line_type == "del" then
    return "DiffDelete"
  elseif line_type == "header" then
    return "Title"
  end
  return "Normal"
end

---@param line string
---@param additions number
---@param deletions number
---@return {add_start: number, add_end: number, del_start: number, del_end: number}
function M.stat_ranges(line, additions, deletions)
  local add_stat = "+" .. tostring(additions)
  local del_stat = "-" .. tostring(deletions)
  local add_start = #line - #add_stat - #del_stat - 1
  local add_end = add_start + #add_stat
  local del_start = add_end + 1
  local del_end = del_start + #del_stat
  return {
    add_start = add_start,
    add_end = add_end,
    del_start = del_start,
    del_end = del_end,
  }
end

---@param opts {icon: string|nil, status_icon: string|nil, path: string, additions: number, deletions: number}
---@return {text: string, add_start: number, add_end: number, del_start: number, del_end: number}
function M.format_file_line(opts)
  local parts = {}
  if opts.icon ~= nil then
    table.insert(parts, opts.icon)
  end
  if opts.status_icon ~= nil then
    table.insert(parts, opts.status_icon)
  end
  table.insert(parts, opts.path)

  local text = table.concat(parts, " ")
    .. "  +"
    .. tostring(opts.additions)
    .. " -"
    .. tostring(opts.deletions)
  local ranges = M.stat_ranges(text, opts.additions, opts.deletions)
  ranges.text = text
  return ranges
end

---@param hunk ZdiffHunk
---@param prefix? string
---@return string
function M.format_hunk_header(hunk, prefix)
  return string.format(
    "%s@@ -%d,%d +%d,%d @@",
    prefix or "",
    hunk.old_start,
    hunk.old_count,
    hunk.new_start,
    hunk.new_count
  )
end

return M
