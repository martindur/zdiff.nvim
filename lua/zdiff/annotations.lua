local selections = require("zdiff.selections")

local M = {}

---@param selection {file_path: string}
---@return string
function M.format_prompt(selection)
  local file_path = selection.file_path
  local max_len = 48

  if #file_path > max_len then
    file_path = "..." .. file_path:sub(#file_path - max_len + 4)
  end

  return "Annotation [" .. file_path .. "]: "
end

---@param annotation {file_path: string, old_ranges: table[]|nil, new_ranges: table[]|nil}
---@return string
function M.format_export_ref(annotation)
  local new_ref = selections.format_ranges(annotation.new_ranges)
  if new_ref then
    return string.format("%s:%s", annotation.file_path, new_ref)
  end

  local old_ref = selections.format_ranges(annotation.old_ranges)
  if old_ref then
    return string.format("%s:deleted %s", annotation.file_path, old_ref)
  end

  return annotation.file_path
end

---@param annotation {file_path: string, old_ranges: table[]|nil, new_ranges: table[]|nil, text: string}
---@return string
function M.format_export_line(annotation)
  return string.format("%s %s", M.format_export_ref(annotation), annotation.text)
end

---@param annotation {text: string}
---@return string
function M.format_display_line(annotation)
  return annotation.text
end

return M
