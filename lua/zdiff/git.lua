local M = {}

---@class ZdiffGitResult
---@field ok boolean
---@field stdout string
---@field error string|nil

---@class ZdiffGitFile
---@field path string current path, or old path for deleted files
---@field display_path string path shown in the UI
---@field old_path string|nil path on the old side of the diff
---@field new_path string|nil path on the new side of the diff
---@field status string git status code
---@field insertions number
---@field deletions number

---@param root string
---@param args string[]
---@return string[]
local function git_argv(root, args)
  local argv = { "git", "-C", root }
  vim.list_extend(argv, args)
  return argv
end

---@param data string[]|nil
---@return string
local function join_job_data(data)
  if not data then
    return ""
  end
  return table.concat(data, "\n")
end

---@param argv string[]
---@param code integer
---@param stdout string|nil
---@param stderr string|nil
---@return ZdiffGitResult
local function build_result(argv, code, stdout, stderr)
  stdout = stdout or ""
  stderr = stderr or ""
  local ok = code == 0
  local err = nil
  if not ok then
    err = vim.trim(stderr)
    if err == "" then
      err = "git command failed: " .. table.concat(argv, " ")
    end
  end
  return {
    ok = ok,
    stdout = stdout,
    error = err,
  }
end

---@param root string
---@param args string[]
---@return {ok: boolean, data?: string[], error?: string}
function M.run_lines(root, args)
  local argv = git_argv(root, args)
  local lines = vim.fn.systemlist(argv)
  local output = table.concat(lines, "\n")
  local result = build_result(argv, vim.v.shell_error, output, output)
  if not result.ok then
    return { ok = false, error = result.error }
  end
  return { ok = true, data = lines }
end

---@param root string
---@param args string[]
---@param callback fun(result: ZdiffGitResult)
function M.run_async(root, args, callback)
  local argv = git_argv(root, args)
  if vim.system then
    vim.system(argv, { text = true }, function(obj)
      vim.schedule(function()
        callback(build_result(argv, obj.code or 1, obj.stdout, obj.stderr))
      end)
    end)
    return
  end

  local stdout = ""
  local stderr = ""
  local job_id = vim.fn.jobstart(argv, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      stdout = join_job_data(data)
    end,
    on_stderr = function(_, data)
      stderr = join_job_data(data)
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        callback(build_result(argv, code or 1, stdout, stderr))
      end)
    end,
  })

  if job_id <= 0 then
    vim.schedule(function()
      callback(build_result(argv, 1, "", "failed to start git command"))
    end)
  end
end

---@return {ok: boolean, data?: string, error?: string}
function M.root()
  local argv = { "git", "-C", vim.fn.getcwd(), "rev-parse", "--show-toplevel" }
  local stdout = vim.fn.system(argv)
  local result = build_result(argv, vim.v.shell_error, stdout, "")
  if not result.ok then
    return { ok = false, error = result.error or "not in a git repository" }
  end

  local root = vim.trim(result.stdout)
  if root == "" then
    return { ok = false, error = "not in a git repository" }
  end
  return { ok = true, data = root }
end

---@param root string
---@param ref string
---@return {ok: boolean, error?: string}
function M.ref_exists(root, ref)
  local result = M.run_lines(root, { "rev-parse", "--verify", ref })
  if result.ok then
    return { ok = true }
  end
  return { ok = false, error = result.error or ("invalid git ref: " .. ref) }
end

---@param root string
---@return boolean
local function has_head(root)
  return M.run_lines(root, { "rev-parse", "--verify", "HEAD" }).ok
end

---@param text string
---@return string[]
local function split_nul(text)
  if text == "" then
    return {}
  end

  local parts = vim.split(text, "\0", { plain = true })
  if #parts > 0 and parts[#parts] == "" then
    table.remove(parts, #parts)
  end
  return parts
end

---@param old_path string
---@param new_path string
---@return string
local function rename_key(old_path, new_path)
  return old_path .. "\0" .. new_path
end

---@param status string
---@param path string|nil
---@param old_path string|nil
---@param new_path string|nil
---@param insertions number
---@param deletions number
---@return ZdiffGitFile
local function build_file(status, path, old_path, new_path, insertions, deletions)
  status = status:sub(1, 1)

  if status == "A" or status == "?" then
    old_path = nil
    new_path = new_path or path
  elseif status == "D" then
    old_path = old_path or path
    new_path = nil
  elseif status ~= "R" and status ~= "C" then
    old_path = old_path or path
    new_path = new_path or path
  end

  local current_path = new_path or old_path or path or ""
  local display_path = current_path
  if
    old_path
    and new_path
    and old_path ~= new_path
    and (status == "R" or status == "C")
  then
    display_path = old_path .. " -> " .. new_path
  end

  return {
    path = current_path,
    display_path = display_path,
    old_path = old_path,
    new_path = new_path,
    status = status,
    insertions = insertions,
    deletions = deletions,
  }
end

---@param stdout string
---@return table<string, {insertions: number, deletions: number, path: string|nil, old_path: string|nil, new_path: string|nil}>
local function parse_numstat_z(stdout)
  local records = {}
  local parts = split_nul(stdout)
  local i = 1

  while i <= #parts do
    local record = parts[i]
    i = i + 1

    local ins, del, path = record:match("^([^\t]+)\t([^\t]+)\t(.*)$")
    if ins and del and path then
      local old_path = nil
      local new_path = nil
      local key = path

      if path == "" then
        old_path = parts[i]
        new_path = parts[i + 1]
        i = i + 2
        if old_path and new_path then
          key = rename_key(old_path, new_path)
        end
      end

      records[key] = {
        insertions = tonumber(ins) or 0,
        deletions = tonumber(del) or 0,
        path = path ~= "" and path or nil,
        old_path = old_path,
        new_path = new_path,
      }
    end
  end

  return records
end

---@param stdout string
---@return table<string, {status: string, path: string|nil, old_path: string|nil, new_path: string|nil}>
local function parse_name_status_z(stdout)
  local records = {}
  local parts = split_nul(stdout)
  local i = 1

  while i <= #parts do
    local status = parts[i]
    i = i + 1

    if status and status ~= "" then
      local kind = status:sub(1, 1)
      if kind == "R" or kind == "C" then
        local old_path = parts[i]
        local new_path = parts[i + 1]
        i = i + 2
        if old_path and new_path then
          records[rename_key(old_path, new_path)] = {
            status = kind,
            old_path = old_path,
            new_path = new_path,
          }
        end
      else
        local path = parts[i]
        i = i + 1
        if path then
          records[path] = {
            status = kind,
            path = path,
          }
        end
      end
    end
  end

  return records
end

---@param root string
---@param base_ref string|nil
---@return string[]
local function diff_target(root, base_ref)
  if base_ref then
    return { base_ref .. "...HEAD" }
  end
  if has_head(root) then
    return { "HEAD" }
  end
  return { "--cached" }
end

---@param root string
---@param rel_path string
---@return {ok: boolean, data?: number, error?: string}
function M.count_worktree_lines(root, rel_path)
  local filepath = root .. "/" .. rel_path
  local file = io.open(filepath, "r")
  if not file then
    return { ok = false, error = "could not read " .. rel_path }
  end

  local line_count = 0
  for _ in file:lines() do
    line_count = line_count + 1
  end
  file:close()
  return { ok = true, data = line_count }
end

---@param root string
---@param rel_path string
---@return {ok: boolean, data?: string[], error?: string}
function M.read_worktree_lines(root, rel_path)
  local filepath = root .. "/" .. rel_path
  local file = io.open(filepath, "r")
  if not file then
    return { ok = false, error = "could not read " .. rel_path }
  end

  local lines = {}
  for line in file:lines() do
    table.insert(lines, line)
  end
  file:close()
  return { ok = true, data = lines }
end

---@param text string
---@param preserve_empty_lines? boolean
---@return string[]
function M.split_lines(text, preserve_empty_lines)
  if text == "" then
    return {}
  end

  local lines = vim.split(text, "\n", { plain = true })
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines, #lines)
  end

  if preserve_empty_lines then
    return lines
  end

  local filtered = {}
  for _, line in ipairs(lines) do
    if line ~= "" then
      table.insert(filtered, line)
    end
  end
  return filtered
end

---@param root string
---@param rev string
---@param rel_path string
---@param done fun(result: {ok: boolean, data?: string[], error?: string})
function M.read_git_file_lines_async(root, rev, rel_path, done)
  M.run_async(root, { "show", rev .. ":" .. rel_path }, function(result)
    if not result.ok then
      done({ ok = false, error = result.error })
      return
    end
    done({ ok = true, data = M.split_lines(result.stdout, true) })
  end)
end

---@param root string
---@param base_ref string|nil
---@param file ZdiffGitFile
---@return string[]
local function file_diff_args(root, base_ref, file)
  local args = { "diff" }
  vim.list_extend(args, diff_target(root, base_ref))
  table.insert(args, "--")
  local seen = {}
  local function append_path(path)
    if path and path ~= "" and not seen[path] then
      table.insert(args, path)
      seen[path] = true
    end
  end

  append_path(file.old_path)
  append_path(file.new_path)
  append_path(file.path)

  return args
end

---@param root string
---@param base_ref string|nil
---@param file ZdiffGitFile
---@return {ok: boolean, data?: string[], error?: string}
function M.file_diff_lines(root, base_ref, file)
  return M.run_lines(root, file_diff_args(root, base_ref, file))
end

---@param root string
---@param base_ref string|nil
---@param file ZdiffGitFile
---@param done fun(result: {ok: boolean, data?: string[], error?: string})
function M.file_diff_lines_async(root, base_ref, file, done)
  M.run_async(root, file_diff_args(root, base_ref, file), function(result)
    if not result.ok then
      done({ ok = false, error = result.error })
      return
    end
    done({ ok = true, data = M.split_lines(result.stdout) })
  end)
end

---@param root string
---@param base_ref string|nil
---@param done fun(result: {ok: boolean, data?: ZdiffGitFile[], error?: string})
function M.diff_files_async(root, base_ref, done)
  local target = diff_target(root, base_ref)
  local numstat_args = { "diff", "-z", "--numstat" }
  vim.list_extend(numstat_args, target)

  M.run_async(root, numstat_args, function(numstat_result)
    if not numstat_result.ok then
      done({ ok = false, error = numstat_result.error })
      return
    end

    local status_args = { "diff", "-z", "--name-status" }
    vim.list_extend(status_args, target)

    M.run_async(root, status_args, function(status_result)
      if not status_result.ok then
        done({ ok = false, error = status_result.error })
        return
      end

      local stats = parse_numstat_z(numstat_result.stdout)
      local statuses = parse_name_status_z(status_result.stdout)
      local files = {}
      local used_stats = {}

      for key, entry in pairs(statuses) do
        local stat = stats[key] or {}
        used_stats[key] = true
        table.insert(
          files,
          build_file(
            entry.status,
            entry.path or stat.path,
            entry.old_path or stat.old_path,
            entry.new_path or stat.new_path,
            stat.insertions or 0,
            stat.deletions or 0
          )
        )
      end

      for key, stat in pairs(stats) do
        if not used_stats[key] then
          table.insert(
            files,
            build_file(
              "M",
              stat.path,
              stat.old_path,
              stat.new_path,
              stat.insertions,
              stat.deletions
            )
          )
        end
      end

      if base_ref then
        done({ ok = true, data = files })
        return
      end

      M.run_async(
        root,
        { "ls-files", "-z", "--others", "--exclude-standard" },
        function(untracked_result)
          if not untracked_result.ok then
            done({ ok = false, error = untracked_result.error })
            return
          end

          local existing = {}
          for _, file in ipairs(files) do
            existing[file.path] = true
          end

          for _, path in ipairs(split_nul(untracked_result.stdout)) do
            if path ~= "" and not existing[path] then
              local count = M.count_worktree_lines(root, path)
              table.insert(
                files,
                build_file("?", path, nil, path, count.ok and count.data or 0, 0)
              )
            end
          end

          done({ ok = true, data = files })
        end
      )
    end)
  end)
end

return M
