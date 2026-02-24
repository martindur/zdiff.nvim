local M = {}
local uv = vim.uv or vim.loop

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

local function wait_for_syntax_idle(timeout_ms)
  local zdiff = require("zdiff")
  local ok = vim.wait(timeout_ms, function()
    local dbg = zdiff._debug_state and zdiff._debug_state() or {}
    return (dbg.pending_syntax_jobs or 0) == 0
  end, 50)
  if not ok then
    error("timeout waiting for zdiff syntax jobs to complete")
  end
end

local function benchmark_open_ms(open_fn, wait_timeout_ms)
  local start = uv.hrtime()
  open_fn()
  wait_for_loaded(wait_timeout_ms)
  wait_for_syntax_idle(wait_timeout_ms)
  local elapsed_ms = (uv.hrtime() - start) / 1e6
  close_zdiff_or_error()
  return elapsed_ms
end

local function avg(values)
  local sum = 0
  for _, v in ipairs(values) do
    sum = sum + v
  end
  if #values == 0 then
    return 0
  end
  return sum / #values
end

local function p95(values)
  if #values == 0 then
    return 0
  end
  table.sort(values)
  local idx = math.max(1, math.ceil(#values * 0.95))
  return values[idx]
end

local function build_load_repo(repo)
  local scenarios = {
    { ext = "lua", name = "lua", template = "local function fn_%d(x)\n  if x > 0 then\n    return x + %d\n  end\n  return 0\nend\n" },
    { ext = "py", name = "python", template = "def fn_%d(x):\n    if x > 0:\n        return x + %d\n    return 0\n" },
    { ext = "js", name = "javascript", template = "function fn_%d(x) {\n  if (x > 0) {\n    return x + %d;\n  }\n  return 0;\n}\n" },
    { ext = "go", name = "go", template = "func fn%d(x int) int {\n\tif x > 0 {\n\t\treturn x + %d\n\t}\n\treturn 0\n}\n" },
  }

  for _, scenario in ipairs(scenarios) do
    local dir = string.format("%s/bench/%s", repo, scenario.name)
    vim.fn.mkdir(dir, "p")
    local lines = {}
    for i = 1, 1500 do
      lines[#lines + 1] = string.format(scenario.template, i, i)
    end
    write_file(string.format("%s/huge.%s", dir, scenario.ext), lines)
  end
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

  -- Build language-varied load benchmark files.
  build_load_repo(repo)
  run_sync("git add . && git commit -m 'add load benchmark files'", repo)
  -- Modify benchmark files to create large hunks.
  local bench_files = {
    string.format("%s/bench/lua/huge.lua", repo),
    string.format("%s/bench/python/huge.py", repo),
    string.format("%s/bench/javascript/huge.js", repo),
    string.format("%s/bench/go/huge.go", repo),
  }
  for _, path in ipairs(bench_files) do
    local f = assert(io.open(path, "a"))
    for i = 1, 400 do
      f:write(string.format("bench_added_%d = %d\n", i, i))
    end
    f:close()
  end

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

    wait_for_loaded(10000)
    wait_for_syntax_idle(10000)

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

  -- Load/open timing benchmark on representative language scenarios.
  zdiff.setup({ default_expanded = true })

  local rounds = 3
  local timings_uncommitted = {}
  local timings_ref = {}
  for _ = 1, rounds do
    table.insert(timings_uncommitted, benchmark_open_ms(function()
      zdiff.open()
    end, 20000))
    table.insert(timings_ref, benchmark_open_ms(function()
      zdiff.open("HEAD~1")
    end, 20000))
    collectgarbage("collect")
  end

  local avg_uncommitted = avg(timings_uncommitted)
  local p95_uncommitted = p95(timings_uncommitted)
  local avg_ref = avg(timings_ref)
  local p95_ref = p95(timings_ref)

  print(string.format("stress test passed: memory growth %.1f KiB", growth_kb))
  print(
    string.format(
      "open benchmark (ms): uncommitted avg=%.1f p95=%.1f | ref avg=%.1f p95=%.1f",
      avg_uncommitted,
      p95_uncommitted,
      avg_ref,
      p95_ref
    )
  )
end

return M
