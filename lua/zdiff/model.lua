local M = {}

function M.new(change_set)
  return change_set
end

function M.toggle_file(model, file_index, load_patch)
  local file = model.files[file_index]
  if not file then
    return nil, "no file at cursor"
  end
  if file.expanded then
    file.expanded = false
    return true
  end
  if not file.patch then
    local patch, err = load_patch(file)
    if not patch then
      return nil, err
    end
    file.patch = patch
  end
  file.expanded = true
  return true
end

return M
