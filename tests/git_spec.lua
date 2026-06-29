local git = require("zdiff.git")

local function run_git(repo, args)
  local argv = { "git", "-C", repo }
  vim.list_extend(argv, args)
  local out = vim.fn.system(argv)
  if vim.v.shell_error ~= 0 then
    error("git command failed: " .. table.concat(argv, " ") .. "\n" .. out)
  end
  return out
end

local function write_file(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

local function create_repo()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  run_git(repo, { "init" })
  run_git(repo, { "config", "user.name", "zdiff-test" })
  run_git(repo, { "config", "user.email", "zdiff@example.com" })
  return repo
end

local function commit_all(repo, message)
  run_git(repo, { "add", "--", "." })
  run_git(repo, { "commit", "-m", message })
end

local function diff_files(repo, base_ref)
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

local function file_diff_lines(repo, base_ref, file)
  local result = git.file_diff_lines(repo, base_ref, file)
  assert.is_true(result.ok, result.error)
  return table.concat(result.data, "\n")
end

local function find_file(files, path)
  for _, file in ipairs(files) do
    if file.path == path then
      return file
    end
  end
  return nil
end

describe("git adapter", function()
  it("returns git stderr for failed line commands", function()
    local repo = create_repo()
    local result = git.run_lines(repo, { "rev-parse", "--verify", "missing-ref" })

    assert.is_false(result.ok)
    assert.is_truthy(result.error:find("Needed a single revision", 1, true))
  end)

  it("reports invalid refs", function()
    local repo = create_repo()
    local result = git.ref_exists(repo, "missing-ref")

    assert.is_false(result.ok)
    assert.is_truthy(result.error)
  end)

  it("lists staged files before the first commit", function()
    local repo = create_repo()
    write_file(repo .. "/new.txt", "one\n")
    run_git(repo, { "add", "--", "new.txt" })

    local file = find_file(diff_files(repo), "new.txt")
    assert.is_not_nil(file)
    assert.equals("A", file.status)
    assert.equals(1, file.insertions)
    assert.equals(0, file.deletions)
  end)

  it("lists staged-only changes after a commit", function()
    local repo = create_repo()
    write_file(repo .. "/tracked.txt", "one\n")
    commit_all(repo, "baseline")
    write_file(repo .. "/tracked.txt", "two\n")
    run_git(repo, { "add", "--", "tracked.txt" })

    local file = find_file(diff_files(repo), "tracked.txt")
    assert.is_not_nil(file)
    assert.equals("M", file.status)
    assert.equals(1, file.insertions)
    assert.equals(1, file.deletions)
  end)

  it("loads only the selected added file diff against a base ref", function()
    local repo = create_repo()
    write_file(repo .. "/baseline.txt", "baseline\n")
    commit_all(repo, "baseline")
    run_git(repo, { "branch", "-M", "main" })
    run_git(repo, { "checkout", "-b", "feature" })
    write_file(repo .. "/added-one.txt", "one\n")
    write_file(repo .. "/added-two.txt", "two\n")
    commit_all(repo, "add files")

    local files = diff_files(repo, "main")
    local file = find_file(files, "added-one.txt")
    assert.is_not_nil(file)

    local content = file_diff_lines(repo, "main", file)
    assert.is_truthy(content:find("added%-one%.txt"))
    assert.is_truthy(content:find("+one", 1, true))
    assert.is_nil(content:find("added-two.txt", 1, true))
    assert.is_nil(content:find("+two", 1, true))
  end)

  it("loads only the selected staged added file diff", function()
    local repo = create_repo()
    write_file(repo .. "/baseline.txt", "baseline\n")
    commit_all(repo, "baseline")
    write_file(repo .. "/added-one.txt", "one\n")
    write_file(repo .. "/added-two.txt", "two\n")
    run_git(repo, { "add", "--", "added-one.txt", "added-two.txt" })

    local files = diff_files(repo)
    local file = find_file(files, "added-one.txt")
    assert.is_not_nil(file)

    local content = file_diff_lines(repo, nil, file)
    assert.is_truthy(content:find("added%-one%.txt"))
    assert.is_truthy(content:find("+one", 1, true))
    assert.is_nil(content:find("added-two.txt", 1, true))
    assert.is_nil(content:find("+two", 1, true))
  end)

  it("parses NUL-delimited paths without Git quote escaping", function()
    local repo = create_repo()
    local path = "tabs\tand\ncafé.txt"
    write_file(repo .. "/" .. path, "one\n")
    commit_all(repo, "baseline")
    write_file(repo .. "/" .. path, "two\n")

    local file = find_file(diff_files(repo), path)
    assert.is_not_nil(file)
    assert.equals("M", file.status)
    assert.equals(path, file.path)
    assert.equals(path, file.display_path)
    assert.equals(path, file.old_path)
    assert.equals(path, file.new_path)
    assert.equals(1, file.insertions)
    assert.equals(1, file.deletions)
  end)

  it("keeps old paths for deleted files", function()
    local repo = create_repo()
    write_file(repo .. "/deleted.txt", "gone\n")
    commit_all(repo, "baseline")
    run_git(repo, { "rm", "--", "deleted.txt" })

    local file = find_file(diff_files(repo), "deleted.txt")
    assert.is_not_nil(file)
    assert.equals("D", file.status)
    assert.equals("deleted.txt", file.path)
    assert.equals("deleted.txt", file.old_path)
    assert.is_nil(file.new_path)
    assert.equals(0, file.insertions)
    assert.equals(1, file.deletions)
  end)

  it("keeps old and new paths for pure renames", function()
    local repo = create_repo()
    write_file(repo .. "/old name.txt", "same\n")
    commit_all(repo, "baseline")
    run_git(repo, { "mv", "old name.txt", "new name.txt" })

    local file = find_file(diff_files(repo), "new name.txt")
    assert.is_not_nil(file)
    assert.equals("R", file.status)
    assert.equals("new name.txt", file.path)
    assert.equals("old name.txt", file.old_path)
    assert.equals("new name.txt", file.new_path)
    assert.equals("old name.txt -> new name.txt", file.display_path)
    assert.equals(0, file.insertions)
    assert.equals(0, file.deletions)
  end)
end)
