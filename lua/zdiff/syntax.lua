local M = {}

---@class ZdiffSyntaxHighlight
---@field line number
---@field hl_group string
---@field col_start number
---@field col_end number

---@class ZdiffInjection
---@field line_offset number
---@field lines string[]
---@field lang string
---@field col_offsets? table<number, number>

local filetype_aliases = {
  bash = { "sh" },
  javascriptreact = { "javascript" },
  shell = { "sh" },
  typescriptreact = { "tsx", "typescript" },
}

local injection_providers = {
  markdown = require("zdiff.syntax.markdown"),
  python = require("zdiff.syntax.python"),
}

---@param lang string
---@return boolean
function M.has_highlights(lang)
  if not lang or not pcall(vim.treesitter.language.inspect, lang) then
    return false
  end
  if not pcall(vim.treesitter.get_string_parser, "probe\n", lang) then
    return false
  end
  local ok, query = pcall(vim.treesitter.query.get, lang, "highlights")
  return ok and query ~= nil
end

---@param ft string
---@return string|nil
function M.get_lang_from_filetype(ft)
  local candidates = { ft }
  vim.list_extend(candidates, filetype_aliases[ft] or {})

  local seen = {}
  for _, candidate in ipairs(candidates) do
    if not seen[candidate] then
      seen[candidate] = true
      local lang = vim.treesitter.language.get_lang(candidate) or candidate
      if lang and M.has_highlights(lang) then
        return lang
      end
    end
  end
  return nil
end

---@param filepath string
---@return string|nil
function M.get_lang_from_path(filepath)
  local ft = vim.filetype.match({ filename = filepath })
  if not ft then
    return nil
  end
  return M.get_lang_from_filetype(ft)
end

---@param code string[]
---@param lang string
---@return ZdiffInjection[]
local function get_injections(code, lang)
  local provider = injection_providers[lang]
  if provider then
    return provider.get_injections(code, M)
  end
  return {}
end

---@param code string[]
---@param lang string
---@return ZdiffSyntaxHighlight[]
local function get_treesitter_highlights(code, lang)
  local source = table.concat(code, "\n")
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, lang)
  if not ok or not parser then
    return {}
  end

  local trees = parser:parse()
  if not trees or #trees == 0 then
    return {}
  end

  local query_ok, query = pcall(vim.treesitter.query.get, lang, "highlights")
  if not query_ok or not query then
    return {}
  end

  local highlights = {}
  for id, node, _ in query:iter_captures(trees[1]:root(), source) do
    local name = query.captures[id]
    local start_row, start_col, end_row, end_col = node:range()
    local hl_group = "@" .. name

    if start_row == end_row then
      table.insert(highlights, {
        line = start_row + 1,
        hl_group = hl_group,
        col_start = start_col,
        col_end = end_col,
      })
    else
      for row = start_row, end_row do
        table.insert(highlights, {
          line = row + 1,
          hl_group = hl_group,
          col_start = row == start_row and start_col or 0,
          col_end = row == end_row and end_col or -1,
        })
      end
    end
  end

  return highlights
end

---@param highlights ZdiffSyntaxHighlight[]
---@param injection ZdiffInjection
local function append_injection_highlights(highlights, injection)
  local injected = M.get_highlights(injection.lines, injection.lang)
  for _, hl in ipairs(injected) do
    local col_offset = (injection.col_offsets and injection.col_offsets[hl.line]) or 0
    table.insert(highlights, {
      line = injection.line_offset + hl.line,
      hl_group = hl.hl_group,
      col_start = col_offset + hl.col_start,
      col_end = hl.col_end == -1 and -1 or (col_offset + hl.col_end),
    })
  end
end

---@param code string[]
---@param lang string
---@return ZdiffSyntaxHighlight[]
function M.get_highlights(code, lang)
  local highlights = get_treesitter_highlights(code, lang)
  for _, injection in ipairs(get_injections(code, lang)) do
    append_injection_highlights(highlights, injection)
  end
  return highlights
end

return M
