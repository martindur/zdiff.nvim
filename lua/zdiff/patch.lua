local M = {}
local diff = require("zdiff.diff")

---@class ZdiffPatchFile
---@field path string current relative file path, or old path for deleted files
---@field display_path string path shown in the UI
---@field old_path string|nil old-side relative file path
---@field new_path string|nil new-side relative file path
---@field status string git status (M, A, D, R)
---@field insertions number lines added
---@field deletions number lines deleted
---@field hunks ZdiffHunk[] parsed diff hunks

---@param raw string
---@return string|nil
local function normalize_path(raw)
  raw = raw:gsub("\t.*$", "")
  if raw == "/dev/null" then
    return nil
  end
  return raw:gsub("^[ab]/", "")
end

---@param file {old_path: string|nil, new_path: string|nil, saw_old_path: boolean, saw_new_path: boolean, fallback_old_path: string|nil, fallback_new_path: string|nil, hunk_lines: string[]}
---@return ZdiffPatchFile
local function finish_file(file)
  local old_path = file.fallback_old_path
  if file.saw_old_path then
    old_path = file.old_path
  end

  local new_path = file.fallback_new_path
  if file.saw_new_path then
    new_path = file.new_path
  end

  local status = "M"
  if not old_path then
    status = "A"
  elseif not new_path then
    status = "D"
  elseif old_path ~= new_path then
    status = "R"
  end

  local hunks = diff.parse_hunks(file.hunk_lines)
  local insertions = 0
  local deletions = 0
  for _, hunk in ipairs(hunks) do
    for _, line in ipairs(hunk.lines) do
      if line.type == "add" then
        insertions = insertions + 1
      elseif line.type == "del" then
        deletions = deletions + 1
      end
    end
  end

  local path = new_path or old_path or ""
  local display_path = path
  if old_path and new_path and old_path ~= new_path then
    display_path = old_path .. " -> " .. new_path
  end

  return {
    path = path,
    display_path = display_path,
    old_path = old_path,
    new_path = new_path,
    status = status,
    insertions = insertions,
    deletions = deletions,
    hunks = hunks,
  }
end

---@param patch_lines string[]
---@return ZdiffPatchFile[]
function M.parse(patch_lines)
  local files = {}
  local current = nil
  local in_hunks = false

  local function finish_current()
    if current then
      table.insert(files, finish_file(current))
      current = nil
      in_hunks = false
    end
  end

  for _, line in ipairs(patch_lines) do
    if line:match("^diff %-%-git ") then
      finish_current()
      local old_path, new_path = line:match("^diff %-%-git a/(.-) b/(.+)$")
      current = {
        old_path = nil,
        new_path = nil,
        saw_old_path = false,
        saw_new_path = false,
        fallback_old_path = old_path,
        fallback_new_path = new_path,
        hunk_lines = {},
      }
    elseif current then
      if line:match("^%-%-%- ") then
        current.old_path = normalize_path(line:sub(5))
        current.saw_old_path = true
      elseif line:match("^%+%+%+ ") then
        current.new_path = normalize_path(line:sub(5))
        current.saw_new_path = true
      elseif line:match("^@@") then
        in_hunks = true
        table.insert(current.hunk_lines, line)
      elseif in_hunks then
        table.insert(current.hunk_lines, line)
      end
    end
  end

  finish_current()
  return files
end

return M
