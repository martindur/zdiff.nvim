local M = {}

---@param target ZdiffReviewCommentTarget
---@return string
function M.target_key(target)
  return table.concat({
    tostring(target.pr_number),
    target.path,
    target.side,
    tostring(target.line),
  }, "\0")
end

---@param pr_number number
---@param comment ZdiffReviewPostedComment
---@return string
function M.comment_key(pr_number, comment)
  return M.target_key({
    pr_number = pr_number,
    path = comment.path,
    side = comment.side,
    line = comment.line,
  })
end

---@param comment ZdiffReviewPostedComment
---@return string
function M.reply_key(comment)
  return "reply\0" .. tostring(comment.id)
end

---@param pr ZdiffReviewPr|nil
---@param file table
---@param diff_line ZdiffLine
---@return ZdiffReviewCommentTarget|nil
function M.target(pr, file, diff_line)
  if not pr then
    return nil
  end

  if diff_line.type == "del" and diff_line.old_lnum then
    return {
      pr_number = pr.number,
      path = file.old_path or file.path,
      side = "LEFT",
      line = diff_line.old_lnum,
    }
  end

  if diff_line.new_lnum then
    return {
      pr_number = pr.number,
      path = file.new_path or file.path,
      side = "RIGHT",
      line = diff_line.new_lnum,
    }
  end

  return nil
end

---@param comment ZdiffReviewPostedComment
---@param file table
---@return boolean
function M.matches_file(comment, file)
  if comment.side == "LEFT" then
    return comment.path == (file.old_path or file.path) or comment.path == file.path
  end
  return comment.path == (file.new_path or file.path) or comment.path == file.path
end

---@param files table[]
---@param comment ZdiffReviewPostedComment
---@return table|nil
function M.location(files, comment)
  for file_idx, file in ipairs(files) do
    if M.matches_file(comment, file) then
      for hunk_idx, hunk in ipairs(file.hunks or {}) do
        for line_idx, diff_line in ipairs(hunk.lines or {}) do
          if
            (comment.side == "LEFT" and diff_line.old_lnum == comment.line)
            or (comment.side == "RIGHT" and diff_line.new_lnum == comment.line)
          then
            return {
              file_idx = file_idx,
              hunk_idx = hunk_idx,
              line_idx = line_idx,
              comment = comment,
            }
          end
        end
      end

      return {
        file_idx = file_idx,
        hunk_idx = 0,
        line_idx = 0,
        comment = comment,
      }
    end
  end
  return nil
end

---@param files table[]
---@param comment_groups table<string, ZdiffReviewPostedComment[]>
---@param file_idx number
---@return number, number, string[]
function M.file_counts(files, comment_groups, file_idx)
  local file = files[file_idx]
  if not file then
    return 0, 0, {}
  end

  local threads = 0
  local comment_count = 0
  local seen_authors = {}
  for _, group in pairs(comment_groups) do
    for _, comment in ipairs(group) do
      if M.matches_file(comment, file) then
        comment_count = comment_count + 1
        if comment.author and comment.author ~= "" then
          seen_authors["@" .. comment.author] = true
        end
        if not comment.in_reply_to_id then
          threads = threads + 1
        end
      end
    end
  end

  local authors = vim.tbl_keys(seen_authors)
  table.sort(authors)
  return threads, comment_count, authors
end

---@param a table
---@param b table
---@return boolean
function M.location_less(a, b)
  if a.file_idx ~= b.file_idx then
    return a.file_idx < b.file_idx
  end
  if a.hunk_idx ~= b.hunk_idx then
    return a.hunk_idx < b.hunk_idx
  end
  if a.line_idx ~= b.line_idx then
    return a.line_idx < b.line_idx
  end
  return (a.comment.id or 0) < (b.comment.id or 0)
end

return M
