local M = {}

---@class ZdiffLine
---@field type "context"|"add"|"del"|"header"
---@field text string
---@field new_lnum number|nil
---@field old_lnum number|nil

---@class ZdiffHunk
---@field old_start number
---@field old_count number
---@field new_start number
---@field new_count number
---@field lines ZdiffLine[]

---@class ZdiffFile
---@field path string
---@field status string
---@field insertions number
---@field deletions number
---@field expanded boolean
---@field hunks ZdiffHunk[]

---@param argv string[]
---@param callback fun(code: number, lines: string[])
---@param opts? {preserve_empty_lines?: boolean}
local function run_command_async(argv, callback, opts)
  local preserve_empty_lines = opts and opts.preserve_empty_lines == true
  if vim.system then
    vim.system(argv, { text = true }, function(obj)
      local lines = {}
      if obj.stdout and obj.stdout ~= "" then
        if preserve_empty_lines then
          lines = vim.split(obj.stdout, "\n", { plain = true })
          if #lines > 0 and lines[#lines] == "" then
            table.remove(lines, #lines)
          end
        else
          lines = vim.split(obj.stdout, "\n", { plain = true, trimempty = true })
        end
      end
      vim.schedule(function()
        callback(obj.code or 1, lines)
      end)
    end)
    return
  end

  local stdout = {}
  local job_id = vim.fn.jobstart(argv, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        stdout = data
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        local lines = {}
        for _, line in ipairs(stdout) do
          if preserve_empty_lines or line ~= "" then
            table.insert(lines, line)
          end
        end
        callback(code or 1, lines)
      end)
    end,
  })
  if job_id <= 0 then
    vim.schedule(function()
      callback(1, {})
    end)
  end
end

---@return string|nil
function M.get_git_root()
  local result = vim.fn.systemlist("git rev-parse --show-toplevel")
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return result[1]
end

---@param rel_path string
---@return number
local function count_file_lines(rel_path)
  local git_root = M.get_git_root()
  if not git_root then
    return 0
  end
  local filepath = git_root .. "/" .. rel_path
  local line_count = 0
  local file = io.open(filepath, "r")
  if file then
    for _ in file:lines() do
      line_count = line_count + 1
    end
    file:close()
  end
  return line_count
end

---@param base_ref string|nil
---@param done fun(stats: table<string, {insertions: number, deletions: number, status: string}>)
local function get_diff_stats_async(base_ref, done)
  local diff_target = base_ref and (base_ref .. "...HEAD") or "HEAD"
  local stats = {}

  run_command_async({ "git", "diff", "--numstat", diff_target }, function(_, result)
    for _, line in ipairs(result) do
      local ins, del, path = line:match("^(%d+)%s+(%d+)%s+(.+)$")
      if path then
        stats[path] = {
          insertions = tonumber(ins) or 0,
          deletions = tonumber(del) or 0,
          status = "M",
        }
      end
    end

    run_command_async(
      { "git", "diff", "--name-status", diff_target },
      function(_, status_result)
        for _, line in ipairs(status_result) do
          local status, path = line:match("^(%a)%s+(.+)$")
          if path and stats[path] then
            stats[path].status = status
          elseif path then
            stats[path] = { insertions = 0, deletions = 0, status = status }
          end
        end

        if base_ref then
          done(stats)
          return
        end

        run_command_async(
          { "git", "ls-files", "--others", "--exclude-standard" },
          function(_, untracked_result)
            for _, path in ipairs(untracked_result) do
              if path ~= "" and not stats[path] then
                stats[path] = {
                  insertions = count_file_lines(path),
                  deletions = 0,
                  status = "?",
                }
              end
            end
            done(stats)
          end
        )
      end
    )
  end)
end

---@param header string
---@return number, number, number, number
local function parse_hunk_header(header)
  local old_start, old_count, new_start, new_count =
    header:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
  return tonumber(old_start) or 0,
    tonumber(old_count) or 1,
    tonumber(new_start) or 0,
    tonumber(new_count) or 1
end

---@param diff_lines string[]
---@return ZdiffHunk[]
local function parse_diff_hunks(diff_lines)
  local hunks = {}
  local current_hunk = nil
  local old_lnum, new_lnum = 0, 0

  for _, line in ipairs(diff_lines) do
    if line:match("^@@") then
      if current_hunk then
        table.insert(hunks, current_hunk)
      end
      local old_start, old_count, new_start, new_count = parse_hunk_header(line)
      old_lnum = old_start
      new_lnum = new_start
      current_hunk = {
        old_start = old_start,
        old_count = old_count,
        new_start = new_start,
        new_count = new_count,
        lines = {},
      }
    elseif current_hunk then
      local diff_line = {
        text = line:sub(2),
        type = "context",
        new_lnum = nil,
        old_lnum = nil,
      }

      if line:match("^%+") then
        diff_line.type = "add"
        diff_line.new_lnum = new_lnum
        new_lnum = new_lnum + 1
      elseif line:match("^%-") then
        diff_line.type = "del"
        diff_line.old_lnum = old_lnum
        old_lnum = old_lnum + 1
      elseif line:match("^ ") or line == "" then
        diff_line.type = "context"
        diff_line.new_lnum = new_lnum
        diff_line.old_lnum = old_lnum
        new_lnum = new_lnum + 1
        old_lnum = old_lnum + 1
      end

      table.insert(current_hunk.lines, diff_line)
    end
  end

  if current_hunk then
    table.insert(hunks, current_hunk)
  end

  return hunks
end

---@param filepath string
---@param base_ref string|nil
---@param status string|nil
---@return ZdiffHunk[]
function M.get_file_diff(filepath, base_ref, status)
  if status == "?" then
    local git_root = M.get_git_root()
    local full_path = git_root .. "/" .. filepath
    local file = io.open(full_path, "r")
    if not file then
      return {}
    end

    local lines = {}
    for line in file:lines() do
      table.insert(lines, { type = "add", text = line, new_lnum = #lines + 1 })
    end
    file:close()

    if #lines == 0 then
      return {}
    end

    return {
      {
        header = string.format("@@ -0,0 +1,%d @@ (new file)", #lines),
        old_start = 0,
        old_count = 0,
        new_start = 1,
        new_count = #lines,
        lines = lines,
      },
    }
  end

  local cmd
  if base_ref then
    cmd = string.format(
      "git diff %s...HEAD -- %s",
      vim.fn.shellescape(base_ref),
      vim.fn.shellescape(filepath)
    )
  else
    cmd = string.format("git diff HEAD -- %s", vim.fn.shellescape(filepath))
  end

  local result = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return {}
  end

  return parse_diff_hunks(result)
end

---@param base_ref string|nil
---@param default_expanded boolean
---@param done fun(files: ZdiffFile[])
function M.load_files_async(base_ref, default_expanded, done)
  get_diff_stats_async(base_ref, function(stats)
    local files = {}

    for path, info in pairs(stats) do
      table.insert(files, {
        path = path,
        status = info.status,
        insertions = info.insertions,
        deletions = info.deletions,
        expanded = default_expanded,
        hunks = {},
      })
    end

    table.sort(files, function(a, b)
      return a.path < b.path
    end)

    done(files)
  end)
end

return M
