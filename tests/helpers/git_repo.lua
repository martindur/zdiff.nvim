local M = {}

function M.run(repo, args)
  local argv = { "git", "-C", repo }
  vim.list_extend(argv, args)
  local out = vim.fn.system(argv)
  if vim.v.shell_error ~= 0 then
    error("git command failed: " .. table.concat(argv, " ") .. "\n" .. out)
  end
  return out
end

function M.write_file(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

function M.write_lines(path, lines)
  M.write_file(path, table.concat(lines, "\n") .. "\n")
end

function M.create(opts)
  opts = opts or {}

  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  M.run(repo, { "init" })

  if opts.config_user ~= false then
    M.run(repo, { "config", "user.name", "zdiff-test" })
    M.run(repo, { "config", "user.email", "zdiff@example.com" })
  end

  return repo
end

function M.commit_all(repo, message)
  M.run(repo, { "add", "--", "." })
  M.run(repo, { "commit", "-m", message })
end

function M.create_changed_file(filename, baseline, changed)
  local repo = M.create()
  M.write_file(repo .. "/" .. filename, baseline)
  M.commit_all(repo, "baseline")
  M.write_file(repo .. "/" .. filename, changed)
  return repo
end

function M.changed_files(repo, base_ref)
  local git = require("zdiff.git")
  local result = nil
  git.diff_files_async(repo, base_ref, function(res)
    result = res
  end)

  local ok = vim.wait(5000, function()
    return result ~= nil
  end, 50)
  assert.is_true(ok, "timed out waiting for git diff files")
  assert.is_true(result.ok, result.error)
  return result.data
end

function M.find_file(files, path)
  for _, file in ipairs(files) do
    if file.path == path then
      return file
    end
  end
  return nil
end

return M
