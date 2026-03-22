local M = {}
local annotation_format = require("zdiff.annotations")
local annotation_focus = require("zdiff.annotation_focus")
local git = require("zdiff.git")
local selections = require("zdiff.selections")

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

---@class ZdiffLineMapEntry
---@field file_idx number
---@field hunk_idx number|nil
---@field line_idx number|nil
---@field lnum number|nil
---@field line_type "context"|"add"|"del"|"header"|nil
---@field old_lnum number|nil
---@field new_lnum number|nil

---@class ZdiffAnnotationAnchorLine
---@field type "context"|"add"|"del"
---@field old_lnum number|nil
---@field new_lnum number|nil

---@class ZdiffAnnotation
---@field id integer
---@field session_key string
---@field file_path string
---@field anchor_lines ZdiffAnnotationAnchorLine[]
---@field old_ranges {start: number, finish: number}[]
---@field new_ranges {start: number, finish: number}[]
---@field text string
---@field created_at integer

---@class ZdiffState
---@field files ZdiffFile[]
---@field buf number|nil buffer handle
---@field win number|nil window handle
---@field base_ref string|nil the git ref to diff against (nil = uncommitted changes vs HEAD)
---@field line_map table<number, ZdiffLineMapEntry>
---@field loading_files boolean whether file list refresh is in progress
---@field refresh_seq number monotonically increasing refresh generation
---@field refresh_timer uv.uv_timer_t|nil timer used for debounced refresh
---@field win_opts table<number, {number: boolean, relativenumber: boolean, signcolumn: string, wrap: boolean, cursorline: boolean}>
---@field syntax_projection_cache table<string, {old: table<number, table[]>, new: table<number, table[]>}|false>
---@field syntax_jobs table<string, integer>
---@field syntax_job_seq integer
---@field annotations table<string, ZdiffAnnotation[]>
---@field next_annotation_id integer
---@field rendered_annotations table<integer, {id: integer, start_line: integer, end_line: integer}>
---@field annotation_editor_buf number|nil
---@field annotation_editor_win number|nil
---@field annotation_editor_prev_win number|nil
---@field annotation_editor_submit fun(text: string)|nil
---@field annotations_only boolean

---@type ZdiffState
local state = {
  files = {},
  buf = nil,
  win = nil,
  base_ref = nil,
  line_map = {},
  loading_files = false,
  refresh_seq = 0,
  refresh_timer = nil,
  win_opts = {},
  syntax_projection_cache = {},
  syntax_jobs = {},
  syntax_job_seq = 0,
  annotations = {},
  next_annotation_id = 0,
  rendered_annotations = {},
  annotation_editor_buf = nil,
  annotation_editor_win = nil,
  annotation_editor_prev_win = nil,
  annotation_editor_submit = nil,
  annotations_only = false,
}

-- Forward declarations
local goto_source
local toggle_expand
local toggle_mode
local show_help
local toggle_annotations_only
local render
local add_comment
local delete_comment
local yank_comments
local open_annotation_editor
local close_annotation_editor
local normalize_annotation_text
local get_git_root = git.get_git_root
local get_file_diff = git.get_file_diff

-- Configuration
---@class ZdiffConfig
---@field default_expanded boolean Whether files are expanded by default
---@field default_branch string|nil Default branch for toggle_mode (e.g., "main", "develop")
---@field keymaps table<string, string> Keymap bindings
---@field icons table<string, string> Icons for UI elements
---@field syntax table Syntax highlight preferences
---@field comments table Annotation export formatting
---@field comments.prefix string|nil Text prepended when yanking annotations
---@field comments.suffix string|nil Text appended when yanking annotations

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
    comment = "c",
    delete_comment = "d",
    yank_comments = "yc",
    toggle_annotations_only = "h",
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
  comments = {
    prefix = "Feedback for changes:\n",
    suffix = "",
  },
}

---Send a notification with zdiff prefix
---@param msg string
---@param level? number vim.log.levels value
local function notify(msg, level)
  vim.notify("[zdiff] " .. msg, level or vim.log.levels.INFO)
end

---@param value string
---@param allowed table<string, boolean>
---@param fallback string
---@return string
local function normalize_enum(value, allowed, fallback)
  if type(value) ~= "string" then
    return fallback
  end
  if allowed[value] then
    return value
  end
  return fallback
end

---@param value any
---@return number
local function normalize_non_negative_number(value)
  if type(value) ~= "number" or value < 0 then
    return 0
  end
  return math.floor(value)
end

---@return string
local function current_session_key()
  return state.base_ref and ("ref:" .. state.base_ref) or "worktree"
end

---@param entry ZdiffLineMapEntry|nil
---@return boolean
local function is_diff_line_entry(entry)
  return entry ~= nil
    and entry.hunk_idx ~= nil
    and entry.line_idx ~= nil
    and entry.line_type ~= nil
end

---@param annotation ZdiffAnnotation
---@return {id: integer, start_line: integer, end_line: integer}|nil
local function resolve_annotation(annotation)
  local anchor_len = #annotation.anchor_lines
  if anchor_len == 0 then
    return nil
  end

  local line_count = 0
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    line_count = vim.api.nvim_buf_line_count(state.buf)
  end

  for start_line = 1, line_count do
    local mapping = state.line_map[start_line]
    if is_diff_line_entry(mapping) then
      local file = state.files[mapping.file_idx]
      if file and file.path == annotation.file_path then
        local matched = true
        for offset = 1, anchor_len do
          local expected = annotation.anchor_lines[offset]
          local actual = state.line_map[start_line + offset - 1]
          if not is_diff_line_entry(actual) then
            matched = false
            break
          end
          local actual_file = state.files[actual.file_idx]
          if
            not actual_file
            or actual_file.path ~= annotation.file_path
            or actual.line_type ~= expected.type
            or actual.old_lnum ~= expected.old_lnum
            or actual.new_lnum ~= expected.new_lnum
          then
            matched = false
            break
          end
        end

        if matched then
          return {
            id = annotation.id,
            start_line = start_line,
            end_line = start_line + anchor_len - 1,
          }
        end
      end
    end
  end

  return nil
end

---@return ZdiffAnnotation[]
local function current_annotations()
  local session_key = current_session_key()
  state.annotations[session_key] = state.annotations[session_key] or {}
  return state.annotations[session_key]
end

---@return string
local function format_annotation_block(annotation)
  return annotation_format.format_export_line(annotation)
end

---@return table<number, table<number, table<number, boolean>>>
---@param label string
---@return table[]
local function build_annotation_note_lines(label)
  local virt_lines = {}
  local parts = vim.split(label, "\n", { plain = true })

  for idx, part in ipairs(parts) do
    if idx == #parts then
      table.insert(virt_lines, {
        { "    ╰─ ", "ZdiffAnnotationBorder" },
        { part, "ZdiffAnnotationNoteText" },
      })
    else
      table.insert(virt_lines, {
        { "    |  ", "ZdiffAnnotationBorder" },
        { part, "ZdiffAnnotationNoteText" },
      })
    end
  end

  return virt_lines
end

---@param selection {file_path: string}
---@param on_submit fun(text: string)
open_annotation_editor = function(selection, on_submit)
  close_annotation_editor()

  local ui = vim.api.nvim_list_uis()[1]
  local editor_width = ui and ui.width or vim.o.columns
  local editor_height = ui and ui.height or vim.o.lines
  local width = math.max(50, math.min(100, editor_width - 10))
  local height = math.max(8, math.min(14, editor_height - 6))
  local row = math.floor((editor_height - height) / 2)
  local col = math.floor((editor_width - width) / 2)

  local title = " Annotation: " .. selection.file_path .. " "
  if #title > width - 4 then
    title = " Annotation "
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(
    buf,
    string.format("zdiff://annotation/%s/%d", selection.file_path, vim.loop.hrtime())
  )
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = true
  vim.bo[buf].undofile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })

  local prev_win = vim.api.nvim_get_current_win()
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  })

  state.annotation_editor_buf = buf
  state.annotation_editor_win = win
  state.annotation_editor_prev_win = prev_win
  state.annotation_editor_submit = on_submit

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = false

  local submit = function()
    if
      not (
        state.annotation_editor_buf
        and vim.api.nvim_buf_is_valid(state.annotation_editor_buf)
      )
    then
      return
    end
    local text = normalize_annotation_text(
      vim.api.nvim_buf_get_lines(state.annotation_editor_buf, 0, -1, false)
    )
    local submit_cb = state.annotation_editor_submit
    close_annotation_editor()
    if text == "" then
      notify("Annotation cancelled", vim.log.levels.INFO)
      return
    end
    if submit_cb then
      submit_cb(text)
    end
  end

  local cancel = function()
    close_annotation_editor()
    notify("Annotation cancelled", vim.log.levels.INFO)
  end

  vim.keymap.set({ "n", "i" }, "<S-CR>", submit, { buffer = buf, silent = true })
  vim.keymap.set("n", "q", cancel, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, silent = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = submit,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    once = true,
    callback = function(args)
      if tonumber(args.match) == win then
        state.annotation_editor_buf = nil
        state.annotation_editor_win = nil
        state.annotation_editor_prev_win = nil
        state.annotation_editor_submit = nil
      end
    end,
  })

  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      vim.cmd("startinsert")
    end
  end)
end

---@param value string
local function set_yank_registers(value)
  vim.fn.setreg('"', value)

  local has_display = vim.env.DISPLAY or vim.env.WAYLAND_DISPLAY
  local can_use_clipboard = vim.fn.has("clipboard") == 1
    and (
      has_display
      or vim.fn.has("macunix") == 1
      or vim.fn.has("win32") == 1
      or vim.fn.has("win64") == 1
    )

  if can_use_clipboard then
    pcall(vim.fn.setreg, "+", value)
  end
end

---@param lines string[]
---@return string
normalize_annotation_text = function(lines)
  local start_idx = 1
  local end_idx = #lines

  while start_idx <= end_idx and lines[start_idx]:match("^%s*$") do
    start_idx = start_idx + 1
  end
  while end_idx >= start_idx and lines[end_idx]:match("^%s*$") do
    end_idx = end_idx - 1
  end

  if start_idx > end_idx then
    return ""
  end

  return table.concat(vim.list_slice(lines, start_idx, end_idx), "\n")
end

close_annotation_editor = function()
  if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
    vim.cmd("stopinsert")
  end

  if
    state.annotation_editor_win and vim.api.nvim_win_is_valid(state.annotation_editor_win)
  then
    vim.api.nvim_win_close(state.annotation_editor_win, true)
  elseif
    state.annotation_editor_buf and vim.api.nvim_buf_is_valid(state.annotation_editor_buf)
  then
    vim.api.nvim_buf_delete(state.annotation_editor_buf, { force = true })
  end

  if
    state.annotation_editor_prev_win
    and vim.api.nvim_win_is_valid(state.annotation_editor_prev_win)
  then
    vim.api.nvim_set_current_win(state.annotation_editor_prev_win)
  elseif state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
  end

  state.annotation_editor_buf = nil
  state.annotation_editor_win = nil
  state.annotation_editor_prev_win = nil
  state.annotation_editor_submit = nil
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
  }
end

---@param win number
local function apply_zdiff_window_opts(win)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "yes:1"
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
  state.win_opts[win] = nil
end

local uv = vim.uv or vim.loop
local ns_diff = vim.api.nvim_create_namespace("zdiff")
local ns_syntax = vim.api.nvim_create_namespace("zdiff_syntax")
local ns_markers = vim.api.nvim_create_namespace("zdiff_markers")
local ns_annotations = vim.api.nvim_create_namespace("zdiff_annotations")

local function ensure_annotation_highlights()
  vim.api.nvim_set_hl(
    0,
    "ZdiffAnnotationRail",
    { default = true, link = "DiagnosticWarn" }
  )
  vim.api.nvim_set_hl(
    0,
    "ZdiffAnnotationBorder",
    { default = true, link = "DiagnosticWarn" }
  )
  vim.api.nvim_set_hl(0, "ZdiffAnnotationNoteText", { default = true, link = "Normal" })
end

---@param argv string[]
---@param callback fun(code: number, lines: string[])
---@param opts? {preserve_empty_lines?: boolean}
local function run_command_async(argv, callback, opts)
  local preserve_empty_lines = opts and opts.preserve_empty_lines == true
  if vim.system then
    vim.system(argv, { text = true }, function(obj)
      local lines = {}
      if obj.stdout and obj.stdout ~= "" then
        if preserve_empty_lines then
          lines = vim.split(obj.stdout, "\n", { plain = true })
          if #lines > 0 and lines[#lines] == "" then
            table.remove(lines, #lines)
          end
        else
          lines = vim.split(obj.stdout, "\n", { plain = true, trimempty = true })
        end
      end
      vim.schedule(function()
        callback(obj.code or 1, lines)
      end)
    end)
    return
  end

  local stdout = {}
  local job_id = vim.fn.jobstart(argv, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        stdout = data
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        local lines = {}
        for _, line in ipairs(stdout) do
          if preserve_empty_lines or line ~= "" then
            table.insert(lines, line)
          end
        end
        callback(code or 1, lines)
      end)
    end,
  })
  if job_id <= 0 then
    vim.schedule(function()
      callback(1, {})
    end)
  end
end

---Get the status icon for a file
---@param status string
---@return string
local function get_status_icon(status)
  if status == "A" or status == "?" then
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

---@param filepath string
---@return string[]
local function read_worktree_lines(filepath)
  local git_root = get_git_root()
  if not git_root then
    return {}
  end
  local full_path = git_root .. "/" .. filepath
  local file = io.open(full_path, "r")
  if not file then
    return {}
  end
  local lines = {}
  for line in file:lines() do
    table.insert(lines, line)
  end
  file:close()
  return lines
end

---@param rev string
---@param filepath string
---@param done fun(lines: string[])
local function read_git_file_lines_async(rev, filepath, done)
  run_command_async({ "git", "show", rev .. ":" .. filepath }, function(code, lines)
    if code ~= 0 then
      done({})
      return
    end
    done(lines)
  end, { preserve_empty_lines = true })
end

---@param file ZdiffFile
---@param side "old"|"new"
---@return "empty"|"worktree"|"git", string|nil
local function get_content_source(file, side)
  local status = file.status
  if side == "old" then
    if status == "A" or status == "?" then
      return "empty", nil
    end
    if state.base_ref then
      return "git", state.base_ref
    end
    return "git", "HEAD"
  end

  if status == "D" then
    return "empty", nil
  end
  if state.base_ref then
    return "git", "HEAD"
  end
  return "worktree", nil
end

---@param file ZdiffFile
---@param done fun(old_lines: string[], new_lines: string[])
local function get_projection_sources_async(file, done)
  local old_kind, old_rev = get_content_source(file, "old")
  local new_kind, new_rev = get_content_source(file, "new")

  local function load_new(old_lines)
    if new_kind == "empty" then
      done(old_lines, {})
      return
    end
    if new_kind == "worktree" then
      done(old_lines, read_worktree_lines(file.path))
      return
    end
    read_git_file_lines_async(new_rev, file.path, function(new_lines)
      done(old_lines, new_lines)
    end)
  end

  if old_kind == "empty" then
    load_new({})
    return
  end
  if old_kind == "worktree" then
    load_new(read_worktree_lines(file.path))
    return
  end
  read_git_file_lines_async(old_rev, file.path, function(old_lines)
    load_new(old_lines)
  end)
end

---@param code string[]
---@param lang string
---@return table<number, table[]>
local function build_syntax_line_map(code, lang)
  local mapped = {}
  local captures = get_syntax_highlights(code, lang)
  for _, cap in ipairs(captures) do
    mapped[cap.line] = mapped[cap.line] or {}
    table.insert(mapped[cap.line], {
      hl_group = cap.hl_group,
      col_start = cap.col_start,
      col_end = cap.col_end,
    })
  end
  return mapped
end

---@param old_lines string[]
---@param new_lines string[]
---@param lang string
---@return {old: table<number, table[]>, new: table<number, table[]>}|nil
local function build_projection_cache(old_lines, new_lines, lang)
  local syntax_cfg = M.config.syntax or {}
  local max_lines = normalize_non_negative_number(syntax_cfg.max_lines)
  if max_lines > 0 and (#old_lines > max_lines or #new_lines > max_lines) then
    return nil
  end

  return {
    old = build_syntax_line_map(old_lines, lang),
    new = build_syntax_line_map(new_lines, lang),
  }
end

---@param file ZdiffFile
---@return string
local function get_syntax_cache_key(file)
  local pieces = {
    state.base_ref or "",
    file.path,
    file.status,
    tostring(file.insertions),
    tostring(file.deletions),
    tostring(#file.hunks),
  }
  for _, hunk in ipairs(file.hunks) do
    table.insert(
      pieces,
      string.format(
        "%d:%d:%d:%d:%d",
        hunk.old_start,
        hunk.old_count,
        hunk.new_start,
        hunk.new_count,
        #hunk.lines
      )
    )
    for _, line in ipairs(hunk.lines) do
      table.insert(pieces, line.type .. ":" .. line.text)
    end
  end
  local raw = table.concat(pieces, "\n")
  local ok, hash = pcall(vim.fn.sha256, raw)
  if ok and hash and hash ~= "" then
    return hash
  end
  return raw
end

---@param key string
---@param file ZdiffFile
---@param lang string
local function queue_projection_cache(key, file, lang)
  if state.syntax_projection_cache[key] or state.syntax_jobs[key] then
    return
  end

  state.syntax_job_seq = state.syntax_job_seq + 1
  local token = state.syntax_job_seq
  state.syntax_jobs[key] = token
  local refresh_seq = state.refresh_seq

  local function finish(cache)
    if state.syntax_jobs[key] ~= token then
      return
    end
    state.syntax_jobs[key] = nil
    if refresh_seq ~= state.refresh_seq then
      return
    end
    state.syntax_projection_cache[key] = cache or false
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
      render()
    end
  end

  get_projection_sources_async(file, function(old_lines, new_lines)
    finish(build_projection_cache(old_lines, new_lines, lang))
  end)
end

---Render the zdiff buffer
render = function()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  ensure_annotation_highlights()
  vim.bo[state.buf].modifiable = true

  local lines = {}
  local highlights = {} -- {line_idx, hl_group, col_start, col_end}
  local syntax_highlights = {} -- collected after we know line positions
  local syntax_requests = {}
  local syntax_cfg = M.config.syntax or {}
  local syntax_mode =
    normalize_enum(syntax_cfg.mode, { projection = true, hunk = true }, "projection")
  local markers = {} -- {line_idx, text, hl_group}
  state.line_map = {}
  local annotation_visibility = state.annotations_only
      and annotation_focus.collect_visibility(state.files, current_annotations(), function(file)
        if #file.hunks == 0 then
          file.hunks = get_file_diff(file.path, state.base_ref, file.status)
        end
        return file.hunks
      end)
    or nil

  -- Header
  local mode_text
  if state.base_ref then
    mode_text = "Changes vs " .. state.base_ref
  else
    mode_text = "Uncommitted changes"
  end
  if state.annotations_only then
    mode_text = mode_text .. " [annotations only]"
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
    if state.loading_files then
      table.insert(lines, "  Loading changed files...")
    else
      table.insert(lines, "  No changes found")
    end
    table.insert(highlights, { #lines, "Comment", 0, -1 })
  else
    for file_idx, file in ipairs(state.files) do
      local visible_hunks = annotation_visibility and annotation_visibility[file_idx] or nil
      if state.annotations_only and not visible_hunks then
        goto continue_files
      end

      -- File header line
      local icon = file.expanded and M.config.icons.expanded or M.config.icons.collapsed
      local status_icon = get_status_icon(file.status)
      local add_stat = string.format("+%d", file.insertions)
      local del_stat = string.format("-%d", file.deletions)
      local file_line =
        string.format("%s %s %s  %s %s", icon, status_icon, file.path, add_stat, del_stat)
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
          file.hunks = get_file_diff(file.path, state.base_ref, file.status)
        end

        -- Get language for syntax highlighting
        local lang = get_lang_from_path(file.path)

        -- Collect diff-line mappings for syntax projection and hunk fallback.
        local code_lines = {}
        local code_line_mapping = {} -- maps code line index to {buffer_line, prefix_len}
        local projection_lines = {}

        for hunk_idx, hunk in ipairs(file.hunks) do
          local visible_lines = visible_hunks and visible_hunks[hunk_idx] or nil
          if state.annotations_only and not visible_lines then
            goto continue_hunks
          end

          -- Hunk header
          local hunk_header = string.format(
            "  @@ -%d,%d +%d,%d @@",
            hunk.old_start,
            hunk.old_count,
            hunk.new_start,
            hunk.new_count
          )
          -- Keep git metadata out of buffer text; render as virtual text instead.
          table.insert(lines, "  ")
          state.line_map[#lines] = {
            file_idx = file_idx,
            hunk_idx = hunk_idx,
            line_type = "header",
          }
          table.insert(highlights, { #lines, "Comment", 0, -1 })
          table.insert(markers, { #lines, hunk_header, "Comment" })

          -- Diff lines
          for line_idx, diff_line in ipairs(hunk.lines) do
            if state.annotations_only and not (visible_lines and visible_lines[line_idx]) then
              goto continue_diff_lines
            end

            local prefix = "  "
            local display_line = prefix .. diff_line.text
            table.insert(lines, display_line)

            -- Map this line
            state.line_map[#lines] = {
              file_idx = file_idx,
              hunk_idx = hunk_idx,
              line_idx = line_idx,
              lnum = diff_line.new_lnum or diff_line.old_lnum,
              line_type = diff_line.type,
              old_lnum = diff_line.old_lnum,
              new_lnum = diff_line.new_lnum,
            }

            -- Add diff background highlight
            table.insert(
              highlights,
              { #lines, get_line_highlight(diff_line.type), 0, -1 }
            )

            -- Render +/- markers as virtual text so they are not part of buffer content
            if diff_line.type == "add" then
              table.insert(markers, { #lines, " " .. M.config.icons.added, "Comment" })
            elseif diff_line.type == "del" then
              table.insert(markers, { #lines, " " .. M.config.icons.deleted, "Comment" })
            end

            -- Track for syntax highlighting
            if lang then
              local source_side = diff_line.type == "del" and "old" or "new"
              table.insert(projection_lines, {
                buffer_line = #lines,
                prefix_len = #prefix,
                source_side = source_side,
                old_lnum = diff_line.old_lnum,
                new_lnum = diff_line.new_lnum,
              })

              table.insert(code_lines, diff_line.text)
              table.insert(
                code_line_mapping,
                { buffer_line = #lines, prefix_len = #prefix }
              )
            end

            ::continue_diff_lines::
          end

          ::continue_hunks::
        end

        -- Apply syntax highlighting if we have a language
        if lang then
          local used_projection = false
          if syntax_mode == "projection" and #projection_lines > 0 then
            local cache_key = get_syntax_cache_key(file)
            local projection = state.syntax_projection_cache[cache_key]
            if projection then
              for _, line_info in ipairs(projection_lines) do
                local side_map = line_info.source_side == "old" and projection.old
                  or projection.new
                local side_lnum = line_info.source_side == "old" and line_info.old_lnum
                  or line_info.new_lnum
                if side_lnum and side_map[side_lnum] then
                  for _, cap in ipairs(side_map[side_lnum]) do
                    local col_start = line_info.prefix_len + cap.col_start
                    local col_end = cap.col_end == -1 and -1
                      or (line_info.prefix_len + cap.col_end)
                    table.insert(syntax_highlights, {
                      line_info.buffer_line,
                      cap.hl_group,
                      col_start,
                      col_end,
                    })
                  end
                end
              end
              used_projection = true
            elseif projection == nil then
              table.insert(syntax_requests, { key = cache_key, file = file, lang = lang })
            end
          end

          if (not used_projection) and #code_lines > 0 then
            local syn_hls = get_syntax_highlights(code_lines, lang)
            for _, hl in ipairs(syn_hls) do
              local mapping = code_line_mapping[hl.line]
              if mapping then
                -- Offset columns by prefix length
                local col_start = mapping.prefix_len + hl.col_start
                local col_end = hl.col_end == -1 and -1
                  or (mapping.prefix_len + hl.col_end)
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

      ::continue_files::
    end
  end

  if state.annotations_only and #lines == 2 then
    table.insert(lines, "")
    table.insert(lines, "  No annotated blocks")
    table.insert(highlights, { #lines, "Comment", 0, -1 })
  end

  -- Set lines
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)

  -- Apply diff highlights first (background)
  vim.api.nvim_buf_clear_namespace(state.buf, ns_diff, 0, -1)
  for _, hl in ipairs(highlights) do
    local line_idx, hl_group, col_start, col_end = hl[1], hl[2], hl[3], hl[4]
    vim.api.nvim_buf_add_highlight(
      state.buf,
      ns_diff,
      hl_group,
      line_idx - 1,
      col_start,
      col_end
    )
  end

  -- Apply syntax highlights on top (foreground colors)
  vim.api.nvim_buf_clear_namespace(state.buf, ns_syntax, 0, -1)
  for _, hl in ipairs(syntax_highlights) do
    local line_idx, hl_group, col_start, col_end = hl[1], hl[2], hl[3], hl[4]
    vim.api.nvim_buf_add_highlight(
      state.buf,
      ns_syntax,
      hl_group,
      line_idx - 1,
      col_start,
      col_end
    )
  end

  -- Apply virtual +/- markers in the left padding columns
  vim.api.nvim_buf_clear_namespace(state.buf, ns_markers, 0, -1)
  for _, marker in ipairs(markers) do
    local line_idx, text, hl_group = marker[1], marker[2], marker[3]
    vim.api.nvim_buf_set_extmark(state.buf, ns_markers, line_idx - 1, 0, {
      virt_text = { { text, hl_group } },
      virt_text_pos = "overlay",
      priority = 200,
    })
  end

  vim.api.nvim_buf_clear_namespace(state.buf, ns_annotations, 0, -1)
  state.rendered_annotations = {}
  local session_annotations = current_annotations()
  local resolved = {}
  local unresolved_ids = {}
  local expanded_files = {}

  for _, file in ipairs(state.files) do
    if file.expanded then
      expanded_files[file.path] = true
    end
  end

  for _, annotation in ipairs(session_annotations) do
    local match = resolve_annotation(annotation)
    if match then
      table.insert(resolved, {
        id = annotation.id,
        start_line = match.start_line,
        end_line = match.end_line,
        label = annotation_format.format_display_line(annotation),
      })
    elseif not state.loading_files and expanded_files[annotation.file_path] then
      unresolved_ids[annotation.id] = true
    end
  end

  if not state.loading_files and next(unresolved_ids) ~= nil then
    local kept = {}
    for _, annotation in ipairs(session_annotations) do
      if not unresolved_ids[annotation.id] then
        table.insert(kept, annotation)
      end
    end
    state.annotations[current_session_key()] = kept
    session_annotations = kept
  end

  local by_line = {}
  local annotated_lines = {}
  for _, annotation in ipairs(resolved) do
    by_line[annotation.end_line] = by_line[annotation.end_line] or {}
    table.insert(by_line[annotation.end_line], annotation)
    table.insert(state.rendered_annotations, {
      id = annotation.id,
      start_line = annotation.start_line,
      end_line = annotation.end_line,
      label = annotation.label,
    })
    for line = annotation.start_line, annotation.end_line do
      annotated_lines[line] = true
    end
  end

  local sign_lines = vim.tbl_keys(annotated_lines)
  table.sort(sign_lines)
  for _, line in ipairs(sign_lines) do
    vim.api.nvim_buf_set_extmark(state.buf, ns_annotations, line - 1, 0, {
      sign_text = "▌",
      sign_hl_group = "ZdiffAnnotationRail",
      priority = 250,
    })
  end

  local function border_text(char)
    return "    " .. char .. string.rep("─", 42)
  end

  local by_start = {}
  for _, annotation in ipairs(resolved) do
    by_start[annotation.start_line] = by_start[annotation.start_line] or {}
    table.insert(by_start[annotation.start_line], annotation)
  end

  local sorted_starts = vim.tbl_keys(by_start)
  table.sort(sorted_starts)
  for _, start_line in ipairs(sorted_starts) do
    local border_lines = {}
    for _ = 1, #by_start[start_line] do
      table.insert(border_lines, { { border_text("┌"), "ZdiffAnnotationBorder" } })
    end
    vim.api.nvim_buf_set_extmark(state.buf, ns_annotations, start_line - 1, 0, {
      virt_lines = border_lines,
      virt_lines_above = true,
    })
  end

  local sorted_lines = vim.tbl_keys(by_line)
  table.sort(sorted_lines)
  for _, end_line in ipairs(sorted_lines) do
    local annotations = by_line[end_line]
    local virt_lines = {}
    for _, annotation in ipairs(annotations) do
      table.insert(virt_lines, {
        { border_text("└"), "ZdiffAnnotationBorder" },
      })
      for _, note_line in ipairs(build_annotation_note_lines(annotation.label)) do
        table.insert(virt_lines, note_line)
      end
    end
    vim.api.nvim_buf_set_extmark(state.buf, ns_annotations, end_line - 1, 0, {
      virt_lines = virt_lines,
      virt_lines_above = false,
    })
  end

  vim.bo[state.buf].modifiable = false

  -- Queue syntax projection jobs after first paint for responsive rendering.
  for _, req in ipairs(syntax_requests) do
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
  local selection, err = selections.collect_reference_selection(
    state.line_map,
    state.files,
    start_line,
    end_line
  )
  if not selection then
    notify("Cannot yank: " .. err, vim.log.levels.WARN)
    return
  end

  local ref = selection.file_path .. ":" .. selections.format_ranges(selection.ranges)

  set_yank_registers(ref)
  notify("Yanked: " .. ref)
end

_G.yank_ref_visual = function()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  yank_ref(start_line, end_line)
end

---@param start_line number
---@param end_line number
---@param text string
---@return boolean
local function store_annotation(start_line, end_line, text)
  local selection, err = selections.collect_annotation_selection(
    state.line_map,
    state.files,
    start_line,
    end_line
  )
  if not selection then
    notify(err, vim.log.levels.WARN)
    return false
  end

  state.next_annotation_id = state.next_annotation_id + 1
  table.insert(current_annotations(), {
    id = state.next_annotation_id,
    session_key = current_session_key(),
    file_path = selection.file_path,
    anchor_lines = selection.anchor_lines,
    old_ranges = selection.old_ranges,
    new_ranges = selection.new_ranges,
    text = text,
    created_at = state.next_annotation_id,
  })

  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    render()
  end

  return true
end

---@param start_line number
---@param end_line number
add_comment = function(start_line, end_line)
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  local selection, err = selections.collect_annotation_selection(
    state.line_map,
    state.files,
    start_line,
    end_line
  )
  if not selection then
    notify(err, vim.log.levels.WARN)
    return
  end

  open_annotation_editor(selection, function(text)
    if store_annotation(start_line, end_line, text) then
      notify("Annotation added", vim.log.levels.INFO)
    end
  end)
end

delete_comment = function()
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then
    return
  end

  local cursor_line = vim.api.nvim_win_get_cursor(state.win)[1]
  local session_annotations = current_annotations()

  for idx = #state.rendered_annotations, 1, -1 do
    local rendered = state.rendered_annotations[idx]
    if cursor_line >= rendered.start_line and cursor_line <= rendered.end_line then
      for annotation_idx = #session_annotations, 1, -1 do
        if session_annotations[annotation_idx].id == rendered.id then
          table.remove(session_annotations, annotation_idx)
          render()
          notify("Annotation deleted", vim.log.levels.INFO)
          return
        end
      end
    end
  end

  notify("No annotation on this line", vim.log.levels.WARN)
end

toggle_annotations_only = function()
  state.annotations_only = not state.annotations_only

  if state.annotations_only then
    local visibility = annotation_focus.collect_visibility(
      state.files,
      current_annotations(),
      function(file)
        if #file.hunks == 0 then
          file.hunks = get_file_diff(file.path, state.base_ref, file.status)
        end
        return file.hunks
      end
    )
    for file_idx, _ in pairs(visibility) do
      local file = state.files[file_idx]
      if file then
        file.expanded = true
      end
    end
  end

  render()
end

yank_comments = function()
  local session_annotations = current_annotations()
  if #session_annotations == 0 then
    notify("No annotations to yank", vim.log.levels.WARN)
    return
  end

  local blocks = {}
  for _, annotation in ipairs(session_annotations) do
    table.insert(blocks, format_annotation_block(annotation))
  end

  local comment_cfg = M.config.comments or {}
  local prefix = comment_cfg.prefix or ""
  local suffix = comment_cfg.suffix or ""
  local content = prefix .. table.concat(blocks, "\n") .. suffix
  set_yank_registers(content)
  notify(
    string.format(
      "Yanked %d annotation%s",
      #session_annotations,
      #session_annotations == 1 and "" or "s"
    )
  )
end

_G.zdiff_add_comment_visual = function()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  add_comment(start_pos[2], end_pos[2])
end

---Show help in a floating window
show_help = function()
  local keymaps = {
    { M.config.keymaps.goto_file, "Go to file/line" },
    { M.config.keymaps.toggle, "Toggle expand/collapse" },
    { M.config.keymaps.toggle_mode, "Toggle mode (uncommitted/branch)" },
    { M.config.keymaps.refresh, "Refresh" },
    { M.config.keymaps.close, "Close zdiff" },
    { M.config.keymaps.help, "Show this help" },
  }

  if M.config.keymaps.toggle_annotations_only then
    table.insert(keymaps, {
      M.config.keymaps.toggle_annotations_only,
      "Toggle annotations-only view",
    })
  end

  if M.config.keymaps.yank_ref then
    table.insert(keymaps, { M.config.keymaps.yank_ref, "Yank file:line reference" })
  end
  if M.config.keymaps.comment then
    table.insert(keymaps, { M.config.keymaps.comment, "Add annotation" })
  end
  if M.config.keymaps.delete_comment then
    table.insert(keymaps, { M.config.keymaps.delete_comment, "Delete annotation" })
  end
  if M.config.keymaps.yank_comments then
    table.insert(keymaps, { M.config.keymaps.yank_comments, "Yank annotations" })
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

  -- Remember expanded state by path
  local expanded_state = {}
  for _, file in ipairs(state.files) do
    expanded_state[file.path] = file.expanded
  end

  state.refresh_seq = state.refresh_seq + 1
  local refresh_seq = state.refresh_seq
  state.loading_files = true
  state.syntax_jobs = {}
  state.syntax_projection_cache = {}
  render()

  git.load_files_async(state.base_ref, M.config.default_expanded, function(files)
    if refresh_seq ~= state.refresh_seq then
      return
    end

    state.files = files
    for _, file in ipairs(state.files) do
      if expanded_state[file.path] ~= nil then
        file.expanded = expanded_state[file.path]
      end
    end

    state.loading_files = false
    render()

    -- Restore cursor position (clamped to valid range)
    if cursor_line and state.win and vim.api.nvim_win_is_valid(state.win) then
      local line_count = vim.api.nvim_buf_line_count(state.buf)
      cursor_line = math.min(cursor_line, line_count)
      vim.api.nvim_win_set_cursor(state.win, { cursor_line, 0 })
    end
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
  for win, _ in pairs(state.win_opts) do
    restore_window_opts(win)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end
  state.buf = nil
  state.win = nil
  state.loading_files = false
  state.refresh_seq = state.refresh_seq + 1
  state.syntax_jobs = {}
  state.syntax_projection_cache = {}
  state.annotations_only = false
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
    vim.fn.system(
      "git rev-parse --verify " .. vim.fn.shellescape(base_ref) .. " 2>/dev/null"
    )
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
  save_window_opts(state.win)
  apply_zdiff_window_opts(state.win)

  -- Set up keymaps
  local opts = { buffer = state.buf, silent = true }
  vim.keymap.set("n", M.config.keymaps.goto_file, goto_source, opts)
  vim.keymap.set("n", M.config.keymaps.toggle, toggle_expand, opts)
  vim.keymap.set("n", M.config.keymaps.close, close, opts)
  vim.keymap.set("n", M.config.keymaps.refresh, refresh, opts)
  vim.keymap.set("n", M.config.keymaps.toggle_mode, toggle_mode, opts)
  vim.keymap.set("n", M.config.keymaps.help, show_help, opts)

  if M.config.keymaps.yank_ref then
    vim.keymap.set("n", M.config.keymaps.yank_ref, function()
      local cursor_line = vim.api.nvim_win_get_cursor(state.win)[1]
      yank_ref(cursor_line, cursor_line)
    end, { buffer = state.buf, silent = true })
    local yank_ref_key = M.config.keymaps.yank_ref
    vim.api.nvim_buf_set_keymap(
      state.buf,
      "v",
      yank_ref_key,
      ":lua yank_ref_visual()<CR>",
      { silent = true }
    )
  end

  if M.config.keymaps.comment then
    vim.keymap.set("n", M.config.keymaps.comment, function()
      local cursor_line = vim.api.nvim_win_get_cursor(state.win)[1]
      add_comment(cursor_line, cursor_line)
    end, { buffer = state.buf, silent = true })
    vim.api.nvim_buf_set_keymap(
      state.buf,
      "v",
      M.config.keymaps.comment,
      ":lua zdiff_add_comment_visual()<CR>",
      { silent = true }
    )
  end

  if M.config.keymaps.delete_comment then
    vim.keymap.set("n", M.config.keymaps.delete_comment, delete_comment, {
      buffer = state.buf,
      silent = true,
    })
  end

  if M.config.keymaps.yank_comments then
    vim.keymap.set("n", M.config.keymaps.yank_comments, yank_comments, {
      buffer = state.buf,
      silent = true,
    })
  end

  if M.config.keymaps.toggle_annotations_only then
    vim.keymap.set("n", M.config.keymaps.toggle_annotations_only, toggle_annotations_only, {
      buffer = state.buf,
      silent = true,
    })
  end

  -- Auto-refresh when returning to zdiff buffer
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = state.buf,
    callback = function()
      state.win = vim.api.nvim_get_current_win()
      save_window_opts(state.win)
      apply_zdiff_window_opts(state.win)
      if state.loading_files or #state.files == 0 then
        return
      end
      refresh_debounced(200)
    end,
  })

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = state.buf,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      restore_window_opts(win)
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

M._debug_add_annotation = function(start_line, end_line, text)
  return store_annotation(start_line, end_line, text)
end

M._debug_open_annotation_editor = function(start_line, end_line)
  local selection, err = selections.collect_annotation_selection(
    state.line_map,
    state.files,
    start_line,
    end_line
  )
  if not selection then
    return nil, err
  end
  open_annotation_editor(selection, function(text)
    if store_annotation(start_line, end_line, text) then
      notify("Annotation added", vim.log.levels.INFO)
    end
  end)
  return {
    buf = state.annotation_editor_buf,
    win = state.annotation_editor_win,
  }
end

M._debug_submit_annotation_editor = function(lines)
  if
    not (
      state.annotation_editor_buf
      and vim.api.nvim_buf_is_valid(state.annotation_editor_buf)
    )
  then
    return false
  end
  if lines then
    vim.api.nvim_buf_set_lines(state.annotation_editor_buf, 0, -1, false, lines)
  end
  local text = normalize_annotation_text(
    vim.api.nvim_buf_get_lines(state.annotation_editor_buf, 0, -1, false)
  )
  local submit_cb = state.annotation_editor_submit
  close_annotation_editor()
  if text == "" then
    notify("Annotation cancelled", vim.log.levels.INFO)
    return false
  end
  if submit_cb then
    submit_cb(text)
  end
  return true
end

M._debug_cancel_annotation_editor = function()
  if
    not (
      state.annotation_editor_buf
      and vim.api.nvim_buf_is_valid(state.annotation_editor_buf)
    )
  then
    return false
  end
  close_annotation_editor()
  notify("Annotation cancelled", vim.log.levels.INFO)
  return true
end

M._debug_rendered_annotations = function()
  return vim.deepcopy(state.rendered_annotations)
end

M._debug_reset = function()
  state.annotations_only = false
  state.files = {}
  state.buf = nil
  state.win = nil
  state.base_ref = nil
  state.line_map = {}
  state.loading_files = false
  state.refresh_seq = state.refresh_seq + 1
  if state.refresh_timer then
    state.refresh_timer:stop()
    state.refresh_timer:close()
    state.refresh_timer = nil
  end
  state.win_opts = {}
  state.syntax_projection_cache = {}
  state.syntax_jobs = {}
  state.syntax_job_seq = 0
  state.annotations = {}
  state.next_annotation_id = 0
  state.rendered_annotations = {}
  close_annotation_editor()
end

M._debug_state = function()
  return {
    loading_files = state.loading_files,
    pending_syntax_jobs = vim.tbl_count(state.syntax_jobs),
    syntax_cache_entries = vim.tbl_count(state.syntax_projection_cache),
    current_session = current_session_key(),
    annotation_count = #current_annotations(),
    rendered_annotation_count = #state.rendered_annotations,
    annotation_editor_open = state.annotation_editor_win ~= nil
      and vim.api.nvim_win_is_valid(state.annotation_editor_win),
    annotations_only = state.annotations_only,
  }
end

return M
