local lens = require("zdiff.lens")

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

describe("zdiff.lens", function()
  local buf

  before_each(function()
    lens.setup({
      auto_attach = false,
      virtual_deleted = true,
      debounce_ms = 10,
    })
    buf = vim.api.nvim_create_buf(false, true)
  end)

  after_each(function()
    lens.detach(buf)
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("parses unified diff hunks", function()
    local hunks = lens._debug.parse_diff_hunks({
      "@@ -1,2 +1,2 @@",
      "-old",
      "+new",
      " context",
    })

    assert.equals(1, #hunks)
    assert.equals("del", hunks[1].lines[1].type)
    assert.equals("old", hunks[1].lines[1].text)
    assert.equals(1, hunks[1].lines[1].old_lnum)
    assert.equals("add", hunks[1].lines[2].type)
    assert.equals(1, hunks[1].lines[2].new_lnum)
    assert.equals("context", hunks[1].lines[3].type)
    assert.equals(2, hunks[1].lines[3].new_lnum)
  end)

  it("applies added highlights and deleted virtual lines", function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "new",
      "context",
    })

    lens._debug.apply_hunks(buf, {
      {
        old_start = 1,
        old_count = 2,
        new_start = 1,
        new_count = 2,
        lines = {
          { type = "del", text = "old", old_lnum = 1 },
          { type = "add", text = "new", new_lnum = 1 },
          { type = "context", text = "context", old_lnum = 2, new_lnum = 2 },
        },
      },
    })

    local ns = vim.api.nvim_get_namespaces().zdiff_lens
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local has_add = false
    local has_del = false

    for _, mark in ipairs(marks) do
      local details = mark[4] or {}
      if details.line_hl_group == "DiffAdd" then
        has_add = true
      end
      for _, virt_line in ipairs(details.virt_lines or {}) do
        for _, chunk in ipairs(virt_line) do
          if chunk[1] == "old" and chunk[2] == "DiffDelete" then
            has_del = true
          end
        end
      end
    end

    assert.is_true(has_add)
    assert.is_true(has_del)
  end)

  it("attaches to a normal file buffer in a git repo", function()
    local repo = vim.fn.tempname()
    vim.fn.mkdir(repo, "p")
    run_sync("git init", repo)
    run_sync("git config user.name 'zdiff-test'", repo)
    run_sync("git config user.email 'zdiff@example.com'", repo)
    vim.fn.writefile({ "old", "context" }, repo .. "/a.txt")
    run_sync("git add . && git commit -m baseline", repo)
    vim.fn.writefile({ "new", "context" }, repo .. "/a.txt")

    vim.api.nvim_buf_delete(buf, { force = true })
    vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/a.txt"))
    buf = vim.api.nvim_get_current_buf()

    assert.is_true(lens.attach(buf))

    local ns = vim.api.nvim_get_namespaces().zdiff_lens
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
    assert.is_true(#marks > 0)
  end)
end)
