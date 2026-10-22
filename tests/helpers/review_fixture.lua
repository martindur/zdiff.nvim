local M = {}

local fixtures = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
  .. "/fixtures/review"

local function git(repo, args)
  local argv = { "git", "-C", repo }
  vim.list_extend(argv, args)
  local output = vim.fn.system(argv)
  assert(vim.v.shell_error == 0, output)
end

local function files(directory)
  local paths = {}
  for _, path in ipairs(vim.fn.globpath(directory, "**/*", false, true)) do
    if vim.fn.filereadable(path) == 1 then
      table.insert(paths, path:sub(#directory + 2))
    end
  end
  return paths
end

local function copy(source, target)
  vim.fn.mkdir(vim.fn.fnamemodify(target, ":h"), "p")
  assert((vim.uv or vim.loop).fs_copyfile(source, target))
end

function M.create_repo()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  git(repo, { "init", "-q", "-b", "main" })
  git(repo, { "config", "diff.renames", "true" })

  local before, after = fixtures .. "/before", fixtures .. "/after"
  for _, path in ipairs(files(before)) do
    copy(before .. "/" .. path, repo .. "/" .. path)
  end
  git(repo, { "add", "." })
  git(repo, {
    "-c",
    "user.name=zdiff",
    "-c",
    "user.email=zdiff@example.com",
    "-c",
    "commit.gpgsign=false",
    "-c",
    "core.hooksPath=/dev/null",
    "commit",
    "-qm",
    "Add project locations",
  })

  for _, path in ipairs(files(before)) do
    if vim.fn.filereadable(after .. "/" .. path) == 0 then
      assert(vim.fn.delete(repo .. "/" .. path) == 0)
    end
  end
  for _, path in ipairs(files(after)) do
    copy(after .. "/" .. path, repo .. "/" .. path)
  end
  git(
    repo,
    { "add", "--", "doc/locations.txt", "doc/waypoint.txt", "lua/waypoint/storage.lua" }
  )
  return repo
end

return M
