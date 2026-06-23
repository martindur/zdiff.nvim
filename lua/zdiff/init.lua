local M = {}
local display = require("zdiff.display")
local git = require("zdiff.git")
local syntax = require("zdiff.syntax")
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
---@field root string|nil git repository root for the current zdiff session
---@field base_ref string|nil the git ref to diff against (nil = uncommitted changes vs HEAD)
---@field load_error string|nil most recent file loading error
---@field line_map table<number, {file_idx: number, hunk_idx: number|nil, line_idx: number|nil, lnum: number|nil}>
---@field file_header_lines table<number, number>
---@field loading_files boolean whether file list refresh is in progress
---@field refresh_seq number monotonically increasing refresh generation
---@field refresh_timer uv.uv_timer_t|nil timer used for debounced refresh
---@field win_opts table<number, {number: boolean, relativenumber: boolean, signcolumn: string, wrap: boolean, cursorline: boolean, winbar: string|nil}>
---@field syntax_projection_cache table<string, {old: table<number, table[]>, new: table<number, table[]>}|false>
---@field syntax_jobs table<string, integer>
---@field syntax_job_seq integer
---@field syntax_debug {projected_files: string[], fallback_files: string[], skipped_files: table<string, string>}

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
  win_opts = {},
  syntax_projection_cache = {},
  syntax_jobs = {},
  syntax_job_seq = 0,
  syntax_debug = {
    projected_files = {},
    fallback_files = {},
    skipped_files = {},
  },
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
---@field keymaps table<string, string> Keymap bindings
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
---@param file ZdiffFile
---@param base_ref string|nil git ref to diff against, or nil for uncommitted
---@return ZdiffHunk[]
local function get_file_diff(file, base_ref)
  -- For untracked files, show entire file as additions
  if file.status == "?" then
    if not state.root then
      return {}
    end

    local result = git.read_worktree_lines(state.root, file.path)
    if not result.ok then
      return {}
    end

    local lines = {}
    for _, line in ipairs(result.data or {}) do
      table.insert(lines, { type = "add", text = line, new_lnum = #lines + 1 })
    end

    if #lines == 0 then
      return {}
    end

    return {
      {
        header = string.format("@@ -0,0 +1,%d @@ (new file)", #lines),
        old_start = 0,
        old_count = 0,
        new_start = 1,
        new_count = #lines,
        lines = lines,
      },
    }
  end

  if not state.root then
    return {}
  end

  local result = git.file_diff_lines(state.root, base_ref, file)
  if not result.ok then
    return {}
  end

  return parse_diff_hunks(result.data or {})
end

---Get the status icon for a file
---@param status string
---@return string
local function get_status_icon(status)
  return display.get_status_icon(status, M.config.icons)
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

---@param code string[]
---@param lang string
---@return table<number, table[]>
local function build_syntax_line_map(code, lang)
  local mapped = {}
  local captures = syntax.get_highlights(code, lang)
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
    state.root or "",
    state.base_ref or "",
    file.path,
    file.display_path or "",
    file.old_path or "",
    file.new_path or "",
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
  state.file_header_lines = {}
  state.syntax_debug = {
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
    for file_idx, file in ipairs(state.files) do
      -- File header line
      local icon = file.expanded and M.config.icons.expanded or M.config.icons.collapsed
      local status_icon = get_status_icon(file.status)
      local add_stat = string.format("+%d", file.insertions)
      local del_stat = string.format("-%d", file.deletions)
      local file_line = string.format(
        "%s %s %s  %s %s",
        icon,
        status_icon,
        file.display_path or file.path,
        add_stat,
        del_stat
      )
      table.insert(lines, file_line)

      -- Map this line to the file
      state.line_map[#lines] = { file_idx = file_idx }
      state.file_header_lines[file_idx] = #lines

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
          file.hunks = get_file_diff(file, state.base_ref)
        end

        -- Get language for syntax highlighting
        local lang = syntax.get_lang_from_path(file.path)

        -- Collect diff-line mappings for syntax projection and hunk fallback.
        local code_lines = {}
        local code_line_mapping = {} -- maps code line index to {buffer_line, prefix_len}
        local projection_lines = {}

        for hunk_idx, hunk in ipairs(file.hunks) do
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
          state.line_map[#lines] = { file_idx = file_idx, hunk_idx = hunk_idx }
          table.insert(highlights, { #lines, "Comment", 0, -1 })
          table.insert(markers, { #lines, hunk_header, "Comment" })

          -- Diff lines
          for line_idx, diff_line in ipairs(hunk.lines) do
            local prefix = "  "
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
          end
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
            local syn_hls = syntax.get_highlights(code_lines, lang)
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

          if used_projection then
            table.insert(state.syntax_debug.projected_files, file.path)
          elseif #code_lines > 0 then
            table.insert(state.syntax_debug.fallback_files, file.path)
          else
            state.syntax_debug.skipped_files[file.path] = "no diff lines"
          end
        else
          state.syntax_debug.skipped_files[file.path] = "no treesitter language"
        end
      end
    end
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

  vim.bo[state.buf].modifiable = false
  update_winbar()

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

  local filepath = state.root and (state.root .. "/" .. file.path) or file.path

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
  local keymaps = {
    { M.config.keymaps.goto_file, "Go to file/line" },
    { M.config.keymaps.toggle, "Toggle expand/collapse" },
    { M.config.keymaps.toggle_mode, "Toggle mode (uncommitted/branch)" },
    { M.config.keymaps.refresh, "Refresh" },
    { M.config.keymaps.close, "Close zdiff" },
    { M.config.keymaps.help, "Show this help" },
  }

  if M.config.keymaps.yank_ref then
    table.insert(keymaps, { M.config.keymaps.yank_ref, "Yank file:line reference" })
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
    render()

    -- Restore cursor position (clamped to valid range)
    if cursor_line and state.win and vim.api.nvim_win_is_valid(state.win) then
      local line_count = vim.api.nvim_buf_line_count(state.buf)
      cursor_line = math.min(cursor_line, line_count)
      vim.api.nvim_win_set_cursor(state.win, { cursor_line, 0 })
      update_winbar(state.win)
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
  state.syntax_jobs = {}
  state.syntax_projection_cache = {}
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

M._debug_state = function()
  return {
    loading_files = state.loading_files,
    pending_syntax_jobs = vim.tbl_count(state.syntax_jobs),
    syntax_cache_entries = vim.tbl_count(state.syntax_projection_cache),
    syntax = vim.deepcopy(state.syntax_debug),
  }
end

return M
