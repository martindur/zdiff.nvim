local M = {}

---@param info string
---@return string|nil
local function parse_fence_info(info)
  return info:match("^%s*{%.([%w_%-]+)") or info:match("^%s*([%w_%-]+)")
end

---@param line string
---@return string|nil marker, string|nil info
local function parse_fence_start(line)
  local marker, info = line:match("^%s*(```+)%s*(.*)$")
  if marker then
    return marker, info or ""
  end

  marker, info = line:match("^%s*(~~~+)%s*(.*)$")
  if marker then
    return marker, info or ""
  end

  return nil, nil
end

---@param line string
---@param marker string
---@return boolean
local function is_fence_end(line, marker)
  return line:match("^%s*" .. marker) ~= nil
end

---@param code string[]
---@param syntax table
---@return ZdiffInjection[]
function M.get_injections(code, syntax)
  local injections = {}
  local fence = nil
  local inline_lang = syntax.get_lang_from_filetype("markdown_inline")

  for line_idx, line in ipairs(code) do
    if fence then
      if is_fence_end(line, fence.marker) then
        local ft = parse_fence_info(fence.info)
        local lang = ft and syntax.get_lang_from_filetype(ft) or nil
        if lang and lang ~= "markdown" and #fence.lines > 0 then
          table.insert(injections, {
            lang = lang,
            lines = fence.lines,
            line_offset = fence.start_line - 1,
          })
        end
        fence = nil
      else
        table.insert(fence.lines, line)
      end
    else
      local marker, info = parse_fence_start(line)
      if marker then
        fence = {
          marker = marker,
          info = info,
          lines = {},
          start_line = line_idx + 1,
        }
      elseif inline_lang and line ~= "" then
        table.insert(injections, {
          lang = inline_lang,
          lines = { line },
          line_offset = line_idx - 1,
        })
      end
    end
  end

  return injections
end

return M
