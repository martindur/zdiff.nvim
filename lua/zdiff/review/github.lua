local M = {}
local diff = require("zdiff.diff")
local process = require("zdiff.process")

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

---@param path string
---@return string
local function encode_path(path)
  local parts = vim.split(path, "/", { plain = true })
  for idx, part in ipairs(parts) do
    parts[idx] = vim.uri_encode(part)
  end
  return table.concat(parts, "/")
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

  local patch = type(raw.patch) == "string" and raw.patch or ""
  return {
    path = new_path or old_path or raw.filename,
    display_path = display_path,
    old_path = old_path,
    new_path = new_path,
    status = status,
    insertions = tonumber(raw.additions) or 0,
    deletions = tonumber(raw.deletions) or 0,
    expanded = false,
    hunks = diff.parse_hunks(split_lines(patch)),
    hunk_status = "loaded",
    hunk_error = nil,
    patch_unavailable = type(raw.patch) ~= "string",
    review_base_ref = refs.base,
    review_head_ref = refs.head,
  }
end

---@param raw table
---@return ZdiffReviewPr
local function normalize_pr(raw)
  local author = raw.author
  if type(author) == "table" then
    author = author.login
  end

  local body = raw.body
  if body == nil then
    body = raw.description
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
    body = type(body) == "string" and body or nil,
  }
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
---@param done fun(result: {ok: boolean, data?: ZdiffReviewPr[], error?: string})
function M.list_prs(root, done)
  process.run(root, {
    "gh",
    "pr",
    "list",
    "--json",
    "number,title,author,additions,deletions,reviewDecision,isDraft,baseRefOid,headRefOid,body",
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
---@param pr ZdiffReviewPr
---@param done fun(result: {ok: boolean, data?: ZdiffFile[], error?: string})
function M.diff_pr(root, pr, done)
  local refs = { base = pr.base_ref_oid, head = pr.head_ref_oid }

  process.run(root, {
    "gh",
    "api",
    "--paginate",
    "--slurp",
    "--method",
    "GET",
    "repos/{owner}/{repo}/pulls/" .. tostring(pr.number) .. "/files",
    "-F",
    "per_page=100",
  }, function(result)
    if not result.ok then
      done({ ok = false, error = result.error })
      return
    end

    local ok, pages = pcall(vim.json.decode, result.stdout)
    if not ok or type(pages) ~= "table" then
      done({ ok = false, error = "could not parse PR files" })
      return
    end

    local files = {}
    for _, page in ipairs(pages) do
      for _, raw in ipairs(page) do
        local file = normalize_pr_file(raw, refs)
        if file then
          table.insert(files, file)
        end
      end
    end
    done({ ok = true, data = files })
  end)
end

---@param root string
---@param number number
---@param done fun(result: {ok: boolean, data?: ZdiffReviewPostedComment[], error?: string})
function M.list_comments(root, number, done)
  process.run(root, {
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
function M.submit_comment(root, number, comment, done)
  process.run(root, {
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
    "commit_id=" .. comment.commit_id,
    "-f",
    "path=" .. comment.path,
    "-f",
    "side=" .. comment.side,
    "-F",
    "line=" .. tostring(comment.line),
    "--silent",
  }, done)
end

---@param root string
---@param number number
---@param comment_id number
---@param body string
---@param done fun(result: {ok: boolean, error?: string})
function M.reply_comment(root, number, comment_id, body, done)
  process.run(root, {
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
  }, done)
end

---@param root string
---@param number number
---@param action "approve"|"request_changes"
---@param body string
---@param done fun(result: {ok: boolean, error?: string})
function M.submit_review(root, number, action, body, done)
  process.run(root, {
    "gh",
    "pr",
    "review",
    tostring(number),
    action == "approve" and "--approve" or "--request-changes",
    "--body",
    body,
  }, done)
end

---@param root string
---@param number number
---@param body string
---@param done fun(result: {ok: boolean, error?: string})
function M.submit_pr_comment(root, number, body, done)
  process.run(root, {
    "gh",
    "pr",
    "comment",
    tostring(number),
    "--body",
    body,
  }, done)
end

---@param root string
---@param path string
---@param ref string
---@param done fun(result: {ok: boolean, data?: string[], error?: string})
function M.read_file(root, path, ref, done)
  process.run(root, {
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

    done({ ok = true, data = split_lines(result.stdout) })
  end)
end

return M
