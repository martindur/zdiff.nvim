local fixture = require("tests.helpers.review_fixture")
local git = require("zdiff.git")

describe("review fixture", function()
  it("provides real Git changes covering review states and separated hunks", function()
    local repo = fixture.create_repo()
    local changes = assert(git.changes(repo))
    local statuses = {}
    for _, file in ipairs(changes.files) do
      statuses[file.path] = file.status
      if file.path == "lua/waypoint/init.lua" then
        assert.equals(2, #assert(git.patch(repo, changes.target, file)))
      elseif file.path == "doc/waypoint.txt" then
        assert.equals("doc/locations.txt", file.old_path)
        assert.equals(1, #assert(git.patch(repo, changes.target, file)))
      end
    end
    assert.same({
      ["README.md"] = "M",
      ["doc/waypoint.txt"] = "R",
      ["examples/locations.lua"] = "?",
      ["lua/waypoint/init.lua"] = "M",
      ["lua/waypoint/legacy.lua"] = "D",
      ["lua/waypoint/storage.lua"] = "A",
      ["waypoint.json"] = "M",
    }, statuses)
    assert.equals("main", assert(git.changes(repo, "main")).base)
  end)
end)
