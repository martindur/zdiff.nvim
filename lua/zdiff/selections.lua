local M = {}

---@param lnums number[]
---@return {start: number, finish: number}[]
local function compress_ranges(lnums)
  table.sort(lnums)
  local ranges = {}
  local current = nil

  for _, lnum in ipairs(lnums) do
    if not current then
      current = { start = lnum, finish = lnum }
    elseif lnum == current.finish + 1 then
      current.finish = lnum
    elseif lnum ~= current.finish then
      table.insert(ranges, current)
      current = { start = lnum, finish = lnum }
    end
  end

  if current then
    table.insert(ranges, current)
  end

  return ranges
end

---@param ranges {start: number, finish: number}[]|nil
---@return string|nil
function M.format_ranges(ranges)
  if not ranges or #ranges == 0 then
    return nil
  end

  local parts = {}
  for _, range in ipairs(ranges) do
    if range.start == range.finish then
      table.insert(parts, tostring(range.start))
    else
      table.insert(parts, string.format("%d-%d", range.start, range.finish))
    end
  end

  return table.concat(parts, ", ")
end

---@param line_map table<number, table>
---@param files table[]
---@param start_line number
---@param end_line number
---@return {file_path: string, anchor_lines: table[], old_ranges: table[], new_ranges: table[]}|nil, string|nil
function M.collect_annotation_selection(line_map, files, start_line, end_line)
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  local file = nil
  local anchor_lines = {}
  local old_lnums = {}
  local new_lnums = {}

  for line = start_line, end_line do
    local mapping = line_map[line]
    local current_file = mapping and mapping.file_idx and files[mapping.file_idx] or nil
    if not current_file
      or mapping.hunk_idx == nil
      or mapping.line_idx == nil
      or mapping.line_type == nil
    then
      return nil, "Can only annotate diff lines"
    end

    if not file then
      file = current_file
    elseif file.path ~= current_file.path then
      return nil, "Cannot annotate across multiple files"
    end

    table.insert(anchor_lines, {
      type = mapping.line_type,
      old_lnum = mapping.old_lnum,
      new_lnum = mapping.new_lnum,
    })

    if mapping.old_lnum then
      table.insert(old_lnums, mapping.old_lnum)
    end
    if mapping.new_lnum then
      table.insert(new_lnums, mapping.new_lnum)
    end
  end

  if not file or #anchor_lines == 0 then
    return nil, "No diff lines selected"
  end

  return {
    file_path = file.path,
    anchor_lines = anchor_lines,
    old_ranges = compress_ranges(old_lnums),
    new_ranges = compress_ranges(new_lnums),
  }, nil
end

---@param line_map table<number, table>
---@param files table[]
---@param start_line number
---@param end_line number
---@return {file_path: string, ranges: table[]}|nil, string|nil
function M.collect_reference_selection(line_map, files, start_line, end_line)
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  local file = nil
  local lnums = {}

  for line = start_line, end_line do
    local mapping = line_map[line]
    local current_file = mapping and mapping.file_idx and files[mapping.file_idx] or nil
    if not current_file then
      return nil, string.format("line %d is not part of a diff", line)
    end

    if not file then
      file = current_file
    elseif file.path ~= current_file.path then
      return nil, "selection spans multiple files"
    end

    if mapping.hunk_idx ~= nil and mapping.line_idx ~= nil and mapping.line_type ~= "del" and mapping.lnum then
      table.insert(lnums, mapping.lnum)
    end
  end

  local ranges = compress_ranges(lnums)
  if not file then
    return nil, "no file selected"
  end
  if #ranges == 0 then
    return nil, "no addition or context lines in selection"
  end

  return {
    file_path = file.path,
    ranges = ranges,
  }, nil
end

return M
