local M = {}

-- State
---@class ZdiffFile
---@field path string relative file path
---@field status string git status (M, A, D, etc.)
---@field insertions number lines added
---@field deletions number lines deleted
---@field expanded boolean whether file is expanded
---@field hunks ZdiffHunk[] parsed diff hunks

---@class ZdiffHunk
---@field old_start number starting line in old file
---@field old_count number number of lines in old file
---@field new_start number starting line in new file
---@field new_count number number of lines in new file
---@field lines ZdiffLine[] individual diff lines

---@class ZdiffLine
---@field type "context"|"add"|"del"|"header" line type
---@field text string the line content (without +/- prefix)
---@field new_lnum number|nil line number in new file (for context/add lines)
---@field old_lnum number|nil line number in old file (for context/del lines)

---@class ZdiffState
---@field files ZdiffFile[]
---@field buf number|nil buffer handle
---@field win number|nil window handle
---@field base_ref string|nil the git ref to diff against (nil = uncommitted changes vs HEAD)
---@field line_map table<number, {file_idx: number, hunk_idx: number|nil, line_idx: number|nil, lnum: number|nil}>

---@type ZdiffState
local state = {
  files = {},
  buf = nil,
  win = nil,
  base_ref = nil,
  line_map = {},
}

-- Forward declarations
local goto_source
local toggle_expand
local toggle_mode
local show_help

-- Configuration
---@class ZdiffConfig
---@field default_expanded boolean Whether files are expanded by default
---@field default_branch string|nil Default branch for toggle_mode (e.g., "main", "develop")
---@field keymaps table<string, string> Keymap bindings
---@field icons table<string, string> Icons for UI elements

---@type ZdiffConfig
M.config = {
  default_expanded = false,
  default_branch = "main",
  keymaps = {
    goto_file = "<CR>",
    toggle = "<Tab>",
    close = "q",
    refresh = "R",
    toggle_mode = "m",
    help = "?",
  },
  icons = {
    collapsed = "",
    expanded = "",
    added = "+",
    deleted = "-",
    modified = "~",
  },
}

---Send a notification with zdiff prefix
---@param msg string
---@param level? number vim.log.levels value
local function notify(msg, level)
  vim.notify("[zdiff] " .. msg, level or vim.log.levels.INFO)
end

---Get the git root directory
---@return string|nil
local function get_git_root()
  local result = vim.fn.systemlist("git rev-parse --show-toplevel")
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return result[1]
end

---Parse the diff stat output to get file statistics
---@param base_ref string|nil git ref to diff against, or nil for uncommitted
---@return table<string, {insertions: number, deletions: number, status: string}>
local function get_diff_stats(base_ref)
  local cmd
  if base_ref then
    cmd = "git diff --numstat " .. vim.fn.shellescape(base_ref) .. "...HEAD"
  else
    cmd = "git diff --numstat HEAD"
  end

  local stats = {}
  local result = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return stats
  end

  for _, line in ipairs(result) do
    local ins, del, path = line:match("^(%d+)%s+(%d+)%s+(.+)$")
    if path then
      stats[path] = {
        insertions = tonumber(ins) or 0,
        deletions = tonumber(del) or 0,
        status = "M",
      }
    end
  end

  -- Get status for each file
  local status_cmd
  if base_ref then
    status_cmd = "git diff --name-status " .. vim.fn.shellescape(base_ref) .. "...HEAD"
  else
    status_cmd = "git diff --name-status HEAD"
  end

  local status_result = vim.fn.systemlist(status_cmd)
  for _, line in ipairs(status_result) do
    local status, path = line:match("^(%a)%s+(.+)$")
    if path and stats[path] then
      stats[path].status = status
    elseif path then
      stats[path] = { insertions = 0, deletions = 0, status = status }
    end
  end

  return stats
end

---Parse a unified diff hunk header
---@param header string the @@ line
---@return number old_start, number old_count, number new_start, number new_count
local function parse_hunk_header(header)
  local old_start, old_count, new_start, new_count =
    header:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
  return tonumber(old_start) or 0,
    tonumber(old_count) or 1,
    tonumber(new_start) or 0,
    tonumber(new_count) or 1
end

---Parse diff output for a single file into hunks
---@param diff_lines string[]
---@return ZdiffHunk[]
local function parse_diff_hunks(diff_lines)
  local hunks = {}
  local current_hunk = nil
  local old_lnum, new_lnum = 0, 0

  for _, line in ipairs(diff_lines) do
    if line:match("^@@") then
      -- New hunk
      if current_hunk then
        table.insert(hunks, current_hunk)
      end
      local old_start, old_count, new_start, new_count = parse_hunk_header(line)
      old_lnum = old_start
      new_lnum = new_start
      current_hunk = {
        old_start = old_start,
        old_count = old_count,
        new_start = new_start,
        new_count = new_count,
        lines = {},
      }
    elseif current_hunk then
      local diff_line = {
        text = line:sub(2), -- Remove the +/- prefix
        type = "context",
        new_lnum = nil,
        old_lnum = nil,
      }

      if line:match("^%+") then
        diff_line.type = "add"
        diff_line.new_lnum = new_lnum
        new_lnum = new_lnum + 1
      elseif line:match("^%-") then
        diff_line.type = "del"
        diff_line.old_lnum = old_lnum
        old_lnum = old_lnum + 1
      elseif line:match("^ ") or line == "" then
        diff_line.type = "context"
        diff_line.new_lnum = new_lnum
        diff_line.old_lnum = old_lnum
        new_lnum = new_lnum + 1
        old_lnum = old_lnum + 1
      end

      table.insert(current_hunk.lines, diff_line)
    end
  end

  if current_hunk then
    table.insert(hunks, current_hunk)
  end

  return hunks
end

---Get diff hunks for a specific file
---@param filepath string
---@param base_ref string|nil git ref to diff against, or nil for uncommitted
---@return ZdiffHunk[]
local function get_file_diff(filepath, base_ref)
  local cmd
  if base_ref then
    cmd = string.format("git diff %s...HEAD -- %s", vim.fn.shellescape(base_ref), vim.fn.shellescape(filepath))
  else
    cmd = string.format("git diff HEAD -- %s", vim.fn.shellescape(filepath))
  end

  local result = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return {}
  end

  return parse_diff_hunks(result)
end

---Load all changed files and their stats
---@param base_ref string|nil git ref to diff against, or nil for uncommitted
---@return ZdiffFile[]
local function load_files(base_ref)
  local stats = get_diff_stats(base_ref)
  local files = {}

  for path, info in pairs(stats) do
    table.insert(files, {
      path = path,
      status = info.status,
      insertions = info.insertions,
      deletions = info.deletions,
      expanded = M.config.default_expanded,
      hunks = {},
    })
  end

  -- Sort by path
  table.sort(files, function(a, b)
    return a.path < b.path
  end)

  return files
end

---Get the status icon for a file
---@param status string
---@return string
local function get_status_icon(status)
  if status == "A" then
    return M.config.icons.added
  elseif status == "D" then
    return M.config.icons.deleted
  else
    return M.config.icons.modified
  end
end

---Get highlight group for diff line type
---@param line_type "context"|"add"|"del"|"header"
---@return string
local function get_line_highlight(line_type)
  if line_type == "add" then
    return "DiffAdd"
  elseif line_type == "del" then
    return "DiffDelete"
  elseif line_type == "header" then
    return "Title"
  else
    return "Normal"
  end
end

---Get the treesitter language for a file path
---@param filepath string
---@return string|nil
local function get_lang_from_path(filepath)
  local ft = vim.filetype.match({ filename = filepath })
  if not ft then
    return nil
  end
  -- Map filetype to treesitter language (they're usually the same, but not always)
  local lang = vim.treesitter.language.get_lang(ft)
  if lang and pcall(vim.treesitter.language.inspect, lang) then
    return lang
  end
  return nil
end

---Get syntax highlights for a code string using treesitter
---@param code string[] array of code lines
---@param lang string treesitter language
---@return table[] highlights array of {line_idx, hl_group, col_start, col_end}
local function get_syntax_highlights(code, lang)
  local highlights = {}

  -- Join lines for parsing
  local source = table.concat(code, "\n")

  -- Try to get a parser for this language
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, lang)
  if not ok or not parser then
    return highlights
  end

  -- Parse the code
  local trees = parser:parse()
  if not trees or #trees == 0 then
    return highlights
  end

  -- Get the highlights query for this language
  local query_ok, query = pcall(vim.treesitter.query.get, lang, "highlights")
  if not query_ok or not query then
    return highlights
  end

  -- Iterate over captures
  for id, node, _ in query:iter_captures(trees[1]:root(), source) do
    local name = query.captures[id]
    local start_row, start_col, end_row, end_col = node:range()

    -- Convert capture name to highlight group (e.g., "keyword" -> "@keyword")
    local hl_group = "@" .. name

    -- Handle single-line captures
    if start_row == end_row then
      table.insert(highlights, {
        line = start_row + 1, -- 1-indexed
        hl_group = hl_group,
        col_start = start_col,
        col_end = end_col,
      })
    else
      -- Multi-line capture: add highlight for each line
      for row = start_row, end_row do
        local cs = row == start_row and start_col or 0
        local ce = row == end_row and end_col or -1
        table.insert(highlights, {
          line = row + 1,
          hl_group = hl_group,
          col_start = cs,
          col_end = ce,
        })
      end
    end
  end

  return highlights
end

---Render the zdiff buffer
local function render()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  vim.bo[state.buf].modifiable = true

  local lines = {}
  local highlights = {} -- {line_idx, hl_group, col_start, col_end}
  local syntax_highlights = {} -- collected after we know line positions
  state.line_map = {}

  -- Header
  local mode_text
  if state.base_ref then
    mode_text = "Changes vs " .. state.base_ref
  else
    mode_text = "Uncommitted changes"
  end
  table.insert(lines, string.format(" zdiff: %s", mode_text))
  table.insert(lines, string.rep("-", 60))
  table.insert(highlights, { #lines - 1, "Title", 0, -1 })
  table.insert(highlights, { #lines, "Comment", 0, -1 })

  if #state.files == 0 then
    table.insert(lines, "")
    table.insert(lines, "  No changes found")
    table.insert(highlights, { #lines, "Comment", 0, -1 })
  else
    for file_idx, file in ipairs(state.files) do
      -- File header line
      local icon = file.expanded and M.config.icons.expanded or M.config.icons.collapsed
      local status_icon = get_status_icon(file.status)
      local add_stat = string.format("+%d", file.insertions)
      local del_stat = string.format("-%d", file.deletions)
      local file_line = string.format("%s %s %s  %s %s", icon, status_icon, file.path, add_stat, del_stat)
      table.insert(lines, file_line)

      -- Map this line to the file
      state.line_map[#lines] = { file_idx = file_idx }

      -- Calculate positions for highlighting
      local line_text = lines[#lines]
      local add_start = #line_text - #add_stat - #del_stat - 1
      local add_end = add_start + #add_stat
      local del_start = add_end + 1
      local del_end = del_start + #del_stat

      -- Highlight the file path part
      table.insert(highlights, { #lines, "Directory", 0, add_start })
      -- Highlight +N in green
      table.insert(highlights, { #lines, "DiffAdd", add_start, add_end })
      -- Highlight -M in red
      table.insert(highlights, { #lines, "DiffDelete", del_start, del_end })

      -- Show hunks only if expanded
      if file.expanded then
        -- Load hunks if not already loaded
        if #file.hunks == 0 then
          file.hunks = get_file_diff(file.path, state.base_ref)
        end

        -- Get language for syntax highlighting
        local lang = get_lang_from_path(file.path)

        -- Collect all code lines and their buffer positions for syntax highlighting
        local code_lines = {}
        local code_line_mapping = {} -- maps code line index to {buffer_line, prefix_len}

        for hunk_idx, hunk in ipairs(file.hunks) do
          -- Hunk header
          local hunk_header = string.format(
            "  @@ -%d,%d +%d,%d @@",
            hunk.old_start,
            hunk.old_count,
            hunk.new_start,
            hunk.new_count
          )
          table.insert(lines, hunk_header)
          state.line_map[#lines] = { file_idx = file_idx, hunk_idx = hunk_idx }
          table.insert(highlights, { #lines, "Comment", 0, -1 })

          -- Diff lines
          for line_idx, diff_line in ipairs(hunk.lines) do
            local prefix = "  "
            if diff_line.type == "add" then
              prefix = " +"
            elseif diff_line.type == "del" then
              prefix = " -"
            end

            local display_line = prefix .. diff_line.text
            table.insert(lines, display_line)

            -- Map this line
            state.line_map[#lines] = {
              file_idx = file_idx,
              hunk_idx = hunk_idx,
              line_idx = line_idx,
              lnum = diff_line.new_lnum or diff_line.old_lnum,
            }

            -- Add diff background highlight
            table.insert(highlights, { #lines, get_line_highlight(diff_line.type), 0, -1 })

            -- Track for syntax highlighting
            if lang then
              table.insert(code_lines, diff_line.text)
              table.insert(code_line_mapping, { buffer_line = #lines, prefix_len = #prefix })
            end
          end
        end

        -- Apply syntax highlighting if we have a language
        if lang and #code_lines > 0 then
          local syn_hls = get_syntax_highlights(code_lines, lang)
          for _, hl in ipairs(syn_hls) do
            local mapping = code_line_mapping[hl.line]
            if mapping then
              -- Offset columns by prefix length
              local col_start = mapping.prefix_len + hl.col_start
              local col_end = hl.col_end == -1 and -1 or (mapping.prefix_len + hl.col_end)
              table.insert(syntax_highlights, {
                mapping.buffer_line,
                hl.hl_group,
                col_start,
                col_end,
              })
            end
          end
        end
      end
    end
  end

  -- Set lines
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)

  -- Apply diff highlights first (background)
  local ns = vim.api.nvim_create_namespace("zdiff")
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, hl in ipairs(highlights) do
    local line_idx, hl_group, col_start, col_end = hl[1], hl[2], hl[3], hl[4]
    vim.api.nvim_buf_add_highlight(state.buf, ns, hl_group, line_idx - 1, col_start, col_end)
  end

  -- Apply syntax highlights on top (foreground colors)
  local ns_syntax = vim.api.nvim_create_namespace("zdiff_syntax")
  vim.api.nvim_buf_clear_namespace(state.buf, ns_syntax, 0, -1)
  for _, hl in ipairs(syntax_highlights) do
    local line_idx, hl_group, col_start, col_end = hl[1], hl[2], hl[3], hl[4]
    vim.api.nvim_buf_add_highlight(state.buf, ns_syntax, hl_group, line_idx - 1, col_start, col_end)
  end

  vim.bo[state.buf].modifiable = false
end

---Toggle expand/collapse for file under cursor
toggle_expand = function()
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then
    return
  end

  local cursor_line = vim.api.nvim_win_get_cursor(state.win)[1]
  local mapping = state.line_map[cursor_line]

  if not mapping or not mapping.file_idx then
    return
  end

  local file = state.files[mapping.file_idx]
  if file then
    file.expanded = not file.expanded
    render()
    -- Keep cursor on the file header
    for lnum, map in pairs(state.line_map) do
      if map.file_idx == mapping.file_idx and not map.hunk_idx then
        vim.api.nvim_win_set_cursor(state.win, { lnum, 0 })
        break
      end
    end
  end
end

---Go to the source file at the correct line
goto_source = function()
  local cursor_line = vim.api.nvim_win_get_cursor(state.win)[1]
  local mapping = state.line_map[cursor_line]

  if not mapping or not mapping.file_idx then
    return
  end

  local file = state.files[mapping.file_idx]
  if not file then
    return
  end

  local git_root = get_git_root()
  local filepath = git_root and (git_root .. "/" .. file.path) or file.path

  -- Determine target line
  local target_line = 1
  if mapping.lnum then
    target_line = mapping.lnum
  elseif mapping.hunk_idx and file.hunks[mapping.hunk_idx] then
    target_line = file.hunks[mapping.hunk_idx].new_start
  end

  -- Open file in the zdiff window (replaces zdiff buffer, but buffer persists hidden)
  -- This adds to jumplist so C-o returns to zdiff
  vim.cmd("edit " .. vim.fn.fnameescape(filepath))
  vim.api.nvim_win_set_cursor(0, { target_line, 0 })
  vim.cmd("normal! zz") -- Center the line
end

---Show help in a floating window
show_help = function()
  local help_lines = {
    " zdiff keymaps",
    "",
    string.format("  %s  Go to file/line", M.config.keymaps.goto_file),
    string.format("  %s  Toggle expand/collapse", M.config.keymaps.toggle),
    string.format("  %s  Toggle mode (uncommitted/branch)", M.config.keymaps.toggle_mode),
    string.format("  %s  Refresh", M.config.keymaps.refresh),
    string.format("  %s  Close zdiff", M.config.keymaps.close),
    string.format("  %s  Show this help", M.config.keymaps.help),
    "",
    " Press any key to close",
  }

  -- Calculate window size
  local width = 0
  for _, line in ipairs(help_lines) do
    width = math.max(width, #line)
  end
  width = width + 4
  local height = #help_lines

  -- Create buffer
  local help_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(help_buf, 0, -1, false, help_lines)
  vim.bo[help_buf].modifiable = false
  vim.bo[help_buf].bufhidden = "wipe"

  -- Calculate position (centered)
  local ui = vim.api.nvim_list_uis()[1]
  local row = math.floor((ui.height - height) / 2)
  local col = math.floor((ui.width - width) / 2)

  -- Create floating window
  local help_win = vim.api.nvim_open_win(help_buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Help ",
    title_pos = "center",
  })

  -- Add highlights
  local ns = vim.api.nvim_create_namespace("zdiff_help")
  vim.api.nvim_buf_add_highlight(help_buf, ns, "Title", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(help_buf, ns, "Comment", #help_lines - 1, 0, -1)

  -- Close on any key
  vim.keymap.set("n", "<Esc>", function()
    vim.api.nvim_win_close(help_win, true)
  end, { buffer = help_buf, nowait = true })

  -- Close on any other key press
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = help_buf,
    once = true,
    callback = function()
      if vim.api.nvim_win_is_valid(help_win) then
        vim.api.nvim_win_close(help_win, true)
      end
    end,
  })

  -- Also close if they press any key (using a catch-all mapping)
  for _, key in ipairs({ "q", "<CR>", "<Space>", "?", "h", "j", "k", "l" }) do
    vim.keymap.set("n", key, function()
      if vim.api.nvim_win_is_valid(help_win) then
        vim.api.nvim_win_close(help_win, true)
      end
    end, { buffer = help_buf, nowait = true })
  end
end

---Refresh the diff view, preserving expanded state and cursor position
local function refresh()
  -- Remember cursor position
  local cursor_line = nil
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    cursor_line = vim.api.nvim_win_get_cursor(state.win)[1]
  end

  -- Remember expanded state by path
  local expanded_state = {}
  for _, file in ipairs(state.files) do
    expanded_state[file.path] = file.expanded
  end

  -- Reload files
  state.files = load_files(state.base_ref)

  -- Restore expanded state
  for _, file in ipairs(state.files) do
    if expanded_state[file.path] ~= nil then
      file.expanded = expanded_state[file.path]
    end
  end

  render()

  -- Restore cursor position (clamped to valid range)
  if cursor_line and state.win and vim.api.nvim_win_is_valid(state.win) then
    local line_count = vim.api.nvim_buf_line_count(state.buf)
    cursor_line = math.min(cursor_line, line_count)
    vim.api.nvim_win_set_cursor(state.win, { cursor_line, 0 })
  end
end

---Toggle between uncommitted and branch mode
toggle_mode = function()
  if state.base_ref then
    -- Currently comparing to a branch, switch to uncommitted
    state.base_ref = nil
  else
    -- Currently showing uncommitted, switch to default_branch
    state.base_ref = M.config.default_branch
  end
  -- Clear hunks so they get reloaded
  for _, file in ipairs(state.files) do
    file.hunks = {}
  end
  refresh()
end

---Close the zdiff window and wipe the buffer
local function close()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end
  state.buf = nil
  state.win = nil
end

---Create the zdiff buffer and window
---@param base_ref? string git ref to diff against (e.g., "main", "develop", "HEAD~3"). If nil, shows uncommitted changes.
function M.open(base_ref)
  -- Check if we're in a git repo
  if not get_git_root() then
    notify("Not in a git repository", vim.log.levels.ERROR)
    return
  end

  -- Validate the ref if provided
  if base_ref and base_ref ~= "" then
    vim.fn.system("git rev-parse --verify " .. vim.fn.shellescape(base_ref) .. " 2>/dev/null")
    if vim.v.shell_error ~= 0 then
      notify("Invalid git ref: " .. base_ref, vim.log.levels.ERROR)
      return
    end
  else
    base_ref = nil
  end

  -- If zdiff buffer already exists and we're switching refs, close it first
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    if state.base_ref == base_ref then
      -- Same ref, just switch to the buffer
      state.win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(state.win, state.buf)
      return
    else
      -- Different ref, close and reopen
      close()
    end
  end

  state.base_ref = base_ref

  -- Create buffer
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].bufhidden = "hide"
  vim.bo[state.buf].swapfile = false
  vim.api.nvim_buf_set_name(state.buf, "zdiff")
  vim.bo[state.buf].filetype = "zdiff"

  -- Open in current window
  state.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.win, state.buf)

  -- Window options
  vim.wo[state.win].number = false
  vim.wo[state.win].relativenumber = false
  vim.wo[state.win].signcolumn = "no"
  vim.wo[state.win].wrap = false
  vim.wo[state.win].cursorline = true

  -- Set up keymaps
  local opts = { buffer = state.buf, silent = true }
  vim.keymap.set("n", M.config.keymaps.goto_file, goto_source, opts)
  vim.keymap.set("n", M.config.keymaps.toggle, toggle_expand, opts)
  vim.keymap.set("n", M.config.keymaps.close, close, opts)
  vim.keymap.set("n", M.config.keymaps.refresh, refresh, opts)
  vim.keymap.set("n", M.config.keymaps.toggle_mode, toggle_mode, opts)
  vim.keymap.set("n", M.config.keymaps.help, show_help, opts)

  -- Auto-refresh when returning to zdiff buffer
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = state.buf,
    callback = function()
      state.win = vim.api.nvim_get_current_win()
      refresh()
    end,
  })

  -- Load and render
  refresh()
end

---Setup function
---@param opts? ZdiffConfig
function M.setup(opts)
  if opts then
    M.config = vim.tbl_deep_extend("force", M.config, opts)
  end
end

return M
