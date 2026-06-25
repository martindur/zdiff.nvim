local patch = require("zdiff.patch")

describe("patch parser", function()
  it("parses whole patches into files with stats", function()
    local files = patch.parse({
      "diff --git a/a.txt b/a.txt",
      "index 111..222 100644",
      "--- a/a.txt",
      "+++ b/a.txt",
      "@@ -1,2 +1,2 @@",
      " same",
      "-old",
      "+new",
      "diff --git a/new.txt b/new.txt",
      "new file mode 100644",
      "--- /dev/null",
      "+++ b/new.txt",
      "@@ -0,0 +1 @@",
      "+hi",
    })

    assert.equals(2, #files)
    assert.equals("a.txt", files[1].path)
    assert.equals("M", files[1].status)
    assert.equals(1, files[1].insertions)
    assert.equals(1, files[1].deletions)
    assert.equals("A", files[2].status)
    assert.equals("new.txt", files[2].path)
    assert.equals(1, files[2].insertions)
    assert.equals(0, files[2].deletions)
  end)
end)
