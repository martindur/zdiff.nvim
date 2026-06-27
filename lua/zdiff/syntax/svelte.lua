local M = {}

---@param attrs string
---@return string
local function script_filetype(attrs)
  local lang = attrs:match("lang%s*=%s*[\"']([^\"']+)[\"']")
    or attrs:match("lang%s*=%s*([^%s>]+)")
  lang = lang and lang:lower() or nil
  if lang == "ts" or lang == "typescript" then
    return "typescript"
  end
  return "javascript"
end

---@param line string
---@return integer|nil start_col, integer|nil end_col, string|nil attrs
local function find_script_start(line)
  return line:find("<script%s*([^>]*)>")
end

---@param block table
---@return ZdiffInjection|nil
local function build_script_injection(block)
  if #block.lines == 0 then
    return nil
  end
  return {
    lang = block.lang,
    lines = block.lines,
    line_offset = block.line_offset,
    col_offsets = block.col_offsets,
  }
end

---@param code string[]
---@param syntax table
---@return ZdiffInjection[]
function M.get_injections(code, syntax)
  local injections = {}
  local block = nil

  for line_idx, line in ipairs(code) do
    if block then
      local close_start = line:find("</script>", 1, true)
      if close_start then
        local before_close = line:sub(1, close_start - 1)
        if before_close ~= "" then
          table.insert(block.lines, before_close)
          block.col_offsets[#block.lines] = 0
        end

        local injection = build_script_injection(block)
        if injection then
          table.insert(injections, injection)
        end
        block = nil
      else
        table.insert(block.lines, line)
        block.col_offsets[#block.lines] = 0
      end
    else
      local _, open_end, attrs = find_script_start(line)
      if open_end and attrs then
        local lang = syntax.get_lang_from_filetype(script_filetype(attrs))
        if lang then
          local after_open = line:sub(open_end + 1)
          block = {
            lang = lang,
            lines = {},
            col_offsets = {},
            line_offset = line_idx - 1,
          }

          local close_start = after_open:find("</script>", 1, true)
          if close_start then
            local before_close = after_open:sub(1, close_start - 1)
            if before_close ~= "" then
              table.insert(block.lines, before_close)
              block.col_offsets[#block.lines] = open_end
            end

            local injection = build_script_injection(block)
            if injection then
              table.insert(injections, injection)
            end
            block = nil
          elseif after_open ~= "" then
            table.insert(block.lines, after_open)
            block.col_offsets[#block.lines] = open_end
          else
            block.line_offset = line_idx
          end
        end
      end
    end
  end

  return injections
end

return M
