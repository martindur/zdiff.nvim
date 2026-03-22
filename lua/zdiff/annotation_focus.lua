local M = {}

---@param files table[]
---@param annotations table[]
---@param ensure_hunks fun(file: table): table[]
---@return table<number, table<number, table<number, boolean>>>
function M.collect_visibility(files, annotations, ensure_hunks)
  local visible = {}

  for _, annotation in ipairs(annotations) do
    for file_idx, file in ipairs(files) do
      if file.path == annotation.file_path then
        local hunks = ensure_hunks(file)
        local anchor_len = #annotation.anchor_lines

        for hunk_idx, hunk in ipairs(hunks) do
          local hunk_lines = hunk.lines
          if anchor_len > 0 and #hunk_lines >= anchor_len then
            for line_idx = 1, (#hunk_lines - anchor_len + 1) do
              local matched = true
              for offset = 1, anchor_len do
                local expected = annotation.anchor_lines[offset]
                local actual = hunk_lines[line_idx + offset - 1]
                if
                  not actual
                  or actual.type ~= expected.type
                  or actual.old_lnum ~= expected.old_lnum
                  or actual.new_lnum ~= expected.new_lnum
                then
                  matched = false
                  break
                end
              end

              if matched then
                visible[file_idx] = visible[file_idx] or {}
                visible[file_idx][hunk_idx] = visible[file_idx][hunk_idx] or {}
                for offset = 0, anchor_len - 1 do
                  visible[file_idx][hunk_idx][line_idx + offset] = true
                end
                break
              end
            end
          end
        end
      end
    end
  end

  return visible
end

return M
