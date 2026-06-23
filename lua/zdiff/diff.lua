local M = {}

---@class ZdiffHunk
---@field old_start number starting line in old file
---@field old_count number number of lines in old file
---@field new_start number starting line in new file
---@field new_count number number of lines in new file
---@field lines ZdiffLine[] individual diff lines

---@class ZdiffLine
---@field type "context"|"add"|"del"|"header" line type
---@field text string the line content (without +/- prefix)
---@field new_lnum number|nil line number in new file (for context/add lines)
---@field old_lnum number|nil line number in old file (for context/del lines)

---@param header string the @@ line
---@return number old_start, number old_count, number new_start, number new_count
local function parse_hunk_header(header)
  local old_start, old_count, new_start, new_count =
    header:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
  return tonumber(old_start) or 0,
    tonumber(old_count) or 1,
    tonumber(new_start) or 0,
    tonumber(new_count) or 1
end

---@param diff_lines string[]
---@return ZdiffHunk[]
function M.parse_hunks(diff_lines)
  local hunks = {}
  local current_hunk = nil
  local old_lnum, new_lnum = 0, 0

  for _, line in ipairs(diff_lines) do
    if line:match("^@@") then
      if current_hunk then
        table.insert(hunks, current_hunk)
      end
      local old_start, old_count, new_start, new_count = parse_hunk_header(line)
      old_lnum = old_start
      new_lnum = new_start
      current_hunk = {
        old_start = old_start,
        old_count = old_count,
        new_start = new_start,
        new_count = new_count,
        lines = {},
      }
    elseif current_hunk and not line:match("^\\") then
      local diff_line = {
        text = line:sub(2),
        type = "context",
        new_lnum = nil,
        old_lnum = nil,
      }

      if line:match("^%+") then
        diff_line.type = "add"
        diff_line.new_lnum = new_lnum
        new_lnum = new_lnum + 1
      elseif line:match("^%-") then
        diff_line.type = "del"
        diff_line.old_lnum = old_lnum
        old_lnum = old_lnum + 1
      elseif line:match("^ ") or line == "" then
        diff_line.type = "context"
        diff_line.new_lnum = new_lnum
        diff_line.old_lnum = old_lnum
        new_lnum = new_lnum + 1
        old_lnum = old_lnum + 1
      end

      table.insert(current_hunk.lines, diff_line)
    end
  end

  if current_hunk then
    table.insert(hunks, current_hunk)
  end

  return hunks
end

---@param raw_lines string[]
---@return ZdiffHunk[]
function M.untracked_hunks(raw_lines)
  local lines = {}
  for _, line in ipairs(raw_lines) do
    table.insert(lines, { type = "add", text = line, new_lnum = #lines + 1 })
  end

  if #lines == 0 then
    return {}
  end

  return {
    {
      header = string.format("@@ -0,0 +1,%d @@ (new file)", #lines),
      old_start = 0,
      old_count = 0,
      new_start = 1,
      new_count = #lines,
      lines = lines,
    },
  }
end

return M
