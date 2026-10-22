local model = require("zdiff.model")

describe("zdiff model", function()
  it("loads a patch once and toggles expansion", function()
    local value = model.new({ files = { { path = "one.lua" } } })
    local loads = 0
    assert.is_true(model.toggle_file(value, 1, function()
      loads = loads + 1
      return {}
    end))
    assert.is_true(value.files[1].expanded)
    assert.is_true(model.toggle_file(value, 1, function()
      loads = loads + 1
      return {}
    end))
    assert.is_false(value.files[1].expanded)
    assert.equals(1, loads)
  end)
end)
