local M = {}
local buffer = require("tests.helpers.buffer")
local git_repo = require("tests.helpers.git_repo")
local session = require("tests.helpers.zdiff_session")

function M.run()
  local zdiff = require("zdiff")
  local plugin_root = vim.fn.getcwd()
  local repo = git_repo.create()

  local file_count = 60
  local lines_per_file = 120

  for i = 1, file_count do
    local dir = string.format("%s/src/mod_%02d", repo, math.floor((i - 1) / 10))
    vim.fn.mkdir(dir, "p")
    local lines = {}
    for j = 1, lines_per_file do
      lines[#lines + 1] = string.format("line %03d in file %03d", j, i)
    end
    git_repo.write_lines(string.format("%s/file_%03d.txt", dir, i), lines)
  end

  git_repo.commit_all(repo, "baseline")

  -- Create a second commit so HEAD~1 is always valid.
  git_repo.write_lines(
    string.format("%s/src/mod_00/file_001.txt", repo),
    { "second commit line", "keep" }
  )
  git_repo.commit_all(repo, "second commit")

  -- Create a heavy working tree diff.
  for i = 1, file_count do
    local path =
      string.format("%s/src/mod_%02d/file_%03d.txt", repo, math.floor((i - 1) / 10), i)
    local f = assert(io.open(path, "a"))
    for j = 1, 20 do
      f:write(string.format("added line %d for file %d\n", j, i))
    end
    f:close()
  end
  git_repo.write_lines(string.format("%s/new_untracked.txt", repo), { "untracked", "content" })

  vim.cmd("cd " .. vim.fn.fnameescape(repo))
  zdiff.setup({
    default_expanded = false,
    syntax = {
      mode = "projection",
      max_lines = 6000,
    },
  })

  local iterations = 40
  local warmup_iterations = 10
  local baseline_kb = 0
  local final_kb = 0

  for i = 1, iterations do
    if i % 2 == 0 then
      zdiff.open("HEAD~1")
    else
      zdiff.open()
    end

    session.wait_for_loaded(10000)
    session.wait_for_syntax_idle(10000)

    local buf = vim.api.nvim_get_current_buf()
    local refresh_cb = buffer.normal_keymap_callback(buf, "R")
    if refresh_cb then
      refresh_cb()
      session.wait_for_loaded(10000)
    end

    session.close_or_error()
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
