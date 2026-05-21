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
  it("resolves common JavaScript and TypeScript filetypes without extension aliases", function()
    local original_get_lang = vim.treesitter.language.get_lang
    local original_has_highlights = syntax.has_highlights
    vim.treesitter.language.get_lang = function(ft)
      return ({ javascript = "javascript", typescript = "typescript" })[ft]
    end
    syntax.has_highlights = function(lang)
      return lang == "javascript" or lang == "typescript"
    end

    local ok, err = pcall(function()
      assert.equals("javascript", syntax.get_lang_from_filetype("javascript"))
      assert.equals("typescript", syntax.get_lang_from_filetype("typescript"))
    end)

    vim.treesitter.language.get_lang = original_get_lang
    syntax.has_highlights = original_has_highlights
    assert.is_true(ok, err)
  end)

  it("falls back for React filetypes when dedicated parsers are unavailable", function()
    local original_get_lang = vim.treesitter.language.get_lang
    local original_has_highlights = syntax.has_highlights
    vim.treesitter.language.get_lang = function(ft)
      return ({
        javascriptreact = "javascriptreact",
        javascript = "javascript",
        typescriptreact = "typescriptreact",
        tsx = "tsx",
        typescript = "typescript",
      })[ft]
    end
    syntax.has_highlights = function(lang)
      return lang == "javascript" or lang == "typescript"
    end

    local ok, err = pcall(function()
      assert.equals("javascript", syntax.get_lang_from_filetype("javascriptreact"))
      assert.equals("typescript", syntax.get_lang_from_filetype("typescriptreact"))
    end)

    vim.treesitter.language.get_lang = original_get_lang
    syntax.has_highlights = original_has_highlights
    assert.is_true(ok, err)
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
