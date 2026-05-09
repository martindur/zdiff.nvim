local winbar = require("zdiff.winbar")

describe("winbar", function()
  local icons = {
    added = "+",
    deleted = "-",
    modified = "~",
  }

  it("formats a file header with escaped filename percent signs", function()
    local header = winbar.format_file({
      path = "lua/100%/file.lua",
      status = "M",
      insertions = 12,
      deletions = 3,
    }, icons)

    assert.equals(
      "%#Directory# ~ lua/100%%/file.lua  %#DiffAdd#+12%* %#DiffDelete#-3%*",
      header
    )
  end)

  it("returns the file only after its header has scrolled off the top", function()
    local files = {
      { path = "a.lua" },
      { path = "b.lua" },
    }
    local line_map = {
      [3] = { file_idx = 1 },
      [4] = { file_idx = 1, hunk_idx = 1 },
      [8] = { file_idx = 2 },
      [9] = { file_idx = 2, hunk_idx = 1 },
    }
    local file_header_lines = {
      [1] = 3,
      [2] = 8,
    }

    assert.is_nil(winbar.file_for_topline(3, line_map, file_header_lines, files))
    assert.equals(
      files[1],
      winbar.file_for_topline(4, line_map, file_header_lines, files)
    )
    assert.is_nil(winbar.file_for_topline(8, line_map, file_header_lines, files))
    assert.equals(
      files[2],
      winbar.file_for_topline(9, line_map, file_header_lines, files)
    )
  end)
end)
