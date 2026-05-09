local M = {}

local function run_sync(cmd, cwd)
  local full_cmd = cmd
  if cwd and cwd ~= "" then
    full_cmd = "cd " .. vim.fn.shellescape(cwd) .. " && " .. cmd
  end
  local out = vim.fn.system(full_cmd)
  if vim.v.shell_error ~= 0 then
    error(string.format("command failed (%s): %s", full_cmd, out))
  end
  return out
end

local function write_file(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "w"))
  f:write(table.concat(lines, "\n"))
  f:write("\n")
  f:close()
end

M.files = {
  {
    path = "src/example.lua",
    probe = "local function render_user",
    before = {
      "local M = {}",
      "",
      "local function render_user(user)",
      "  local name = user.name or 'anonymous'",
      "  return string.format('hello %s', name)",
      "end",
      "",
      "return M",
    },
    after = {
      "local M = {}",
      "",
      "local function render_user(user)",
      "  local name = user.display_name or user.name or 'anonymous'",
      "  return string.format('welcome %s', name)",
      "end",
      "",
      "return M",
    },
  },
  {
    path = "src/example.py",
    probe = "def render_user",
    before = {
      "class UserPresenter:",
      "    def render_user(self, user):",
      "        name = user.get('name', 'anonymous')",
      "        return f'hello {name}'",
    },
    after = {
      "class UserPresenter:",
      "    def render_user(self, user):",
      "        name = user.get('display_name') or user.get('name', 'anonymous')",
      "        return f'welcome {name}'",
    },
  },
  {
    path = "web/example.tsx",
    probe = "export function UserCard",
    before = {
      "type User = { name: string; active: boolean };",
      "",
      "export function UserCard({ user }: { user: User }) {",
      '  return <section className="card">{user.name}</section>;',
      "}",
    },
    after = {
      "type User = { name: string; active: boolean };",
      "",
      "export function UserCard({ user }: { user: User }) {",
      "  const label = user.active ? user.name : `Inactive ${user.name}`;",
      '  return <section className="card" data-active={user.active}>{label}</section>;',
      "}",
    },
  },
  {
    path = "cmd/example.go",
    probe = "func RenderUser",
    before = {
      "package main",
      "",
      "func RenderUser(name string) string {",
      '\treturn "hello " + name',
      "}",
    },
    after = {
      "package main",
      "",
      "func RenderUser(name string) string {",
      '\tif name == "" {',
      '\t\tname = "anonymous"',
      "\t}",
      '\treturn "welcome " + name',
      "}",
    },
  },
  {
    path = "data/example.json",
    probe = '"displayName"',
    before = {
      "{",
      '  "name": "Ada",',
      '  "active": true',
      "}",
    },
    after = {
      "{",
      '  "name": "Ada",',
      '  "displayName": "Ada Lovelace",',
      '  "active": true',
      "}",
    },
  },
  {
    path = "docs/example.md",
    probe = "## Usage",
    before = {
      "# Example",
      "",
      "Run the command with default settings.",
    },
    after = {
      "# Example",
      "",
      "## Usage",
      "",
      "Run the command with explicit settings.",
      "",
      "```lua",
      "require('zdiff').setup({ default_expanded = true })",
      "```",
    },
  },
  {
    path = "styles/example.css",
    probe = ".user-card",
    before = {
      ".user-card {",
      "  color: black;",
      "}",
    },
    after = {
      ".user-card {",
      "  color: var(--fg);",
      "  border: 1px solid var(--border);",
      "}",
    },
  },
  {
    path = "config/example.yaml",
    probe = "default_expanded",
    before = {
      "zdiff:",
      "  mode: projection",
    },
    after = {
      "zdiff:",
      "  mode: projection",
      "  default_expanded: true",
    },
  },
}

function M.create_repo()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")

  run_sync("git init", repo)
  run_sync("git config user.name 'zdiff-test'", repo)
  run_sync("git config user.email 'zdiff@example.com'", repo)

  for _, file in ipairs(M.files) do
    write_file(repo .. "/" .. file.path, file.before)
  end

  run_sync("git add .", repo)
  run_sync("git commit -m 'baseline syntax fixtures'", repo)

  for _, file in ipairs(M.files) do
    write_file(repo .. "/" .. file.path, file.after)
  end

  write_file(repo .. "/untracked/example.sh", {
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
  local ok = vim.wait(timeout_ms, function()
    local buf = vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= "zdiff" then
      return false
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, 2, false)
    local header = lines[1] or ""
    return header ~= "" and header:find("%(loading%.%.%.%)", 1, false) == nil
  end, 50)
  if not ok then
    error("timeout waiting for zdiff async refresh to complete")
  end
end

function M.wait_for_syntax_idle(timeout_ms)
  local zdiff = require("zdiff")
  local ok = vim.wait(timeout_ms, function()
    local dbg = zdiff._debug_state and zdiff._debug_state() or {}
    return (dbg.pending_syntax_jobs or 0) == 0
  end, 50)
  if not ok then
    error("timeout waiting for zdiff syntax jobs to complete")
  end
end

return M
