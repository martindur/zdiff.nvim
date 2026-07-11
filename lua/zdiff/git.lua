local M = {}

local function run(root, args)
  local argv = { "git", "-C", root }
  vim.list_extend(argv, args)
  local output = vim.fn.system(argv)
  if vim.v.shell_error ~= 0 then
    return nil, vim.trim(output)
  end
  return output
end

local function split_lines(output)
  if not output or output == "" then
    return {}
  end
  local parts = vim.split(output, "\n", { plain = true })
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

function M.uncommitted_changes(root)
  local statuses_output, err = run(root, { "diff", "--name-status", "HEAD" })
  if not statuses_output then
    return nil, err
  end
  local stats_output, stats_err = run(root, { "diff", "--numstat", "HEAD" })
  if not stats_output then
    return nil, stats_err
  end

  local stats = {}
  for _, record in ipairs(split_lines(stats_output)) do
    local additions, deletions, path = record:match("^([^\t]+)\t([^\t]+)\t(.+)$")
    if path then
      stats[path] = {
        additions = tonumber(additions) or 0,
        deletions = tonumber(deletions) or 0,
      }
    end
  end

  local files = {}
  for _, record in ipairs(split_lines(statuses_output)) do
    local fields = vim.split(record, "\t", { plain = true })
    local status = fields[1]:sub(1, 1)
    local path = fields[2]
    local old_path
    if status == "R" or status == "C" then
      old_path = path
      path = fields[3]
    end
    local counts = stats[path] or stats[old_path] or {}
    table.insert(files, {
      path = path,
      old_path = old_path,
      status = status,
      additions = counts.additions or 0,
      deletions = counts.deletions or 0,
    })
  end

  local untracked_output, untracked_err =
    run(root, { "ls-files", "--others", "--exclude-standard" })
  if not untracked_output then
    return nil, untracked_err
  end
  for _, path in ipairs(split_lines(untracked_output)) do
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
      old_line = nil,
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
