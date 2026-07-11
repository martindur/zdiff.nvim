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

local function file_at_cursor()
  local line = current_line()
  local file_index = state.rendered.file_lines[line]
  if file_index then
    return file_index
  end
  local target = state.rendered.targets[line]
  return target and target.file_index or nil
end

function M.refresh()
  if not state.model then
    return
  end
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
end

function M.toggle()
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
  local target = state.rendered and state.rendered.targets[current_line()]
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
