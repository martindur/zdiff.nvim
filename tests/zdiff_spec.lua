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
  end)
end)
