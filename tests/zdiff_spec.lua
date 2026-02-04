local zdiff = require("zdiff")

describe("zdiff", function()
  before_each(function()
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
  end)

  describe("setup", function()
    it("should use default config when called without arguments", function()
      zdiff.setup()
      assert.equals(false, zdiff.config.default_expanded)
      assert.equals("main", zdiff.config.default_branch)
      assert.equals("<CR>", zdiff.config.keymaps.goto_file)
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
      assert.is_true(vim.api.nvim_win_is_valid(float_win), "Help window should remain open")

      -- Check buffer content contains expected text
      local lines = vim.api.nvim_buf_get_lines(help_buf, 0, -1, false)
      local content = table.concat(lines, "\n")

      assert.is_truthy(content:find("zdiff keymaps"), "Help should contain title")
      assert.is_truthy(content:find("Go to file"), "Help should contain goto_file description")
      assert.is_truthy(content:find("Toggle"), "Help should contain toggle description")
      assert.is_truthy(content:find("Close"), "Help should contain close description")
      assert.is_truthy(content:find("Press any key"), "Help should contain footer")

      -- Clean up
      vim.api.nvim_win_close(float_win, true)
    end)
  end)
end)
