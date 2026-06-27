local review = require("zdiff.review")
local diff = require("zdiff.diff")
local syntax = require("zdiff.syntax")
local buffer = require("tests.helpers.buffer")
local git_repo = require("tests.helpers.git_repo")
local syntax_marks = require("tests.helpers.syntax_marks")

local function wait_for_loaded()
  local ok = vim.wait(1000, function()
    return not review._debug_state().loading
  end, 20)
  assert.is_true(ok, "timed out waiting for review PRs to load")
end

local function expand_file(text)
  local toggle_keymap = buffer.normal_keymap(vim.api.nvim_get_current_buf(), "<Tab>")
  assert.is_not_nil(toggle_keymap)
  vim.api.nvim_win_set_cursor(0, { assert(buffer.find_line(text or "a.txt")), 0 })
  toggle_keymap.callback()
end

local function review_file(path, lines)
  return {
    path = path,
    display_path = path,
    old_path = path,
    new_path = path,
    status = "M",
    insertions = 1,
    deletions = 1,
    hunks = diff.parse_hunks(lines),
  }
end

local function review_backend(methods, pr)
  pr = vim.tbl_extend("force", {
    number = 12,
    title = "Add review browser",
    author = "dur",
    additions = 1,
    deletions = 1,
    review_decision = "",
    is_draft = false,
    base_ref_oid = "base123",
    head_ref_oid = "head123",
  }, pr or {})

  return vim.tbl_extend("force", {
    list_prs = function(_, done)
      done({ ok = true, data = { pr } })
    end,
  }, methods or {})
end

describe("zdiff.review", function()
  local plugin_root

  before_each(function()
    plugin_root = vim.fn.getcwd()
    pcall(vim.api.nvim_del_user_command, "ZdiffReview")
    vim.cmd("cd " .. vim.fn.fnameescape(git_repo.create()))
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
    review._set_backend(review_backend(nil, { additions = 10, deletions = 2 }))

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

  it("submits PR actions from the list", function()
    local reviews = {}
    local comments = {}
    local finish_approval = nil
    review._set_backend(review_backend({
      diff_pr = function(_, _, done)
        done({ ok = true, data = {} })
      end,
      submit_review = function(_, number, action, body, done)
        table.insert(reviews, { number = number, action = action, body = body })
        if action == "approve" then
          finish_approval = done
        else
          done({ ok = true })
        end
      end,
      submit_pr_comment = function(_, number, body, done)
        table.insert(comments, { number = number, body = body })
        done({ ok = true })
      end,
    }, { additions = 10, deletions = 2 }))

    review.open()
    wait_for_loaded()
    vim.api.nvim_win_set_cursor(0, { assert(buffer.find_line("#12")), 0 })

    local choices = {
      "Approve",
      "Request changes",
      "General comment",
      "Request changes",
    }
    local inputs = { "Looks good", "Please fix this", "FYI", "" }
    local select_calls = 0
    local old_select = vim.ui.select
    local old_input = vim.ui.input
    vim.ui.select = function(_, _, on_choice)
      select_calls = select_calls + 1
      on_choice(table.remove(choices, 1))
    end
    vim.ui.input = function(_, on_confirm)
      on_confirm(table.remove(inputs, 1))
    end

    local ok, err = pcall(function()
      local action = assert(buffer.normal_keymap(vim.api.nvim_get_current_buf(), "a"))
      action.callback()
      assert.equals(12, review._debug_state().pr_action_pending)
      assert.is_not_nil(buffer.find_line("submitting..."))

      action.callback()
      assert.equals(1, #reviews)
      assert.equals(1, select_calls)

      finish_approval({ ok = true })
      action.callback()
      action.callback()
      action.callback()

      assert.equals(2, #reviews)
      assert.same({ number = 12, action = "approve", body = "Looks good" }, reviews[1])
      assert.same({
        number = 12,
        action = "request_changes",
        body = "Please fix this",
      }, reviews[2])
      assert.same({ number = 12, body = "FYI" }, comments[1])

      vim.ui.select = function(_, _, on_choice)
        on_choice(nil)
      end
      action.callback()
      assert.equals(2, #reviews)
      assert.equals(1, #comments)

      vim.api.nvim_win_set_cursor(0, { assert(buffer.find_line("#12")), 0 })
      buffer.normal_keymap(vim.api.nvim_get_current_buf(), "<CR>").callback()
      wait_for_loaded()
      action.callback()
      assert.equals(2, #reviews)
      assert.equals(1, #comments)
    end)
    vim.ui.select = old_select
    vim.ui.input = old_input
    assert.is_true(ok, err)
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

  it("opens a selected pull request diff and returns to the cached list", function()
    local list_calls = 0
    review._set_backend({
      list_prs = function(_, done)
        list_calls = list_calls + 1
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
      diff_pr = function(_, pr, done)
        assert.equals(12, pr.number)
        done({
          ok = true,
          data = {
            review_file("a.txt", {
              "@@ -1,2 +1,2 @@",
              " same",
              "-old",
              "+new",
            }),
          },
        })
      end,
    })

    review.open()
    wait_for_loaded()

    local open_keymap = buffer.normal_keymap(vim.api.nvim_get_current_buf(), "<CR>")
    assert.is_not_nil(open_keymap)
    vim.api.nvim_win_set_cursor(0, { assert(buffer.find_line("#12")), 0 })
    open_keymap.callback()
    wait_for_loaded()

    local content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.equals("diff", review._debug_state().view)
    assert.equals(1, review._debug_state().file_count)
    assert.is_truthy(content:find("PR #12 Add review browser", 1, true))
    assert.is_truthy(content:find("a.txt", 1, true))
    assert.is_nil(content:find("-old", 1, true))

    expand_file("a.txt")
    content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.is_truthy(content:find("old", 1, true))
    assert.is_truthy(content:find("new", 1, true))

    vim.api.nvim_win_set_cursor(0, { assert(buffer.find_line("new")), 0 })
    buffer.normal_keymap(vim.api.nvim_get_current_buf(), "<Tab>").callback()
    content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.equals(0, review._debug_state().expanded_count)
    assert.is_nil(content:find("old", 1, true))

    local buf = vim.api.nvim_get_current_buf()
    local close_keymap = assert(buffer.normal_keymap(buf, "q"))
    close_keymap.callback()
    assert.equals("list", review._debug_state().view)
    assert.equals(1, list_calls)
    assert.is_not_nil(buffer.find_line("#12 Add review browser"))

    close_keymap.callback()
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
  end)

  it("renders and toggles the pull request description", function()
    review._set_backend(review_backend({
      diff_pr = function(_, _, done)
        done({
          ok = true,
          data = {
            review_file("a.txt", {
              "@@ -1,2 +1,2 @@",
              " same",
              "-old",
              "+new",
            }),
          },
        })
      end,
    }, {
      body = table.concat({
        "# Summary",
        "- `Visible 2`",
        "Visible 3",
        "Visible 4",
        "Visible 5",
        "Visible 6",
        "Visible 7",
        "Visible 8",
        "Hidden 9",
        "Hidden 10",
      }, "\n"),
    }))

    review.open()
    wait_for_loaded()
    vim.api.nvim_win_set_cursor(0, { assert(buffer.find_line("#12")), 0 })
    buffer.normal_keymap(vim.api.nvim_get_current_buf(), "<CR>").callback()
    wait_for_loaded()

    local content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.is_truthy(content:find("Description", 1, true))
    assert.is_truthy(content:find("Summary", 1, true))
    assert.is_truthy(content:find("Visible 8", 1, true))
    assert.is_truthy(content:find("... 2 more description lines", 1, true))
    assert.is_nil(content:find("Hidden 9", 1, true))

    local description_keymap = assert(buffer.normal_keymap(vim.api.nvim_get_current_buf(), "d"))
    description_keymap.callback()

    content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.is_true(review._debug_state().description_expanded)
    assert.is_truthy(content:find("Hidden 9", 1, true))
    assert.is_truthy(content:find("Hidden 10", 1, true))
    assert.is_nil(content:find("... 2 more description lines", 1, true))

    if syntax.get_lang_from_filetype("markdown") then
      local ns = vim.api.nvim_get_namespaces().zdiff_review_syntax
      assert.is_not_nil(ns, "zdiff_review_syntax namespace should exist")
      local marks = syntax_marks.for_line(
        vim.api.nvim_get_current_buf(),
        ns,
        assert(buffer.find_line("# Summary")) - 1
      )
      assert.is_true(syntax_marks.has_group_prefix(marks, "@markup.heading"))

      if syntax.get_lang_from_filetype("markdown_inline") then
        marks = syntax_marks.for_line(
          vim.api.nvim_get_current_buf(),
          ns,
          assert(buffer.find_line("`Visible 2`")) - 1
        )
        assert.is_true(syntax_marks.has_group_prefix(marks, "@markup.raw"))
      end
    end
  end)

  it("projects syntax from backend file contents", function()
    local reads = {}
    review._set_backend(review_backend({
      diff_pr = function(_, _, done)
        done({
          ok = true,
          data = {
            review_file("a.lua", {
              "@@ -1,2 +1,2 @@",
              " local value = 1",
              "-return value",
              "+return value + 1",
            }),
          },
        })
      end,
      read_file = function(_, path, ref, done)
        table.insert(reads, { path = path, ref = ref })
        if ref == "base123" then
          done({ ok = true, data = { "local value = 1", "return value" } })
        else
          done({ ok = true, data = { "local value = 1", "return value + 1" } })
        end
      end,
    }, { base_ref_oid = "base123", head_ref_oid = "head123" }))

    review.open()
    wait_for_loaded()
    vim.api.nvim_win_set_cursor(0, { assert(buffer.find_line("#12")), 0 })
    buffer.normal_keymap(vim.api.nvim_get_current_buf(), "<CR>").callback()
    wait_for_loaded()
    expand_file("a.lua")

    assert.is_true(vim.wait(1000, function()
      return review._debug_state().syntax_cache_entries == 1
    end, 20))

    local syntax_state = review._debug_state().syntax or {}
    assert.is_true(vim.tbl_contains(syntax_state.projected_files or {}, "a.lua"))
    assert.equals("base123", reads[1].ref)
    assert.equals("head123", reads[2].ref)
  end)

  it("posts prompted comments through the backend", function()
    local submitted = nil
    review._set_backend(review_backend({
      diff_pr = function(_, _, done)
        done({
          ok = true,
          data = {
            review_file("a.txt", {
              "@@ -1,2 +1,2 @@",
              " same",
              "-old",
              "+new",
            }),
          },
        })
      end,
      submit_comment = function(_, number, comment, done)
        submitted = { number = number, comment = comment }
        done({ ok = true })
      end,
    }))

    review.open()
    wait_for_loaded()
    vim.api.nvim_win_set_cursor(0, { assert(buffer.find_line("#12")), 0 })
    buffer.normal_keymap(vim.api.nvim_get_current_buf(), "<CR>").callback()
    wait_for_loaded()
    expand_file("a.txt")

    local old_input = vim.ui.input
    vim.ui.input = function(opts, on_confirm)
      assert.equals("Comment: ", opts.prompt)
      on_confirm("Needs follow-up")
    end

    local ok, err = pcall(function()
      vim.api.nvim_win_set_cursor(0, { assert(buffer.find_line("new")), 0 })
      buffer.normal_keymap(vim.api.nvim_get_current_buf(), "c").callback()
    end)
    vim.ui.input = old_input

    assert.is_true(ok, err)
    assert.equals(12, submitted.number)
    assert.equals("a.txt", submitted.comment.path)
    assert.equals("RIGHT", submitted.comment.side)
    assert.equals(2, submitted.comment.line)
    assert.equals("Needs follow-up", submitted.comment.body)
    assert.equals("head123", submitted.comment.commit_id)
  end)

  it("shows posting state and blocks duplicate posts", function()
    local calls = 0
    review._set_backend(review_backend({
      diff_pr = function(_, _, done)
        done({
          ok = true,
          data = {
            review_file("a.txt", {
              "@@ -1,2 +1,2 @@",
              " same",
              "-old",
              "+new",
            }),
          },
        })
      end,
      submit_comment = function()
        calls = calls + 1
      end,
    }))

    review.open()
    wait_for_loaded()
    vim.api.nvim_win_set_cursor(0, { assert(buffer.find_line("#12")), 0 })
    buffer.normal_keymap(vim.api.nvim_get_current_buf(), "<CR>").callback()
    wait_for_loaded()
    expand_file("a.txt")

    local old_input = vim.ui.input
    vim.ui.input = function(_, on_confirm)
      on_confirm("Needs follow-up")
    end

    local ok, err = pcall(function()
      vim.api.nvim_win_set_cursor(0, { assert(buffer.find_line("new")), 0 })
      buffer.normal_keymap(vim.api.nvim_get_current_buf(), "c").callback()
      buffer.normal_keymap(vim.api.nvim_get_current_buf(), "c").callback()
    end)
    vim.ui.input = old_input

    assert.is_true(ok, err)
    assert.equals(1, calls)
    assert.equals(1, review._debug_state().posting_count)
    local content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.is_truthy(content:find("Posting...", 1, true))
  end)

  it("replies to a top-level comment through the backend", function()
    local reply = nil
    review._set_backend(review_backend({
      diff_pr = function(_, _, done)
        done({
          ok = true,
          data = {
            review_file("a.txt", {
              "@@ -1,2 +1,2 @@",
              " same",
              "-old",
              "+new",
            }),
          },
        })
      end,
      list_comments = function(_, _, done)
        done({
          ok = true,
          data = {
            {
              id = 44,
              path = "a.txt",
              side = "RIGHT",
              line = 2,
              body = "Already posted",
              author = "dur",
            },
          },
        })
      end,
      reply_comment = function(_, number, comment_id, body, done)
        reply = { number = number, comment_id = comment_id, body = body }
        done({ ok = true })
      end,
    }))

    review.open()
    wait_for_loaded()
    vim.api.nvim_win_set_cursor(0, { assert(buffer.find_line("#12")), 0 })
    buffer.normal_keymap(vim.api.nvim_get_current_buf(), "<CR>").callback()
    assert.is_true(vim.wait(1000, function()
      return review._debug_state().comment_count == 1
    end, 20))
    expand_file("a.txt")

    local old_input = vim.ui.input
    vim.ui.input = function(opts, on_confirm)
      assert.equals("Reply: ", opts.prompt)
      on_confirm("Reply body")
    end

    local ok, err = pcall(function()
      vim.api.nvim_win_set_cursor(0, { assert(buffer.find_line("@dur: Already posted")), 0 })
      buffer.normal_keymap(vim.api.nvim_get_current_buf(), "r").callback()
    end)
    vim.ui.input = old_input

    assert.is_true(ok, err)
    assert.equals(12, reply.number)
    assert.equals(44, reply.comment_id)
    assert.equals("Reply body", reply.body)
  end)

  it("loads posted comments through the backend", function()
    review._set_backend(review_backend({
      diff_pr = function(_, _, done)
        done({
          ok = true,
          data = {
            review_file("a.txt", {
              "@@ -1,2 +1,2 @@",
              " same",
              "-old",
              "+new",
            }),
          },
        })
      end,
      list_comments = function(_, _, done)
        done({
          ok = true,
          data = {
            {
              id = 44,
              path = "a.txt",
              side = "RIGHT",
              line = 2,
              body = "Already posted\nSecond line",
              author = "dur",
            },
            {
              id = 45,
              in_reply_to_id = 44,
              path = "a.txt",
              side = "RIGHT",
              line = 2,
              body = "Existing reply\nReply continuation",
              author = "sam",
            },
          },
        })
      end,
    }))

    review.open()
    wait_for_loaded()
    vim.api.nvim_win_set_cursor(0, { assert(buffer.find_line("#12")), 0 })
    buffer.normal_keymap(vim.api.nvim_get_current_buf(), "<CR>").callback()

    assert.is_true(vim.wait(1000, function()
      return review._debug_state().comment_count == 1
    end, 20))
    expand_file("a.txt")

    local content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.is_truthy(content:find("@dur: Already posted", 1, true))
    assert.is_truthy(content:find("    Second line", 1, true))
    assert.is_truthy(content:find("@sam: Existing reply", 1, true))
    assert.is_truthy(content:find("      Reply continuation", 1, true))
  end)

  it("summarizes collapsed threads and jumps between them", function()
    review._set_backend(review_backend({
      diff_pr = function(_, _, done)
        done({
          ok = true,
          data = {
            review_file("a.txt", {
              "@@ -1,2 +1,2 @@",
              " same",
              "-old",
              "+new",
            }),
            review_file("b.txt", {
              "@@ -1,2 +1,2 @@",
              " same",
              "-before",
              "+after",
            }),
          },
        })
      end,
      list_comments = function(_, _, done)
        done({
          ok = true,
          data = {
            {
              id = 44,
              path = "a.txt",
              side = "RIGHT",
              line = 2,
              body = "First thread",
              author = "dur",
            },
            {
              id = 45,
              in_reply_to_id = 44,
              path = "a.txt",
              side = "RIGHT",
              line = 2,
              body = "First reply",
              author = "sam",
            },
            {
              id = 46,
              path = "b.txt",
              side = "RIGHT",
              line = 2,
              body = "Second thread",
              author = "sam",
            },
          },
        })
      end,
    }, { additions = 2, deletions = 2 }))

    review.open()
    wait_for_loaded()
    vim.api.nvim_win_set_cursor(0, { assert(buffer.find_line("#12")), 0 })
    buffer.normal_keymap(vim.api.nvim_get_current_buf(), "<CR>").callback()
    assert.is_true(vim.wait(1000, function()
      return review._debug_state().comment_count == 2
    end, 20))

    local content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.is_truthy(content:find("1 thread, 2 comments by @dur, @sam", 1, true))
    assert.is_truthy(content:find("1 thread, 1 comment by @sam", 1, true))
    assert.is_nil(content:find("@dur: First thread", 1, true))

    local next_thread = buffer.normal_keymap(vim.api.nvim_get_current_buf(), "]t")
    local prev_thread = buffer.normal_keymap(vim.api.nvim_get_current_buf(), "[t")
    assert.is_not_nil(next_thread)
    assert.is_not_nil(prev_thread)

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    next_thread.callback()
    assert.is_truthy(buffer.current_line():find("@dur: First thread", 1, true))

    next_thread.callback()
    assert.is_truthy(buffer.current_line():find("@sam: Second thread", 1, true))

    prev_thread.callback()
    assert.is_truthy(buffer.current_line():find("@dur: First thread", 1, true))
  end)

  it("posts PR actions with gh in the default backend", function()
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
      elseif
        argv[1] == "gh"
        and argv[2] == "pr"
        and (argv[3] == "review" or argv[3] == "comment")
      then
        callback({ code = 0, stdout = "", stderr = "" })
      else
        callback({ code = 1, stdout = "", stderr = "unexpected command" })
      end
      return {}
    end

    local old_select = vim.ui.select
    local old_input = vim.ui.input
    local choices = { "Approve", "Request changes", "General comment" }
    local inputs = { "Looks good", "Please fix this", "FYI" }
    vim.ui.select = function(_, _, on_choice)
      on_choice(table.remove(choices, 1))
    end
    vim.ui.input = function(_, on_confirm)
      on_confirm(table.remove(inputs, 1))
    end

    local ok, err = pcall(function()
      review.open()
      wait_for_loaded()
      local action = assert(buffer.normal_keymap(vim.api.nvim_get_current_buf(), "a"))
      for _ = 1, 3 do
        vim.api.nvim_win_set_cursor(0, { assert(buffer.find_line("#12")), 0 })
        action.callback()
        assert.is_true(vim.wait(1000, function()
          local debug = review._debug_state()
          return debug.pr_action_pending == nil and not debug.loading
        end, 20))
      end
    end)
    vim.ui.select = old_select
    vim.ui.input = old_input
    vim.system = old_system
    assert.is_true(ok, err)

    local approve = nil
    local request_changes = nil
    local comment = nil
    for _, call in ipairs(calls) do
      if call[3] == "review" and vim.tbl_contains(call, "--approve") then
        approve = call
      elseif call[3] == "review" and vim.tbl_contains(call, "--request-changes") then
        request_changes = call
      elseif call[3] == "comment" then
        comment = call
      end
    end

    assert.is_not_nil(approve)
    assert.is_true(vim.tbl_contains(approve, "Looks good"))
    assert.is_not_nil(request_changes)
    assert.is_true(vim.tbl_contains(request_changes, "Please fix this"))
    assert.is_not_nil(comment)
    assert.is_true(vim.tbl_contains(comment, "FYI"))
  end)

  it("posts comments and replies with gh api in the default backend", function()
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
              baseRefOid = "base123",
              headRefOid = "head123",
            },
          }),
          stderr = "",
        })
      elseif argv[1] == "gh" and argv[2] == "pr" and argv[3] == "view" then
        callback({
          code = 0,
          stdout = vim.json.encode({ body = "Default backend description" }),
          stderr = "",
        })
      elseif argv[1] == "gh" and argv[2] == "api" then
        if vim.tbl_contains(argv, "repos/{owner}/{repo}/pulls/12/files") then
          callback({
            code = 0,
            stdout = vim.json.encode({
              {
                {
                  filename = "a.txt",
                  status = "modified",
                  additions = 1,
                  deletions = 1,
                  patch = table.concat({
                    "@@ -1,2 +1,2 @@",
                    " same",
                    "-old",
                    "+new",
                  }, "\n"),
                },
                {
                  filename = "b.bin",
                  status = "modified",
                  additions = 0,
                  deletions = 0,
                },
              },
            }),
            stderr = "",
          })
        elseif vim.tbl_contains(argv, "repos/{owner}/{repo}/contents/a.txt") then
          callback({ code = 0, stdout = "same\nnew\n", stderr = "" })
        elseif vim.tbl_contains(argv, "--method") then
          callback({ code = 0, stdout = "", stderr = "" })
        else
          callback({
            code = 0,
            stdout = vim.json.encode({
              {
                id = 44,
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
    vim.api.nvim_win_set_cursor(0, { assert(buffer.find_line("#12")), 0 })
    buffer.normal_keymap(vim.api.nvim_get_current_buf(), "<CR>").callback()
    assert.is_true(vim.wait(1000, function()
      return review._debug_state().comment_count == 1
    end, 20))
    expand_file("b.bin")
    local content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.is_truthy(content:find("Default backend description", 1, true))
    assert.is_truthy(
      content:find("Patch unavailable from GitHub (binary or too large)", 1, true)
    )
    expand_file("a.txt")

    local old_input = vim.ui.input
    vim.ui.input = function(opts, on_confirm)
      if opts.prompt == "Reply: " then
        on_confirm("Reply body")
      else
        on_confirm("Needs follow-up")
      end
    end

    local ok, err = pcall(function()
      vim.api.nvim_win_set_cursor(0, { assert(buffer.find_line("new")), 0 })
      buffer.normal_keymap(vim.api.nvim_get_current_buf(), "c").callback()
      assert.is_true(vim.wait(1000, function()
        for _, call in ipairs(calls) do
          if
            call[1] == "gh"
            and call[2] == "api"
            and vim.tbl_contains(call, "--method")
            and vim.tbl_contains(call, "repos/{owner}/{repo}/pulls/12/comments")
          then
            return true
          end
        end
        return false
      end, 20))

      vim.api.nvim_win_set_cursor(0, { assert(buffer.find_line("@dur: Existing comment")), 0 })
      buffer.normal_keymap(vim.api.nvim_get_current_buf(), "r").callback()
      assert.is_true(vim.wait(1000, function()
        for _, call in ipairs(calls) do
          if
            call[1] == "gh"
            and call[2] == "api"
            and vim.tbl_contains(call, "--method")
            and vim.tbl_contains(call, "repos/{owner}/{repo}/pulls/12/comments/44/replies")
          then
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
    local reply_call = nil
    for _, call in ipairs(calls) do
      if call[1] == "gh" and call[2] == "api" and vim.tbl_contains(call, "--method") then
        if vim.tbl_contains(call, "repos/{owner}/{repo}/pulls/12/comments") then
          api_call = call
        elseif
          vim.tbl_contains(call, "repos/{owner}/{repo}/pulls/12/comments/44/replies")
        then
          reply_call = call
        end
      end
    end

    assert.is_not_nil(api_call)
    assert.is_true(vim.tbl_contains(api_call, "repos/{owner}/{repo}/pulls/12/comments"))
    assert.is_true(vim.tbl_contains(api_call, "body=Needs follow-up"))
    assert.is_true(vim.tbl_contains(api_call, "commit_id=head123"))
    assert.is_true(vim.tbl_contains(api_call, "path=a.txt"))
    assert.is_true(vim.tbl_contains(api_call, "side=RIGHT"))
    assert.is_true(vim.tbl_contains(api_call, "line=2"))
    assert.is_not_nil(reply_call)
    assert.is_true(vim.tbl_contains(reply_call, "body=Reply body"))
  end)
end)
