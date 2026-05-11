local M = {}

---@param path? string
---@return string|nil
function M.root(path)
  local argv = { "git" }
  if path and path ~= "" then
    vim.list_extend(argv, { "-C", vim.fn.fnamemodify(path, ":p:h") })
  end
  vim.list_extend(argv, { "rev-parse", "--show-toplevel" })

  local ok, result = pcall(vim.fn.systemlist, argv)
  if not ok or vim.v.shell_error ~= 0 then
    return nil
  end
  return result[1]
end

---@param path string
---@param root string
---@return string
function M.relative_path(path, root)
  local full = vim.fn.fnamemodify(path, ":p")
  local normalized_root = vim.fn.fnamemodify(root, ":p")
  if full:sub(1, #normalized_root) == normalized_root then
    return full:sub(#normalized_root + 1)
  end
  return vim.fn.fnamemodify(path, ":.")
end

---@param header string
---@return number, number, number, number
function M.parse_hunk_header(header)
  local old_start, old_count, new_start, new_count =
    header:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
  return tonumber(old_start) or 0,
    tonumber(old_count) or 1,
    tonumber(new_start) or 0,
    tonumber(new_count) or 1
end

---@param diff_lines string[]
---@return ZdiffHunk[]
function M.parse_diff_hunks(diff_lines)
  local hunks = {}
  local current_hunk = nil
  local old_lnum, new_lnum = 0, 0

  for _, line in ipairs(diff_lines) do
    if line:match("^@@") then
      if current_hunk then
        table.insert(hunks, current_hunk)
      end
      local old_start, old_count, new_start, new_count = M.parse_hunk_header(line)
      old_lnum = old_start
      new_lnum = new_start
      current_hunk = {
        old_start = old_start,
        old_count = old_count,
        new_start = new_start,
        new_count = new_count,
        lines = {},
      }
    elseif current_hunk then
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

---@param root string
---@param rel_path string
---@param base_ref? string
---@return ZdiffHunk[]
function M.file_hunks(root, rel_path, base_ref)
  local argv = { "git", "-C", root, "diff" }
  if base_ref and base_ref ~= "" then
    table.insert(argv, base_ref .. "...HEAD")
  else
    table.insert(argv, "HEAD")
  end
  vim.list_extend(argv, { "--", rel_path })

  local ok, result = pcall(vim.fn.systemlist, argv)
  if not ok or vim.v.shell_error ~= 0 then
    return {}
  end
  return M.parse_diff_hunks(result)
end

return M
