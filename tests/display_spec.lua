local display = require("zdiff.display")

describe("display", function()
  it("uses status icons for added, deleted, and modified files", function()
    local icons = {
      added = "+",
      deleted = "-",
      modified = "~",
    }

    assert.equals("+", display.get_status_icon("A", icons))
    assert.equals("+", display.get_status_icon("?", icons))
    assert.equals("-", display.get_status_icon("D", icons))
    assert.equals("~", display.get_status_icon("M", icons))
  end)

  it("formats file rows with stat highlight ranges", function()
    local row = display.format_file_line({
      icon = ">",
      status_icon = "~",
      path = "lua/zdiff/review.lua",
      additions = 12,
      deletions = 3,
    })

    assert.equals("> ~ lua/zdiff/review.lua  +12 -3", row.text)
    assert.equals("+12", row.text:sub(row.add_start + 1, row.add_end))
    assert.equals("-3", row.text:sub(row.del_start + 1, row.del_end))
  end)

  it("formats hunk headers and diff highlights", function()
    local hunk = {
      old_start = 1,
      old_count = 2,
      new_start = 3,
      new_count = 4,
    }

    assert.equals("  @@ -1,2 +3,4 @@", display.format_hunk_header(hunk, "  "))
    assert.equals("DiffAdd", display.get_line_highlight("add"))
    assert.equals("DiffDelete", display.get_line_highlight("del"))
    assert.equals("Normal", display.get_line_highlight("context"))
  end)
end)
