local M = {}
local display = require("zdiff.display")
local git = require("zdiff.git")
local patch = require("zdiff.patch")

---@class ZdiffReviewPr
---@field number number
---@field title string
---@field author string
---@field additions number
---@field deletions number
---@field review_decision string
---@field is_draft boolean

---@class ZdiffReviewState
---@field buf number|nil
---@field win number|nil
---@field root string|nil
---@field view "list"|"diff"
---@field prs ZdiffReviewPr[]
---@field files ZdiffPatchFile[]
---@field active_pr ZdiffReviewPr|nil
---@field line_map table<number, number|ZdiffReviewFileTarget|ZdiffReviewCommentTarget|ZdiffReviewPostedComment>
---@field expanded table<string, boolean>
---@field comments table<string, ZdiffReviewPostedComment[]>
---@field posting table<string, boolean>
---@field loading boolean
---@field comments_loading boolean
---@field comment_error string|nil
---@field load_error string|nil
---@field refresh_seq number
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
  line_map = {},
  expanded = {},
  comments = {},
  posting = {},
  loading = false,
  comments_loading = false,
  comment_error = nil,
  load_error = nil,
  refresh_seq = 0,
  backend = nil,
}

local ns = vim.api.nvim_create_namespace("zdiff_review")
local icons = {
  collapsed = ">",
  expanded = "v",
  added = "+",
  deleted = "-",
  modified = "~",
}

---@class ZdiffReviewFileTarget
---@field file_key string

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

local function join_job_data(data)
  if not data then
    return ""
  end
  return table.concat(data, "\n")
end

---@param argv string[]
---@param code integer
---@param stdout string|nil
---@param stderr string|nil
---@return {ok: boolean, stdout: string, error: string|nil}
local function build_result(argv, code, stdout, stderr)
  stdout = stdout or ""
  stderr = stderr or ""
  if code == 0 then
    return { ok = true, stdout = stdout, error = nil }
  end

  local err = vim.trim(stderr)
  if err == "" then
    err = "command failed: " .. table.concat(argv, " ")
  end
  return { ok = false, stdout = stdout, error = err }
end

---@param root string
---@param argv string[]
---@param callback fun(result: {ok: boolean, stdout: string, error: string|nil})
local function run_async(root, argv, callback)
  local function finish(code, stdout, stderr)
    vim.schedule(function()
      callback(build_result(argv, code or 1, stdout, stderr))
    end)
  end

  if vim.system then
    local ok, err = pcall(vim.system, argv, { text = true, cwd = root }, function(obj)
      finish(obj.code, obj.stdout, obj.stderr)
    end)
    if not ok then
      finish(1, "", err)
    end
    return
  end

  local stdout = ""
  local stderr = ""
  local job_id = vim.fn.jobstart(argv, {
    cwd = root,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      stdout = join_job_data(data)
    end,
    on_stderr = function(_, data)
      stderr = join_job_data(data)
    end,
    on_exit = function(_, code)
      finish(code, stdout, stderr)
    end,
  })

  if job_id <= 0 then
    finish(1, "", "failed to start command: " .. table.concat(argv, " "))
  end
end

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

---@param raw table
---@return ZdiffReviewPr
local function normalize_pr(raw)
  local author = raw.author
  if type(author) == "table" then
    author = author.login
  end

  return {
    number = tonumber(raw.number) or 0,
    title = tostring(raw.title or ""),
    author = tostring(author or ""),
    additions = tonumber(raw.additions) or 0,
    deletions = tonumber(raw.deletions) or 0,
    review_decision = tostring(raw.reviewDecision or ""),
    is_draft = raw.isDraft == true,
  }
end

---@param root string
---@param done fun(result: {ok: boolean, data?: ZdiffReviewPr[], error?: string})
local function list_github_prs(root, done)
  run_async(root, {
    "gh",
    "pr",
    "list",
    "--json",
    "number,title,author,additions,deletions,reviewDecision,isDraft",
  }, function(result)
    if not result.ok then
      done({ ok = false, error = result.error })
      return
    end

    local ok, decoded = pcall(vim.json.decode, result.stdout)
    if not ok or type(decoded) ~= "table" then
      done({ ok = false, error = "could not parse gh pr list output" })
      return
    end

    local prs = {}
    for _, raw in ipairs(decoded) do
      table.insert(prs, normalize_pr(raw))
    end
    done({ ok = true, data = prs })
  end)
end

---@param root string
---@param number number
---@param done fun(result: {ok: boolean, data?: ZdiffPatchFile[], error?: string})
local function diff_github_pr(root, number, done)
  run_async(root, { "gh", "pr", "diff", tostring(number), "--patch" }, function(result)
    if not result.ok then
      done({ ok = false, error = result.error })
      return
    end
    done({ ok = true, data = patch.parse(split_lines(result.stdout)) })
  end)
end

---@param raw table
---@return ZdiffReviewPostedComment|nil
local function normalize_comment(raw)
  local line = tonumber(raw.line) or tonumber(raw.original_line)
  if not line or type(raw.path) ~= "string" or type(raw.body) ~= "string" then
    return nil
  end

  local user = raw.user
  local author = ""
  if type(user) == "table" and type(user.login) == "string" then
    author = user.login
  end

  return {
    id = tonumber(raw.id),
    in_reply_to_id = tonumber(raw.in_reply_to_id),
    path = raw.path,
    side = raw.side == "LEFT" and "LEFT" or "RIGHT",
    line = line,
    body = raw.body,
    author = author,
  }
end

---@param root string
---@param number number
---@param done fun(result: {ok: boolean, data?: ZdiffReviewPostedComment[], error?: string})
local function list_github_comments(root, number, done)
  run_async(root, {
    "gh",
    "api",
    "repos/{owner}/{repo}/pulls/" .. tostring(number) .. "/comments",
  }, function(result)
    if not result.ok then
      done({ ok = false, error = result.error })
      return
    end

    local ok, decoded = pcall(vim.json.decode, result.stdout)
    if not ok or type(decoded) ~= "table" then
      done({ ok = false, error = "could not parse PR comments" })
      return
    end

    local comments = {}
    for _, raw in ipairs(decoded) do
      local comment = normalize_comment(raw)
      if comment then
        table.insert(comments, comment)
      end
    end
    done({ ok = true, data = comments })
  end)
end

---@param root string
---@param number number
---@param comment ZdiffReviewComment
---@param done fun(result: {ok: boolean, error?: string})
local function submit_github_comment(root, number, comment, done)
  run_async(root, {
    "gh",
    "pr",
    "view",
    tostring(number),
    "--json",
    "headRefOid",
    "--jq",
    ".headRefOid",
  }, function(view_result)
    if not view_result.ok then
      done({ ok = false, error = view_result.error })
      return
    end

    local commit_id = vim.trim(view_result.stdout)
    if commit_id == "" then
      done({ ok = false, error = "could not resolve PR head commit" })
      return
    end

    run_async(root, {
      "gh",
      "api",
      "--method",
      "POST",
      "repos/{owner}/{repo}/pulls/" .. tostring(number) .. "/comments",
      "-H",
      "Accept: application/vnd.github+json",
      "-f",
      "body=" .. comment.body,
      "-f",
      "commit_id=" .. commit_id,
      "-f",
      "path=" .. comment.path,
      "-f",
      "side=" .. comment.side,
      "-F",
      "line=" .. tostring(comment.line),
      "--silent",
    }, function(api_result)
      if not api_result.ok then
        done({ ok = false, error = api_result.error })
        return
      end
      done({ ok = true })
    end)
  end)
end

---@param root string
---@param number number
---@param comment_id number
---@param body string
---@param done fun(result: {ok: boolean, error?: string})
local function submit_github_reply(root, number, comment_id, body, done)
  run_async(root, {
    "gh",
    "api",
    "--method",
    "POST",
    "repos/{owner}/{repo}/pulls/" .. tostring(number) .. "/comments/" .. tostring(
      comment_id
    ) .. "/replies",
    "-H",
    "Accept: application/vnd.github+json",
    "-f",
    "body=" .. body,
    "--silent",
  }, function(api_result)
    if not api_result.ok then
      done({ ok = false, error = api_result.error })
      return
    end
    done({ ok = true })
  end)
end

local default_backend = {
  list_prs = list_github_prs,
  diff_pr = diff_github_pr,
  list_comments = list_github_comments,
  submit_comment = submit_github_comment,
  reply_comment = submit_github_reply,
}

---@return table
local function backend()
  return state.backend or default_backend
end

---@param pr ZdiffReviewPr
---@return string
local function format_pr(pr)
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

---@param lines string[]
---@param highlights table[]
local function render_list(lines, highlights)
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
      local line = format_pr(pr)
      table.insert(lines, line)
      state.line_map[#lines] = idx

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
end

---@param target ZdiffReviewCommentTarget
---@return string
local function target_key(target)
  return table.concat({
    tostring(target.pr_number),
    target.path,
    target.side,
    tostring(target.line),
  }, "\0")
end

---@param pr_number number
---@param comment ZdiffReviewPostedComment
---@return string
local function comment_key(pr_number, comment)
  return target_key({
    pr_number = pr_number,
    path = comment.path,
    side = comment.side,
    line = comment.line,
  })
end

---@param file ZdiffPatchFile
---@return string
local function file_key(file)
  return table.concat({
    file.old_path or "",
    file.new_path or "",
    file.path,
  }, "\0")
end

---@param comment ZdiffReviewPostedComment
---@return string
local function reply_key(comment)
  return "reply\0" .. tostring(comment.id)
end

---@param file ZdiffPatchFile
---@param diff_line ZdiffLine
---@return ZdiffReviewCommentTarget|nil
local function comment_target(file, diff_line)
  local pr = state.active_pr
  if not pr then
    return nil
  end

  if diff_line.type == "del" and diff_line.old_lnum then
    return {
      pr_number = pr.number,
      path = file.old_path or file.path,
      side = "LEFT",
      line = diff_line.old_lnum,
    }
  end

  if diff_line.new_lnum then
    return {
      pr_number = pr.number,
      path = file.new_path or file.path,
      side = "RIGHT",
      line = diff_line.new_lnum,
    }
  end

  return nil
end

---@param lines string[]
---@param highlights table[]
local function render_diff(lines, highlights)
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
    return
  end

  for _, file in ipairs(state.files) do
    local key = file_key(file)
    local expanded = state.expanded[key] == true
    local file_line = display.format_file_line({
      icon = expanded and icons.expanded or icons.collapsed,
      status_icon = display.get_status_icon(file.status, icons),
      path = file.display_path or file.path,
      additions = file.insertions,
      deletions = file.deletions,
    })
    table.insert(lines, file_line.text)
    state.line_map[#lines] = { file_key = key }

    table.insert(highlights, { #lines, "Directory", 0, file_line.add_start })
    table.insert(
      highlights,
      { #lines, "DiffAdd", file_line.add_start, file_line.add_end }
    )
    table.insert(
      highlights,
      { #lines, "DiffDelete", file_line.del_start, file_line.del_end }
    )

    if expanded then
      for _, hunk in ipairs(file.hunks) do
        table.insert(lines, display.format_hunk_header(hunk, "  "))
        table.insert(highlights, { #lines, "Comment", 0, -1 })

        for _, diff_line in ipairs(hunk.lines) do
          local marker = " "
          if diff_line.type == "add" then
            marker = "+"
          elseif diff_line.type == "del" then
            marker = "-"
          end

          table.insert(lines, "  " .. marker .. diff_line.text)
          table.insert(
            highlights,
            { #lines, display.get_line_highlight(diff_line.type), 0, -1 }
          )

          local target = comment_target(file, diff_line)
          if target then
            state.line_map[#lines] = target
            local target_map_key = target_key(target)
            if state.posting[target_map_key] then
              table.insert(lines, "    # Posting...")
              table.insert(highlights, { #lines, "Comment", 0, -1 })
            end
            for _, comment in ipairs(state.comments[target_map_key] or {}) do
              local author = comment.author or ""
              local prefix = author ~= "" and ("@" .. author .. ": ") or ""
              local indent = comment.in_reply_to_id and "      " or "    "
              table.insert(lines, indent .. prefix .. comment.body)
              table.insert(highlights, { #lines, "Comment", 0, -1 })
              if comment.id and not comment.in_reply_to_id then
                state.line_map[#lines] = comment
                if state.posting[reply_key(comment)] then
                  table.insert(lines, "      # Replying...")
                  table.insert(highlights, { #lines, "Comment", 0, -1 })
                end
              end
            end
          end
        end
      end
    end
  end
end

local function render()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  state.line_map = {}

  local lines = {}
  local highlights = {}
  if state.view == "diff" then
    render_diff(lines, highlights)
  else
    render_list(lines, highlights)
  end

  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(state.buf, ns, hl[2], hl[1] - 1, hl[3], hl[4])
  end
  vim.bo[state.buf].modifiable = false
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
        local key = comment_key(pr.number, comment)
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
  state.view = "diff"
  state.active_pr = pr
  state.files = {}
  state.expanded = {}
  state.comments = {}
  state.posting = {}
  state.comment_error = nil
  state.comments_loading = false
  state.loading = true
  state.load_error = nil
  render()

  backend().diff_pr(state.root, pr.number, function(result)
    if refresh_seq ~= state.refresh_seq then
      return
    end

    if result.ok then
      state.files = result.data or {}
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
  state.files = {}
  state.expanded = {}
  state.comments = {}
  state.posting = {}
  state.comment_error = nil
  state.comments_loading = false
  state.loading = true
  state.load_error = nil
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

local function open_selected_pr()
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then
    return
  end

  local cursor_line = vim.api.nvim_win_get_cursor(state.win)[1]
  local pr_idx = state.line_map[cursor_line]
  if type(pr_idx) ~= "number" then
    return
  end

  local pr = state.prs[pr_idx]
  if pr then
    load_pr_diff(pr)
  end
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
  local target = state.line_map[cursor_line]
  if type(target) ~= "table" or not target.file_key then
    return
  end

  if state.expanded[target.file_key] then
    state.expanded[target.file_key] = nil
  else
    state.expanded[target.file_key] = true
  end
  render()
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

  local key = target_key(target)
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
  local target = state.line_map[cursor_line]
  if type(target) ~= "table" or not target.pr_number then
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

  local key = reply_key(comment)
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
  local comment = state.line_map[cursor_line]
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
  state.line_map = {}
  state.expanded = {}
  state.comments = {}
  state.posting = {}
  state.comments_loading = false
  state.comment_error = nil
  state.loading = false
  state.load_error = nil
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
  state.files = {}
  state.expanded = {}
  state.comments = {}
  state.posting = {}
  state.comments_loading = false
  state.comment_error = nil
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].bufhidden = "hide"
  vim.bo[state.buf].swapfile = false
  vim.api.nvim_buf_set_name(state.buf, "zdiff.review")
  vim.bo[state.buf].filetype = "zdiffreview"

  state.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.win, state.buf)

  vim.keymap.set("n", "q", close, { buffer = state.buf, silent = true })
  vim.keymap.set("n", "<CR>", open_selected_pr, { buffer = state.buf, silent = true })
  vim.keymap.set("n", "<Tab>", toggle_file, { buffer = state.buf, silent = true })
  vim.keymap.set("n", "c", prompt_comment, { buffer = state.buf, silent = true })
  vim.keymap.set("n", "r", prompt_reply, { buffer = state.buf, silent = true })
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
  return {
    loading = state.loading,
    load_error = state.load_error,
    view = state.view,
    pr_count = #state.prs,
    file_count = #state.files,
    expanded_count = vim.tbl_count(state.expanded),
    comment_count = vim.tbl_count(state.comments),
    posting_count = vim.tbl_count(state.posting),
    comments_loading = state.comments_loading,
    root = state.root,
  }
end

return M
