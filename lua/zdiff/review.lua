local M = {}
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
---@field line_map table<number, number>
---@field loading boolean
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
  loading = false,
  load_error = nil,
  refresh_seq = 0,
  backend = nil,
}

local ns = vim.api.nvim_create_namespace("zdiff_review")

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

local default_backend = {
  list_prs = list_github_prs,
  diff_pr = diff_github_pr,
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

      local add_stat = "+" .. pr.additions
      local del_stat = "-" .. pr.deletions
      local add_start = #line - #add_stat - #del_stat - 1
      local add_end = add_start + #add_stat
      local del_start = add_end + 1
      local del_end = del_start + #del_stat

      table.insert(highlights, { #lines, "Directory", 0, add_start })
      table.insert(highlights, { #lines, "DiffAdd", add_start, add_end })
      table.insert(highlights, { #lines, "DiffDelete", del_start, del_end })
    end
  end
end

---@param status string
---@return string
local function status_icon(status)
  if status == "A" then
    return "+"
  elseif status == "D" then
    return "-"
  else
    return "~"
  end
end

---@param line_type "context"|"add"|"del"|"header"
---@return string
local function line_highlight(line_type)
  if line_type == "add" then
    return "DiffAdd"
  elseif line_type == "del" then
    return "DiffDelete"
  elseif line_type == "header" then
    return "Title"
  end
  return "Normal"
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
  end

  table.insert(lines, title)
  table.insert(lines, string.rep("-", 60))
  table.insert(highlights, { #lines - 1, "Title", 0, -1 })
  table.insert(highlights, { #lines, "Comment", 0, -1 })

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
    local add_stat = "+" .. file.insertions
    local del_stat = "-" .. file.deletions
    local file_line = string.format(
      "%s %s  %s %s",
      status_icon(file.status),
      file.display_path or file.path,
      add_stat,
      del_stat
    )
    table.insert(lines, file_line)

    local add_start = #file_line - #add_stat - #del_stat - 1
    local add_end = add_start + #add_stat
    local del_start = add_end + 1
    local del_end = del_start + #del_stat
    table.insert(highlights, { #lines, "Directory", 0, add_start })
    table.insert(highlights, { #lines, "DiffAdd", add_start, add_end })
    table.insert(highlights, { #lines, "DiffDelete", del_start, del_end })

    for _, hunk in ipairs(file.hunks) do
      table.insert(
        lines,
        string.format(
          "  @@ -%d,%d +%d,%d @@",
          hunk.old_start,
          hunk.old_count,
          hunk.new_start,
          hunk.new_count
        )
      )
      table.insert(highlights, { #lines, "Comment", 0, -1 })

      for _, diff_line in ipairs(hunk.lines) do
        local marker = " "
        if diff_line.type == "add" then
          marker = "+"
        elseif diff_line.type == "del" then
          marker = "-"
        end

        table.insert(lines, "  " .. marker .. diff_line.text)
        table.insert(highlights, { #lines, line_highlight(diff_line.type), 0, -1 })
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
  local pr = pr_idx and state.prs[pr_idx]
  if pr then
    load_pr_diff(pr)
  end
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
    root = state.root,
  }
end

return M
