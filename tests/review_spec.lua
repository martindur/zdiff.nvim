local review = require("zdiff.review")
local patch = require("zdiff.patch")

local function run_git(repo, args)
  local argv = { "git", "-C", repo }
  vim.list_extend(argv, args)
  local out = vim.fn.system(argv)
  if vim.v.shell_error ~= 0 then
    error("git command failed: " .. table.concat(argv, " ") .. "\n" .. out)
  end
  return out
end

local function create_repo()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  run_git(repo, { "init" })
  return repo
end

local function wait_for_loaded()
  local ok = vim.wait(1000, function()
    return not review._debug_state().loading
  end, 20)
  assert.is_true(ok, "timed out waiting for review PRs to load")
end

local function get_normal_keymap(buf, lhs)
  for _, km in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if km.lhs == lhs then
      return km
    end
  end
  return nil
end

local function find_line(text)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for i, line in ipairs(lines) do
    if line:find(text, 1, true) then
      return i
    end
  end
  return nil
end

describe("zdiff.review", function()
  local plugin_root

  before_each(function()
    plugin_root = vim.fn.getcwd()
    pcall(vim.api.nvim_del_user_command, "ZdiffReview")
    vim.cmd("cd " .. vim.fn.fnameescape(create_repo()))
  end)

  after_each(function()
    review.close()
    review._set_backend(nil)
    pcall(vim.api.nvim_del_user_command, "ZdiffReview")
    vim.cmd("cd " .. vim.fn.fnameescape(plugin_root))
  end)

  it("registers the review command from setup", function()
    local commands = vim.api.nvim_get_commands({ builtin = false })
    assert.is_nil(commands.ZdiffReview)

    review.setup()

    commands = vim.api.nvim_get_commands({ builtin = false })
    assert.is_not_nil(commands.ZdiffReview)
  end)

  it("renders pull requests from the backend", function()
    review._set_backend({
      list_prs = function(_, done)
        done({
          ok = true,
          data = {
            {
              number = 12,
              title = "Add review browser",
              author = "dur",
              additions = 10,
              deletions = 2,
              review_decision = "",
              is_draft = false,
            },
          },
        })
      end,
    })

    review.open()
    wait_for_loaded()

    local buf = vim.api.nvim_get_current_buf()
    local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")

    assert.equals("zdiffreview", vim.bo[buf].filetype)
    assert.equals("nofile", vim.bo[buf].buftype)
    assert.is_false(vim.bo[buf].modifiable)
    assert.is_truthy(content:find("#12 Add review browser", 1, true))
    assert.is_truthy(content:find("@dur", 1, true))
    assert.is_truthy(content:find("+10 -2", 1, true))
  end)

  it("renders backend errors", function()
    review._set_backend({
      list_prs = function(_, done)
        done({ ok = false, error = "gh not found" })
      end,
    })

    review.open()
    wait_for_loaded()

    local content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.is_truthy(content:find("Error loading pull requests: gh not found", 1, true))
  end)

  it("opens a selected pull request diff", function()
    review._set_backend({
      list_prs = function(_, done)
        done({
          ok = true,
          data = {
            {
              number = 12,
              title = "Add review browser",
              author = "dur",
              additions = 1,
              deletions = 1,
              review_decision = "",
              is_draft = false,
            },
          },
        })
      end,
      diff_pr = function(_, number, done)
        assert.equals(12, number)
        done({
          ok = true,
          data = patch.parse({
            "diff --git a/a.txt b/a.txt",
            "--- a/a.txt",
            "+++ b/a.txt",
            "@@ -1,2 +1,2 @@",
            " same",
            "-old",
            "+new",
          }),
        })
      end,
    })

    review.open()
    wait_for_loaded()

    local open_keymap = get_normal_keymap(vim.api.nvim_get_current_buf(), "<CR>")
    assert.is_not_nil(open_keymap)
    vim.api.nvim_win_set_cursor(0, { assert(find_line("#12")), 0 })
    open_keymap.callback()
    wait_for_loaded()

    local content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.equals("diff", review._debug_state().view)
    assert.equals(1, review._debug_state().file_count)
    assert.is_truthy(content:find("PR #12 Add review browser", 1, true))
    assert.is_truthy(content:find("a.txt", 1, true))
    assert.is_truthy(content:find("-old", 1, true))
    assert.is_truthy(content:find("+new", 1, true))
  end)

  it("adds a local draft comment on a diff line", function()
    review._set_backend({
      list_prs = function(_, done)
        done({
          ok = true,
          data = {
            {
              number = 12,
              title = "Add review browser",
              author = "dur",
              additions = 1,
              deletions = 1,
              review_decision = "",
              is_draft = false,
            },
          },
        })
      end,
      diff_pr = function(_, _, done)
        done({
          ok = true,
          data = patch.parse({
            "diff --git a/a.txt b/a.txt",
            "--- a/a.txt",
            "+++ b/a.txt",
            "@@ -1,2 +1,2 @@",
            " same",
            "-old",
            "+new",
          }),
        })
      end,
    })

    review.open()
    wait_for_loaded()
    vim.api.nvim_win_set_cursor(0, { assert(find_line("#12")), 0 })
    get_normal_keymap(vim.api.nvim_get_current_buf(), "<CR>").callback()
    wait_for_loaded()

    local old_input = vim.ui.input
    vim.ui.input = function(opts, on_confirm)
      assert.equals("Comment: ", opts.prompt)
      assert.equals("", opts.default)
      on_confirm("Needs follow-up")
    end

    local ok, err = pcall(function()
      vim.api.nvim_win_set_cursor(0, { assert(find_line("+new")), 0 })
      get_normal_keymap(vim.api.nvim_get_current_buf(), "c").callback()
    end)
    vim.ui.input = old_input

    assert.is_true(ok, err)
    local content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.equals(1, review._debug_state().draft_count)
    assert.is_truthy(content:find("# Needs follow-up", 1, true))
  end)

  it("submits draft comments through the backend", function()
    local submitted = nil
    review._set_backend({
      list_prs = function(_, done)
        done({
          ok = true,
          data = {
            {
              number = 12,
              title = "Add review browser",
              author = "dur",
              additions = 1,
              deletions = 1,
              review_decision = "",
              is_draft = false,
            },
          },
        })
      end,
      diff_pr = function(_, _, done)
        done({
          ok = true,
          data = patch.parse({
            "diff --git a/a.txt b/a.txt",
            "--- a/a.txt",
            "+++ b/a.txt",
            "@@ -1,2 +1,2 @@",
            " same",
            "-old",
            "+new",
          }),
        })
      end,
      submit_review = function(_, number, payload, done)
        submitted = { number = number, payload = payload }
        done({ ok = true })
      end,
    })

    review.open()
    wait_for_loaded()
    vim.api.nvim_win_set_cursor(0, { assert(find_line("#12")), 0 })
    get_normal_keymap(vim.api.nvim_get_current_buf(), "<CR>").callback()
    wait_for_loaded()

    local old_input = vim.ui.input
    vim.ui.input = function(_, on_confirm)
      on_confirm("Needs follow-up")
    end

    local ok, err = pcall(function()
      vim.api.nvim_win_set_cursor(0, { assert(find_line("+new")), 0 })
      get_normal_keymap(vim.api.nvim_get_current_buf(), "c").callback()
      get_normal_keymap(vim.api.nvim_get_current_buf(), "S").callback()
    end)
    vim.ui.input = old_input

    assert.is_true(ok, err)
    assert.equals(12, submitted.number)
    assert.equals("COMMENT", submitted.payload.event)
    assert.equals("", submitted.payload.body)
    assert.equals(1, #submitted.payload.comments)
    assert.equals("a.txt", submitted.payload.comments[1].path)
    assert.equals("RIGHT", submitted.payload.comments[1].side)
    assert.equals(2, submitted.payload.comments[1].line)
    assert.equals("Needs follow-up", submitted.payload.comments[1].body)
    assert.equals(0, review._debug_state().draft_count)
  end)
end)
