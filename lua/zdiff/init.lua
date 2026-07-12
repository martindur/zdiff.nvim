local git = require("zdiff.git")
local Session = require("zdiff.session")

local M = {}
local sessions = {}

local function notify(message, level)
  vim.notify("[zdiff] " .. message, level or vim.log.levels.INFO)
end

local function session_key(root, base)
  return root .. "\0" .. base
end

local function current_session()
  local buf = vim.api.nvim_get_current_buf()
  for _, session in pairs(sessions) do
    if session.buf == buf then
      return session
    end
  end
end

function M.open(base)
  base = base or ""
  local root, root_err = git.root()
  if not root then
    notify(root_err or "not in a Git repository", vim.log.levels.ERROR)
    return
  end

  local active = current_session()
  if active then
    active:remember_cursor()
  end

  local key = session_key(root, base)
  local existing = sessions[key]
  if existing and existing:is_valid() then
    existing:enter()
    return
  end

  local change_set, err = git.changes(root, base)
  if not change_set then
    notify(err or "could not load changes", vim.log.levels.ERROR)
    return
  end
  local session
  session = Session.new(change_set, function(wiped)
    if sessions[key] == wiped then
      sessions[key] = nil
    end
  end)
  sessions[key] = session
  vim.api.nvim_win_set_buf(0, session.buf)
end

M._sessions = sessions

return M
