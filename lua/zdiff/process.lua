local M = {}

local function result(argv, code, stdout, stderr)
  stdout = stdout or ""
  local err = code == 0 and nil or vim.trim(stderr or "")
  if err == "" then
    err = "command failed: " .. table.concat(argv, " ")
  end
  return { ok = code == 0, stdout = stdout, error = err }
end

---@param cwd string|nil
---@param argv string[]
---@param callback fun(result: {ok: boolean, stdout: string, error: string|nil})
function M.run(cwd, argv, callback)
  local function finish(code, stdout, stderr)
    vim.schedule(function()
      callback(result(argv, code or 1, stdout, stderr))
    end)
  end

  if vim.system then
    local ok, err = pcall(vim.system, argv, { text = true, cwd = cwd }, function(obj)
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
    cwd = cwd,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      stdout = data and table.concat(data, "\n") or ""
    end,
    on_stderr = function(_, data)
      stderr = data and table.concat(data, "\n") or ""
    end,
    on_exit = function(_, code)
      finish(code, stdout, stderr)
    end,
  })

  if job_id <= 0 then
    finish(1, "", "failed to start command")
  end
end

return M
