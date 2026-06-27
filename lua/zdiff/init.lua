local M = {}
local diff = require("zdiff.diff")
local diff_view = require("zdiff.diff_view")
local git = require("zdiff.git")
local winbar = require("zdiff.winbar")

-- State
---@class ZdiffFile
---@field path string current relative file path, or old path for deleted files
---@field display_path string path shown in the UI
---@field old_path string|nil old-side relative file path
---@field new_path string|nil new-side relative file path
---@field status string git status (M, A, D, etc.)
---@field insertions number lines added
---@field deletions number lines deleted
---@field expanded boolean whether file is expanded
---@field hunks ZdiffHunk[] parsed diff hunks
---@field hunk_status "unloaded"|"loading"|"loaded"|"failed"
---@field hunk_error string|nil
---@field hunk_job integer|nil

---@class ZdiffState
---@field files ZdiffFile[]
---@field buf number|nil buffer handle
---@field win number|nil window handle
---@field root string|nil git repository root for the current zdiff session
---@field base_ref string|nil the git ref to diff against (nil = uncommitted changes vs HEAD)
---@field load_error string|nil most recent file loading error
---@field line_map table<number, {file_idx: number, hunk_idx: number|nil, line_idx: number|nil, lnum: number|nil}>
---@field file_header_lines table<number, number>
---@field loading_files boolean whether file list refresh is in progress
---@field refresh_seq number monotonically increasing refresh generation
---@field refresh_timer uv.uv_timer_t|nil timer used for debounced refresh
---@field render_timer uv.uv_timer_t|nil timer used for debounced renders
---@field render_pending boolean whether a debounced render is queued
---@field win_opts table<number, {number: boolean, relativenumber: boolean, signcolumn: string, wrap: boolean, cursorline: boolean, winbar: string|nil}>
---@field hunk_job_seq integer
---@field syntax_projection_cache table<string, {old: table<number, table[]>, new: table<number, table[]>}|false>
---@field syntax_jobs table<string, integer>
---@field syntax_job_seq integer
---@field syntax_debug {projected_files: string[], fallback_files: string[], skipped_files: table<string, string>}
---@field restore_cursor_line number|nil cursor line restored after expanded hunks reload

---@type ZdiffState
local state = {
  files = {},
  buf = nil,
  win = nil,
  root = nil,
  base_ref = nil,
  load_error = nil,
  line_map = {},
  file_header_lines = {},
  loading_files = false,
  refresh_seq = 0,
  refresh_timer = nil,
  render_timer = nil,
  render_pending = false,
  win_opts = {},
  hunk_job_seq = 0,
  syntax_projection_cache = {},
  syntax_jobs = {},
  syntax_job_seq = 0,
  syntax_debug = {
    projected_files = {},
    fallback_files = {},
    skipped_files = {},
  },
  restore_cursor_line = nil,
}

-- Forward declarations
local goto_source
local toggle_expand
local toggle_mode
local show_help
local render
local update_winbar

-- Configuration
---@class ZdiffConfig
---@field default_expanded boolean Whether files are expanded by default
---@field default_branch string|nil Default branch for toggle_mode (e.g., "main", "develop")
---@field keymaps table<string, string|false|nil> Keymap bindings
---@field icons table<string, string> Icons for UI elements
---@field syntax table Syntax highlight preferences

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
    yank_ref = "gy",
  },
  icons = {
    collapsed = "",
    expanded = "",
    added = "+",
    deleted = "-",
    modified = "~",
  },
  syntax = {
    mode = "projection", -- "projection"|"hunk"
    max_lines = 8000, -- 0 means unlimited
  },
}

---Send a notification with zdiff prefix
---@param msg string
---@param level? number vim.log.levels value
local function notify(msg, level)
  vim.notify("[zdiff] " .. msg, level or vim.log.levels.INFO)
end

---@param msg string|nil
---@return string
local function render_error(msg)
  return vim.trim((msg or "unknown git error"):gsub("%s+", " "))
end

---@param name string
---@return string|nil
local function keymap_lhs(name)
  local lhs = M.config.keymaps[name]
  if type(lhs) == "string" and lhs ~= "" then
    return lhs
  end
  return nil
end

---@param win number
local function save_window_opts(win)
  if state.win_opts[win] or not vim.api.nvim_win_is_valid(win) then
    return
  end
  state.win_opts[win] = {
    number = vim.wo[win].number,
    relativenumber = vim.wo[win].relativenumber,
    signcolumn = vim.wo[win].signcolumn,
    wrap = vim.wo[win].wrap,
    cursorline = vim.wo[win].cursorline,
    winbar = vim.wo[win].winbar,
  }
end

---@param win number
local function apply_zdiff_window_opts(win)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
end

---@param win number
local function restore_window_opts(win)
  local opts = state.win_opts[win]
  if not opts or not vim.api.nvim_win_is_valid(win) then
    state.win_opts[win] = nil
    return
  end
  vim.wo[win].number = opts.number
  vim.wo[win].relativenumber = opts.relativenumber
  vim.wo[win].signcolumn = opts.signcolumn
  vim.wo[win].wrap = opts.wrap
  vim.wo[win].cursorline = opts.cursorline
  vim.wo[win].winbar = opts.winbar or ""
  state.win_opts[win] = nil
end

---@param win? number
update_winbar = function(win)
  winbar.update({
    buf = state.buf,
    win = state.win,
    files = state.files,
    line_map = state.line_map,
    file_header_lines = state.file_header_lines,
    icons = M.config.icons,
  }, win)
end

local uv = vim.uv or vim.loop
local ns_diff = vim.api.nvim_create_namespace("zdiff")
local ns_syntax = vim.api.nvim_create_namespace("zdiff_syntax")
local ns_markers = vim.api.nvim_create_namespace("zdiff_markers")
local augroup = vim.api.nvim_create_augroup("zdiff", { clear = false })

local function render_debounced()
  if state.render_pending then
    return
  end

  state.render_pending = true
  local timer = uv.new_timer()
  state.render_timer = timer
  timer:start(10, 0, function()
    timer:stop()
    timer:close()
    if state.render_timer == timer then
      state.render_timer = nil
    end
    vim.schedule(function()
      if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        render()
      end
      state.render_pending = false
    end)
  end)
end

---@param file ZdiffFile
---@return {ok: boolean, data?: ZdiffHunk[], error?: string}
local function get_untracked_file_hunks(file)
  if not state.root then
    return { ok = false, error = "no git repository root for current session" }
  end

  local result = git.read_worktree_lines(state.root, file.path)
  if not result.ok then
    return { ok = false, error = result.error }
  end

  return { ok = true, data = diff.untracked_hunks(result.data or {}) }
end

---Load diff hunks for a specific file
---@param file ZdiffFile
---@param base_ref string|nil git ref to diff against, or nil for uncommitted
---@param done fun(result: {ok: boolean, data?: ZdiffHunk[], error?: string})
local function load_file_hunks_async(file, base_ref, done)
  if file.status == "?" then
    local result = get_untracked_file_hunks(file)
    vim.schedule(function()
      done(result)
    end)
    return
  end

  if not state.root then
    vim.schedule(function()
      done({ ok = false, error = "no git repository root for current session" })
    end)
    return
  end

  git.file_diff_lines_async(state.root, base_ref, file, function(result)
    if not result.ok then
      done({ ok = false, error = result.error })
      return
    end
    done({ ok = true, data = diff.parse_hunks(result.data or {}) })
  end)
end

---@param file_idx number
---@param file ZdiffFile
local function queue_file_hunks(file_idx, file)
  if file.hunk_status == "loading" or file.hunk_status == "loaded" then
    return
  end

  state.hunk_job_seq = state.hunk_job_seq + 1
  local token = state.hunk_job_seq
  local refresh_seq = state.refresh_seq
  file.hunk_status = "loading"
  file.hunk_error = nil
  file.hunk_job = token

  load_file_hunks_async(file, state.base_ref, function(result)
    if refresh_seq ~= state.refresh_seq then
      return
    end

    local current = state.files[file_idx]
    if not current or current.hunk_job ~= token then
      return
    end

    current.hunk_job = nil
    if result.ok then
      current.hunks = result.data or {}
      current.hunk_status = "loaded"
      current.hunk_error = nil
    else
      current.hunks = {}
      current.hunk_status = "failed"
      current.hunk_error = render_error(result.error)
    end
    render_debounced()
  end)
end

---@param filepath string
---@return string[]
local function read_worktree_lines(filepath)
  if not state.root then
    return {}
  end
  local result = git.read_worktree_lines(state.root, filepath)
  if not result.ok then
    return {}
  end
  return result.data or {}
end

---@param rev string
---@param filepath string
---@param done fun(lines: string[])
local function read_git_file_lines_async(rev, filepath, done)
  if not state.root then
    done({})
    return
  end
  git.read_git_file_lines_async(state.root, rev, filepath, function(result)
    if not result.ok then
      done({})
      return
    end
    done(result.data or {})
  end)
end

---@param file ZdiffFile
---@param side "old"|"new"
---@return "empty"|"worktree"|"git", string|nil, string|nil
local function get_content_source(file, side)
  local status = file.status
  if side == "old" then
    if status == "A" or status == "?" then
      return "empty", nil
    end
    if state.base_ref then
      return "git", state.base_ref, file.old_path or file.path
    end
    return "git", "HEAD", file.old_path or file.path
  end

  if status == "D" then
    return "empty", nil
  end
  if state.base_ref then
    return "git", "HEAD", file.new_path or file.path
  end
  return "worktree", nil, file.new_path or file.path
end

---@param file ZdiffFile
---@param done fun(old_lines: string[], new_lines: string[])
local function get_projection_sources_async(file, done)
  local old_kind, old_rev, old_path = get_content_source(file, "old")
  local new_kind, new_rev, new_path = get_content_source(file, "new")

  local function load_new(old_lines)
    if new_kind == "empty" then
      done(old_lines, {})
      return
    end
    if new_kind == "worktree" then
      done(old_lines, read_worktree_lines(new_path or file.path))
      return
    end
    read_git_file_lines_async(new_rev, new_path or file.path, function(new_lines)
      done(old_lines, new_lines)
    end)
  end

  if old_kind == "empty" then
    load_new({})
    return
  end
  if old_kind == "worktree" then
    load_new(read_worktree_lines(old_path or file.path))
    return
  end
  read_git_file_lines_async(old_rev, old_path or file.path, function(old_lines)
    load_new(old_lines)
  end)
end

---@param key string
---@param file ZdiffFile
---@param lang string
local function queue_projection_cache(key, file, lang)
  diff_view.queue_projection_cache(state, { key = key, file = file, lang = lang }, {
    syntax = M.config.syntax,
    refresh_seq = state.refresh_seq,
    load_sources = get_projection_sources_async,
    on_done = function()
      if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        render_debounced()
      end
    end,
  })
end

local function restore_cursor_when_ready()
  if not state.restore_cursor_line then
    return
  end
  for _, file in ipairs(state.files) do
    if
      file.expanded and (file.hunk_status == "unloaded" or file.hunk_status == "loading")
    then
      return
    end
  end
  if
    not state.win
    or not vim.api.nvim_win_is_valid(state.win)
    or vim.api.nvim_win_get_buf(state.win) ~= state.buf
  then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(state.buf)
  vim.api.nvim_win_set_cursor(
    state.win,
    { math.min(state.restore_cursor_line, line_count), 0 }
  )
  state.restore_cursor_line = nil
end

---Render the zdiff buffer
render = function()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  vim.bo[state.buf].modifiable = true

  local lines = {}
  local highlights = {} -- {line_idx, hl_group, col_start, col_end}
  local rendered = {
    lines = lines,
    highlights = highlights,
    syntax_highlights = {},
    syntax_requests = {},
    markers = {},
    line_map = {},
    file_header_lines = {},
    syntax_debug = {
      projected_files = {},
      fallback_files = {},
      skipped_files = {},
    },
  }
  local empty_syntax_debug = {
    projected_files = {},
    fallback_files = {},
    skipped_files = {},
  }

  -- Header
  local mode_text
  if state.base_ref then
    mode_text = "Changes vs " .. state.base_ref
  else
    mode_text = "Uncommitted changes"
  end
  if state.loading_files then
    mode_text = mode_text .. " (loading...)"
  end
  table.insert(lines, string.format(" zdiff: %s", mode_text))
  table.insert(lines, string.rep("-", 60))
  table.insert(highlights, { #lines - 1, "Title", 0, -1 })
  table.insert(highlights, { #lines, "Comment", 0, -1 })

  if #state.files == 0 then
    table.insert(lines, "")
    if state.load_error then
      table.insert(lines, "  Error loading changes: " .. state.load_error)
    elseif state.loading_files then
      table.insert(lines, "  Loading changed files...")
    else
      table.insert(lines, "  No changes found")
    end
    table.insert(highlights, { #lines, "Comment", 0, -1 })
  else
    rendered = diff_view.render({
      lines = lines,
      highlights = highlights,
      files = state.files,
      icons = M.config.icons,
      syntax = M.config.syntax,
      syntax_projection_cache = state.syntax_projection_cache,
      syntax_cache_prefix = table.concat(
        { state.root or "", state.base_ref or "" },
        "\n"
      ),
      queue_hunks = queue_file_hunks,
    })
  end

  state.line_map = rendered.line_map
  state.file_header_lines = rendered.file_header_lines
  state.syntax_debug = rendered.syntax_debug or empty_syntax_debug

  diff_view.apply(state.buf, rendered, {
    diff = ns_diff,
    syntax = ns_syntax,
    markers = ns_markers,
  })

  vim.bo[state.buf].modifiable = false
  restore_cursor_when_ready()
  update_winbar()

  -- Queue syntax projection jobs after first paint for responsive rendering.
  for _, req in ipairs(rendered.syntax_requests or {}) do
    queue_projection_cache(req.key, req.file, req.lang)
  end
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
      if map.file_idx == mapping.file_idx and map.kind == "file" then
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

  if file.status == "D" then
    notify("Cannot open deleted file: " .. file.path, vim.log.levels.WARN)
    return
  end

  local diff_line = nil
  if mapping.hunk_idx and mapping.line_idx and file.hunks[mapping.hunk_idx] then
    diff_line = file.hunks[mapping.hunk_idx].lines[mapping.line_idx]
    if diff_line and diff_line.type == "del" then
      notify("Cannot open deleted line: " .. file.path, vim.log.levels.WARN)
      return
    end
  end

  local rel_path = file.new_path or file.path
  local filepath = state.root and (state.root .. "/" .. rel_path) or rel_path

  -- Determine target line
  local target_line = 1
  if diff_line and diff_line.new_lnum then
    target_line = diff_line.new_lnum
  elseif mapping.lnum then
    target_line = mapping.lnum
  elseif mapping.hunk_idx and file.hunks[mapping.hunk_idx] then
    target_line = file.hunks[mapping.hunk_idx].new_start
  end

  -- Open file in the zdiff window (replaces zdiff buffer, but buffer persists hidden)
  -- This adds to jumplist so C-o returns to zdiff
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    restore_window_opts(state.win)
  end
  vim.cmd("edit " .. vim.fn.fnameescape(filepath))
  local line_count = vim.api.nvim_buf_line_count(0)
  target_line = math.min(target_line, math.max(1, line_count))
  vim.api.nvim_win_set_cursor(0, { target_line, 0 })
  vim.cmd("normal! zz") -- Center the line
end

---Yank a file:line reference for the current line or visual selection
---@param start_line number
---@param end_line number
local function yank_ref(start_line, end_line)
  local file_idx = nil
  local ranges = {}
  local current_range = nil

  local function add_to_range(lnum)
    if not current_range then
      current_range = { start = lnum, finish = lnum }
    elseif lnum == current_range.finish + 1 then
      current_range.finish = lnum
    else
      table.insert(ranges, current_range)
      current_range = { start = lnum, finish = lnum }
    end
  end

  for line = start_line, end_line do
    local mapping = state.line_map[line]
    if not mapping or not mapping.file_idx then
      notify("Cannot yank: line " .. line .. " is not a diff line", vim.log.levels.WARN)
      return
    end

    if not file_idx then
      file_idx = mapping.file_idx
    elseif file_idx ~= mapping.file_idx then
      notify("Cannot yank: selection spans multiple files", vim.log.levels.WARN)
      return
    end

    if mapping.line_idx and mapping.hunk_idx then
      local file = state.files[mapping.file_idx]
      if file and file.hunks[mapping.hunk_idx] then
        local diff_line = file.hunks[mapping.hunk_idx].lines[mapping.line_idx]
        if diff_line.type ~= "del" then
          local lnum = mapping.lnum
          if lnum then
            add_to_range(lnum)
          end
        end
      end
    end
  end

  if current_range then
    table.insert(ranges, current_range)
  end

  local file = state.files[file_idx]
  if not file then
    return
  end

  if #ranges == 0 then
    notify("Cannot yank: no addition or context lines in selection", vim.log.levels.WARN)
    return
  end

  local parts = {}
  for _, r in ipairs(ranges) do
    if r.start == r.finish then
      table.insert(parts, tostring(r.start))
    else
      table.insert(parts, tostring(r.start) .. "-" .. tostring(r.finish))
    end
  end

  local ref = file.path .. ":" .. table.concat(parts, ", ")
  vim.fn.setreg('"', ref)
  vim.fn.setreg("+", ref)
  notify("Yanked: " .. ref)
end

_G.yank_ref_visual = function()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  yank_ref(start_line, end_line)
end

---Show help in a floating window
show_help = function()
  local configured_keymaps = {
    { "goto_file", "Go to file/line" },
    { "toggle", "Toggle expand/collapse" },
    { "toggle_mode", "Toggle mode (uncommitted/branch)" },
    { "refresh", "Refresh" },
    { "close", "Close zdiff" },
    { "help", "Show this help" },
    { "yank_ref", "Yank file:line reference" },
  }
  local keymaps = {}
  for _, map in ipairs(configured_keymaps) do
    local lhs = keymap_lhs(map[1])
    if lhs then
      table.insert(keymaps, { lhs, map[2] })
    end
  end

  -- Find the longest description to calculate width
  local max_desc_len = 0
  local max_key_len = 0
  for _, map in ipairs(keymaps) do
    max_key_len = math.max(max_key_len, #map[1])
    max_desc_len = math.max(max_desc_len, #map[2])
  end

  local inner_width = max_key_len + max_desc_len + 6 -- padding and spacing
  local title = "zdiff keymaps"
  inner_width = math.max(inner_width, #title + 2)

  -- Build help lines with justified layout
  local help_lines = {
    " " .. title .. string.rep(" ", inner_width - #title - 1),
    "",
  }

  for _, map in ipairs(keymaps) do
    local key = map[1]
    local desc = map[2]
    local padding = inner_width - #key - #desc - 4
    table.insert(help_lines, "  " .. key .. string.rep(" ", padding) .. desc .. "  ")
  end

  table.insert(help_lines, "")
  local footer = "Press any key to close"
  local footer_padding = math.floor((inner_width - #footer) / 2)
  table.insert(help_lines, string.rep(" ", footer_padding) .. footer)

  local width = inner_width + 2
  local height = #help_lines

  -- Create buffer
  local help_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(help_buf, 0, -1, false, help_lines)
  vim.bo[help_buf].modifiable = false
  vim.bo[help_buf].bufhidden = "wipe"

  -- Calculate position (centered)
  local ui = vim.api.nvim_list_uis()[1]
  local editor_width = ui and ui.width or vim.o.columns
  local editor_height = ui and ui.height or vim.o.lines
  local row = math.floor((editor_height - height) / 2)
  local col = math.floor((editor_width - width) / 2)

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

  -- Close when leaving the window
  vim.api.nvim_create_autocmd("WinLeave", {
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
  state.restore_cursor_line = nil

  -- Remember expanded state by path
  local expanded_state = {}
  for _, file in ipairs(state.files) do
    expanded_state[file.display_path or file.path] = file.expanded
  end

  state.refresh_seq = state.refresh_seq + 1
  local refresh_seq = state.refresh_seq
  state.loading_files = true
  state.load_error = nil
  state.syntax_jobs = {}
  state.syntax_projection_cache = {}
  render()

  if not state.root then
    state.loading_files = false
    state.load_error = "no git repository root for current session"
    render()
    return
  end

  git.diff_files_async(state.root, state.base_ref, function(result)
    if refresh_seq ~= state.refresh_seq then
      return
    end

    if not result.ok then
      state.files = {}
      state.loading_files = false
      state.load_error = render_error(result.error)
      render()
      return
    end

    local files = {}
    for _, info in ipairs(result.data or {}) do
      table.insert(files, {
        path = info.path,
        display_path = info.display_path,
        old_path = info.old_path,
        new_path = info.new_path,
        status = info.status,
        insertions = info.insertions,
        deletions = info.deletions,
        expanded = M.config.default_expanded,
        hunks = {},
        hunk_status = "unloaded",
        hunk_error = nil,
      })
    end
    table.sort(files, function(a, b)
      return a.display_path < b.display_path
    end)

    state.files = files
    for _, file in ipairs(state.files) do
      local key = file.display_path or file.path
      if expanded_state[key] ~= nil then
        file.expanded = expanded_state[key]
      end
    end

    state.loading_files = false
    state.load_error = nil
    state.restore_cursor_line = cursor_line
    render()
  end)
end

---@param delay_ms number
local function refresh_debounced(delay_ms)
  if state.refresh_timer then
    state.refresh_timer:stop()
    state.refresh_timer:close()
    state.refresh_timer = nil
  end

  local timer = uv.new_timer()
  state.refresh_timer = timer
  timer:start(delay_ms, 0, function()
    timer:stop()
    timer:close()
    if state.refresh_timer == timer then
      state.refresh_timer = nil
    end
    vim.schedule(function()
      if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        refresh()
      end
    end)
  end)
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
    file.hunk_status = "unloaded"
    file.hunk_error = nil
    file.hunk_job = nil
  end
  refresh()
end

---Close the zdiff window and wipe the buffer
local function close()
  if state.refresh_timer then
    state.refresh_timer:stop()
    state.refresh_timer:close()
    state.refresh_timer = nil
  end
  if state.render_timer then
    state.render_timer:stop()
    state.render_timer:close()
    state.render_timer = nil
  end
  state.render_pending = false
  vim.api.nvim_clear_autocmds({ group = augroup })
  for win, _ in pairs(state.win_opts) do
    restore_window_opts(win)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end
  state.files = {}
  state.buf = nil
  state.win = nil
  state.root = nil
  state.load_error = nil
  state.loading_files = false
  state.refresh_seq = state.refresh_seq + 1
  state.hunk_job_seq = state.hunk_job_seq + 1
  state.syntax_jobs = {}
  state.syntax_projection_cache = {}
  state.restore_cursor_line = nil
end

---Create the zdiff buffer and window
---@param base_ref? string git ref to diff against (e.g., "main", "develop", "HEAD~3"). If nil, shows uncommitted changes.
function M.open(base_ref)
  -- Check if we're in a git repo
  local root_result = git.root()
  if not root_result.ok then
    notify("Not in a git repository", vim.log.levels.ERROR)
    return
  end
  local root = root_result.data

  -- Validate the ref if provided
  if base_ref and base_ref ~= "" then
    local ref_result = git.ref_exists(root, base_ref)
    if not ref_result.ok then
      notify("Invalid git ref: " .. base_ref, vim.log.levels.ERROR)
      return
    end
  else
    base_ref = nil
  end

  -- If zdiff buffer already exists and we're switching refs, close it first
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    if state.root == root and state.base_ref == base_ref then
      -- Same ref, just switch to the buffer
      state.win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(state.win, state.buf)
      save_window_opts(state.win)
      apply_zdiff_window_opts(state.win)
      update_winbar(state.win)
      return
    else
      -- Different ref, close and reopen
      close()
    end
  end

  state.root = root
  state.base_ref = base_ref
  state.load_error = nil

  -- Create buffer
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].bufhidden = "hide"
  vim.bo[state.buf].swapfile = false
  vim.api.nvim_buf_set_name(state.buf, "zdiff")
  vim.bo[state.buf].filetype = "zdiff"
  vim.api.nvim_clear_autocmds({ group = augroup })

  -- Open in current window
  state.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.win, state.buf)

  -- Window options
  save_window_opts(state.win)
  apply_zdiff_window_opts(state.win)

  -- Set up keymaps
  local opts = { buffer = state.buf, silent = true }
  local mappings = {
    { "goto_file", goto_source },
    { "toggle", toggle_expand },
    { "close", close },
    { "refresh", refresh },
    { "toggle_mode", toggle_mode },
    { "help", show_help },
  }
  for _, map in ipairs(mappings) do
    local lhs = keymap_lhs(map[1])
    if lhs then
      vim.keymap.set("n", lhs, map[2], opts)
    end
  end

  local yank_ref_key = keymap_lhs("yank_ref")
  if yank_ref_key then
    vim.keymap.set("n", yank_ref_key, function()
      local cursor_line = vim.api.nvim_win_get_cursor(state.win)[1]
      yank_ref(cursor_line, cursor_line)
    end, { buffer = state.buf, silent = true })
    vim.api.nvim_buf_set_keymap(
      state.buf,
      "v",
      yank_ref_key,
      ":lua yank_ref_visual()<CR>",
      { silent = true }
    )
  end

  -- Auto-refresh when returning to zdiff buffer
  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    buffer = state.buf,
    callback = function()
      state.win = vim.api.nvim_get_current_win()
      save_window_opts(state.win)
      apply_zdiff_window_opts(state.win)
      update_winbar(state.win)
      if state.loading_files then
        return
      end
      refresh_debounced(200)
    end,
  })

  vim.api.nvim_create_autocmd("BufLeave", {
    group = augroup,
    buffer = state.buf,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      restore_window_opts(win)
    end,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    buffer = state.buf,
    callback = function()
      update_winbar(vim.api.nvim_get_current_win())
    end,
  })

  vim.api.nvim_create_autocmd("WinScrolled", {
    group = augroup,
    callback = function()
      local event = vim.v.event or {}
      local win = tonumber(event.winid) or state.win
      update_winbar(win)
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

-- Expose for debugging/testing
M.show_help = function()
  show_help()
end

local function pending_hunk_jobs()
  local count = 0
  for _, file in ipairs(state.files) do
    if file.hunk_status == "loading" then
      count = count + 1
    end
  end
  return count
end

M._debug_state = function()
  return {
    loading_files = state.loading_files,
    pending_hunk_jobs = pending_hunk_jobs(),
    pending_render = state.render_pending,
    pending_syntax_jobs = vim.tbl_count(state.syntax_jobs),
    syntax_cache_entries = vim.tbl_count(state.syntax_projection_cache),
    syntax = vim.deepcopy(state.syntax_debug),
  }
end

return M
