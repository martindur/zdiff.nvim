local M = {}
local comments = require("zdiff.review.comments")
local diff_view = require("zdiff.diff_view")
local display = require("zdiff.display")
local syntax = require("zdiff.syntax")

local description_preview_lines = 8

---@param text string
---@return string[]
local function split_lines(text)
  if text == "" then
    return {}
  end

  local lines = vim.split(text, "\n", { plain = true })
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  return lines
end

---@param pr ZdiffReviewPr
---@param pending_pr number|nil
---@return string
local function format_pr(pr, pending_pr)
  local meta = {}
  if pr.author ~= "" then
    table.insert(meta, "@" .. pr.author)
  end
  if pr.is_draft then
    table.insert(meta, "draft")
  end
  if pr.review_decision ~= "" then
    table.insert(meta, pr.review_decision:lower())
  end
  if pending_pr == pr.number then
    table.insert(meta, "submitting...")
  end

  local suffix = ""
  if #meta > 0 then
    suffix = "  " .. table.concat(meta, " ")
  end

  return string.format(
    "#%d %s%s  +%d -%d",
    pr.number,
    pr.title,
    suffix,
    pr.additions,
    pr.deletions
  )
end

---@param count number
---@param word string
---@return string
local function count_word(count, word)
  if count == 1 then
    return "1 " .. word
  end
  return tostring(count) .. " " .. word .. "s"
end

---@param pr ZdiffReviewPr|nil
---@return string
local function pr_body(pr)
  if not pr or type(pr.body) ~= "string" then
    return ""
  end
  return vim.trim(pr.body:gsub("\r\n", "\n"):gsub("\r", "\n"))
end

---@param pr ZdiffReviewPr|nil
---@return boolean
function M.has_pr_body(pr)
  return pr_body(pr) ~= ""
end

---@param markdown_lines string[]
---@param line_mappings table<number, {buffer_line: number, prefix_len: number}>
---@param syntax_highlights table[]
local function add_description_syntax(markdown_lines, line_mappings, syntax_highlights)
  local lang = syntax.get_lang_from_filetype("markdown")
  if not lang then
    return
  end

  for _, hl in ipairs(syntax.get_highlights(markdown_lines, lang)) do
    local mapping = line_mappings[hl.line]
    if mapping then
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

---@param state ZdiffReviewState
---@param lines string[]
---@param highlights table[]
---@param syntax_highlights table[]
local function render_pr_description(state, lines, highlights, syntax_highlights)
  local body = pr_body(state.active_pr)
  if body == "" then
    return
  end

  local body_lines = split_lines(body)
  if #body_lines == 0 then
    return
  end

  table.insert(lines, " Description")
  table.insert(highlights, { #lines, "Title", 0, -1 })

  local limit = state.description_expanded and #body_lines
    or math.min(#body_lines, description_preview_lines)
  local line_mappings = {}
  for idx = 1, limit do
    table.insert(lines, "  " .. body_lines[idx])
    line_mappings[idx] = {
      buffer_line = #lines,
      prefix_len = 2,
    }
    table.insert(highlights, { #lines, "Comment", 0, -1 })
  end
  add_description_syntax(body_lines, line_mappings, syntax_highlights)

  local remaining = #body_lines - limit
  if remaining > 0 then
    local suffix = remaining == 1 and "line" or "lines"
    table.insert(
      lines,
      string.format("  ... %d more description %s", remaining, suffix)
    )
    table.insert(highlights, { #lines, "Comment", 0, -1 })
  end

  table.insert(lines, string.rep("-", 60))
  table.insert(highlights, { #lines, "Comment", 0, -1 })
end

---@param state ZdiffReviewState
---@param ctx table
---@return table[]
local function file_summary_rows(state, ctx)
  if ctx.file.expanded then
    if ctx.file.patch_unavailable then
      return {
        {
          text = "  Patch unavailable from GitHub (binary or too large)",
          hl_group = "Comment",
        },
      }
    end
    return {}
  end

  local threads, comment_count, authors =
    comments.file_counts(state.files, state.comments, ctx.file_idx)
  if threads == 0 then
    return {}
  end

  local text = "  "
    .. count_word(threads, "thread")
    .. ", "
    .. count_word(comment_count, "comment")
  if #authors > 0 then
    text = text .. " by " .. table.concat(authors, ", ")
  end

  return {
    {
      text = text,
      hl_group = "ZdiffReviewThread",
      map = { kind = "review_thread_summary", file_idx = ctx.file_idx },
    },
  }
end

---@param state ZdiffReviewState
---@param ctx table
---@return table[]
local function comment_rows(state, ctx)
  local target = ctx.mapping.review_target
  if not target then
    return {}
  end

  local rows = {}
  local key = comments.target_key(target)
  if state.posting[key] then
    table.insert(rows, { text = "    Posting...", hl_group = "ZdiffReviewThread" })
  end

  for _, comment in ipairs(state.comments[key] or {}) do
    local author = comment.author or ""
    local prefix = author ~= "" and ("@" .. author .. ": ") or ""
    local indent = comment.in_reply_to_id and "      " or "    "
    for line_idx, body_line in
      ipairs(vim.split(comment.body:gsub("\r\n", "\n"), "\n", { plain = true }))
    do
      local row = {
        text = indent .. (line_idx == 1 and prefix or "") .. body_line,
        hl_group = "ZdiffReviewThread",
      }
      if line_idx == 1 and comment.id and not comment.in_reply_to_id then
        row.map = {
          kind = "review_comment",
          file_idx = ctx.file_idx,
          comment = comment,
        }
      end
      table.insert(rows, row)
    end

    if
      comment.id
      and not comment.in_reply_to_id
      and state.posting[comments.reply_key(comment)]
    then
      table.insert(rows, { text = "      Replying...", hl_group = "ZdiffReviewThread" })
    end
  end

  return rows
end

---@param state ZdiffReviewState
---@param lines string[]
---@param highlights table[]
---@return table
function M.render_list(state, lines, highlights)
  local line_map = {}
  local title = " zdiff.review: Pull requests"
  if state.loading then
    title = title .. " (loading...)"
  end

  table.insert(lines, title)
  table.insert(lines, string.rep("-", 60))
  table.insert(highlights, { #lines - 1, "Title", 0, -1 })
  table.insert(highlights, { #lines, "Comment", 0, -1 })

  if #state.prs == 0 then
    table.insert(lines, "")
    if state.load_error then
      table.insert(lines, "  Error loading pull requests: " .. state.load_error)
    elseif state.loading then
      table.insert(lines, "  Loading pull requests...")
    else
      table.insert(lines, "  No pull requests found")
    end
    table.insert(highlights, { #lines, "Comment", 0, -1 })
  else
    for idx, pr in ipairs(state.prs) do
      local line = format_pr(pr, state.pr_action_pending)
      table.insert(lines, line)
      line_map[#lines] = idx

      local stat_ranges = display.stat_ranges(line, pr.additions, pr.deletions)

      table.insert(highlights, { #lines, "Directory", 0, stat_ranges.add_start })
      table.insert(
        highlights,
        { #lines, "DiffAdd", stat_ranges.add_start, stat_ranges.add_end }
      )
      table.insert(
        highlights,
        { #lines, "DiffDelete", stat_ranges.del_start, stat_ranges.del_end }
      )
    end
  end

  return {
    lines = lines,
    highlights = highlights,
    syntax_highlights = {},
    syntax_requests = {},
    markers = {},
    line_map = line_map,
  }
end

---@param state ZdiffReviewState
---@param lines string[]
---@param highlights table[]
---@param opts {icons: table, syntax: table, map_diff_line: fun(mapping: table, file: table, diff_line: table)}
---@return table
function M.render_diff(state, lines, highlights, opts)
  local syntax_highlights = {}
  local pr = state.active_pr
  local title = " zdiff.review: PR diff"
  if pr then
    title = string.format(" zdiff.review: PR #%d %s", pr.number, pr.title)
  end
  if state.loading then
    title = title .. " (loading...)"
  elseif state.comments_loading then
    title = title .. " (loading comments...)"
  end

  table.insert(lines, title)
  table.insert(lines, string.rep("-", 60))
  table.insert(highlights, { #lines - 1, "Title", 0, -1 })
  table.insert(highlights, { #lines, "Comment", 0, -1 })
  if state.comment_error then
    table.insert(lines, "  Error loading comments: " .. state.comment_error)
    table.insert(highlights, { #lines, "Comment", 0, -1 })
  end
  render_pr_description(state, lines, highlights, syntax_highlights)

  if #state.files == 0 then
    table.insert(lines, "")
    if state.load_error then
      table.insert(lines, "  Error loading PR diff: " .. state.load_error)
    elseif state.loading then
      table.insert(lines, "  Loading PR diff...")
    else
      table.insert(lines, "  No diff found")
    end
    table.insert(highlights, { #lines, "Comment", 0, -1 })
    return {
      lines = lines,
      highlights = highlights,
      syntax_highlights = syntax_highlights,
      syntax_requests = {},
      markers = {},
      line_map = {},
    }
  end

  return diff_view.render({
    lines = lines,
    highlights = highlights,
    syntax_highlights = syntax_highlights,
    files = state.files,
    icons = opts.icons,
    syntax = opts.syntax,
    syntax_projection_cache = state.syntax_projection_cache,
    syntax_cache_prefix = table.concat({
      state.root or "",
      pr and tostring(pr.number) or "",
      pr and (pr.base_ref_oid or "") or "",
      pr and (pr.head_ref_oid or "") or "",
    }, "\n"),
    map_diff_line = opts.map_diff_line,
    extra_file_rows = function(ctx)
      return file_summary_rows(state, ctx)
    end,
    extra_rows = function(ctx)
      return comment_rows(state, ctx)
    end,
  })
end

return M
