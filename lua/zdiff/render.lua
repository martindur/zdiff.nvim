local M = {}

local status_names = {
  A = "added",
  C = "copied",
  D = "deleted",
  M = "modified",
  R = "renamed",
  ["?"] = "untracked",
}

function M.render(model)
  local rendered = {
    lines = {},
    sources = {},
    file_at_line = {},
    file_lines = {},
    highlights = {},
  }
  local function add(line, highlight, file_index)
    table.insert(rendered.lines, line)
    if file_index then
      rendered.file_at_line[#rendered.lines] = file_index
    end
    if highlight then
      table.insert(rendered.highlights, { line = #rendered.lines, group = highlight })
    end
    return #rendered.lines
  end

  add("Uncommitted changes", "Title")
  add("")
  if #model.files == 0 then
    add("No changes found", "Comment")
    return rendered
  end

  for file_index, file in ipairs(model.files) do
    local label = string.format(
      "%s  %s  +%d -%d",
      status_names[file.status] or file.status,
      file.old_path and (file.old_path .. " -> " .. file.path) or file.path,
      file.additions,
      file.deletions
    )
    local line = add(label, "Directory", file_index)
    rendered.file_lines[line] = file_index
    rendered.sources[line] = {
      file_index = file_index,
      path = file.path,
      line = 1,
      deleted = file.status == "D",
    }

    if file.expanded then
      for hunk_index, hunk in ipairs(file.patch or {}) do
        if hunk_index > 1 then
          add("", nil, file_index)
        end
        add(hunk.header, "Comment", file_index)
        for _, patch_line in ipairs(hunk.lines) do
          local group = patch_line.kind == "add" and "DiffAdd"
            or patch_line.kind == "delete" and "DiffDelete"
            or nil
          local patch_lnum = add(patch_line.text, group, file_index)
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
