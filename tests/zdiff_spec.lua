local zdiff = require("zdiff")

local plugin_root = vim.fn.getcwd()

local function run_sync(cmd, cwd)
  local full_cmd = cmd
  if cwd and cwd ~= "" then
    full_cmd = "cd " .. vim.fn.shellescape(cwd) .. " && " .. cmd
  end
  local out = vim.fn.system(full_cmd)
  if vim.v.shell_error ~= 0 then
    error(string.format("command failed (%s): %s", full_cmd, out))
  end
  return out
end

local function write_file(path, lines)
  local file = assert(io.open(path, "w"))
  file:write(table.concat(lines, "\n"))
  file:write("\n")
  file:close()
end

local function wait_for_loaded(timeout_ms)
  local ok = vim.wait(timeout_ms, function()
    local buf = vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= "zdiff" then
      return false
    end
    local dbg = zdiff._debug_state()
    return not dbg.loading_files and dbg.pending_syntax_jobs == 0
  end, 50)
  if not ok then
    error("timeout waiting for zdiff to load")
  end
end

local function find_keymap_callback(buf, lhs, mode)
  local keymaps = vim.api.nvim_buf_get_keymap(buf, mode or "n")
  for _, km in ipairs(keymaps) do
    if km.lhs == lhs then
      return km.callback
    end
  end
  return nil
end

local function find_buffer_line(buf, text)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for idx, line in ipairs(lines) do
    if line == text then
      return idx
    end
  end
  error(
    "line not found: "
      .. text
      .. "\nrendered lines:\n"
      .. table.concat(vim.tbl_map(function(line)
        return string.format("%q", line)
      end, lines), "\n")
  )
end

local function create_modified_repo()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")

  run_sync("git init", repo)
  run_sync("git config user.name 'zdiff-test'", repo)
  run_sync("git config user.email 'zdiff@example.com'", repo)

  write_file(repo .. "/example.txt", { "alpha", "beta", "gamma" })
  run_sync("git add .", repo)
  run_sync("git commit -m 'initial'", repo)

  write_file(repo .. "/example.txt", { "alpha", "beta changed", "gamma", "delta" })

  return repo
end

local function create_deleted_repo()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")

  run_sync("git init", repo)
  run_sync("git config user.name 'zdiff-test'", repo)
  run_sync("git config user.email 'zdiff@example.com'", repo)

  write_file(repo .. "/gone.txt", { "one", "two" })
  run_sync("git add .", repo)
  run_sync("git commit -m 'initial'", repo)
  vim.fn.delete(repo .. "/gone.txt")

  return repo
end

local function create_two_commit_repo()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")

  run_sync("git init", repo)
  run_sync("git config user.name 'zdiff-test'", repo)
  run_sync("git config user.email 'zdiff@example.com'", repo)

  write_file(repo .. "/tracked.txt", { "base" })
  run_sync("git add .", repo)
  run_sync("git commit -m 'initial'", repo)

  write_file(repo .. "/tracked.txt", { "second" })
  run_sync("git add .", repo)
  run_sync("git commit -m 'second'", repo)

  write_file(repo .. "/tracked.txt", { "working tree change" })

  return repo
end

local function create_multihunk_repo()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")

  run_sync("git init", repo)
  run_sync("git config user.name 'zdiff-test'", repo)
  run_sync("git config user.email 'zdiff@example.com'", repo)

  write_file(repo .. "/multi.txt", {
    "line 1",
    "line 2",
    "line 3",
    "line 4",
    "line 5",
    "line 6",
    "line 7",
    "line 8",
    "line 9",
    "line 10",
    "line 11",
    "line 12",
  })
  run_sync("git add .", repo)
  run_sync("git commit -m 'initial'", repo)

  write_file(repo .. "/multi.txt", {
    "line 1",
    "line 2 changed",
    "line 3",
    "line 4",
    "line 5",
    "line 6",
    "line 7",
    "line 8",
    "line 9",
    "line 10 changed",
    "line 11",
    "line 12",
  })

  return repo
end

describe("zdiff", function()
  before_each(function()
    if zdiff._debug_reset then
      zdiff._debug_reset()
    end

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
        yank_ref = "gy",
        comment = "c",
        delete_comment = "d",
        yank_comments = "yc",
        toggle_annotations_only = "h",
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
      comments = {
        prefix = "Feedback for changes:\n",
        suffix = "",
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
    if zdiff._debug_reset then
      zdiff._debug_reset()
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
      assert.equals("Feedback for changes:\n", zdiff.config.comments.prefix)
      assert.equals("h", zdiff.config.keymaps.toggle_annotations_only)
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
      assert.equals("c", zdiff.config.keymaps.comment)
      assert.equals("Feedback for changes:\n", zdiff.config.comments.prefix)
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
      assert.equals("yc", zdiff.config.keymaps.yank_comments)
      assert.equals("h", zdiff.config.keymaps.toggle_annotations_only)
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

    it("should allow overriding annotation yank formatting", function()
      zdiff.setup({
        comments = {
          prefix = "Review notes:\n",
          suffix = "\n-- end --",
        },
      })
      assert.equals("Review notes:\n", zdiff.config.comments.prefix)
      assert.equals("\n-- end --", zdiff.config.comments.suffix)
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
      assert.is_truthy(
        content:find("Add annotation"),
        "Help should contain annotation description"
      )
      assert.is_truthy(
        content:find("Yank annotations"),
        "Help should contain yank annotations description"
      )
      assert.is_truthy(content:find("Press any key"), "Help should contain footer")

      -- Clean up
      vim.api.nvim_win_close(float_win, true)
    end)
  end)

  describe("annotations", function()
    it("should add, yank, and delete annotations on mixed diff ranges", function()
      local repo = create_modified_repo()
      vim.cmd("cd " .. vim.fn.fnameescape(repo))

      zdiff.setup({ default_expanded = true })
      zdiff.open()
      wait_for_loaded(5000)

      local buf = vim.api.nvim_get_current_buf()
      local start_line = find_buffer_line(buf, "  beta")
      local end_line = find_buffer_line(buf, "  delta")
      assert.is_true(zdiff._debug_add_annotation(start_line, end_line, "Needs follow-up"))

      local dbg = zdiff._debug_state()
      assert.equals(1, dbg.annotation_count)
      assert.equals(1, dbg.rendered_annotation_count)
      assert.equals("yes:1", vim.wo[0].signcolumn)
      assert.equals("Needs follow-up", zdiff._debug_rendered_annotations()[1].label)

      local yank_cb = find_keymap_callback(buf, "yc")
      assert.is_not_nil(yank_cb, "Yank annotations keymap should be defined")
      yank_cb()

      local content = vim.fn.getreg('"')
      assert.is_truthy(content:find("^Feedback for changes:\n"))
      assert.is_truthy(content:find("example.txt:2%-4 Needs follow%-up"))

      local line = find_buffer_line(buf, "  beta changed")
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      local delete_cb = find_keymap_callback(buf, "d")
      assert.is_not_nil(delete_cb, "Delete annotation keymap should be defined")
      delete_cb()

      assert.equals(0, zdiff._debug_state().annotation_count)
    end)

    it("should show only annotated blocks and still allow goto source", function()
      local repo = create_modified_repo()
      vim.cmd("cd " .. vim.fn.fnameescape(repo))

      zdiff.setup({ default_expanded = true })
      zdiff.open()
      wait_for_loaded(5000)

      local buf = vim.api.nvim_get_current_buf()
      local annotated_line = find_buffer_line(buf, "  beta changed")
      assert.is_true(
        zdiff._debug_add_annotation(annotated_line, annotated_line, "Check this")
      )

      local toggle_cb = find_keymap_callback(buf, "h")
      assert.is_not_nil(toggle_cb, "Annotations-only keymap should be defined")
      toggle_cb()

      local dbg = zdiff._debug_state()
      assert.is_true(dbg.annotations_only)

      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local content = table.concat(lines, "\n")
      assert.is_truthy(content:find("%[annotations only%]"))
      assert.is_truthy(content:find("example.txt"))
      assert.is_truthy(content:find("  beta changed"))
      assert.is_falsy(content:find("  alpha", 1, true))
      assert.is_falsy(content:find("  gamma", 1, true))
      assert.is_falsy(content:find("  delta", 1, true))

      local visible_line = find_buffer_line(buf, "  beta changed")
      vim.api.nvim_win_set_cursor(0, { visible_line, 0 })
      local goto_cb = find_keymap_callback(buf, "<CR>")
      assert.is_not_nil(goto_cb, "Goto keymap should be defined")
      goto_cb()

      assert.is_truthy(vim.api.nvim_buf_get_name(0):match("example%.txt$"))
      assert.equals(2, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("should submit multiline annotations from the editor float", function()
      local repo = create_modified_repo()
      vim.cmd("cd " .. vim.fn.fnameescape(repo))

      zdiff.setup({ default_expanded = true })
      zdiff.open()
      wait_for_loaded(5000)

      local buf = vim.api.nvim_get_current_buf()
      local line = find_buffer_line(buf, "  beta")
      local editor = zdiff._debug_open_annotation_editor(line, line)
      assert.is_table(editor)
      assert.is_true(vim.api.nvim_win_is_valid(editor.win))
      assert.is_true(vim.api.nvim_buf_is_valid(editor.buf))

      vim.api.nvim_buf_set_lines(editor.buf, 0, -1, false, {
        "Needs follow-up.",
        "",
        "Please simplify this path.",
      })

      assert.is_true(zdiff._debug_submit_annotation_editor())

      local dbg = zdiff._debug_state()
      assert.equals(1, dbg.annotation_count)
      assert.is_false(dbg.annotation_editor_open)
      assert.equals(
        "Needs follow-up.\n\nPlease simplify this path.",
        zdiff._debug_rendered_annotations()[1].label
      )
    end)

    it("should cancel annotation editor without creating an annotation", function()
      local repo = create_modified_repo()
      vim.cmd("cd " .. vim.fn.fnameescape(repo))

      zdiff.setup({ default_expanded = true })
      zdiff.open()
      wait_for_loaded(5000)

      local buf = vim.api.nvim_get_current_buf()
      local line = find_buffer_line(buf, "  beta")
      local editor = zdiff._debug_open_annotation_editor(line, line)
      assert.is_table(editor)

      assert.is_true(zdiff._debug_cancel_annotation_editor())

      local dbg = zdiff._debug_state()
      assert.equals(0, dbg.annotation_count)
      assert.is_false(dbg.annotation_editor_open)
    end)

    it("should submit annotation editor with :write", function()
      local repo = create_modified_repo()
      vim.cmd("cd " .. vim.fn.fnameescape(repo))

      zdiff.setup({ default_expanded = true })
      zdiff.open()
      wait_for_loaded(5000)

      local buf = vim.api.nvim_get_current_buf()
      local line = find_buffer_line(buf, "  beta")
      local editor = zdiff._debug_open_annotation_editor(line, line)
      assert.is_table(editor)
      assert.is_true(vim.api.nvim_win_is_valid(editor.win))
      assert.is_true(vim.api.nvim_buf_is_valid(editor.buf))

      vim.api.nvim_buf_set_lines(editor.buf, 0, -1, false, { "Submitted via write" })
      vim.api.nvim_set_current_win(editor.win)
      vim.cmd("write")

      local dbg = zdiff._debug_state()
      assert.equals(1, dbg.annotation_count)
      assert.is_false(dbg.annotation_editor_open)
      assert.equals("Submitted via write", zdiff._debug_rendered_annotations()[1].label)
    end)

    it("should expose shift-enter submit in insert mode", function()
      local repo = create_modified_repo()
      vim.cmd("cd " .. vim.fn.fnameescape(repo))

      zdiff.setup({ default_expanded = true })
      zdiff.open()
      wait_for_loaded(5000)

      local buf = vim.api.nvim_get_current_buf()
      local line = find_buffer_line(buf, "  beta")
      local editor = zdiff._debug_open_annotation_editor(line, line)
      assert.is_table(editor)

      local submit_cb = find_keymap_callback(editor.buf, "<S-CR>", "i")
      assert.is_not_nil(submit_cb, "Shift-Enter insert-mode keymap should be defined")
      assert.is_true(zdiff._debug_cancel_annotation_editor())
    end)

    it("should support deleted-only annotations", function()
      local repo = create_deleted_repo()
      vim.cmd("cd " .. vim.fn.fnameescape(repo))

      zdiff.setup({ default_expanded = true })
      zdiff.open()
      wait_for_loaded(5000)

      local buf = vim.api.nvim_get_current_buf()
      local line = find_buffer_line(buf, "  one")
      assert.is_true(zdiff._debug_add_annotation(line, line, "Remove this"))

      local yank_cb = find_keymap_callback(buf, "yc")
      yank_cb()

      local content = vim.fn.getreg('"')
      assert.is_truthy(content:find("gone.txt:1%(deleted%) Remove this"))
    end)

    it("should respect configured annotation prefix and suffix", function()
      local repo = create_modified_repo()
      vim.cmd("cd " .. vim.fn.fnameescape(repo))

      zdiff.setup({
        default_expanded = true,
        comments = {
          prefix = "Review notes:\n",
          suffix = "\n-- end --",
        },
      })
      zdiff.open()
      wait_for_loaded(5000)

      local buf = vim.api.nvim_get_current_buf()
      local line = find_buffer_line(buf, "  beta")
      assert.is_true(zdiff._debug_add_annotation(line, line, "Keep this"))

      local yank_cb = find_keymap_callback(buf, "yc")
      yank_cb()

      local content = vim.fn.getreg('"')
      assert.equals("Review notes:\nexample.txt:2(deleted) Keep this\n-- end --", content)
    end)

    it("should persist annotations for the same diff target across reopen", function()
      local repo = create_modified_repo()
      vim.cmd("cd " .. vim.fn.fnameescape(repo))

      zdiff.setup({ default_expanded = true })
      zdiff.open()
      wait_for_loaded(5000)

      local buf = vim.api.nvim_get_current_buf()
      local line = find_buffer_line(buf, "  beta")
      assert.is_true(zdiff._debug_add_annotation(line, line, "Session note"))

      local close_cb = find_keymap_callback(buf, "q")
      assert.is_not_nil(close_cb, "Close keymap should be defined")
      close_cb()

      zdiff.open()
      wait_for_loaded(5000)

      local dbg = zdiff._debug_state()
      assert.equals(1, dbg.annotation_count)
      assert.equals(1, dbg.rendered_annotation_count)
    end)

    it("should preserve annotations when collapsing and re-expanding a file", function()
      local repo = create_modified_repo()
      vim.cmd("cd " .. vim.fn.fnameescape(repo))

      zdiff.setup({ default_expanded = true })
      zdiff.open()
      wait_for_loaded(5000)

      local buf = vim.api.nvim_get_current_buf()
      local line = find_buffer_line(buf, "  beta")
      assert.is_true(zdiff._debug_add_annotation(line, line, "Keep after collapse"))
      assert.equals(1, zdiff._debug_state().rendered_annotation_count)

      local file_header = find_buffer_line(buf, " ~ example.txt  +2 -1")
      vim.api.nvim_win_set_cursor(0, { file_header, 0 })
      local toggle_cb = find_keymap_callback(buf, "<Tab>")
      assert.is_not_nil(toggle_cb, "Toggle keymap should be defined")
      toggle_cb()

      assert.equals(1, zdiff._debug_state().annotation_count)
      assert.equals(0, zdiff._debug_state().rendered_annotation_count)

      toggle_cb()

      assert.equals(1, zdiff._debug_state().annotation_count)
      assert.equals(1, zdiff._debug_state().rendered_annotation_count)
    end)

    it("should scope annotations by diff target", function()
      local repo = create_two_commit_repo()
      vim.cmd("cd " .. vim.fn.fnameescape(repo))

      zdiff.setup({ default_expanded = true })
      zdiff.open()
      wait_for_loaded(5000)

      local line =
        find_buffer_line(vim.api.nvim_get_current_buf(), "  working tree change")
      assert.is_true(zdiff._debug_add_annotation(line, line, "Worktree only"))
      assert.equals(1, zdiff._debug_state().annotation_count)

      zdiff.open("HEAD~1")
      wait_for_loaded(5000)
      assert.equals("ref:HEAD~1", zdiff._debug_state().current_session)
      assert.equals(0, zdiff._debug_state().annotation_count)

      zdiff.open()
      wait_for_loaded(5000)
      assert.equals("worktree", zdiff._debug_state().current_session)
      assert.equals(1, zdiff._debug_state().annotation_count)
      assert.equals(1, zdiff._debug_state().rendered_annotation_count)
    end)
  end)

  describe("yank_ref", function()
    it("should preserve original file:range output across hunks", function()
      local repo = create_multihunk_repo()
      vim.cmd("cd " .. vim.fn.fnameescape(repo))

      zdiff.setup({ default_expanded = true })
      zdiff.open()
      wait_for_loaded(5000)

      local buf = vim.api.nvim_get_current_buf()
      local start_line = find_buffer_line(buf, "  line 2")
      local end_line = find_buffer_line(buf, "  line 10 changed")

      local yank_cb = find_keymap_callback(buf, "gy")
      assert.is_not_nil(yank_cb, "Yank reference keymap should be defined")

      vim.fn.setpos("'<", { 0, start_line, 1, 0 })
      vim.fn.setpos("'>", { 0, end_line, 1, 0 })
      _G.yank_ref_visual()

      local content = vim.fn.getreg('"')
      assert.equals("multi.txt:2-5, 7-10", content)
    end)
  end)
end)
