local buffer = require("tests.helpers.buffer")

local M = {}

function M.wait_for_loaded(timeout_ms)
  local zdiff = require("zdiff")
  local ok = vim.wait(timeout_ms or 5000, function()
    local dbg = zdiff._debug_state and zdiff._debug_state() or {}
    return not dbg.loading_files
      and not dbg.pending_render
      and (dbg.pending_hunk_jobs or 0) == 0
  end, 50)
  assert.is_true(ok, "timed out waiting for zdiff to load")
end

function M.wait_for_syntax_idle(timeout_ms)
  local zdiff = require("zdiff")
  local ok = vim.wait(timeout_ms or 5000, function()
    local dbg = zdiff._debug_state and zdiff._debug_state() or {}
    return not dbg.pending_render
      and (dbg.pending_hunk_jobs or 0) == 0
      and (dbg.pending_syntax_jobs or 0) == 0
  end, 50)
  assert.is_true(ok, "timeout waiting for zdiff syntax jobs to complete")
end

function M.close_or_error()
  local buf = vim.api.nvim_get_current_buf()
  local close_cb = buffer.normal_keymap_callback(buf, "q")
  if not close_cb then
    error("could not find close keymap callback in zdiff buffer")
  end
  close_cb()
end

return M
