local M = {}
local comments = require("zdiff.review.comments")
local diff_view = require("zdiff.diff_view")
local git = require("zdiff.git")
local github = require("zdiff.review.github")
local view = require("zdiff.review.view")

---@class ZdiffReviewPr
---@field number number
---@field title string
---@field author string
---@field additions number
---@field deletions number
---@field review_decision string
---@field is_draft boolean
---@field base_ref_oid string|nil
---@field head_ref_oid string|nil
---@field body string|nil

---@class ZdiffReviewState
---@field buf number|nil
---@field win number|nil
---@field root string|nil
---@field view "list"|"diff"
---@field prs ZdiffReviewPr[]
---@field files ZdiffFile[]
---@field active_pr ZdiffReviewPr|nil
---@field description_expanded boolean
---@field line_map table<number, table|number>
---@field comments table<string, ZdiffReviewPostedComment[]>
---@field posting table<string, boolean>
---@field pr_action_pending number|nil
---@field loading boolean
---@field comments_loading boolean
---@field comment_error string|nil
---@field load_error string|nil
---@field refresh_seq number
---@field syntax_projection_cache table<string, {old: table<number, table[]>, new: table<number, table[]>}|false>
---@field syntax_jobs table<string, integer>
---@field syntax_job_seq integer
---@field syntax_debug {projected_files: string[], fallback_files: string[], skipped_files: table<string, string>}
---@field backend table|nil

---@type ZdiffReviewState
local state = {
  buf = nil,
  win = nil,
  root = nil,
  view = "list",
  prs = {},
  files = {},
  active_pr = nil,
  description_expanded = false,
  line_map = {},
  comments = {},
  posting = {},
  pr_action_pending = nil,
  loading = false,
  comments_loading = false,
  comment_error = nil,
  load_error = nil,
  refresh_seq = 0,
  syntax_projection_cache = {},
  syntax_jobs = {},
  syntax_job_seq = 0,
  syntax_debug = {
    projected_files = {},
    fallback_files = {},
    skipped_files = {},
  },
  backend = nil,
}

local render

local ns_diff = vim.api.nvim_create_namespace("zdiff_review")
local ns_syntax = vim.api.nvim_create_namespace("zdiff_review_syntax")
local ns_markers = vim.api.nvim_create_namespace("zdiff_review_markers")
vim.api.nvim_set_hl(0, "ZdiffReviewThread", { link = "DiagnosticWarn" })
local icons = {
  collapsed = "",
  expanded = "",
  added = "+",
  deleted = "-",
  modified = "~",
}
local syntax_config = {
  mode = "projection",
  max_lines = 8000,
}

---@class ZdiffReviewCommentTarget
---@field pr_number number
---@field path string
---@field side "LEFT"|"RIGHT"
---@field line number

---@class ZdiffReviewComment
---@field path string
---@field side "LEFT"|"RIGHT"
---@field line number
---@field body string
---@field commit_id string

---@class ZdiffReviewPostedComment
---@field id number|nil
---@field in_reply_to_id number|nil
---@field path string
---@field side "LEFT"|"RIGHT"
---@field line number
---@field body string
---@field author string

local function notify(msg, level)
  vim.notify("[zdiff.review] " .. msg, level or vim.log.levels.INFO)
end

local function render_error(msg)
  return vim.trim((msg or "unknown review error"):gsub("%s+", " "))
end

---@param file table
---@param pr ZdiffReviewPr
---@return ZdiffFile
local function normalize_backend_file(file, pr)
  file.expanded = file.expanded == true
  file.hunk_status = file.hunk_status or "loaded"
  file.review_base_ref = file.review_base_ref or pr.base_ref_oid
  file.review_head_ref = file.review_head_ref or pr.head_ref_oid
  return file
end

local default_backend = github

---@return table
local function backend()
  return state.backend or default_backend
end

---@param file table
---@param done fun(old_lines: string[]|nil, new_lines: string[]|nil)
local function get_review_sources_async(file, done)
  local read_file = backend().read_file
  if not read_file or not state.root then
    done(nil, nil)
    return
  end

  local function load(path, ref, cb)
    if not path then
      cb(true, {})
      return
    end
    if not ref then
      cb(false, nil)
      return
    end
    read_file(state.root, path, ref, function(result)
      cb(result.ok, result.data or {})
    end)
  end

  local old_lines = nil
  local new_lines = nil
  local failed = false
  local completed = false

  local function maybe_done()
    if completed then
      return
    end
    if failed then
      completed = true
      done(nil, nil)
    elseif old_lines and new_lines then
      completed = true
      done(old_lines, new_lines)
    end
  end

  load(file.old_path, file.review_base_ref, function(ok, lines)
    if not ok then
      failed = true
    else
      old_lines = lines
    end
    maybe_done()
  end)

  load(file.new_path, file.review_head_ref, function(ok, lines)
    if not ok then
      failed = true
    else
      new_lines = lines
    end
    maybe_done()
  end)
end

---@param req {key: string, file: table, lang: string}
local function queue_projection_cache(req)
  diff_view.queue_projection_cache(state, req, {
    syntax = syntax_config,
    refresh_seq = state.refresh_seq,
    load_sources = get_review_sources_async,
    on_done = function()
      render()
    end,
  })
end

---@param mapping table
---@param file table
---@param diff_line ZdiffLine
local function map_diff_line(mapping, file, diff_line)
  mapping.review_target = comments.target(state.active_pr, file, diff_line)
end

render = function()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  vim.bo[state.buf].modifiable = true
  state.line_map = {}

  local lines = {}
  local highlights = {}
  local rendered = {
    lines = lines,
    highlights = highlights,
    syntax_highlights = {},
    syntax_requests = {},
    markers = {},
    line_map = state.line_map,
    syntax_debug = state.syntax_debug,
  }
  if state.view == "diff" then
    rendered = view.render_diff(state, lines, highlights, {
      icons = icons,
      syntax = syntax_config,
      map_diff_line = map_diff_line,
    })
    state.line_map = rendered.line_map or {}
    state.syntax_debug = rendered.syntax_debug or state.syntax_debug
  else
    rendered = view.render_list(state, lines, highlights)
    state.line_map = rendered.line_map or {}
  end

  diff_view.apply(state.buf, rendered, {
    diff = ns_diff,
    syntax = ns_syntax,
    markers = ns_markers,
  })
  vim.bo[state.buf].modifiable = false

  for _, req in ipairs(rendered.syntax_requests or {}) do
    queue_projection_cache(req)
  end
end

---@param pr ZdiffReviewPr
---@param done fun()
local function load_pr_details(pr, done)
  if type(pr.body) == "string" then
    done()
    return
  end

  local read_pr = backend().read_pr
  if not read_pr or not state.root then
    done()
    return
  end

  read_pr(state.root, pr.number, function(result)
    if result.ok and type(result.data) == "table" then
      local body = result.data.body
      if body == nil then
        body = result.data.description
      end
      if type(body) == "string" then
        pr.body = body
      end
    end
    done()
  end)
end

---@param pr ZdiffReviewPr
local function load_pr_comments(pr)
  local list_comments = backend().list_comments
  if not list_comments or not state.root then
    return
  end

  state.comments_loading = true
  state.comment_error = nil
  render()

  list_comments(state.root, pr.number, function(result)
    state.comments_loading = false
    state.comments = {}

    if result.ok then
      for _, comment in ipairs(result.data or {}) do
        local key = comments.comment_key(pr.number, comment)
        state.comments[key] = state.comments[key] or {}
        table.insert(state.comments[key], comment)
      end
      state.comment_error = nil
    else
      state.comment_error = render_error(result.error)
    end
    render()
  end)
end

---@param pr ZdiffReviewPr
local function load_pr_diff(pr)
  if not state.root then
    state.load_error = "no git repository root for current session"
    state.loading = false
    render()
    return
  end

  state.refresh_seq = state.refresh_seq + 1
  local refresh_seq = state.refresh_seq
  local keep_description_expanded = state.active_pr
    and state.active_pr.number == pr.number
    and state.description_expanded
  state.view = "diff"
  state.active_pr = pr
  state.description_expanded = keep_description_expanded == true
  state.files = {}
  state.comments = {}
  state.posting = {}
  state.comment_error = nil
  state.comments_loading = false
  state.loading = true
  state.load_error = nil
  state.syntax_projection_cache = {}
  state.syntax_jobs = {}
  state.syntax_debug = {
    projected_files = {},
    fallback_files = {},
    skipped_files = {},
  }
  render()

  load_pr_details(pr, function()
    if refresh_seq ~= state.refresh_seq then
      return
    end

    render()

    backend().diff_pr(state.root, pr, function(result)
      if refresh_seq ~= state.refresh_seq then
        return
      end

      if result.ok then
        state.files = {}
        for _, file in ipairs(result.data or {}) do
          table.insert(state.files, normalize_backend_file(file, pr))
        end
        state.load_error = nil
      else
        state.files = {}
        state.load_error = render_error(result.error)
      end
      state.loading = false
      render()
      if result.ok then
        load_pr_comments(pr)
      end
    end)
  end)
end

local function refresh_list()
  if not state.root then
    state.load_error = "no git repository root for current session"
    state.loading = false
    render()
    return
  end

  state.refresh_seq = state.refresh_seq + 1
  local refresh_seq = state.refresh_seq
  state.view = "list"
  state.active_pr = nil
  state.description_expanded = false
  state.files = {}
  state.comments = {}
  state.posting = {}
  state.comment_error = nil
  state.comments_loading = false
  state.loading = true
  state.load_error = nil
  state.syntax_jobs = {}
  state.syntax_projection_cache = {}
  render()

  backend().list_prs(state.root, function(result)
    if refresh_seq ~= state.refresh_seq then
      return
    end

    if result.ok then
      state.prs = result.data or {}
      state.load_error = nil
    else
      state.prs = {}
      state.load_error = render_error(result.error)
    end
    state.loading = false
    render()
  end)
end

local function refresh()
  if state.view == "diff" and state.active_pr then
    load_pr_diff(state.active_pr)
  else
    refresh_list()
  end
end

---@return ZdiffReviewPr|nil
local function selected_pr()
  if
    state.view ~= "list"
    or not state.win
    or not vim.api.nvim_win_is_valid(state.win)
  then
    return nil
  end

  local cursor_line = vim.api.nvim_win_get_cursor(state.win)[1]
  local pr_idx = state.line_map[cursor_line]
  if type(pr_idx) ~= "number" then
    return nil
  end

  return state.prs[pr_idx]
end

local function open_selected_pr()
  local pr = selected_pr()
  if pr then
    load_pr_diff(pr)
  end
end

---@param pr ZdiffReviewPr
---@param action "approve"|"request_changes"|"comment"
---@param body string
local function post_pr_action(pr, action, body)
  if state.pr_action_pending then
    notify("A PR action is already submitting", vim.log.levels.WARN)
    return
  end
  if not state.root then
    return
  end

  local submit_review = backend().submit_review
  local submit_pr_comment = backend().submit_pr_comment
  if
    (action == "comment" and not submit_pr_comment)
    or (action ~= "comment" and not submit_review)
  then
    notify("PR actions are not supported", vim.log.levels.WARN)
    return
  end

  state.pr_action_pending = pr.number
  render()

  local function done(result)
    state.pr_action_pending = nil
    if not result.ok then
      notify(render_error(result.error), vim.log.levels.ERROR)
      render()
      return
    end

    if action == "approve" then
      notify("Approved PR #" .. tostring(pr.number))
    elseif action == "request_changes" then
      notify("Requested changes on PR #" .. tostring(pr.number))
    else
      notify("Posted comment on PR #" .. tostring(pr.number))
    end

    if action == "comment" then
      render()
    else
      refresh_list()
    end
  end

  if action == "comment" then
    submit_pr_comment(state.root, pr.number, body, done)
  else
    submit_review(state.root, pr.number, action, body, done)
  end
end

local function prompt_pr_action()
  local pr = selected_pr()
  if not pr then
    return
  end
  if state.pr_action_pending then
    notify("A PR action is already submitting", vim.log.levels.WARN)
    return
  end

  vim.ui.select({
    "Approve",
    "Request changes",
    "General comment",
  }, { prompt = "PR #" .. tostring(pr.number) .. " action: " }, function(choice)
    if not choice then
      return
    end

    local action = choice == "Approve" and "approve"
      or choice == "Request changes" and "request_changes"
      or "comment"
    local prompt = action == "approve" and "Approval message: "
      or action == "request_changes" and "Request changes message: "
      or "Comment: "

    vim.ui.input({ prompt = prompt }, function(input)
      if input == nil or (action ~= "approve" and input == "") then
        return
      end
      post_pr_action(pr, action, input)
    end)
  end)
end

local function toggle_description()
  if state.view ~= "diff" or not view.has_pr_body(state.active_pr) then
    return
  end

  state.description_expanded = not state.description_expanded
  render()
end

local function toggle_file()
  if
    state.view ~= "diff"
    or not state.win
    or not vim.api.nvim_win_is_valid(state.win)
  then
    return
  end

  local cursor_line = vim.api.nvim_win_get_cursor(state.win)[1]
  local mapping = state.line_map[cursor_line]
  if type(mapping) ~= "table" or not mapping.file_idx then
    return
  end

  local file = state.files[mapping.file_idx]
  if not file then
    return
  end

  file.expanded = not file.expanded
  render()
  for lnum, map in pairs(state.line_map) do
    if
      type(map) == "table"
      and map.file_idx == mapping.file_idx
      and map.kind == "file"
    then
      vim.api.nvim_win_set_cursor(state.win, { lnum, 0 })
      break
    end
  end
end

---@return table[]
local function thread_locations()
  local locations = {}
  for _, group in pairs(state.comments) do
    for _, comment in ipairs(group) do
      if not comment.in_reply_to_id then
        local location = comments.location(state.files, comment)
        if location then
          table.insert(locations, location)
        end
      end
    end
  end
  table.sort(locations, comments.location_less)
  return locations
end

---@param cursor_line number
---@return table
local function cursor_location(cursor_line)
  local mapping = state.line_map[cursor_line]
  if type(mapping) ~= "table" then
    return { file_idx = 0, hunk_idx = 0, line_idx = 0, comment = {} }
  end
  if mapping.kind == "review_comment" and mapping.comment then
    return comments.location(state.files, mapping.comment)
      or { file_idx = mapping.file_idx or 0, hunk_idx = 0, line_idx = 0, comment = {} }
  end
  return {
    file_idx = mapping.file_idx or 0,
    hunk_idx = mapping.hunk_idx or 0,
    line_idx = mapping.line_idx or 0,
    comment = {},
  }
end

---@param location table
---@return number|nil
local function find_thread_line(location)
  for lnum, mapping in pairs(state.line_map) do
    if
      type(mapping) == "table"
      and mapping.kind == "review_comment"
      and mapping.comment
      and mapping.comment.id == location.comment.id
    then
      return lnum
    end
  end

  for lnum, mapping in pairs(state.line_map) do
    if
      type(mapping) == "table"
      and mapping.file_idx == location.file_idx
      and mapping.hunk_idx == location.hunk_idx
      and mapping.line_idx == location.line_idx
    then
      return lnum
    end
  end

  for lnum, mapping in pairs(state.line_map) do
    if
      type(mapping) == "table"
      and mapping.file_idx == location.file_idx
      and mapping.kind == "file"
    then
      return lnum
    end
  end
  return nil
end

---@param direction 1|-1
local function jump_thread(direction)
  if
    state.view ~= "diff"
    or not state.win
    or not vim.api.nvim_win_is_valid(state.win)
  then
    return
  end

  local locations = thread_locations()
  if #locations == 0 then
    notify("No review threads", vim.log.levels.WARN)
    return
  end

  local current = cursor_location(vim.api.nvim_win_get_cursor(state.win)[1])
  local selected = nil
  if direction > 0 then
    for _, location in ipairs(locations) do
      if comments.location_less(current, location) then
        selected = location
        break
      end
    end
    selected = selected or locations[1]
  else
    for idx = #locations, 1, -1 do
      if comments.location_less(locations[idx], current) then
        selected = locations[idx]
        break
      end
    end
    selected = selected or locations[#locations]
  end

  local file = state.files[selected.file_idx]
  if file then
    file.expanded = true
  end
  render()

  local lnum = find_thread_line(selected)
  if lnum then
    vim.api.nvim_win_set_cursor(state.win, { lnum, 0 })
  end
end

---@param target ZdiffReviewCommentTarget
---@param body string
local function post_comment(target, body)
  local pr = state.active_pr
  local submit_comment = backend().submit_comment
  if not pr or not state.root or not submit_comment then
    notify("Comment posting is not supported", vim.log.levels.WARN)
    return
  end

  local key = comments.target_key(target)
  if state.posting[key] then
    notify("Comment is already posting", vim.log.levels.WARN)
    return
  end

  state.posting[key] = true
  notify("Posting comment...")
  render()

  submit_comment(state.root, pr.number, {
    path = target.path,
    side = target.side,
    line = target.line,
    body = body,
    commit_id = pr.head_ref_oid,
  }, function(result)
    state.posting[key] = nil
    if result.ok then
      notify("Posted comment")
      render()
      load_pr_comments(pr)
    else
      notify(render_error(result.error), vim.log.levels.ERROR)
      render()
    end
  end)
end

local function prompt_comment()
  if
    state.view ~= "diff"
    or not state.win
    or not vim.api.nvim_win_is_valid(state.win)
  then
    return
  end

  local cursor_line = vim.api.nvim_win_get_cursor(state.win)[1]
  local mapping = state.line_map[cursor_line]
  local target = type(mapping) == "table" and mapping.review_target or nil
  if not target then
    notify("No reviewable line under cursor", vim.log.levels.WARN)
    return
  end

  vim.ui.input({ prompt = "Comment: " }, function(input)
    if not input or input == "" then
      return
    end
    post_comment(target, input)
  end)
end

---@param comment ZdiffReviewPostedComment
---@param body string
local function post_reply(comment, body)
  local pr = state.active_pr
  local reply_comment = backend().reply_comment
  if not pr or not state.root or not reply_comment or not comment.id then
    notify("Comment replies are not supported", vim.log.levels.WARN)
    return
  end

  local key = comments.reply_key(comment)
  if state.posting[key] then
    notify("Reply is already posting", vim.log.levels.WARN)
    return
  end

  state.posting[key] = true
  notify("Posting reply...")
  render()

  reply_comment(state.root, pr.number, comment.id, body, function(result)
    state.posting[key] = nil
    if result.ok then
      notify("Posted reply")
      render()
      load_pr_comments(pr)
    else
      notify(render_error(result.error), vim.log.levels.ERROR)
      render()
    end
  end)
end

local function prompt_reply()
  if
    state.view ~= "diff"
    or not state.win
    or not vim.api.nvim_win_is_valid(state.win)
  then
    return
  end

  local cursor_line = vim.api.nvim_win_get_cursor(state.win)[1]
  local mapping = state.line_map[cursor_line]
  local comment = type(mapping) == "table" and mapping.comment or nil
  if type(comment) ~= "table" or not comment.id or comment.in_reply_to_id then
    notify("No top-level comment under cursor", vim.log.levels.WARN)
    return
  end

  vim.ui.input({ prompt = "Reply: " }, function(input)
    if not input or input == "" then
      return
    end
    post_reply(comment, input)
  end)
end

local function close()
  state.refresh_seq = state.refresh_seq + 1
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end
  state.buf = nil
  state.win = nil
  state.root = nil
  state.view = "list"
  state.prs = {}
  state.files = {}
  state.active_pr = nil
  state.description_expanded = false
  state.line_map = {}
  state.comments = {}
  state.posting = {}
  state.pr_action_pending = nil
  state.comments_loading = false
  state.comment_error = nil
  state.loading = false
  state.load_error = nil
  state.syntax_jobs = {}
  state.syntax_projection_cache = {}
end

local function back_or_close()
  if state.view == "list" then
    close()
    return
  end

  state.refresh_seq = state.refresh_seq + 1
  state.view = "list"
  state.active_pr = nil
  state.description_expanded = false
  state.files = {}
  state.comments = {}
  state.posting = {}
  state.loading = false
  render()
end

function M.open()
  local root_result = git.root()
  if not root_result.ok then
    notify("Not in a git repository", vim.log.levels.ERROR)
    return
  end

  local root = root_result.data
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    if state.root == root then
      state.win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(state.win, state.buf)
      return
    end
    close()
  end

  state.root = root
  state.view = "list"
  state.active_pr = nil
  state.description_expanded = false
  state.files = {}
  state.comments = {}
  state.posting = {}
  state.pr_action_pending = nil
  state.comments_loading = false
  state.comment_error = nil
  state.syntax_jobs = {}
  state.syntax_projection_cache = {}
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].bufhidden = "hide"
  vim.bo[state.buf].swapfile = false
  vim.api.nvim_buf_set_name(state.buf, "zdiff.review")
  vim.bo[state.buf].filetype = "zdiffreview"

  state.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.win, state.buf)

  vim.keymap.set("n", "q", back_or_close, { buffer = state.buf, silent = true })
  vim.keymap.set("n", "<CR>", open_selected_pr, { buffer = state.buf, silent = true })
  vim.keymap.set("n", "a", prompt_pr_action, { buffer = state.buf, silent = true })
  vim.keymap.set("n", "d", toggle_description, { buffer = state.buf, silent = true })
  vim.keymap.set("n", "<Tab>", toggle_file, { buffer = state.buf, silent = true })
  vim.keymap.set("n", "c", prompt_comment, { buffer = state.buf, silent = true })
  vim.keymap.set("n", "r", prompt_reply, { buffer = state.buf, silent = true })
  vim.keymap.set("n", "]t", function()
    jump_thread(1)
  end, { buffer = state.buf, silent = true })
  vim.keymap.set("n", "[t", function()
    jump_thread(-1)
  end, { buffer = state.buf, silent = true })
  vim.keymap.set("n", "R", refresh, { buffer = state.buf, silent = true })

  refresh_list()
end

function M.setup()
  vim.api.nvim_create_user_command("ZdiffReview", function()
    M.open()
  end, {
    desc = "Open zdiff review pull request browser",
    force = true,
  })
end

M.close = close

function M._set_backend(test_backend)
  state.backend = test_backend
end

function M._debug_state()
  local expanded_count = 0
  for _, file in ipairs(state.files) do
    if file.expanded then
      expanded_count = expanded_count + 1
    end
  end

  return {
    loading = state.loading,
    load_error = state.load_error,
    view = state.view,
    pr_count = #state.prs,
    file_count = #state.files,
    expanded_count = expanded_count,
    description_expanded = state.description_expanded,
    comment_count = vim.tbl_count(state.comments),
    posting_count = vim.tbl_count(state.posting),
    pr_action_pending = state.pr_action_pending,
    comments_loading = state.comments_loading,
    pending_syntax_jobs = vim.tbl_count(state.syntax_jobs),
    syntax_cache_entries = vim.tbl_count(state.syntax_projection_cache),
    syntax = vim.deepcopy(state.syntax_debug),
    root = state.root,
  }
end

return M
