local M = {}
local diff = require("zdiff.diff")
local diff_view = require("zdiff.diff_view")
local display = require("zdiff.display")
local git = require("zdiff.git")

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

---@class ZdiffReviewState
---@field buf number|nil
---@field win number|nil
---@field root string|nil
---@field view "list"|"diff"
---@field prs ZdiffReviewPr[]
---@field files ZdiffFile[]
---@field active_pr ZdiffReviewPr|nil
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
local cache_ttl = 300
local cache = {
  pr_refs = {},
  pr_files = {},
  file_contents = {},
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

---@return integer
local function now()
  return os.time()
end

---@param path string
---@return string
local function encode_path(path)
  local parts = vim.split(path, "/", { plain = true })
  for idx, part in ipairs(parts) do
    parts[idx] = vim.uri_encode(part)
  end
  return table.concat(parts, "/")
end

---@param value any
---@return table[]
local function flatten_pages(value)
  local out = {}
  if type(value) ~= "table" then
    return out
  end

  for _, item in ipairs(value) do
    if type(item) == "table" and item.filename then
      table.insert(out, item)
    elseif type(item) == "table" then
      for _, nested in ipairs(item) do
        if type(nested) == "table" then
          table.insert(out, nested)
        end
      end
    end
  end
  return out
end

---@param raw table
---@param refs {base: string|nil, head: string|nil}
---@return ZdiffFile|nil
local function normalize_pr_file(raw, refs)
  if type(raw.filename) ~= "string" then
    return nil
  end

  local status = "M"
  if raw.status == "added" then
    status = "A"
  elseif raw.status == "removed" then
    status = "D"
  elseif raw.status == "renamed" then
    status = "R"
  end

  local old_path = raw.filename
  local new_path = raw.filename
  if status == "A" then
    old_path = nil
  elseif status == "D" then
    new_path = nil
  elseif status == "R" then
    old_path = type(raw.previous_filename) == "string" and raw.previous_filename
      or raw.filename
  end

  local display_path = raw.filename
  if old_path and new_path and old_path ~= new_path then
    display_path = old_path .. " -> " .. new_path
  end

  return {
    path = new_path or old_path or raw.filename,
    display_path = display_path,
    old_path = old_path,
    new_path = new_path,
    status = status,
    insertions = tonumber(raw.additions) or 0,
    deletions = tonumber(raw.deletions) or 0,
    expanded = false,
    hunks = diff.parse_hunks(split_lines(tostring(raw.patch or ""))),
    hunk_status = "loaded",
    hunk_error = nil,
    review_base_ref = refs.base,
    review_head_ref = refs.head,
  }
end

---@param file table
---@param pr ZdiffReviewPr
---@return ZdiffFile
local function normalize_backend_file(file, pr)
  file.expanded = file.expanded == true
  file.hunk_status = file.hunk_status or "loaded"
  file.hunk_error = file.hunk_error
  file.review_base_ref = file.review_base_ref or pr.base_ref_oid
  file.review_head_ref = file.review_head_ref or pr.head_ref_oid
  return file
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
    base_ref_oid = type(raw.baseRefOid) == "string" and raw.baseRefOid or nil,
    head_ref_oid = type(raw.headRefOid) == "string" and raw.headRefOid or nil,
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
    "number,title,author,additions,deletions,reviewDecision,isDraft,baseRefOid,headRefOid",
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
---@param done fun(result: {ok: boolean, data?: {base: string|nil, head: string|nil}, error?: string})
local function get_github_pr_refs(root, number, done)
  local ref_cache_key = root .. "\0" .. tostring(number)
  local cached = cache.pr_refs[ref_cache_key]
  if cached and cached.expires_at > now() then
    done({ ok = true, data = cached.data })
    return
  end

  run_async(root, {
    "gh",
    "pr",
    "view",
    tostring(number),
    "--json",
    "baseRefOid,headRefOid",
  }, function(result)
    if not result.ok then
      done({ ok = false, error = result.error })
      return
    end

    local ok, decoded = pcall(vim.json.decode, result.stdout)
    if not ok or type(decoded) ~= "table" then
      done({ ok = false, error = "could not parse PR refs" })
      return
    end

    local refs = {
      base = type(decoded.baseRefOid) == "string" and decoded.baseRefOid or nil,
      head = type(decoded.headRefOid) == "string" and decoded.headRefOid or nil,
    }
    cache.pr_refs[ref_cache_key] = {
      expires_at = now() + cache_ttl,
      data = refs,
    }
    done({ ok = true, data = refs })
  end)
end

---@param root string
---@param number number
---@param done fun(result: {ok: boolean, data?: ZdiffFile[], error?: string})
local function diff_github_pr(root, number, done)
  get_github_pr_refs(root, number, function(ref_result)
    if not ref_result.ok then
      done({ ok = false, error = ref_result.error })
      return
    end

    local refs = ref_result.data or {}
    local cache_key = table.concat({
      root,
      tostring(number),
      refs.base or "",
      refs.head or "",
    }, "\0")
    local cached = cache.pr_files[cache_key]
    if cached and cached.expires_at > now() then
      done({ ok = true, data = vim.deepcopy(cached.data) })
      return
    end

    run_async(root, {
      "gh",
      "api",
      "--paginate",
      "--slurp",
      "--method",
      "GET",
      "repos/{owner}/{repo}/pulls/" .. tostring(number) .. "/files",
      "-F",
      "per_page=100",
    }, function(result)
      if not result.ok then
        done({ ok = false, error = result.error })
        return
      end

      local ok, decoded = pcall(vim.json.decode, result.stdout)
      if not ok then
        done({ ok = false, error = "could not parse PR files" })
        return
      end

      local files = {}
      for _, raw in ipairs(flatten_pages(decoded)) do
        local file = normalize_pr_file(raw, refs)
        if file then
          table.insert(files, file)
        end
      end
      cache.pr_files[cache_key] = {
        expires_at = now() + cache_ttl,
        data = vim.deepcopy(files),
      }
      done({ ok = true, data = files })
    end)
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

---@param root string
---@param number number
---@param action "approve"|"request_changes"
---@param body string
---@param done fun(result: {ok: boolean, error?: string})
local function submit_github_review(root, number, action, body, done)
  local argv = {
    "gh",
    "api",
    "--method",
    "POST",
    "repos/{owner}/{repo}/pulls/" .. tostring(number) .. "/reviews",
    "-H",
    "Accept: application/vnd.github+json",
    "-f",
    "event=" .. (action == "approve" and "APPROVE" or "REQUEST_CHANGES"),
  }
  if body ~= "" then
    vim.list_extend(argv, { "-f", "body=" .. body })
  end
  table.insert(argv, "--silent")

  run_async(root, argv, function(result)
    done({ ok = result.ok, error = result.error })
  end)
end

---@param root string
---@param number number
---@param body string
---@param done fun(result: {ok: boolean, error?: string})
local function submit_github_pr_comment(root, number, body, done)
  run_async(root, {
    "gh",
    "api",
    "--method",
    "POST",
    "repos/{owner}/{repo}/issues/" .. tostring(number) .. "/comments",
    "-H",
    "Accept: application/vnd.github+json",
    "-f",
    "body=" .. body,
    "--silent",
  }, function(result)
    done({ ok = result.ok, error = result.error })
  end)
end

---@param root string
---@param path string
---@param ref string
---@param done fun(result: {ok: boolean, data?: string[], error?: string})
local function read_github_file(root, path, ref, done)
  local cache_key = table.concat({ root, ref, path }, "\0")
  local cached = cache.file_contents[cache_key]
  if cached and cached.expires_at > now() then
    done({ ok = true, data = cached.data })
    return
  end

  run_async(root, {
    "gh",
    "api",
    "--method",
    "GET",
    "repos/{owner}/{repo}/contents/" .. encode_path(path),
    "-H",
    "Accept: application/vnd.github.raw",
    "-F",
    "ref=" .. ref,
  }, function(result)
    if not result.ok then
      done({ ok = false, error = result.error })
      return
    end

    local lines = split_lines(result.stdout)
    cache.file_contents[cache_key] = {
      expires_at = now() + cache_ttl,
      data = lines,
    }
    done({ ok = true, data = lines })
  end)
end

local default_backend = {
  list_prs = list_github_prs,
  diff_pr = diff_github_pr,
  list_comments = list_github_comments,
  submit_comment = submit_github_comment,
  reply_comment = submit_github_reply,
  submit_review = submit_github_review,
  submit_pr_comment = submit_github_pr_comment,
  read_file = read_github_file,
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
  if state.pr_action_pending == pr.number then
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

---@param comment ZdiffReviewPostedComment
---@return string
local function reply_key(comment)
  return "reply\0" .. tostring(comment.id)
end

---@param file table
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

---@param comment ZdiffReviewPostedComment
---@param file table
---@return boolean
local function comment_matches_file(comment, file)
  if comment.side == "LEFT" then
    return comment.path == (file.old_path or file.path) or comment.path == file.path
  end
  return comment.path == (file.new_path or file.path) or comment.path == file.path
end

---@param comment ZdiffReviewPostedComment
---@return table|nil
local function comment_location(comment)
  for file_idx, file in ipairs(state.files) do
    if comment_matches_file(comment, file) then
      for hunk_idx, hunk in ipairs(file.hunks or {}) do
        for line_idx, diff_line in ipairs(hunk.lines or {}) do
          if
            (comment.side == "LEFT" and diff_line.old_lnum == comment.line)
            or (comment.side == "RIGHT" and diff_line.new_lnum == comment.line)
          then
            return {
              file_idx = file_idx,
              hunk_idx = hunk_idx,
              line_idx = line_idx,
              comment = comment,
            }
          end
        end
      end

      return {
        file_idx = file_idx,
        hunk_idx = 0,
        line_idx = 0,
        comment = comment,
      }
    end
  end
  return nil
end

---@param file_idx number
---@return number, number, string[]
local function file_comment_counts(file_idx)
  local file = state.files[file_idx]
  if not file then
    return 0, 0, {}
  end

  local threads = 0
  local comments = 0
  local seen_authors = {}
  for _, group in pairs(state.comments) do
    for _, comment in ipairs(group) do
      if comment_matches_file(comment, file) then
        comments = comments + 1
        if comment.author and comment.author ~= "" then
          seen_authors["@" .. comment.author] = true
        end
        if not comment.in_reply_to_id then
          threads = threads + 1
        end
      end
    end
  end

  local authors = vim.tbl_keys(seen_authors)
  table.sort(authors)
  return threads, comments, authors
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

---@param ctx table
---@return table[]
local function file_summary_rows(ctx)
  if ctx.file.expanded then
    return {}
  end

  local threads, comments, authors = file_comment_counts(ctx.file_idx)
  if threads == 0 then
    return {}
  end

  local text = "  "
    .. count_word(threads, "thread")
    .. ", "
    .. count_word(comments, "comment")
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
  mapping.review_target = comment_target(file, diff_line)
end

---@param ctx table
---@return table[]
local function comment_rows(ctx)
  local target = ctx.mapping.review_target
  if not target then
    return {}
  end

  local rows = {}
  local key = target_key(target)
  if state.posting[key] then
    table.insert(rows, { text = "    Posting...", hl_group = "ZdiffReviewThread" })
  end

  for _, comment in ipairs(state.comments[key] or {}) do
    local author = comment.author or ""
    local prefix = author ~= "" and ("@" .. author .. ": ") or ""
    local indent = comment.in_reply_to_id and "      " or "    "
    local row = {
      text = indent .. prefix .. comment.body,
      hl_group = "ZdiffReviewThread",
    }
    if comment.id and not comment.in_reply_to_id then
      row.map = {
        kind = "review_comment",
        file_idx = ctx.file_idx,
        comment = comment,
      }
    end
    table.insert(rows, row)

    if
      comment.id
      and not comment.in_reply_to_id
      and state.posting[reply_key(comment)]
    then
      table.insert(rows, { text = "      Replying...", hl_group = "ZdiffReviewThread" })
    end
  end

  return rows
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
    return {
      lines = lines,
      highlights = highlights,
      syntax_highlights = {},
      syntax_requests = {},
      markers = {},
      line_map = {},
      syntax_debug = state.syntax_debug,
    }
  end

  return diff_view.render({
    lines = lines,
    highlights = highlights,
    files = state.files,
    icons = icons,
    syntax = syntax_config,
    syntax_projection_cache = state.syntax_projection_cache,
    syntax_cache_prefix = table.concat({
      state.root or "",
      pr and tostring(pr.number) or "",
      pr and (pr.base_ref_oid or "") or "",
      pr and (pr.head_ref_oid or "") or "",
    }, "\n"),
    map_diff_line = map_diff_line,
    extra_file_rows = file_summary_rows,
    extra_rows = comment_rows,
  })
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
    rendered = render_diff(lines, highlights)
    state.line_map = rendered.line_map or {}
    state.syntax_debug = rendered.syntax_debug or state.syntax_debug
  else
    render_list(lines, highlights)
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

  backend().diff_pr(state.root, pr.number, function(result)
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

---@param a table
---@param b table
---@return boolean
local function location_less(a, b)
  if a.file_idx ~= b.file_idx then
    return a.file_idx < b.file_idx
  end
  if a.hunk_idx ~= b.hunk_idx then
    return a.hunk_idx < b.hunk_idx
  end
  if a.line_idx ~= b.line_idx then
    return a.line_idx < b.line_idx
  end
  return (a.comment.id or 0) < (b.comment.id or 0)
end

---@return table[]
local function thread_locations()
  local locations = {}
  for _, group in pairs(state.comments) do
    for _, comment in ipairs(group) do
      if not comment.in_reply_to_id then
        local location = comment_location(comment)
        if location then
          table.insert(locations, location)
        end
      end
    end
  end
  table.sort(locations, location_less)
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
    return comment_location(mapping.comment)
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
      if location_less(current, location) then
        selected = location
        break
      end
    end
    selected = selected or locations[1]
  else
    for idx = #locations, 1, -1 do
      if location_less(locations[idx], current) then
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
  state.files = {}
  state.comments = {}
  state.posting = {}
  state.comments_loading = false
  state.comment_error = nil
  state.loading = false
  state.load_error = nil
  state.syntax_jobs = {}
  state.syntax_projection_cache = {}
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
