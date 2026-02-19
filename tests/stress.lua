local M = {}

local function run_sync(cmd, cwd)
  local full_cmd = cmd
  if cwd and cwd ~= "" then
    full_cmd = "cd " .. vim.fn.shellescape(cwd) .. " && " .. cmd
  end
  local out = vim.fn.system(full_cmd)
  if vim.v.shell_error ~= 0 then
    error(string.format("command failed (%s): %s", full_cmd, out))
  end
  return out
end

local function write_file(path, lines)
  local f = assert(io.open(path, "w"))
  f:write(table.concat(lines, "\n"))
  f:write("\n")
  f:close()
end

local function find_keymap_callback(buf, lhs)
  local keymaps = vim.api.nvim_buf_get_keymap(buf, "n")
  for _, km in ipairs(keymaps) do
    if km.lhs == lhs then
      return km.callback
    end
  end
  return nil
end

local function wait_for_loaded(timeout_ms)
  local ok = vim.wait(timeout_ms, function()
    local buf = vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= "zdiff" then
      return false
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, 5, false)
    if #lines == 0 then
      return false
    end
    local header = lines[1] or ""
    local loading = header:find("%(loading%.%.%.%)", 1, false) ~= nil
    return not loading
  end, 50)
  if not ok then
    error("timeout waiting for zdiff async refresh to complete")
  end
end

local function close_zdiff_or_error()
  local buf = vim.api.nvim_get_current_buf()
  local close_cb = find_keymap_callback(buf, "q")
  if not close_cb then
    error("could not find close keymap callback in zdiff buffer")
  end
  close_cb()
end

function M.run()
  local zdiff = require("zdiff")
  local plugin_root = vim.fn.getcwd()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")

  run_sync("git init", repo)
  run_sync("git config user.name 'zdiff-test'", repo)
  run_sync("git config user.email 'zdiff@example.com'", repo)

  local file_count = 60
  local lines_per_file = 120

  for i = 1, file_count do
    local dir = string.format("%s/src/mod_%02d", repo, math.floor((i - 1) / 10))
    vim.fn.mkdir(dir, "p")
    local lines = {}
    for j = 1, lines_per_file do
      lines[#lines + 1] = string.format("line %03d in file %03d", j, i)
    end
    write_file(string.format("%s/file_%03d.txt", dir, i), lines)
  end

  run_sync("git add . && git commit -m 'baseline'", repo)

  -- Create a second commit so HEAD~1 is always valid.
  write_file(string.format("%s/src/mod_00/file_001.txt", repo), { "second commit line", "keep" })
  run_sync("git add . && git commit -m 'second commit'", repo)

  -- Create a heavy working tree diff.
  for i = 1, file_count do
    local path = string.format("%s/src/mod_%02d/file_%03d.txt", repo, math.floor((i - 1) / 10), i)
    local f = assert(io.open(path, "a"))
    for j = 1, 20 do
      f:write(string.format("added line %d for file %d\n", j, i))
    end
    f:close()
  end
  write_file(string.format("%s/new_untracked.txt", repo), { "untracked", "content" })

  vim.cmd("cd " .. vim.fn.fnameescape(repo))

  local iterations = 80
  local warmup_iterations = 10
  local baseline_kb = 0
  local final_kb = 0

  for i = 1, iterations do
    if i % 2 == 0 then
      zdiff.open("HEAD~1")
    else
      zdiff.open()
    end

    wait_for_loaded(10000)

    local buf = vim.api.nvim_get_current_buf()
    local refresh_cb = find_keymap_callback(buf, "R")
    if refresh_cb then
      refresh_cb()
      wait_for_loaded(10000)
    end

    close_zdiff_or_error()
    collectgarbage("collect")

    if i == warmup_iterations then
      collectgarbage("collect")
      baseline_kb = collectgarbage("count")
    end
  end

  collectgarbage("collect")
  final_kb = collectgarbage("count")
  local growth_kb = final_kb - baseline_kb

  vim.cmd("cd " .. vim.fn.fnameescape(plugin_root))

  if growth_kb > 4096 then
    error(
      string.format(
        "possible memory leak: growth after GC %.1f KiB (baseline %.1f KiB, final %.1f KiB)",
        growth_kb,
        baseline_kb,
        final_kb
      )
    )
  end

  print(string.format("stress test passed: memory growth %.1f KiB", growth_kb))
end

return M
