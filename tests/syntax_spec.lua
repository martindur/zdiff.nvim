local fixtures = require("tests.helpers.syntax_fixtures")
local zdiff = require("zdiff")
local syntax_marks = require("tests.helpers.syntax_marks")

local function is_file_header(line, fixtures_files)
  for _, file in ipairs(fixtures_files) do
    if line:find(file.path, 1, true) then
      return true
    end
  end
  return false
end

local function line_with_probe(buf, path, probe)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local start_idx = nil

  for idx, line in ipairs(lines) do
    if line:find(path, 1, true) then
      start_idx = idx + 1
      break
    end
  end

  if not start_idx then
    return nil, nil
  end

  for idx = start_idx, #lines do
    local line = lines[idx]
    if is_file_header(line, fixtures.files) then
      return nil, nil
    end
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
    local dbg = zdiff._debug_state()
    local syntax = dbg.syntax or {}
    local projected_files = syntax.projected_files or {}
    local fallback_files = syntax.fallback_files or {}

    for _, file in ipairs(fixtures.files) do
      local available, lang = fixtures.lang_available(file.path)
      if available then
        local row, line = line_with_probe(buf, file.path, file.probe)
        assert.is_not_nil(row, "expected rendered probe for " .. file.path)

        local marks = syntax_marks.for_line(buf, ns, row)
        assert.is_true(
          #marks > 0,
          string.format("expected syntax extmarks on %s probe line %q", file.path, line)
        )
        assert.is_true(
          vim.tbl_contains(projected_files, file.path),
          "expected projection syntax for " .. file.path
        )
        assert.is_false(
          vim.tbl_contains(fallback_files, file.path),
          "expected no hunk fallback after projection settled for " .. file.path
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

    local markdown_available = fixtures.lang_available("docs/example.md")
    local lua_available = fixtures.lang_available("src/example.lua")
    if markdown_available and lua_available then
      local row, line = line_with_probe(buf, "docs/example.md", "require('zdiff')")
      assert.is_not_nil(row, "expected rendered markdown lua fence line")

      local marks = syntax_marks.for_line(buf, ns, row)
      assert.is_true(
        syntax_marks.has_group(marks, "@function.call"),
        string.format("expected injected lua captures on markdown fence line %q", line)
      )
    end
  end)
end)
