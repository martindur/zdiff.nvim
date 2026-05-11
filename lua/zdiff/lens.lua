local M = {}
local git = require("zdiff.git")

local ns = vim.api.nvim_create_namespace("zdiff_lens")
local augroup = vim.api.nvim_create_augroup("zdiff_lens", { clear = false })

---@class ZdiffLensConfig
---@field auto_attach boolean Whether to attach to normal file buffers automatically
---@field virtual_deleted boolean Whether to show deleted lines as virtual lines
---@field debounce_ms number Debounce delay for automatic refresh

---@type ZdiffLensConfig
M.config = {
  auto_attach = false,
  virtual_deleted = true,
  debounce_ms = 150,
}

local state = {
  attached = {},
  timers = {},
}

---@param bufnr number
local function clear(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

---@param bufnr number
---@param lnum number
local function mark_add(bufnr, lnum)
  if lnum < 1 then
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, lnum - 1, 0, {
    line_hl_group = "DiffAdd",
    priority = 80,
  })
end

---@param bufnr number
---@param lnum number
---@param text string
local function mark_delete(bufnr, lnum, text)
  if not M.config.virtual_deleted then
    return
  end

  local line_count = math.max(vim.api.nvim_buf_line_count(bufnr), 1)
  local anchor = math.min(math.max(lnum, 1), line_count)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, anchor - 1, 0, {
    virt_lines = { { { text, "DiffDelete" } } },
    virt_lines_above = true,
    priority = 80,
  })
end

---@param bufnr number
---@param hunks table[]
local function apply_hunks(bufnr, hunks)
  clear(bufnr)

  for _, hunk in ipairs(hunks) do
    local next_new_lnum = hunk.new_start
    for _, diff_line in ipairs(hunk.lines) do
      if diff_line.type == "add" and diff_line.new_lnum then
        mark_add(bufnr, diff_line.new_lnum)
        next_new_lnum = diff_line.new_lnum + 1
      elseif diff_line.type == "context" and diff_line.new_lnum then
        next_new_lnum = diff_line.new_lnum + 1
      elseif diff_line.type == "del" then
        mark_delete(bufnr, next_new_lnum, diff_line.text)
      end
    end
  end
end

---@param bufnr? number
function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local info = state.attached[bufnr]
  if not info then
    return
  end

  if vim.bo[bufnr].buftype ~= "" then
    M.detach(bufnr)
    return
  end

  local hunks = git.file_hunks(info.root, info.rel_path)
  apply_hunks(bufnr, hunks)
end

---@param bufnr number
local function refresh_debounced(bufnr)
  local existing = state.timers[bufnr]
  if existing then
    existing:stop()
    existing:close()
    state.timers[bufnr] = nil
  end

  local timer = (vim.uv or vim.loop).new_timer()
  state.timers[bufnr] = timer
  timer:start(M.config.debounce_ms, 0, function()
    timer:stop()
    timer:close()
    if state.timers[bufnr] == timer then
      state.timers[bufnr] = nil
    end
    vim.schedule(function()
      M.refresh(bufnr)
    end)
  end)
end

---@param bufnr? number
function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
    return false
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return false
  end

  local root = git.root(path)
  if not root then
    return false
  end

  state.attached[bufnr] = {
    root = root,
    rel_path = git.relative_path(path, root),
  }
  M.refresh(bufnr)
  return true
end

---@param bufnr? number
function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local timer = state.timers[bufnr]
  if timer then
    timer:stop()
    timer:close()
    state.timers[bufnr] = nil
  end
  state.attached[bufnr] = nil
  clear(bufnr)
end

---@param bufnr? number
function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if state.attached[bufnr] then
    M.detach(bufnr)
    return false
  end
  return M.attach(bufnr)
end

local function setup_autocmds()
  vim.api.nvim_clear_autocmds({ group = augroup })

  vim.api.nvim_create_autocmd({ "BufWritePost", "FocusGained" }, {
    group = augroup,
    callback = function(args)
      if state.attached[args.buf] then
        refresh_debounced(args.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    callback = function(args)
      local timer = state.timers[args.buf]
      if timer then
        timer:stop()
        timer:close()
        state.timers[args.buf] = nil
      end
      state.attached[args.buf] = nil
    end,
  })

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = augroup,
    callback = function(args)
      if M.config.auto_attach then
        M.attach(args.buf)
      end
    end,
  })
end

---@param opts? ZdiffLensConfig
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  setup_autocmds()

  if M.config.auto_attach then
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        M.attach(bufnr)
      end
    end
  end
end

M._debug = {
  parse_diff_hunks = git.parse_diff_hunks,
  apply_hunks = apply_hunks,
  attached = state.attached,
}

return M
