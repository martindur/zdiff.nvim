local zdiff = require("zdiff")
local git = require("zdiff.git")
local buffer = require("tests.helpers.buffer")
local git_repo = require("tests.helpers.git_repo")
local session = require("tests.helpers.zdiff_session")

describe("zdiff", function()
  local plugin_root

  before_each(function()
    plugin_root = vim.fn.getcwd()

    -- Reset config to defaults before each test
    zdiff.config = {
      default_expanded = false,
      default_branch = "main",
      keymaps = {
        goto_file = "<CR>",
        toggle = "<Tab>",
        close = "q",
        refresh = "R",
        toggle_mode = "m",
        help = "?",
      },
      icons = {
        collapsed = "",
        expanded = "",
        added = "+",
        deleted = "-",
        modified = "~",
      },
      syntax = {
        mode = "projection",
        max_lines = 8000,
      },
    }
  end)

  after_each(function()
    -- Close any zdiff buffers after each test
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) then
        local name = vim.api.nvim_buf_get_name(buf)
        if name:match("zdiff") then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end
    end
    vim.cmd("cd " .. vim.fn.fnameescape(plugin_root))
  end)

  describe("setup", function()
    it("should use default config when called without arguments", function()
      zdiff.setup()
      assert.equals(false, zdiff.config.default_expanded)
      assert.equals("main", zdiff.config.default_branch)
      assert.equals("<CR>", zdiff.config.keymaps.goto_file)
      assert.equals("projection", zdiff.config.syntax.mode)
      assert.equals(8000, zdiff.config.syntax.max_lines)
    end)

    it("should merge user config with defaults", function()
      zdiff.setup({
        default_expanded = true,
        default_branch = "develop",
      })
      assert.equals(true, zdiff.config.default_expanded)
      assert.equals("develop", zdiff.config.default_branch)
      -- Should preserve other defaults
      assert.equals("<CR>", zdiff.config.keymaps.goto_file)
    end)

    it("should allow overriding individual keymaps", function()
      zdiff.setup({
        keymaps = {
          goto_file = "o",
        },
      })
      assert.equals("o", zdiff.config.keymaps.goto_file)
      -- Should preserve other keymaps
      assert.equals("<Tab>", zdiff.config.keymaps.toggle)
      assert.equals("q", zdiff.config.keymaps.close)
    end)

    it("should allow overriding icons", function()
      zdiff.setup({
        icons = {
          collapsed = ">",
          expanded = "v",
        },
      })
      assert.equals(">", zdiff.config.icons.collapsed)
      assert.equals("v", zdiff.config.icons.expanded)
      -- Should preserve other icons
      assert.equals("+", zdiff.config.icons.added)
    end)

    it("should allow overriding syntax config", function()
      zdiff.setup({
        syntax = {
          mode = "hunk",
          max_lines = 1000,
        },
      })
      assert.equals("hunk", zdiff.config.syntax.mode)
      assert.equals(1000, zdiff.config.syntax.max_lines)
    end)
  end)

  describe("open", function()
    it("should fail gracefully outside a git repo", function()
      -- This test would need to be run outside a git repo
      -- or we'd need to mock get_git_root
      -- For now, just verify the function exists
      assert.is_function(zdiff.open)
    end)

    it("should create a buffer with zdiff filetype", function()
      zdiff.open()
      local buf = vim.api.nvim_get_current_buf()
      assert.equals("zdiff", vim.bo[buf].filetype)
    end)

    it("should set up help keymap that opens a floating window", function()
      zdiff.open()
      local zdiff_buf = vim.api.nvim_get_current_buf()

      -- Count windows before
      local wins_before = #vim.api.nvim_list_wins()

      -- Simulate pressing '?' by executing the keymap
      local keymaps = vim.api.nvim_buf_get_keymap(zdiff_buf, "n")
      local help_keymap = nil
      for _, km in ipairs(keymaps) do
        if km.lhs == "?" then
          help_keymap = km
          break
        end
      end

      assert.is_not_nil(help_keymap, "Help keymap '?' should be defined")
      assert.is_not_nil(help_keymap.callback, "Help keymap should have a callback")

      -- Execute the callback
      help_keymap.callback()

      -- Count windows after - should have one more (the floating window)
      local wins_after = #vim.api.nvim_list_wins()
      assert.equals(wins_before + 1, wins_after, "Help should open a floating window")

      -- The new window should be floating
      local float_win = vim.api.nvim_get_current_win()
      local win_config = vim.api.nvim_win_get_config(float_win)
      assert.equals("editor", win_config.relative, "Help window should be floating")

      -- Clean up - close the float
      vim.api.nvim_win_close(float_win, true)
    end)

    it("should keep help window open until user interacts", function()
      zdiff.open()
      local zdiff_buf = vim.api.nvim_get_current_buf()

      -- Get and execute help keymap
      local keymaps = vim.api.nvim_buf_get_keymap(zdiff_buf, "n")
      local help_keymap = nil
      for _, km in ipairs(keymaps) do
        if km.lhs == "?" then
          help_keymap = km
          break
        end
      end
      help_keymap.callback()

      local float_win = vim.api.nvim_get_current_win()
      local help_buf = vim.api.nvim_win_get_buf(float_win)

      -- Window should still be valid (not closed immediately)
      assert.is_true(
        vim.api.nvim_win_is_valid(float_win),
        "Help window should remain open"
      )

      -- Check buffer content contains expected text
      local lines = vim.api.nvim_buf_get_lines(help_buf, 0, -1, false)
      local content = table.concat(lines, "\n")

      assert.is_truthy(content:find("zdiff keymaps"), "Help should contain title")
      assert.is_truthy(
        content:find("Go to file"),
        "Help should contain goto_file description"
      )
      assert.is_truthy(content:find("Toggle"), "Help should contain toggle description")
      assert.is_truthy(content:find("Close"), "Help should contain close description")
      assert.is_truthy(content:find("Press any key"), "Help should contain footer")

      -- Clean up
      vim.api.nvim_win_close(float_win, true)
    end)

    it("should not reuse a zdiff session across repository roots", function()
      local repo_a = git_repo.create_changed_file("a.txt", "a old\n", "a new\n")
      local repo_b = git_repo.create_changed_file("b.txt", "b old\n", "b new\n")

      vim.cmd("cd " .. vim.fn.fnameescape(repo_a))
      zdiff.open()
      session.wait_for_loaded()
      local first_content =
        table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      assert.is_truthy(first_content:find("a.txt", 1, true))

      vim.cmd("cd " .. vim.fn.fnameescape(repo_b))
      zdiff.open()
      session.wait_for_loaded()
      local second_content =
        table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      assert.is_truthy(second_content:find("b.txt", 1, true))
      assert.is_nil(second_content:find("a.txt", 1, true))
    end)

    it("should show git errors when toggle mode uses an invalid ref", function()
      local repo = git_repo.create_changed_file("a.txt", "old\n", "new\n")
      zdiff.config.default_branch = "missing-branch"

      vim.cmd("cd " .. vim.fn.fnameescape(repo))
      zdiff.open()
      session.wait_for_loaded()

      local toggle_keymap = buffer.normal_keymap(vim.api.nvim_get_current_buf(), "m")
      assert.is_not_nil(toggle_keymap)
      toggle_keymap.callback()
      session.wait_for_loaded()

      local content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      assert.is_truthy(content:find("Error loading changes", 1, true))
      assert.is_nil(content:find("No changes found", 1, true))
    end)

    it("should not reload expanded files with no hunks", function()
      local repo = git_repo.create_changed_file("old.txt", "same\n", "same\n")
      git_repo.run(repo, { "mv", "old.txt", "new.txt" })
      zdiff.config.default_expanded = true

      local calls = 0
      local original = git.file_diff_lines_async
      git.file_diff_lines_async = function(...)
        calls = calls + 1
        return original(...)
      end

      local ok, err = pcall(function()
        vim.cmd("cd " .. vim.fn.fnameescape(repo))
        zdiff.open()
        session.wait_for_loaded()

        local toggle_keymap = buffer.normal_keymap(vim.api.nvim_get_current_buf(), "<Tab>")
        vim.api.nvim_win_set_cursor(0, { assert(buffer.find_line("old.txt -> new.txt")), 0 })
        toggle_keymap.callback()
        toggle_keymap.callback()
        session.wait_for_loaded()
      end)
      git.file_diff_lines_async = original

      assert.is_true(ok, err)
      assert.equals(1, calls)
    end)

    it("should ignore non-source diff metadata lines", function()
      local repo = git_repo.create_changed_file("no-newline.txt", "old", "new")
      zdiff.config.default_expanded = true

      vim.cmd("cd " .. vim.fn.fnameescape(repo))
      zdiff.open()
      session.wait_for_loaded()

      local content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      assert.is_truthy(content:find("old", 1, true))
      assert.is_truthy(content:find("new", 1, true))
      assert.is_nil(content:find("No newline at end of file", 1, true))
    end)

    it("should skip disabled and invalid keymaps", function()
      zdiff.setup({
        keymaps = {
          goto_file = false,
          toggle = false,
          close = false,
          refresh = 123,
          toggle_mode = "",
          help = false,
          yank_ref = false,
        },
      })

      zdiff.open()
      local buf = vim.api.nvim_get_current_buf()

      assert.is_nil(buffer.normal_keymap(buf, "<CR>"))
      assert.is_nil(buffer.normal_keymap(buf, "<Tab>"))
      assert.is_nil(buffer.normal_keymap(buf, "q"))
      assert.is_nil(buffer.normal_keymap(buf, "R"))
      assert.is_nil(buffer.normal_keymap(buf, "m"))
      assert.is_nil(buffer.normal_keymap(buf, "?"))
      assert.is_nil(buffer.normal_keymap(buf, "gy"))
      assert.is_nil(buffer.visual_keymap(buf, "gy"))
    end)

    it("should only show enabled keymaps in help", function()
      zdiff.setup({
        keymaps = {
          close = false,
          yank_ref = false,
        },
      })

      zdiff.show_help()
      local help_buf = vim.api.nvim_get_current_buf()
      local content =
        table.concat(vim.api.nvim_buf_get_lines(help_buf, 0, -1, false), "\n")

      assert.is_truthy(content:find("Go to file", 1, true))
      assert.is_nil(content:find("Close zdiff", 1, true))
      assert.is_nil(content:find("Yank file:line reference", 1, true))

      vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
    end)

    it("should preserve the cursor after returning from a source file", function()
      local baseline = {}
      for i = 1, 40 do
        baseline[i] = "line " .. i
      end
      local changed = vim.deepcopy(baseline)
      changed[30] = "changed target"
      local repo = git_repo.create_changed_file(
        "a.txt",
        table.concat(baseline, "\n") .. "\n",
        table.concat(changed, "\n") .. "\n"
      )
      zdiff.config.default_expanded = true

      local calls = 0
      local original = git.diff_files_async
      local old_directory = vim.o.directory
      vim.o.directory = "/tmp"
      git.diff_files_async = function(...)
        calls = calls + 1
        return original(...)
      end

      local ok, err = pcall(function()
        vim.cmd("cd " .. vim.fn.fnameescape(repo))
        zdiff.open()
        session.wait_for_loaded()

        local diff_buf = vim.api.nvim_get_current_buf()
        local target_line = assert(buffer.find_line("changed target"))
        vim.api.nvim_win_set_cursor(0, { target_line, 0 })
        buffer.normal_keymap(diff_buf, "<CR>").callback()

        vim.api.nvim_win_set_buf(0, diff_buf)
        assert.is_true(vim.wait(5000, function()
          local dbg = zdiff._debug_state()
          return calls >= 2
            and not dbg.loading_files
            and not dbg.pending_render
            and dbg.pending_hunk_jobs == 0
            and vim.api.nvim_win_get_cursor(0)[1] == target_line
        end, 50))
      end)
      git.diff_files_async = original
      vim.o.directory = old_directory

      assert.is_true(ok, err)
    end)

    it("should not open deleted files from the worktree", function()
      local repo = git_repo.create_changed_file("deleted.txt", "gone\n", "gone\n")
      git_repo.run(repo, { "rm", "--", "deleted.txt" })

      vim.cmd("cd " .. vim.fn.fnameescape(repo))
      zdiff.open()
      session.wait_for_loaded()

      local goto_keymap = buffer.normal_keymap(vim.api.nvim_get_current_buf(), "<CR>")
      vim.api.nvim_win_set_cursor(0, { assert(buffer.find_line("deleted.txt")), 0 })

      local notifications = {}
      local old_notify = vim.notify
      vim.notify = function(msg)
        table.insert(notifications, msg)
      end
      local ok, err = pcall(goto_keymap.callback)
      vim.notify = old_notify

      assert.is_true(ok, err)
      assert.equals("zdiff", vim.bo[vim.api.nvim_get_current_buf()].filetype)
      assert.is_truthy(notifications[1]:find("Cannot open deleted file", 1, true))
    end)

    it("should not navigate deleted lines to the current file", function()
      local repo = git_repo.create_changed_file("a.txt", "one\ntwo\nthree\n", "one\nthree\n")
      zdiff.config.default_expanded = true

      vim.cmd("cd " .. vim.fn.fnameescape(repo))
      zdiff.open()
      session.wait_for_loaded()

      local goto_keymap = buffer.normal_keymap(vim.api.nvim_get_current_buf(), "<CR>")
      vim.api.nvim_win_set_cursor(0, { assert(buffer.find_line("two")), 0 })

      local notifications = {}
      local old_notify = vim.notify
      vim.notify = function(msg)
        table.insert(notifications, msg)
      end
      local ok, err = pcall(goto_keymap.callback)
      vim.notify = old_notify

      assert.is_true(ok, err)
      assert.equals("zdiff", vim.bo[vim.api.nvim_get_current_buf()].filetype)
      assert.is_truthy(notifications[1]:find("Cannot open deleted line", 1, true))
    end)
  end)
end)
