local git = require("zdiff.git")
local model = require("zdiff.model")
local renderer = require("zdiff.render")

local M = {}
local state = { buf = nil, model = nil, rendered = nil }
local namespace = vim.api.nvim_create_namespace("zdiff")

local function notify(message, level)
  vim.notify("[zdiff] " .. message, level or vim.log.levels.INFO)
end

local function render()
  state.rendered = renderer.render(state.model)
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, state.rendered.lines)
  vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
  for _, highlight in ipairs(state.rendered.highlights) do
    vim.api.nvim_buf_add_highlight(
      state.buf,
      namespace,
      highlight.group,
      highlight.line - 1,
      0,
      -1
    )
  end
  vim.bo[state.buf].modifiable = false
end

local function current_line()
  return vim.api.nvim_win_get_cursor(0)[1]
end

local function buffer_is_valid()
  return state.buf and vim.api.nvim_buf_is_valid(state.buf)
end

local function in_zdiff_buffer()
  return buffer_is_valid() and vim.api.nvim_get_current_buf() == state.buf
end

local function file_at_cursor()
  return state.rendered.file_at_line[current_line()]
end

local function cursor_position()
  if not in_zdiff_buffer() then
    return nil
  end
  local line = current_line()
  local source = state.rendered.sources[line]
  local file_index = state.rendered.file_at_line[line]
  local file = file_index and state.model.files[file_index] or nil
  return {
    path = source and source.path or (file and file.path),
    source_line = source and source.line or nil,
  }
end

local function restore_cursor(position)
  if not position or not position.path or not in_zdiff_buffer() then
    return
  end
  local fallback
  for line, file_index in pairs(state.rendered.file_lines) do
    if state.model.files[file_index].path == position.path then
      fallback = line
      break
    end
  end
  local target = fallback
  if position.source_line then
    for line, source in pairs(state.rendered.sources) do
      if
        source.path == position.path
        and source.line == position.source_line
        and not source.deleted
      then
        target = line
        break
      end
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(0, { target, 0 })
  end
end

function M.refresh()
  if not state.model or not buffer_is_valid() then
    return
  end
  local position = cursor_position()
  local change_set, err = git.uncommitted_changes(state.model.root)
  if not change_set then
    notify(err or "could not load changes", vim.log.levels.ERROR)
    return
  end
  local expanded = {}
  for _, file in ipairs(state.model.files) do
    expanded[file.path] = file.expanded
  end
  state.model = model.new(change_set)
  for _, file in ipairs(state.model.files) do
    if expanded[file.path] then
      local patch = git.patch(state.model.root, file)
      if patch then
        file.patch, file.expanded = patch, true
      end
    end
  end
  render()
  restore_cursor(position)
end

function M.toggle()
  if not in_zdiff_buffer() then
    return
  end
  local file_index = file_at_cursor()
  if not file_index then
    return
  end
  local header_line
  for line, index in pairs(state.rendered.file_lines) do
    if index == file_index then
      header_line = line
      break
    end
  end
  local ok, err = model.toggle_file(state.model, file_index, function(file)
    return git.patch(state.model.root, file)
  end)
  if not ok then
    notify(err or "could not load patch", vim.log.levels.ERROR)
    return
  end
  render()
  vim.api.nvim_win_set_cursor(0, { header_line, 0 })
end

function M.open_source()
  if not in_zdiff_buffer() then
    return
  end
  local target = state.rendered and state.rendered.sources[current_line()]
  if not target or target.deleted then
    return
  end
  local path = state.model.root .. "/" .. target.path
  vim.cmd("normal! m'")
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local last_line = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(0, { math.min(target.line or 1, last_line), 0 })
end

function M.open()
  local root, root_err = git.root()
  if not root then
    notify(root_err or "not in a Git repository", vim.log.levels.ERROR)
    return
  end
  if buffer_is_valid() and state.model and state.model.root == root then
    vim.api.nvim_win_set_buf(0, state.buf)
    M.refresh()
    return
  end
  if buffer_is_valid() then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end

  local change_set, err = git.uncommitted_changes(root)
  if not change_set then
    notify(err or "could not load changes", vim.log.levels.ERROR)
    return
  end

  state.model = model.new(change_set)
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(state.buf, "zdiff://uncommitted")
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].bufhidden = "hide"
  vim.bo[state.buf].swapfile = false
  vim.bo[state.buf].filetype = "zdiff"
  vim.api.nvim_win_set_buf(0, state.buf)
  render()
end

M._state = state

return M
