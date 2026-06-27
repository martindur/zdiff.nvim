local M = {}
local uv = vim.uv or vim.loop
local buffer = require("tests.helpers.buffer")
local git_repo = require("tests.helpers.git_repo")
local session = require("tests.helpers.zdiff_session")

local function benchmark_open_ms(open_fn, wait_timeout_ms)
  local start = uv.hrtime()
  open_fn()
  session.wait_for_loaded(wait_timeout_ms)
  session.wait_for_syntax_idle(wait_timeout_ms)
  local elapsed_ms = (uv.hrtime() - start) / 1e6
  session.close_or_error()
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
    {
      ext = "lua",
      name = "lua",
      template = "local function fn_%d(x)\n  if x > 0 then\n    return x + %d\n  end\n  return 0\nend\n",
    },
    {
      ext = "py",
      name = "python",
      template = "def fn_%d(x):\n    if x > 0:\n        return x + %d\n    return 0\n",
    },
    {
      ext = "js",
      name = "javascript",
      template = "function fn_%d(x) {\n  if (x > 0) {\n    return x + %d;\n  }\n  return 0;\n}\n",
    },
    {
      ext = "go",
      name = "go",
      template = "func fn%d(x int) int {\n\tif x > 0 {\n\t\treturn x + %d\n\t}\n\treturn 0\n}\n",
    },
  }

  for _, scenario in ipairs(scenarios) do
    local dir = string.format("%s/bench/%s", repo, scenario.name)
    vim.fn.mkdir(dir, "p")
    local lines = {}
    for i = 1, 1500 do
      lines[#lines + 1] = string.format(scenario.template, i, i)
    end
    git_repo.write_lines(string.format("%s/huge.%s", dir, scenario.ext), lines)
  end
end

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

  -- Build language-varied load benchmark files.
  build_load_repo(repo)
  git_repo.commit_all(repo, "add load benchmark files")
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

  -- Load/open timing benchmark on representative language scenarios.
  zdiff.setup({ default_expanded = true })

  local rounds = 3
  local timings_uncommitted = {}
  local timings_ref = {}
  for _ = 1, rounds do
    table.insert(
      timings_uncommitted,
      benchmark_open_ms(function()
        zdiff.open()
      end, 20000)
    )
    table.insert(
      timings_ref,
      benchmark_open_ms(function()
        zdiff.open("HEAD~1")
      end, 20000)
    )
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
