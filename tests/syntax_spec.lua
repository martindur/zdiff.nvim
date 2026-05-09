local fixtures = require("tests.helpers.syntax_fixtures")
local zdiff = require("zdiff")

local function syntax_marks_for_line(buf, ns, row)
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  local found = {}
  for _, mark in ipairs(marks) do
    if mark[2] == row then
      table.insert(found, mark)
    end
  end
  return found
end

local function line_with_probe(buf, probe)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for idx, line in ipairs(lines) do
    if line:find(probe, 1, true) then
      return idx - 1, line
    end
  end
  return nil, nil
end

describe("syntax highlighting", function()
  local plugin_root

  before_each(function()
    plugin_root = vim.fn.getcwd()
  end)

  after_each(function()
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

  it("renders treesitter syntax extmarks for changed fixture files", function()
    local repo = fixtures.create_repo()
    vim.cmd("cd " .. vim.fn.fnameescape(repo))

    zdiff.setup({
      default_expanded = true,
      syntax = {
        mode = "projection",
        max_lines = 0,
      },
    })

    zdiff.open()
    fixtures.wait_for_loaded(10000)
    fixtures.wait_for_syntax_idle(10000)

    local buf = vim.api.nvim_get_current_buf()
    local ns = vim.api.nvim_get_namespaces().zdiff_syntax
    assert.is_not_nil(ns, "zdiff_syntax namespace should exist")

    local checked = 0
    local skipped = {}

    for _, file in ipairs(fixtures.files) do
      local available, lang = fixtures.lang_available(file.path)
      if available then
        local row, line = line_with_probe(buf, file.probe)
        assert.is_not_nil(row, "expected rendered probe for " .. file.path)

        local marks = syntax_marks_for_line(buf, ns, row)
        assert.is_true(
          #marks > 0,
          string.format("expected syntax extmarks on %s probe line %q", file.path, line)
        )
        checked = checked + 1
      else
        table.insert(skipped, string.format("%s (%s)", file.path, lang or "no filetype"))
      end
    end

    assert.is_true(
      checked > 0,
      "no fixture languages had installed treesitter parsers/queries; skipped: "
        .. table.concat(skipped, ", ")
    )
  end)
end)
