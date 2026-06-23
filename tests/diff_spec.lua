local diff = require("zdiff.diff")

describe("diff parser", function()
  it("parses hunks and ignores diff metadata lines", function()
    local hunks = diff.parse_hunks({
      "@@ -2,2 +2,2 @@",
      " keep",
      "-old",
      "+new",
      "\\ No newline at end of file",
    })

    assert.equals(1, #hunks)
    assert.equals(2, hunks[1].old_start)
    assert.equals(2, hunks[1].new_start)
    assert.equals(3, #hunks[1].lines)
    assert.equals("context", hunks[1].lines[1].type)
    assert.equals(2, hunks[1].lines[1].old_lnum)
    assert.equals(2, hunks[1].lines[1].new_lnum)
    assert.equals("del", hunks[1].lines[2].type)
    assert.equals(3, hunks[1].lines[2].old_lnum)
    assert.equals("add", hunks[1].lines[3].type)
    assert.equals(3, hunks[1].lines[3].new_lnum)
  end)

  it("builds one new-file hunk for untracked lines", function()
    local hunks = diff.untracked_hunks({ "one", "two" })

    assert.equals(1, #hunks)
    assert.equals(0, hunks[1].old_count)
    assert.equals(2, hunks[1].new_count)
    assert.equals("add", hunks[1].lines[1].type)
    assert.equals(1, hunks[1].lines[1].new_lnum)
    assert.equals("two", hunks[1].lines[2].text)
  end)
end)
