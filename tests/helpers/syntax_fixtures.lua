local M = {}
local git_repo = require("tests.helpers.git_repo")
local session = require("tests.helpers.zdiff_session")

M.files = {
  {
    path = "src/example.lua",
    probe = "local function render_user",
    before = {
      "local function render_user(user)",
      "  local name = user.name or 'anonymous'",
      "  return string.format('hello %s', name)",
      "end",
    },
    after = {
      "local function render_user(user)",
      "  local name = user.display_name or user.name or 'anonymous'",
      "  return string.format('welcome %s', name)",
      "end",
    },
  },
  {
    path = "src/example.py",
    probe = "SELECT id",
    before = {
      'USER_QUERY = """',
      "SELECT id, name",
      "FROM users",
      "WHERE active = TRUE",
      '"""',
    },
    after = {
      'USER_QUERY = """',
      "SELECT id, COALESCE(display_name, name) AS label",
      "FROM users",
      "WHERE active = TRUE",
      "ORDER BY label ASC",
      '"""',
    },
  },
  {
    path = "docs/example.md",
    probe = "require('zdiff')",
    before = {
      "# Example",
      "",
      "```lua",
      "require('zdiff').setup()",
      "```",
    },
    after = {
      "# Example",
      "",
      "## Usage",
      "",
      "```lua",
      "require('zdiff').setup({ default_expanded = true })",
      "```",
    },
  },
}

function M.create_repo()
  local repo = git_repo.create()

  for _, file in ipairs(M.files) do
    git_repo.write_lines(repo .. "/" .. file.path, file.before)
  end

  git_repo.commit_all(repo, "baseline syntax fixtures")

  for _, file in ipairs(M.files) do
    git_repo.write_lines(repo .. "/" .. file.path, file.after)
  end

  git_repo.write_lines(repo .. "/untracked/example.sh", {
    "#!/usr/bin/env bash",
    "set -euo pipefail",
    'echo "hello from an untracked shell file"',
  })

  return repo
end

function M.lang_available(path)
  local ft = vim.filetype.match({ filename = path })
  if not ft then
    return false, nil
  end

  local lang = vim.treesitter.language.get_lang(ft)
  if not lang then
    return false, nil
  end

  local inspect_ok = pcall(vim.treesitter.language.inspect, lang)
  if not inspect_ok then
    return false, lang
  end

  local parser_ok = pcall(vim.treesitter.get_string_parser, "probe\n", lang)
  if not parser_ok then
    return false, lang
  end

  local query_ok, query = pcall(vim.treesitter.query.get, lang, "highlights")
  if not query_ok or not query then
    return false, lang
  end

  return true, lang
end

function M.wait_for_loaded(timeout_ms)
  session.wait_for_loaded(timeout_ms)
end

function M.wait_for_syntax_idle(timeout_ms)
  session.wait_for_syntax_idle(timeout_ms)
end

return M
