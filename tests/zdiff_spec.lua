local zdiff = require("zdiff")

local function run_git(repo, args)
  local argv = { "git", "-C", repo }
  vim.list_extend(argv, args)
  local output = vim.fn.system(argv)
  assert.equals(0, vim.v.shell_error, output)
end

local function write(path, contents)
  local file = assert(io.open(path, "w"))
  file:write(contents)
  file:close()
end

local function fixture()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  run_git(repo, { "init", "-q" })
  run_git(repo, { "config", "user.name", "zdiff" })
  run_git(repo, { "config", "user.email", "zdiff@example.com" })
  write(repo .. "/one.txt", "one\ntwo\nthree\n")
  run_git(repo, { "add", "one.txt" })
  run_git(repo, { "commit", "-qm", "initial" })
  write(repo .. "/one.txt", "one\nchanged\nthree\n")
  return repo
end

describe("zdiff", function()
  local original_directory

  before_each(function()
    original_directory = vim.fn.getcwd()
  end)

  after_each(function()
    vim.cmd("cd " .. vim.fn.fnameescape(original_directory))
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buffer) then
        local name = vim.api.nvim_buf_get_name(buffer)
        if name:find("zdiff", 1, true) or name:find("one.txt", 1, true) then
          pcall(vim.api.nvim_buf_delete, buffer, { force = true })
        end
      end
    end
  end)

  it("opens, expands, and returns from source through the jumplist", function()
    local repo = fixture()
    vim.cmd("cd " .. vim.fn.fnameescape(repo))
    zdiff.open()
    local diff_buf = vim.api.nvim_get_current_buf()
    assert.same({
      path = "one.txt",
      status = "M",
      additions = 1,
      deletions = 1,
    }, zdiff._state.model.files[1])
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    zdiff.toggle()

    local lines = vim.api.nvim_buf_get_lines(diff_buf, 0, -1, false)
    local changed_line
    for line, text in ipairs(lines) do
      if text == "changed" then
        changed_line = line
      end
    end
    assert.is_not_nil(changed_line)
    vim.api.nvim_win_set_cursor(0, { changed_line, 0 })
    assert.same({
      file_index = 1,
      path = "one.txt",
      line = 2,
      deleted = false,
    }, zdiff._state.rendered.sources[changed_line])
    zdiff.open_source()
    assert.equals(repo .. "/one.txt", vim.api.nvim_buf_get_name(0))
    assert.equals(2, vim.api.nvim_win_get_cursor(0)[1])

    vim.cmd("normal! \15")
    assert.equals(diff_buf, vim.api.nvim_get_current_buf())
    assert.equals(changed_line, vim.api.nvim_win_get_cursor(0)[1])

    local ctrl_i = vim.api.nvim_replace_termcodes("<C-I>", true, false, true)
    vim.api.nvim_feedkeys(ctrl_i, "x", false)
    assert.equals(repo .. "/one.txt", vim.api.nvim_buf_get_name(0))
    assert.equals(2, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("reuses its buffer and ignores buffer actions from source files", function()
    local repo = fixture()
    vim.cmd("cd " .. vim.fn.fnameescape(repo))
    zdiff.open()
    local diff_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    zdiff.toggle()
    local header
    for line, text in ipairs(vim.api.nvim_buf_get_lines(diff_buf, 0, -1, false)) do
      if text:find("@@", 1, true) then
        header = line
      end
    end
    assert.is_not_nil(header)
    vim.api.nvim_win_set_cursor(0, { header, 0 })
    zdiff.toggle()
    assert.is_false(zdiff._state.model.files[1].expanded)
    zdiff.toggle()
    assert.is_true(zdiff._state.model.files[1].expanded)

    local changed_line
    for line, text in ipairs(vim.api.nvim_buf_get_lines(diff_buf, 0, -1, false)) do
      if text == "changed" then
        changed_line = line
      end
    end
    vim.api.nvim_win_set_cursor(0, { changed_line, 0 })
    zdiff.open_source()
    zdiff.toggle()
    assert.is_true(zdiff._state.model.files[1].expanded)

    zdiff.open()
    assert.equals(diff_buf, vim.api.nvim_get_current_buf())
  end)

  it("restores a source location after refresh changes surrounding rows", function()
    local repo = fixture()
    vim.cmd("cd " .. vim.fn.fnameescape(repo))
    zdiff.open()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    zdiff.toggle()
    local function find_changed()
      for line, text in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
        if text == "changed" then
          return line
        end
      end
    end
    vim.api.nvim_win_set_cursor(0, { find_changed(), 0 })
    write(repo .. "/before.txt", "new\n")
    zdiff.refresh()
    assert.equals("changed", vim.api.nvim_get_current_line())
  end)
end)
