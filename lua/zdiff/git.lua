local M = {}

local function run(root, args)
  local argv = { "git", "-C", root }
  vim.list_extend(argv, args)

  if vim.system then
    local result = vim.system(argv, { text = false }):wait()
    if result.code ~= 0 then
      return nil, vim.trim(result.stderr or "")
    end
    return result.stdout or ""
  end

  local output = vim.fn.system(argv)
  if vim.v.shell_error ~= 0 then
    return nil, vim.trim(output)
  end
  -- system() represents NUL bytes as SOH; restore them for -z Git output.
  return output:gsub("\1", "\0")
end

local function split_nul(output)
  if not output or output == "" then
    return {}
  end
  local parts = vim.split(output, "\0", { plain = true })
  if parts[#parts] == "" then
    table.remove(parts)
  end
  return parts
end

function M.root()
  local output, err = run(vim.fn.getcwd(), { "rev-parse", "--show-toplevel" })
  if not output then
    return nil, err
  end
  return vim.trim(output)
end

local function has_head(root)
  local output = run(root, { "rev-parse", "--verify", "HEAD" })
  return output ~= nil
end

local function line_count(path)
  local file = io.open(path, "r")
  if not file then
    return 0
  end
  local count = 0
  for _ in file:lines() do
    count = count + 1
  end
  file:close()
  return count
end

local function rename_key(old_path, new_path)
  return old_path .. "\0" .. new_path
end

local function parse_stats(output)
  local stats = {}
  local parts = split_nul(output)
  local index = 1
  while index <= #parts do
    local additions, deletions, path = parts[index]:match("^([^\t]+)\t([^\t]+)\t(.*)$")
    index = index + 1
    if additions and deletions then
      local key = path
      if path == "" then
        local old_path, new_path = parts[index], parts[index + 1]
        index = index + 2
        if old_path and new_path then
          key = rename_key(old_path, new_path)
        end
      end
      if key and key ~= "" then
        stats[key] = {
          additions = tonumber(additions) or 0,
          deletions = tonumber(deletions) or 0,
        }
      end
    end
  end
  return stats
end

local function parse_statuses(output, stats)
  local files = {}
  local parts = split_nul(output)
  local index = 1
  while index <= #parts do
    local status = parts[index]:sub(1, 1)
    index = index + 1
    local old_path, path
    if status == "R" or status == "C" then
      old_path, path = parts[index], parts[index + 1]
      index = index + 2
    else
      path = parts[index]
      index = index + 1
    end
    if path then
      local key = old_path and rename_key(old_path, path) or path
      local counts = stats[key] or {}
      table.insert(files, {
        path = path,
        old_path = old_path,
        status = status,
        additions = counts.additions or 0,
        deletions = counts.deletions or 0,
      })
    end
  end
  return files
end

function M.uncommitted_changes(root)
  local files = {}
  if has_head(root) then
    local statuses_output, err = run(root, { "diff", "--name-status", "-z", "HEAD" })
    if not statuses_output then
      return nil, err
    end
    local stats_output, stats_err = run(root, { "diff", "--numstat", "-z", "HEAD" })
    if not stats_output then
      return nil, stats_err
    end
    files = parse_statuses(statuses_output, parse_stats(stats_output))
  end

  local untracked_output, untracked_err =
    run(root, { "ls-files", "--others", "--exclude-standard", "-z" })
  if not untracked_output then
    return nil, untracked_err
  end
  for _, path in ipairs(split_nul(untracked_output)) do
    table.insert(files, {
      path = path,
      status = "?",
      additions = line_count(root .. "/" .. path),
      deletions = 0,
    })
  end

  table.sort(files, function(left, right)
    return left.path < right.path
  end)
  return { root = root, files = files }
end

local function untracked_patch(root, path)
  local file = io.open(root .. "/" .. path, "r")
  if not file then
    return nil, "could not read " .. path
  end
  local lines = {}
  for line in file:lines() do
    table.insert(lines, {
      kind = "add",
      text = line,
      new_line = #lines + 1,
    })
  end
  file:close()
  return { { header = string.format("@@ -0,0 +1,%d @@", #lines), lines = lines } }
end

function M.patch(root, changed_file)
  if changed_file.status == "?" then
    return untracked_patch(root, changed_file.path)
  end
  local args = { "diff", "--unified=3", "HEAD", "--" }
  if changed_file.old_path then
    table.insert(args, changed_file.old_path)
  end
  table.insert(args, changed_file.path)
  local output, err = run(root, args)
  if not output then
    return nil, err
  end

  local hunks = {}
  local hunk
  local old_line, new_line
  for _, line in ipairs(vim.split(output, "\n", { plain = true })) do
    local old_start, new_start = line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
    if old_start then
      old_line, new_line = tonumber(old_start), tonumber(new_start)
      hunk = { header = line, lines = {} }
      table.insert(hunks, hunk)
    elseif hunk and line:sub(1, 1) ~= "\\" then
      local prefix = line:sub(1, 1)
      local entry = { text = line:sub(2) }
      if prefix == "+" then
        entry.kind, entry.new_line = "add", new_line
        new_line = new_line + 1
      elseif prefix == "-" then
        entry.kind, entry.old_line = "delete", old_line
        old_line = old_line + 1
      elseif prefix == " " then
        entry.kind, entry.old_line, entry.new_line = "context", old_line, new_line
        old_line, new_line = old_line + 1, new_line + 1
      end
      if entry.kind then
        table.insert(hunk.lines, entry)
      end
    end
  end
  return hunks
end

return M
