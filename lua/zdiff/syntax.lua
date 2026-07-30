local M = {}

-- Syntax is a best-effort enhancement. Keep synchronous parsing bounded so
-- opening or expanding an unusually large patch retains the plain diff.
local MAX_PARSE_BYTES = 256 * 1024
local DEFAULT_PRIORITY = 100

local function language_for_path(path)
  if
    not vim.filetype
    or not vim.filetype.match
    or not vim.treesitter
    or not vim.treesitter.get_string_parser
    or not vim.treesitter.language
    or not vim.treesitter.language.get_lang
  then
    return nil
  end
  local filetype = vim.filetype.match({ filename = path })
  return filetype and vim.treesitter.language.get_lang(filetype) or nil
end

local function range_for_capture(node, source, capture_metadata)
  if vim.treesitter.get_range then
    local range = vim.treesitter.get_range(node, source, capture_metadata)
    return range[1], range[2], range[4], range[5]
  end
  return node:range()
end

local function append_capture(highlights, lines, rows, group, priority, range)
  local start_row, start_col, end_row, end_col = unpack(range)
  local last_row = end_col == 0 and end_row - 1 or end_row
  for source_row = start_row, last_row do
    local buffer_line = rows[source_row + 1]
    if buffer_line then
      table.insert(highlights, {
        line = buffer_line,
        group = group,
        start_col = source_row == start_row and start_col or 0,
        end_col = source_row == end_row and end_col or #lines[source_row + 1],
        priority = priority,
      })
    end
  end
end

local function parse_fragment(lines, rows, lang)
  if #lines == 0 then
    return {}
  end
  local source = table.concat(lines, "\n") .. "\n"
  local parser_ok, parser = pcall(vim.treesitter.get_string_parser, source, lang)
  if not parser_ok or not parser then
    return {}
  end
  local parse_ok = pcall(parser.parse, parser, true)
  if not parse_ok then
    return {}
  end

  local highlights = {}
  pcall(parser.for_each_tree, parser, function(tree, language_tree)
    local tree_lang = language_tree:lang()
    local query_ok, query = pcall(vim.treesitter.query.get, tree_lang, "highlights")
    if not query_ok or not query then
      return
    end
    local capture_ok = pcall(function()
      for id, node, metadata in query:iter_captures(tree:root(), source) do
        local capture = query.captures[id]
        if capture and not vim.startswith(capture, "_") then
          local capture_metadata = metadata[id]
          local priority = tonumber(metadata.priority)
            or (capture_metadata and tonumber(capture_metadata.priority))
            or DEFAULT_PRIORITY
          append_capture(
            highlights,
            lines,
            rows,
            "@" .. capture .. "." .. tree_lang,
            priority,
            { range_for_capture(node, source, capture_metadata) }
          )
        end
      end
    end)
    if not capture_ok then
      return
    end
  end)
  return highlights
end

local function build_fragments(hunk, rows)
  local old = { lines = {}, rows = {} }
  local new = { lines = {}, rows = {} }
  local bytes = 0
  for line_index, patch_line in ipairs(hunk.lines) do
    local buffer_line = rows[line_index]
    if patch_line.kind ~= "add" then
      table.insert(old.lines, patch_line.text)
      table.insert(old.rows, patch_line.kind == "delete" and buffer_line or false)
      bytes = bytes + #patch_line.text + 1
    end
    if patch_line.kind ~= "delete" then
      table.insert(new.lines, patch_line.text)
      table.insert(new.rows, buffer_line)
      bytes = bytes + #patch_line.text + 1
    end
  end
  return old, new, bytes
end

local function get_highlights(files, patch_rows)
  local highlights = {}
  local parsed_bytes = 0
  for file_index, file in ipairs(files) do
    local file_rows = patch_rows[file_index]
    local lang = file_rows and language_for_path(file.path) or nil
    if lang then
      for hunk_index, hunk in ipairs(file.patch or {}) do
        local rows = file_rows[hunk_index]
        if rows then
          local old, new, bytes = build_fragments(hunk, rows)
          if parsed_bytes + bytes <= MAX_PARSE_BYTES then
            parsed_bytes = parsed_bytes + bytes
            vim.list_extend(highlights, parse_fragment(new.lines, new.rows, lang))
            vim.list_extend(highlights, parse_fragment(old.lines, old.rows, lang))
          end
        end
      end
    end
  end
  return highlights
end

function M.highlights(files, patch_rows)
  local ok, highlights = pcall(get_highlights, files, patch_rows)
  return ok and highlights or {}
end

return M
