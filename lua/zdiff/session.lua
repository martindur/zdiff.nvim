local git = require("zdiff.git")
local model = require("zdiff.model")
local renderer = require("zdiff.render")

local Session = {}
Session.__index = Session

local namespace = vim.api.nvim_create_namespace("zdiff")

local function notify(message, level)
  vim.notify("[zdiff] " .. message, level or vim.log.levels.INFO)
end

function Session.new(change_set, on_delete)
  local self = setmetatable({
    model = model.new(change_set),
    rendered = nil,
    last_position = nil,
  }, Session)
  self.buf = vim.api.nvim_create_buf(false, true)
  local label = self.model.base == "" and "uncommitted" or self.model.base
  local identity = vim.fn.sha256(self.model.root .. "\0" .. self.model.base):sub(1, 12)
  vim.api.nvim_buf_set_name(self.buf, string.format("zdiff://%s/%s", label, identity))
  vim.bo[self.buf].buftype = "nofile"
  vim.bo[self.buf].bufhidden = "hide"
  vim.bo[self.buf].swapfile = false
  vim.b[self.buf].zdiff = { root = self.model.root, base = self.model.base }

  vim.api.nvim_buf_create_user_command(self.buf, "ZdiffOpen", function()
    self:open_source()
  end, { desc = "Open the source location at the cursor" })
  vim.api.nvim_buf_create_user_command(self.buf, "ZdiffToggle", function()
    self:toggle()
  end, { desc = "Expand or collapse the file at the cursor" })
  vim.api.nvim_buf_create_user_command(self.buf, "ZdiffRefresh", function()
    self:refresh()
  end, { desc = "Refresh this comparison" })
  vim.api.nvim_create_autocmd({ "BufUnload", "BufDelete", "BufWipeout" }, {
    buffer = self.buf,
    once = true,
    callback = function()
      on_delete(self)
    end,
  })

  vim.bo[self.buf].filetype = "zdiff"
  self:render()
  return self
end

function Session:is_valid()
  return self.buf
    and vim.api.nvim_buf_is_valid(self.buf)
    and vim.api.nvim_buf_is_loaded(self.buf)
end

function Session:is_current()
  return self:is_valid() and vim.api.nvim_get_current_buf() == self.buf
end

function Session:render()
  self.rendered = renderer.render(self.model)
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, self.rendered.lines)
  vim.api.nvim_buf_clear_namespace(self.buf, namespace, 0, -1)
  for _, highlight in ipairs(self.rendered.highlights) do
    vim.api.nvim_buf_add_highlight(
      self.buf,
      namespace,
      highlight.group,
      highlight.line - 1,
      0,
      -1
    )
  end
  vim.bo[self.buf].modifiable = false
end

function Session:cursor_position()
  if not self:is_current() then
    return self.last_position
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local source = self.rendered.sources[line]
  local file_index = self.rendered.file_at_line[line]
  local file = file_index and self.model.files[file_index] or nil
  return {
    path = source and source.path or (file and file.path),
    source_line = source and source.line or nil,
  }
end

function Session:remember_cursor()
  if self:is_current() then
    self.last_position = self:cursor_position()
  end
end

function Session:restore_cursor(position)
  if not position or not position.path or not self:is_current() then
    return
  end
  local fallback
  for line, file_index in pairs(self.rendered.file_lines) do
    if self.model.files[file_index].path == position.path then
      fallback = line
      break
    end
  end
  local target = fallback
  if position.source_line then
    for line, source in pairs(self.rendered.sources) do
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

function Session:refresh()
  if not self:is_valid() then
    return
  end
  local position = self:cursor_position()
  local change_set, err = git.changes(self.model.root, self.model.base)
  if not change_set then
    notify(err or "could not load changes", vim.log.levels.ERROR)
    return
  end
  local expanded = {}
  for _, file in ipairs(self.model.files) do
    expanded[file.path] = file.expanded
  end
  self.model = model.new(change_set)
  for _, file in ipairs(self.model.files) do
    if expanded[file.path] then
      local patch = git.patch(self.model.root, self.model.target, file)
      if patch then
        file.patch, file.expanded = patch, true
      end
    end
  end
  self:render()
  self.last_position = position
  self:restore_cursor(position)
end

function Session:enter()
  if not self:is_valid() then
    return
  end
  vim.api.nvim_win_set_buf(0, self.buf)
  self:refresh()
end

function Session:toggle()
  if not self:is_current() then
    return
  end
  local file_index = self.rendered.file_at_line[vim.api.nvim_win_get_cursor(0)[1]]
  if not file_index then
    return
  end
  local header_line
  for line, index in pairs(self.rendered.file_lines) do
    if index == file_index then
      header_line = line
      break
    end
  end
  local ok, err = model.toggle_file(self.model, file_index, function(file)
    return git.patch(self.model.root, self.model.target, file)
  end)
  if not ok then
    notify(err or "could not load patch", vim.log.levels.ERROR)
    return
  end
  self:render()
  vim.api.nvim_win_set_cursor(0, { header_line, 0 })
end

function Session:open_source()
  if not self:is_current() then
    return
  end
  local target = self.rendered.sources[vim.api.nvim_win_get_cursor(0)[1]]
  if not target or target.deleted then
    return
  end
  self:remember_cursor()
  vim.cmd("normal! m'")
  vim.cmd("edit " .. vim.fn.fnameescape(self.model.root .. "/" .. target.path))
  local last_line = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(0, { math.min(target.line or 1, last_line), 0 })
end

return Session
