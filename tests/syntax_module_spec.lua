local syntax = require("zdiff.syntax")

local function has_group(highlights, group)
  for _, hl in ipairs(highlights) do
    if hl.hl_group == group then
      return true
    end
  end
  return false
end

describe("syntax module", function()
  it("prefers native tree-sitter languages before aliases", function()
    local native = vim.treesitter.language.get_lang("javascript")
    if not native or not syntax.has_highlights(native) then
      pending("javascript treesitter highlights are not available")
      return
    end

    assert.equals(native, syntax.get_lang_from_filetype("javascript"))
  end)

  it("adds injected highlights for markdown fenced code blocks", function()
    if
      not syntax.get_lang_from_filetype("markdown")
      or not syntax.get_lang_from_filetype("lua")
    then
      pending("markdown or lua treesitter highlights are not available")
      return
    end

    local highlights = syntax.get_highlights({
      "# Example",
      "",
      "```lua",
      "require('zdiff').setup({ default_expanded = true })",
      "```",
      "",
      "```json",
      "{",
      '  "enabled": true',
      "}",
      "```",
      "",
      "```bash",
      "set -euo pipefail",
      "echo ready",
      "```",
    }, "markdown")

    assert.is_true(has_group(highlights, "@markup.raw.block"))
    assert.is_true(has_group(highlights, "@function.call"))
    if syntax.get_lang_from_filetype("json") then
      assert.is_true(has_group(highlights, "@boolean"))
    end
  end)

  it("adds injected sql highlights for python query strings", function()
    if
      not syntax.get_lang_from_filetype("python")
      or not syntax.get_lang_from_filetype("sql")
    then
      pending("python or sql treesitter highlights are not available")
      return
    end

    local highlights = syntax.get_highlights({
      'USER_QUERY = """',
      "SELECT id, COALESCE(display_name, name) AS label",
      "FROM users",
      "WHERE active = TRUE",
      '"""',
    }, "python")

    assert.is_true(has_group(highlights, "@keyword"))
  end)
end)
