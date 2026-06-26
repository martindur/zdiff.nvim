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

local function contains_arg(argv, value)
  for _, arg in ipairs(argv) do
    if arg == value then
      return true
    end
  end
  return false
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

  it("posts the current line draft comment through the backend", function()
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
      submit_comment = function(_, number, comment, done)
        submitted = { number = number, comment = comment }
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
      get_normal_keymap(vim.api.nvim_get_current_buf(), "p").callback()
    end)
    vim.ui.input = old_input

    assert.is_true(ok, err)
    assert.equals(12, submitted.number)
    assert.equals("a.txt", submitted.comment.path)
    assert.equals("RIGHT", submitted.comment.side)
    assert.equals(2, submitted.comment.line)
    assert.equals("Needs follow-up", submitted.comment.body)
    assert.equals(0, review._debug_state().draft_count)
  end)

  it("shows posting state and blocks duplicate posts", function()
    local calls = 0
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
      submit_comment = function()
        calls = calls + 1
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
      get_normal_keymap(vim.api.nvim_get_current_buf(), "p").callback()
      get_normal_keymap(vim.api.nvim_get_current_buf(), "p").callback()
    end)
    vim.ui.input = old_input

    assert.is_true(ok, err)
    assert.equals(1, calls)
    assert.equals(1, review._debug_state().posting_count)
    local content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.is_truthy(content:find("# Posting...", 1, true))
  end)

  it("loads posted comments through the backend", function()
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
      list_comments = function(_, _, done)
        done({
          ok = true,
          data = {
            {
              path = "a.txt",
              side = "RIGHT",
              line = 2,
              body = "Already posted",
              author = "dur",
            },
          },
        })
      end,
    })

    review.open()
    wait_for_loaded()
    vim.api.nvim_win_set_cursor(0, { assert(find_line("#12")), 0 })
    get_normal_keymap(vim.api.nvim_get_current_buf(), "<CR>").callback()

    assert.is_true(vim.wait(1000, function()
      return review._debug_state().comment_count == 1
    end, 20))

    local content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.is_truthy(content:find("@dur: Already posted", 1, true))
  end)

  it("posts draft comments with gh api in the default backend", function()
    local old_system = vim.system
    local calls = {}

    vim.system = function(argv, _, callback)
      table.insert(calls, argv)

      if argv[1] == "gh" and argv[2] == "pr" and argv[3] == "list" then
        callback({
          code = 0,
          stdout = vim.json.encode({
            {
              number = 12,
              title = "Add review browser",
              author = { login = "dur" },
              additions = 1,
              deletions = 1,
              reviewDecision = "",
              isDraft = false,
            },
          }),
          stderr = "",
        })
      elseif argv[1] == "gh" and argv[2] == "pr" and argv[3] == "diff" then
        callback({
          code = 0,
          stdout = table.concat({
            "diff --git a/a.txt b/a.txt",
            "--- a/a.txt",
            "+++ b/a.txt",
            "@@ -1,2 +1,2 @@",
            " same",
            "-old",
            "+new",
          }, "\n"),
          stderr = "",
        })
      elseif argv[1] == "gh" and argv[2] == "pr" and argv[3] == "view" then
        callback({ code = 0, stdout = "abc123\n", stderr = "" })
      elseif argv[1] == "gh" and argv[2] == "api" then
        if contains_arg(argv, "--method") then
          callback({ code = 0, stdout = "", stderr = "" })
        else
          callback({
            code = 0,
            stdout = vim.json.encode({
              {
                path = "a.txt",
                side = "RIGHT",
                line = 2,
                body = "Existing comment",
                user = { login = "dur" },
              },
            }),
            stderr = "",
          })
        end
      else
        callback({ code = 1, stdout = "", stderr = "unexpected command" })
      end
      return {}
    end

    review.open()
    wait_for_loaded()
    vim.api.nvim_win_set_cursor(0, { assert(find_line("#12")), 0 })
    get_normal_keymap(vim.api.nvim_get_current_buf(), "<CR>").callback()
    assert.is_true(vim.wait(1000, function()
      return review._debug_state().comment_count == 1
    end, 20))

    local old_input = vim.ui.input
    vim.ui.input = function(_, on_confirm)
      on_confirm("Needs follow-up")
    end

    local ok, err = pcall(function()
      vim.api.nvim_win_set_cursor(0, { assert(find_line("+new")), 0 })
      get_normal_keymap(vim.api.nvim_get_current_buf(), "c").callback()
      get_normal_keymap(vim.api.nvim_get_current_buf(), "p").callback()
      assert.is_true(vim.wait(1000, function()
        for _, call in ipairs(calls) do
          if call[1] == "gh" and call[2] == "api" and contains_arg(call, "--method") then
            return true
          end
        end
        return false
      end, 20))
    end)
    vim.ui.input = old_input
    vim.system = old_system

    assert.is_true(ok, err)

    local api_call = nil
    for _, call in ipairs(calls) do
      if call[1] == "gh" and call[2] == "api" and contains_arg(call, "--method") then
        api_call = call
      end
    end

    assert.is_not_nil(api_call)
    assert.is_true(contains_arg(api_call, "repos/{owner}/{repo}/pulls/12/comments"))
    assert.is_true(contains_arg(api_call, "body=Needs follow-up"))
    assert.is_true(contains_arg(api_call, "commit_id=abc123"))
    assert.is_true(contains_arg(api_call, "path=a.txt"))
    assert.is_true(contains_arg(api_call, "side=RIGHT"))
    assert.is_true(contains_arg(api_call, "line=2"))
    assert.equals(0, review._debug_state().draft_count)
  end)
end)
