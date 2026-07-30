local syntax = require("zdiff.syntax")

describe("zdiff syntax", function()
  it("silently skips files without a parser", function()
    local highlights = syntax.highlights({
      {
        path = "one.zdiff-no-parser",
        patch = { { lines = { { kind = "add", text = "new" } } } },
      },
    }, { { { 4 } } })

    assert.same({}, highlights)
  end)

  it("projects new and deleted source captures onto patch rows", function()
    local parser_ok = pcall(vim.treesitter.get_string_parser, "", "lua")
    local query_ok, query = pcall(vim.treesitter.query.get, "lua", "highlights")
    if not parser_ok or not query_ok or not query then
      return
    end

    local highlights = syntax.highlights({
      {
        path = "one.lua",
        patch = {
          {
            lines = {
              { kind = "delete", text = "local old = true" },
              { kind = "add", text = "local new = false" },
              { kind = "context", text = "return new" },
            },
          },
        },
      },
    }, { { { 7, 8, 9 } } })

    local keyword_lines = {}
    for _, highlight in ipairs(highlights) do
      if vim.startswith(highlight.group, "@keyword") then
        keyword_lines[highlight.line] = true
      end
    end
    assert.is_true(keyword_lines[7])
    assert.is_true(keyword_lines[8])
    assert.is_true(keyword_lines[9])
  end)
end)
