local M = {}

function M.keymap(buf, mode, lhs)
  for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if keymap.lhs == lhs then
      return keymap
    end
  end
  return nil
end

function M.normal_keymap(buf, lhs)
  return M.keymap(buf, "n", lhs)
end

function M.visual_keymap(buf, lhs)
  return M.keymap(buf, "v", lhs)
end

function M.normal_keymap_callback(buf, lhs)
  local keymap = M.normal_keymap(buf, lhs)
  return keymap and keymap.callback or nil
end

function M.find_line(text)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for idx, line in ipairs(lines) do
    if line:find(text, 1, true) then
      return idx
    end
  end
  return nil
end

function M.current_line()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  return vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1]
end

return M
