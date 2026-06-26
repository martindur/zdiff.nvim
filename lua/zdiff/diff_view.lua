local M = {}
local display = require("zdiff.display")
local syntax = require("zdiff.syntax")

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
---@param syntax_cfg table|nil
---@return {old: table<number, table[]>, new: table<number, table[]>}|nil
function M.build_projection_cache(old_lines, new_lines, lang, syntax_cfg)
  syntax_cfg = syntax_cfg or {}
  local max_lines = normalize_non_negative_number(syntax_cfg.max_lines)
  if max_lines > 0 and (#old_lines > max_lines or #new_lines > max_lines) then
    return nil
  end

  return {
    old = build_syntax_line_map(old_lines, lang),
    new = build_syntax_line_map(new_lines, lang),
  }
end

---@param prefix string|nil
---@param file table
---@return string
function M.syntax_cache_key(prefix, file)
  local pieces = {
    prefix or "",
    file.path,
    file.display_path or "",
    file.old_path or "",
    file.new_path or "",
    file.review_base_ref or "",
    file.review_head_ref or "",
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

---@param state table
---@param req {key: string, file: table, lang: string}
---@param opts {syntax: table|nil, refresh_seq: number|nil, load_sources: fun(file: table, done: fun(old_lines: string[], new_lines: string[])), on_done: fun()|nil}
function M.queue_projection_cache(state, req, opts)
  if state.syntax_projection_cache[req.key] ~= nil or state.syntax_jobs[req.key] then
    return
  end

  state.syntax_job_seq = (state.syntax_job_seq or 0) + 1
  local token = state.syntax_job_seq
  state.syntax_jobs[req.key] = token
  local refresh_seq = opts.refresh_seq

  opts.load_sources(req.file, function(old_lines, new_lines)
    if state.syntax_jobs[req.key] ~= token then
      return
    end
    state.syntax_jobs[req.key] = nil
    if refresh_seq and state.refresh_seq ~= refresh_seq then
      return
    end
    if old_lines and new_lines then
      state.syntax_projection_cache[req.key] = M.build_projection_cache(
        old_lines,
        new_lines,
        req.lang,
        opts.syntax
      ) or false
    else
      state.syntax_projection_cache[req.key] = false
    end
    if opts.on_done then
      opts.on_done()
    end
  end)
end

---@param ctx table
---@param row table
local function append_extra_row(ctx, row)
  table.insert(ctx.lines, row.text or "")
  if row.map then
    ctx.line_map[#ctx.lines] = row.map
  end
  table.insert(
    ctx.highlights,
    { #ctx.lines, row.hl_group or "Comment", row.col_start or 0, row.col_end or -1 }
  )
end

---@param ctx table
---@param line_info table
---@param projection table
local function add_projected_syntax(ctx, line_info, projection)
  local side_map = line_info.source_side == "old" and projection.old or projection.new
  local side_lnum = line_info.source_side == "old" and line_info.old_lnum
    or line_info.new_lnum
  if not side_lnum or not side_map[side_lnum] then
    return
  end

  for _, cap in ipairs(side_map[side_lnum]) do
    local col_start = line_info.prefix_len + cap.col_start
    local col_end = cap.col_end == -1 and -1 or (line_info.prefix_len + cap.col_end)
    table.insert(ctx.syntax_highlights, {
      line_info.buffer_line,
      cap.hl_group,
      col_start,
      col_end,
    })
  end
end

---@param ctx table
---@param code_lines string[]
---@param code_line_mapping table[]
---@param lang string
local function add_hunk_syntax(ctx, code_lines, code_line_mapping, lang)
  local syn_hls = syntax.get_highlights(code_lines, lang)
  for _, hl in ipairs(syn_hls) do
    local mapping = code_line_mapping[hl.line]
    if mapping then
      local col_start = mapping.prefix_len + hl.col_start
      local col_end = hl.col_end == -1 and -1 or (mapping.prefix_len + hl.col_end)
      table.insert(ctx.syntax_highlights, {
        mapping.buffer_line,
        hl.hl_group,
        col_start,
        col_end,
      })
    end
  end
end

---@param ctx table
---@param file_idx number
---@param file table
local function render_loaded_hunks(ctx, file_idx, file)
  local lang = syntax.get_lang_from_path(file.path)
  local code_lines = {}
  local code_line_mapping = {}
  local projection_lines = {}

  for hunk_idx, hunk in ipairs(file.hunks) do
    local hunk_header = display.format_hunk_header(hunk, "  ")
    table.insert(ctx.lines, "  ")
    ctx.line_map[#ctx.lines] = {
      kind = "hunk",
      file_idx = file_idx,
      hunk_idx = hunk_idx,
    }
    table.insert(ctx.highlights, { #ctx.lines, "Comment", 0, -1 })
    table.insert(ctx.markers, { #ctx.lines, hunk_header, "Comment" })

    for line_idx, diff_line in ipairs(hunk.lines) do
      local prefix = "  "
      table.insert(ctx.lines, prefix .. diff_line.text)

      local mapping = {
        kind = "line",
        file_idx = file_idx,
        hunk_idx = hunk_idx,
        line_idx = line_idx,
        lnum = diff_line.new_lnum or diff_line.old_lnum,
      }
      if ctx.map_diff_line then
        ctx.map_diff_line(mapping, file, diff_line)
      end
      ctx.line_map[#ctx.lines] = mapping

      table.insert(
        ctx.highlights,
        { #ctx.lines, display.get_line_highlight(diff_line.type), 0, -1 }
      )

      if diff_line.type == "add" then
        table.insert(ctx.markers, { #ctx.lines, " " .. ctx.icons.added, "Comment" })
      elseif diff_line.type == "del" then
        table.insert(ctx.markers, { #ctx.lines, " " .. ctx.icons.deleted, "Comment" })
      end

      if lang then
        local source_side = diff_line.type == "del" and "old" or "new"
        table.insert(projection_lines, {
          buffer_line = #ctx.lines,
          prefix_len = #prefix,
          source_side = source_side,
          old_lnum = diff_line.old_lnum,
          new_lnum = diff_line.new_lnum,
        })
        table.insert(code_lines, diff_line.text)
        table.insert(
          code_line_mapping,
          { buffer_line = #ctx.lines, prefix_len = #prefix }
        )
      end

      if ctx.extra_rows then
        for _, row in
          ipairs(ctx.extra_rows({
            file_idx = file_idx,
            file = file,
            hunk_idx = hunk_idx,
            hunk = hunk,
            line_idx = line_idx,
            diff_line = diff_line,
            mapping = mapping,
          }) or {})
        do
          append_extra_row(ctx, row)
        end
      end
    end
  end

  if not lang then
    ctx.syntax_debug.skipped_files[file.path] = "no treesitter language"
    return
  end

  local used_projection = false
  if ctx.syntax_mode == "projection" and #projection_lines > 0 then
    local cache_key = M.syntax_cache_key(ctx.syntax_cache_prefix, file)
    local projection = ctx.syntax_projection_cache[cache_key]
    if projection then
      for _, line_info in ipairs(projection_lines) do
        add_projected_syntax(ctx, line_info, projection)
      end
      used_projection = true
    elseif projection == nil then
      table.insert(ctx.syntax_requests, { key = cache_key, file = file, lang = lang })
    end
  end

  if (not used_projection) and #code_lines > 0 then
    add_hunk_syntax(ctx, code_lines, code_line_mapping, lang)
  end

  if used_projection then
    table.insert(ctx.syntax_debug.projected_files, file.path)
  elseif #code_lines > 0 then
    table.insert(ctx.syntax_debug.fallback_files, file.path)
  else
    ctx.syntax_debug.skipped_files[file.path] = "no diff lines"
  end
end

---@param opts {lines: string[], highlights: table[], files: table[], icons: table, syntax: table|nil, syntax_projection_cache: table|nil, syntax_cache_prefix: string|nil, queue_hunks: fun(file_idx: number, file: table)|nil, map_diff_line: fun(mapping: table, file: table, diff_line: table)|nil, extra_rows: fun(ctx: table): table[]|nil}
---@return table
function M.render(opts)
  local ctx = {
    lines = opts.lines,
    highlights = opts.highlights,
    syntax_highlights = {},
    syntax_requests = {},
    markers = {},
    line_map = {},
    file_header_lines = {},
    files = opts.files or {},
    icons = opts.icons,
    syntax_cfg = opts.syntax or {},
    syntax_projection_cache = opts.syntax_projection_cache or {},
    syntax_cache_prefix = opts.syntax_cache_prefix,
    queue_hunks = opts.queue_hunks,
    map_diff_line = opts.map_diff_line,
    extra_rows = opts.extra_rows,
    syntax_debug = {
      projected_files = {},
      fallback_files = {},
      skipped_files = {},
    },
  }
  ctx.syntax_mode =
    normalize_enum(ctx.syntax_cfg.mode, { projection = true, hunk = true }, "projection")

  for file_idx, file in ipairs(ctx.files) do
    local icon = file.expanded and ctx.icons.expanded or ctx.icons.collapsed
    local file_line = display.format_file_line({
      icon = icon,
      status_icon = display.get_status_icon(file.status, ctx.icons),
      path = file.display_path or file.path,
      additions = file.insertions,
      deletions = file.deletions,
    })
    table.insert(ctx.lines, file_line.text)
    ctx.line_map[#ctx.lines] = { kind = "file", file_idx = file_idx }
    ctx.file_header_lines[file_idx] = #ctx.lines

    table.insert(ctx.highlights, { #ctx.lines, "Directory", 0, file_line.add_start })
    table.insert(
      ctx.highlights,
      { #ctx.lines, "DiffAdd", file_line.add_start, file_line.add_end }
    )
    table.insert(
      ctx.highlights,
      { #ctx.lines, "DiffDelete", file_line.del_start, file_line.del_end }
    )

    if file.expanded then
      if file.hunk_status == "unloaded" and ctx.queue_hunks then
        ctx.queue_hunks(file_idx, file)
      end

      if file.hunk_status == "loading" then
        table.insert(ctx.lines, "  Loading diff...")
        ctx.line_map[#ctx.lines] = { kind = "loading", file_idx = file_idx }
        table.insert(ctx.highlights, { #ctx.lines, "Comment", 0, -1 })
      elseif file.hunk_status == "failed" then
        table.insert(
          ctx.lines,
          "  Error loading diff: " .. (file.hunk_error or "unknown")
        )
        ctx.line_map[#ctx.lines] = { kind = "error", file_idx = file_idx }
        table.insert(ctx.highlights, { #ctx.lines, "Comment", 0, -1 })
      elseif file.hunk_status == "loaded" then
        render_loaded_hunks(ctx, file_idx, file)
      end
    end
  end

  return ctx
end

---@param buf number
---@param rendered table
---@param ns {diff: number, syntax: number|nil, markers: number|nil}
function M.apply(buf, rendered, ns)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, rendered.lines)

  vim.api.nvim_buf_clear_namespace(buf, ns.diff, 0, -1)
  for _, hl in ipairs(rendered.highlights) do
    vim.api.nvim_buf_add_highlight(buf, ns.diff, hl[2], hl[1] - 1, hl[3], hl[4])
  end

  if ns.syntax then
    vim.api.nvim_buf_clear_namespace(buf, ns.syntax, 0, -1)
    for _, hl in ipairs(rendered.syntax_highlights or {}) do
      vim.api.nvim_buf_add_highlight(buf, ns.syntax, hl[2], hl[1] - 1, hl[3], hl[4])
    end
  end

  if ns.markers then
    vim.api.nvim_buf_clear_namespace(buf, ns.markers, 0, -1)
    for _, marker in ipairs(rendered.markers or {}) do
      vim.api.nvim_buf_set_extmark(buf, ns.markers, marker[1] - 1, 0, {
        virt_text = { { marker[2], marker[3] } },
        virt_text_pos = "overlay",
        priority = 200,
      })
    end
  end
end

return M
