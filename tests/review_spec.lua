local review = require("zdiff.review")

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
end)
