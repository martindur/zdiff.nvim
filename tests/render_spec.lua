local render = require("zdiff.render")

describe("zdiff renderer", function()
  it("keeps the file overview compact", function()
    local result = render.render({
      files = {
        { path = "one.lua", status = "M", additions = 2, deletions = 1 },
        { path = "two.lua", status = "?", additions = 3, deletions = 0 },
      },
    })
    assert.same({
      "Uncommitted changes",
      "",
      "one.lua  +2 -1",
      "two.lua  +3 -0",
    }, result.lines)
    assert.equals(1, result.file_lines[3])
    assert.equals(2, result.file_lines[4])
    assert.same({
      { line = 1, group = "Title", start_col = 0, end_col = -1 },
      { line = 3, group = "Directory", start_col = 0, end_col = 7 },
      { line = 3, group = "DiffAdd", start_col = 9, end_col = 11 },
      { line = 3, group = "DiffDelete", start_col = 12, end_col = -1 },
      { line = 4, group = "DiffAdd", start_col = 0, end_col = -1 },
    }, result.highlights)
  end)

  it("renders plain patch text with source targets", function()
    local result = render.render({
      files = {
        {
          path = "one.lua",
          status = "M",
          additions = 1,
          deletions = 1,
          expanded = true,
          patch = {
            {
              header = "@@ -2,2 +2,2 @@",
              lines = {
                { kind = "delete", text = "old", old_line = 2 },
                { kind = "add", text = "new", new_line = 2 },
              },
            },
          },
        },
      },
    })
    assert.equals("old", result.lines[5])
    assert.equals("new", result.lines[6])
    assert.is_true(result.sources[5].deleted)
    assert.equals(2, result.sources[6].line)
    assert.equals(1, result.file_at_line[4])
    assert.equals(1, result.file_at_line[5])
  end)

  it("separates distinct hunks with one blank line", function()
    local result = render.render({
      files = {
        {
          path = "one.lua",
          status = "M",
          additions = 2,
          deletions = 0,
          expanded = true,
          patch = {
            { header = "@@ -1 +1 @@", lines = { { kind = "add", text = "one" } } },
            { header = "@@ -9 +9 @@", lines = { { kind = "add", text = "nine" } } },
          },
        },
      },
    })
    assert.same({
      "Uncommitted changes",
      "",
      "one.lua  +2 -0",
      "@@ -1 +1 @@",
      "one",
      "",
      "@@ -9 +9 @@",
      "nine",
    }, result.lines)
  end)

  it("names a base comparison", function()
    local result = render.render({ base = "main", files = {} })
    assert.equals("Changes since main", result.lines[1])
  end)

  it("highlights added and deleted files across the full row", function()
    local result = render.render({
      files = {
        { path = "added.lua", status = "A", additions = 4, deletions = 0 },
        { path = "deleted.lua", status = "D", additions = 0, deletions = 8 },
      },
    })
    assert.same({
      { line = 1, group = "Title", start_col = 0, end_col = -1 },
      { line = 3, group = "DiffAdd", start_col = 0, end_col = -1 },
      { line = 4, group = "DiffDelete", start_col = 0, end_col = -1 },
    }, result.highlights)
  end)
end)
