local git = require("zdiff.git")

local function run_git(repo, args)
  local argv = { "git", "-C", repo }
  vim.list_extend(argv, args)
  local result = vim.system(argv, { text = true }):wait()
  assert.equals(0, result.code, result.stderr)
end

local function write(path, contents)
  local file = assert(io.open(path, "w"))
  file:write(contents)
  file:close()
end

local function repository()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  run_git(repo, { "init", "-q" })
  run_git(repo, { "config", "user.name", "zdiff" })
  run_git(repo, { "config", "user.email", "zdiff@example.com" })
  return repo
end

local function commit(repo, files)
  for path, contents in pairs(files) do
    write(repo .. "/" .. path, contents)
  end
  run_git(repo, { "add", "." })
  run_git(repo, { "commit", "-qm", "fixture" })
end

describe("zdiff git", function()
  it("lists untracked files before the first commit", function()
    local repo = repository()
    write(repo .. "/new file.txt", "one\ntwo\n")
    local changes = assert(git.uncommitted_changes(repo))
    assert.same({
      path = "new file.txt",
      status = "?",
      additions = 2,
      deletions = 0,
    }, changes.files[1])
  end)

  it("combines staged and unstaged changes", function()
    local repo = repository()
    commit(repo, { ["staged.txt"] = "old\n", ["unstaged.txt"] = "old\n" })
    write(repo .. "/staged.txt", "new\n")
    run_git(repo, { "add", "staged.txt" })
    write(repo .. "/unstaged.txt", "new\n")
    local changes = assert(git.uncommitted_changes(repo))
    assert.equals(2, #changes.files)
    assert.same({ additions = 1, deletions = 1 }, {
      additions = changes.files[1].additions,
      deletions = changes.files[1].deletions,
    })
    assert.same({ additions = 1, deletions = 1 }, {
      additions = changes.files[2].additions,
      deletions = changes.files[2].deletions,
    })
  end)

  it("preserves rename and deletion status", function()
    local repo = repository()
    commit(repo, { ["delete.txt"] = "gone\n", ["old name.txt"] = "same\n" })
    run_git(repo, { "mv", "old name.txt", "new name.txt" })
    run_git(repo, { "rm", "delete.txt" })
    local changes = assert(git.uncommitted_changes(repo))
    assert.same({
      path = "delete.txt",
      status = "D",
      additions = 0,
      deletions = 1,
    }, changes.files[1])
    assert.same({
      path = "new name.txt",
      old_path = "old name.txt",
      status = "R",
      additions = 0,
      deletions = 0,
    }, changes.files[2])
  end)

  it("preserves unusual filenames", function()
    local repo = repository()
    local names = { "space name.txt", "tab\tname.txt", "line\nbreak.txt" }
    local initial = {}
    for _, name in ipairs(names) do
      initial[name] = "old\n"
    end
    commit(repo, initial)
    for _, name in ipairs(names) do
      write(repo .. "/" .. name, "new\n")
    end
    local changes = assert(git.uncommitted_changes(repo))
    local actual = {}
    for _, file in ipairs(changes.files) do
      table.insert(actual, file.path)
    end
    table.sort(names)
    assert.same(names, actual)
  end)
end)
