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
      "---@class User",
      "---@field name string?",
      "---@field active boolean",
      "local M = {}",
      "",
      "local function render_user(user)",
      "  local name = user.name or 'anonymous'",
      "  if user.active then",
      "    return string.format('hello %s', name)",
      "  end",
      "  return 'inactive'",
      "end",
      "",
      "M.render_user = render_user",
      "",
      "return M",
    },
    after = {
      "---@class User",
      "---@field name string?",
      "---@field display_name string?",
      "---@field active boolean",
      "local M = {}",
      "",
      "local function render_user(user)",
      "  local name = user.display_name or user.name or 'anonymous'",
      "  if user.active then",
      "    return string.format('welcome %s', name)",
      "  end",
      "  return string.format('inactive: %s', name)",
      "end",
      "",
      "M.render_user = render_user",
      "",
      "return M",
    },
  },
  {
    path = "lib/example.ex",
    probe = "def render_user",
    before = {
      "defmodule Fixtures.Example do",
      "  @moduledoc false",
      "",
      "  def render_user(%{name: name, active: true}) do",
      [[    "hello #{name || "anonymous"}"]],
      "  end",
      "",
      '  def render_user(_user), do: "inactive"',
      "end",
    },
    after = {
      "defmodule Fixtures.Example do",
      "  @moduledoc false",
      "",
      "  def render_user(%{display_name: display_name, name: name, active: true}) do",
      [[    label = display_name || name || "anonymous"]],
      [[    "welcome #{label}"]],
      "  end",
      "",
      "  def render_user(%{name: name}) do",
      [[    "inactive: #{name || "anonymous"}"]],
      "  end",
      "end",
    },
  },
  {
    path = "src/example.py",
    probe = "def render_user",
    before = {
      "from dataclasses import dataclass",
      "",
      "",
      "@dataclass",
      "class User:",
      "    name: str",
      "    active: bool = True",
      "",
      "",
      "class UserPresenter:",
      "    def render_user(self, user: User) -> str:",
      "        name = user.name or 'anonymous'",
      "        if user.active:",
      "            return f'hello {name}'",
      "        return 'inactive'",
      "",
      'USER_QUERY = """',
      "SELECT id, name",
      "FROM users",
      "WHERE active = TRUE",
      '"""',
    },
    after = {
      "from dataclasses import dataclass",
      "",
      "",
      "@dataclass",
      "class User:",
      "    name: str",
      "    display_name: str | None = None",
      "    active: bool = True",
      "",
      "",
      "class UserPresenter:",
      "    def render_user(self, user: User) -> str:",
      "        name = user.display_name or user.name or 'anonymous'",
      "        if user.active:",
      "            return f'welcome {name}'",
      "        return f'inactive: {name}'",
      "",
      'USER_QUERY = """',
      "SELECT id, COALESCE(display_name, name) AS label",
      "FROM users",
      "WHERE active = TRUE",
      "ORDER BY label ASC",
      '"""',
    },
  },
  {
    path = "web/example.js",
    probe = "export function renderUser",
    before = {
      "const DEFAULT_NAME = 'anonymous';",
      "",
      "export function renderUser(user) {",
      "  const name = user.name ?? DEFAULT_NAME;",
      "  return {",
      "    label: `Hello ${name}`,",
      "    active: Boolean(user.active),",
      "  };",
      "}",
    },
    after = {
      "const DEFAULT_NAME = 'anonymous';",
      "",
      "export function renderUser(user) {",
      "  const name = user.displayName ?? user.name ?? DEFAULT_NAME;",
      "  return {",
      "    label: user.active ? `Welcome ${name}` : `Inactive ${name}`,",
      "    active: Boolean(user.active),",
      "    metadata: { source: 'fixture', tags: ['syntax', 'diff'] },",
      "  };",
      "}",
    },
  },
  {
    path = "web/example.ts",
    probe = "export function summarizeUser",
    before = {
      "type User = {",
      "  name: string;",
      "  roles: string[];",
      "};",
      "",
      "export function summarizeUser(user: User): string {",
      "  const roleCount = user.roles.length;",
      "  return `${user.name} has ${roleCount} roles`;",
      "}",
    },
    after = {
      "type User = {",
      "  name: string;",
      "  displayName?: string;",
      "  roles: string[];",
      "};",
      "",
      "export function summarizeUser(user: User): string {",
      "  const roleCount = user.roles.length;",
      "  const name = user.displayName ?? user.name;",
      "  return `${name} has ${roleCount} roles`;",
      "}",
    },
  },
  {
    path = "web/example.tsx",
    probe = "export function UserCard",
    before = {
      "type User = { name: string; active: boolean; roles: string[] };",
      "",
      "export function UserCard({ user }: { user: User }) {",
      "  return (",
      '    <section className="card">',
      "      <h2>{user.name}</h2>",
      "      <span>{user.roles.length} roles</span>",
      "    </section>",
      "  );",
      "}",
    },
    after = {
      "type User = { name: string; active: boolean; roles: string[] };",
      "",
      "export function UserCard({ user }: { user: User }) {",
      "  const label = user.active ? user.name : `Inactive ${user.name}`;",
      "  return (",
      '    <section className="card" data-active={user.active}>',
      "      <h2>{label}</h2>",
      "      <ul>{user.roles.map((role) => <li key={role}>{role}</li>)}</ul>",
      "    </section>",
      "  );",
      "}",
    },
  },
  {
    path = "cmd/example.go",
    probe = "func RenderUser",
    before = {
      "package main",
      "",
      "type User struct {",
      "\tName   string",
      "\tActive bool",
      "}",
      "",
      "func RenderUser(user User) string {",
      "\tname := user.Name",
      '\tif name == "" {',
      '\t\tname = "anonymous"',
      "\t}",
      '\treturn "hello " + name',
      "}",
    },
    after = {
      "package main",
      "",
      "type User struct {",
      "\tName        string",
      "\tDisplayName string",
      "\tActive      bool",
      "}",
      "",
      "func RenderUser(user User) string {",
      "\tname := user.DisplayName",
      '\tif name == "" {',
      "\t\tname = user.Name",
      "\t}",
      '\tif name == "" {',
      '\t\tname = "anonymous"',
      "\t}",
      "\tif !user.Active {",
      '\t\treturn "inactive: " + name',
      "\t}",
      '\treturn "welcome " + name',
      "}",
    },
  },
  {
    path = "src/example.rs",
    probe = "pub fn render_user",
    before = {
      "pub struct User {",
      "    pub name: Option<String>,",
      "    pub active: bool,",
      "}",
      "",
      "pub fn render_user(user: &User) -> String {",
      [[    let name = user.name.as_deref().unwrap_or("anonymous");]],
      "    if user.active {",
      [[        format!("hello {name}")]],
      "    } else {",
      [[        "inactive".to_string()]],
      "    }",
      "}",
    },
    after = {
      "pub struct User {",
      "    pub name: Option<String>,",
      "    pub display_name: Option<String>,",
      "    pub active: bool,",
      "}",
      "",
      "pub fn render_user(user: &User) -> String {",
      [[    let name = user.display_name.as_deref().or(user.name.as_deref()).unwrap_or("anonymous");]],
      "    match user.active {",
      [[        true => format!("welcome {name}"),]],
      [[        false => format!("inactive: {name}"),]],
      "    }",
      "}",
    },
  },
  {
    path = "src/example.c",
    probe = "char *render_user",
    before = {
      "#include <stdbool.h>",
      "#include <stdio.h>",
      "",
      "struct user {",
      "  const char *name;",
      "  bool active;",
      "};",
      "",
      "char *render_user(struct user user, char *buffer, int size) {",
      [[  const char *name = user.name ? user.name : "anonymous";]],
      [[  snprintf(buffer, size, "hello %s", name);]],
      "  return buffer;",
      "}",
    },
    after = {
      "#include <stdbool.h>",
      "#include <stdio.h>",
      "",
      "struct user {",
      "  const char *name;",
      "  const char *display_name;",
      "  bool active;",
      "};",
      "",
      "char *render_user(struct user user, char *buffer, int size) {",
      [[  const char *name = user.display_name ? user.display_name : user.name;]],
      [[  snprintf(buffer, size, user.active ? "welcome %s" : "inactive: %s", name);]],
      "  return buffer;",
      "}",
    },
  },
  {
    path = "src/example.cpp",
    probe = "std::string render_user",
    before = {
      "#include <optional>",
      "#include <string>",
      "",
      "struct User {",
      "  std::optional<std::string> name;",
      "  bool active;",
      "};",
      "",
      "std::string render_user(const User& user) {",
      [[  auto name = user.name.value_or("anonymous");]],
      [[  return "hello " + name;]],
      "}",
    },
    after = {
      "#include <optional>",
      "#include <string>",
      "",
      "struct User {",
      "  std::optional<std::string> name;",
      "  std::optional<std::string> display_name;",
      "  bool active;",
      "};",
      "",
      "std::string render_user(const User& user) {",
      [[  auto name = user.display_name.value_or(user.name.value_or("anonymous"));]],
      [[  return user.active ? "welcome " + name : "inactive: " + name;]],
      "}",
    },
  },
  {
    path = "data/example.json",
    probe = '"displayName"',
    before = {
      "{",
      '  "user": {',
      '    "name": "Ada",',
      '    "active": true,',
      '    "roles": ["admin", "reviewer"]',
      "  }",
      "}",
    },
    after = {
      "{",
      '  "user": {',
      '    "name": "Ada",',
      '    "displayName": "Ada Lovelace",',
      '    "active": true,',
      '    "roles": ["admin", "reviewer", "maintainer"]',
      "  }",
      "}",
    },
  },
  {
    path = "docs/example.md",
    probe = "## Usage",
    before = {
      "# Example",
      "",
      "Run the command with **default** settings and `projection` mode.",
      "",
      "- Opens a diff view",
      "- Uses projection highlighting",
      "",
      "> Syntax should remain readable while reviewing changes.",
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
      "Run the command with **explicit** settings and compare the result in [Neovim](https://neovim.io).",
      "",
      "- [x] Open a diff view",
      "- [x] Use projection highlighting",
      "- [ ] Inspect injected fenced-code highlighting",
      "",
      "> Syntax should remain readable while reviewing changes.",
      "",
      "```lua",
      "require('zdiff').setup({ default_expanded = true })",
      "```",
      "",
      "```python",
      "def render_user(user):",
      "    name = user.get('display_name') or user.get('name', 'anonymous')",
      "    return f'welcome {name}'",
      "```",
      "",
      "```json",
      "{",
      '  "syntax": "projection",',
      '  "languages": ["markdown", "lua", "python", "json"]',
      "}",
      "```",
      "",
      "```bash",
      "set -euo pipefail",
      "nvim -c 'Zdiff'",
      "```",
      "",
      "| Key | Action |",
      "| --- | --- |",
      "| `<Tab>` | Toggle file |",
      "| `R` | Refresh diff |",
    },
  },
  {
    path = "web/example.html",
    probe = "<main",
    before = {
      "<!doctype html>",
      '<html lang="en">',
      "  <body>",
      '    <main class="page">',
      "      <h1>Hello Ada</h1>",
      "    </main>",
      "  </body>",
      "</html>",
    },
    after = {
      "<!doctype html>",
      '<html lang="en">',
      "  <body>",
      '    <main class="page" data-state="active">',
      "      <h1>Welcome Ada</h1>",
      '      <button type="button">Review changes</button>',
      "    </main>",
      "  </body>",
      "</html>",
    },
  },
  {
    path = "styles/example.css",
    probe = ".user-card",
    before = {
      ":root {",
      "  --fg: #111827;",
      "}",
      "",
      ".user-card {",
      "  color: black;",
      "  display: block;",
      "}",
    },
    after = {
      ":root {",
      "  --fg: #111827;",
      "  --border: #d1d5db;",
      "}",
      "",
      ".user-card {",
      "  color: var(--fg);",
      "  display: grid;",
      "  gap: 0.5rem;",
      "  border: 1px solid var(--border);",
      "}",
    },
  },
  {
    path = "db/example.sql",
    probe = "SELECT",
    before = {
      "CREATE TABLE users (",
      "  id INTEGER PRIMARY KEY,",
      "  name TEXT NOT NULL,",
      "  active BOOLEAN NOT NULL DEFAULT TRUE",
      ");",
      "",
      "SELECT id, name FROM users WHERE active = TRUE;",
    },
    after = {
      "CREATE TABLE users (",
      "  id INTEGER PRIMARY KEY,",
      "  name TEXT NOT NULL,",
      "  display_name TEXT,",
      "  active BOOLEAN NOT NULL DEFAULT TRUE",
      ");",
      "",
      "SELECT id, COALESCE(display_name, name) AS label",
      "FROM users",
      "WHERE active = TRUE",
      "ORDER BY label ASC;",
    },
  },
  {
    path = "config/example.yaml",
    probe = "default_expanded",
    before = {
      "zdiff:",
      "  mode: projection",
      "  keymaps:",
      "    toggle: <Tab>",
    },
    after = {
      "zdiff:",
      "  mode: projection",
      "  default_expanded: true",
      "  keymaps:",
      "    toggle: <Tab>",
      "    refresh: R",
    },
  },
  {
    path = "config/example.toml",
    probe = "default_expanded",
    before = {
      "[zdiff]",
      [[mode = "projection"]],
      "",
      "[zdiff.keymaps]",
      [[toggle = "<Tab>"]],
    },
    after = {
      "[zdiff]",
      [[mode = "projection"]],
      "default_expanded = true",
      "",
      "[zdiff.keymaps]",
      [[toggle = "<Tab>"]],
      [[refresh = "R"]],
    },
  },
  {
    path = "scripts/example.sh",
    probe = "render_user",
    before = {
      "#!/usr/bin/env bash",
      "set -euo pipefail",
      "",
      "render_user() {",
      '  local name="${1:-anonymous}"',
      "  printf 'hello %s\\n' \"$name\"",
      "}",
      "",
      'render_user "$@"',
    },
    after = {
      "#!/usr/bin/env bash",
      "set -euo pipefail",
      "",
      "render_user() {",
      '  local name="${1:-anonymous}"',
      '  local active="${2:-true}"',
      '  if [[ "$active" == true ]]; then',
      "    printf 'welcome %s\\n' \"$name\"",
      "  else",
      "    printf 'inactive: %s\\n' \"$name\"",
      "  fi",
      "}",
      "",
      'render_user "$@"',
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
    return not dbg.pending_render
      and (dbg.pending_hunk_jobs or 0) == 0
      and (dbg.pending_syntax_jobs or 0) == 0
  end, 50)
  if not ok then
    error("timeout waiting for zdiff syntax jobs to complete")
  end
end

return M
