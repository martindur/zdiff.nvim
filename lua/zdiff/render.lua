local M = {}

local status_groups = {
  A = "Added",
  C = "Added",
  D = "Removed",
  M = "Changed",
  R = "Changed",
  ["?"] = "Added",
}

function M.render(model)
  local rendered = {
    lines = {},
    sources = {},
    file_at_line = {},
    file_lines = {},
    patch_rows = {},
    highlights = {},
  }
  local function add(line, highlight, file_index, start_col, end_col)
    table.insert(rendered.lines, line)
    if file_index then
      rendered.file_at_line[#rendered.lines] = file_index
    end
    if highlight then
      table.insert(rendered.highlights, {
        line = #rendered.lines,
        group = highlight,
        start_col = start_col or 0,
        end_col = end_col or -1,
      })
    end
    return #rendered.lines
  end

  local base = model.base or ""
  local title = base == "" and "Uncommitted changes" or ("Changes since " .. base)
  add(title, "Title")
  add("")
  if #model.files == 0 then
    add("No changes found", "Comment")
    return rendered
  end

  for file_index, file in ipairs(model.files) do
    local path = file.old_path and (file.old_path .. " -> " .. file.path) or file.path
    local additions = string.format("+%d", file.additions)
    local deletions = string.format("-%d", file.deletions)
    local label = string.format("%s  %s  %s %s", file.status, path, additions, deletions)
    local line = add(label, nil, file_index)
    local path_start = #file.status + 2
    local path_end = path_start + #path
    local additions_start = path_end + 2
    table.insert(rendered.highlights, {
      line = line,
      group = status_groups[file.status] or "Comment",
      start_col = 0,
      end_col = #file.status,
    })
    table.insert(rendered.highlights, {
      line = line,
      group = "Directory",
      start_col = path_start,
      end_col = path_end,
    })
    table.insert(rendered.highlights, {
      line = line,
      group = "DiffAdd",
      start_col = additions_start,
      end_col = additions_start + #additions,
    })
    table.insert(rendered.highlights, {
      line = line,
      group = "DiffDelete",
      start_col = additions_start + #additions + 1,
      end_col = -1,
    })
    rendered.file_lines[line] = file_index
    rendered.sources[line] = {
      file_index = file_index,
      path = file.path,
      line = 1,
      deleted = file.status == "D",
    }

    if file.expanded then
      for hunk_index, hunk in ipairs(file.patch or {}) do
        rendered.patch_rows[file_index] = rendered.patch_rows[file_index] or {}
        rendered.patch_rows[file_index][hunk_index] = {}
        if hunk_index > 1 then
          add("", nil, file_index)
        end
        add(hunk.header, "Comment", file_index)
        for patch_line_index, patch_line in ipairs(hunk.lines) do
          local group = patch_line.kind == "add" and "DiffAdd"
            or patch_line.kind == "delete" and "DiffDelete"
            or nil
          local patch_lnum = add(patch_line.text, group, file_index)
          rendered.patch_rows[file_index][hunk_index][patch_line_index] = patch_lnum
          rendered.sources[patch_lnum] = {
            file_index = file_index,
            path = file.path,
            line = patch_line.new_line or patch_line.old_line,
            deleted = patch_line.kind == "delete",
          }
        end
      end
    end
  end
  return rendered
end

return M
