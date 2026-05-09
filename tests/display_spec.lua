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
end)
