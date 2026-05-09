local M = {}
local display = require("zdiff.display")

---@param text string
---@return string
local function statusline_escape(text)
  return text:gsub("%%", "%%%%")
end

---@param file ZdiffFile
---@param icons table<string, string>
---@return string
function M.format_file(file, icons)
  local status_icon = display.get_status_icon(file.status, icons)
  local add_stat = string.format("+%d", file.insertions)
  local del_stat = string.format("-%d", file.deletions)

  return table.concat({
    "%#Directory# ",
    statusline_escape(status_icon .. " " .. file.path),
    "  %#DiffAdd#",
    statusline_escape(add_stat),
    "%* %#DiffDelete#",
    statusline_escape(del_stat),
    "%*",
  })
end

---@param topline number
---@param line_map table<number, {file_idx: number, hunk_idx: number|nil, line_idx: number|nil, lnum: number|nil}>
---@param file_header_lines table<number, number>
---@param files ZdiffFile[]
---@return ZdiffFile|nil
function M.file_for_topline(topline, line_map, file_header_lines, files)
  for lnum = topline, 1, -1 do
    local mapping = line_map[lnum]
    if mapping and mapping.file_idx then
      local header_line = file_header_lines[mapping.file_idx]
      local file = files[mapping.file_idx]
      if file and header_line and header_line < topline then
        return file
      end
      return nil
    end
  end

  return nil
end

---@param win number
local function clear(win)
  if vim.api.nvim_win_is_valid(win) then
    vim.wo[win].winbar = ""
  end
end

---@param win number
---@return number|nil
local function get_window_topline(win)
  local ok, topline = pcall(vim.fn.line, "w0", win)
  if not ok or type(topline) ~= "number" then
    return nil
  end
  return topline
end

---@param ctx {buf: number|nil, win: number|nil, files: ZdiffFile[], line_map: table, file_header_lines: table, icons: table<string, string>}
---@param win? number
function M.update(ctx, win)
  win = win or ctx.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  if not ctx.buf or vim.api.nvim_win_get_buf(win) ~= ctx.buf then
    return
  end

  local topline = get_window_topline(win)
  if not topline then
    clear(win)
    return
  end

  local file = M.file_for_topline(topline, ctx.line_map, ctx.file_header_lines, ctx.files)
  if file then
    vim.wo[win].winbar = M.format_file(file, ctx.icons)
  else
    clear(win)
  end
end

return M
