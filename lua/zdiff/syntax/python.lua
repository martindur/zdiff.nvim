local M = {}

---@param line string
---@return integer|nil start_col, integer|nil end_col, string|nil marker
local function find_triple_quote(line)
  local double_start, double_end = line:find('"""', 1, true)
  local single_start, single_end = line:find("'''", 1, true)

  if double_start and (not single_start or double_start < single_start) then
    return double_start, double_end, '"""'
  end
  if single_start then
    return single_start, single_end, "'''"
  end
  return nil, nil, nil
end

---@param line string
---@return boolean
local function context_looks_sql(line)
  local name = line:lower():match("([%w_]+)%s*=%s*$")
  if not name then
    return false
  end
  return name:find("sql", 1, true) ~= nil
    or name:find("query", 1, true) ~= nil
    or name:find("statement", 1, true) ~= nil
end

---@param lines string[]
---@return boolean
local function lines_look_sql(lines)
  local text = table.concat(lines, "\n"):upper()
  return text:match("%f[%a]SELECT%f[%A]") ~= nil
    or text:match("%f[%a]INSERT%f[%A]") ~= nil
    or text:match("%f[%a]UPDATE%f[%A]") ~= nil
    or text:match("%f[%a]DELETE%f[%A]") ~= nil
    or text:match("%f[%a]WITH%f[%A]") ~= nil
    or text:match("%f[%a]CREATE%f[%A]") ~= nil
end

---@param string table
---@param sql_lang string
---@return ZdiffInjection|nil
local function build_sql_injection(string, sql_lang)
  if #string.lines == 0 then
    return nil
  end
  if not string.sql_context and not lines_look_sql(string.lines) then
    return nil
  end

  return {
    lang = sql_lang,
    lines = string.lines,
    line_offset = string.line_offset,
    col_offsets = string.col_offsets,
  }
end

---@param code string[]
---@param syntax table
---@return ZdiffInjection[]
function M.get_injections(code, syntax)
  local sql_lang = syntax.get_lang_from_filetype("sql")
  if not sql_lang then
    return {}
  end

  local injections = {}
  local string = nil

  for line_idx, line in ipairs(code) do
    if string then
      local close_start = line:find(string.marker, 1, true)
      if close_start then
        local before_close = line:sub(1, close_start - 1)
        if before_close ~= "" then
          table.insert(string.lines, before_close)
          string.col_offsets[#string.lines] = 0
        end

        local injection = build_sql_injection(string, sql_lang)
        if injection then
          table.insert(injections, injection)
        end
        string = nil
      else
        table.insert(string.lines, line)
        string.col_offsets[#string.lines] = 0
      end
    else
      local open_start, open_end, marker = find_triple_quote(line)
      if marker then
        local after_open = line:sub(open_end + 1)
        local sql_string = {
          marker = marker,
          sql_context = context_looks_sql(line:sub(1, open_start - 1)),
          lines = {},
          col_offsets = {},
          line_offset = line_idx - 1,
        }

        local close_start = after_open:find(marker, 1, true)
        if close_start then
          local before_close = after_open:sub(1, close_start - 1)
          if before_close ~= "" then
            table.insert(sql_string.lines, before_close)
            sql_string.col_offsets[#sql_string.lines] = open_end
          end

          local injection = build_sql_injection(sql_string, sql_lang)
          if injection then
            table.insert(injections, injection)
          end
        elseif after_open ~= "" then
          table.insert(sql_string.lines, after_open)
          sql_string.col_offsets[#sql_string.lines] = open_end
          string = sql_string
        else
          sql_string.line_offset = line_idx
          string = sql_string
        end
      end
    end
  end

  return injections
end

return M
