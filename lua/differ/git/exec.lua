-- spawning git, and telling the user (or a stale buffer) about it. every git module
-- runs through here, so the argv prefix and the message shape sit in one place

local M = {}

-- every path differ hands git is a real file name, never a glob
M.GIT = { "git", "--literal-pathspecs" }

---@param msg string
---@param level integer|nil
function M.notify(msg, level)
    vim.notify("differ: " .. msg, level or vim.log.levels.INFO)
end

-- spawn git and wait. vim.system raises when the process can't start, so that comes
-- back as `err`; a nil res with no err is wait() answering nothing at all
---@param cmd string[]
---@param opts table
---@return { code: integer, stdout: string|nil, stderr: string|nil }|nil res, string|nil err
local function run(cmd, opts)
    local ok, obj = pcall(vim.system, cmd, opts)
    if not ok then
        return nil, tostring(obj)
    end
    return obj:wait()
end

-- run git in `cwd`: stdout on success, nil + stderr on failure. `text = true`
-- normalises `\r\n`, which is right for plumbing output but would corrupt file content
-- read via `git show`; content reads use git_raw instead
---@param args string[]
---@param cwd string
---@param opts? { timeout?: integer, env?: table<string, string> }
---@return string|nil stdout, string|nil stderr
function M.git(args, cwd, opts)
    local cmd = vim.list_extend({}, M.GIT)
    vim.list_extend(cmd, args)
    opts = opts or {}
    local res, err = run(cmd, {
        cwd = cwd,
        text = true,
        timeout = opts.timeout,
        env = opts.env,
    })
    if err then
        return nil, err -- never started
    end
    -- a killed process exits 124 with an empty stderr, or answers nothing at all when a
    -- child outlives it holding the pipes. both are the budget, and neither says so
    if opts.timeout and (not res or res.code == 124) then
        return nil, ("git %s timed out after %ds"):format(args[1], opts.timeout / 1000)
    end
    if not res then
        return nil, "git exited without a result"
    end
    if res.code ~= 0 then
        return nil, res.stderr
    end
    return res.stdout
end

-- like `git`, but byte-true stdout (CRLF kept): for content reads (`git show` on the
-- index, a rev, a conflict stage), never for plumbing output
---@param args string[]
---@param cwd string
---@return string|nil stdout, string|nil stderr
function M.git_raw(args, cwd)
    local cmd = vim.list_extend({}, M.GIT)
    vim.list_extend(cmd, args)
    local res, err = run(cmd, { cwd = cwd })
    if not res then
        return nil, err
    end
    if res.code ~= 0 then
        return nil, res.stderr
    end
    return res.stdout
end

-- run git and report a failure where the user can see it. the wrapper owns the message,
-- so a caller branching on the boolean alone can't swallow one
---@param args string[]
---@param cwd string
---@param what string  -- names the operation in the message
---@return boolean ok
function M.git_ok(args, cwd, what)
    local out, err = M.git(args, cwd) -- nil out is exactly a non-zero exit; stderr can be empty
    if not out then
        M.notify(("%s failed: %s"):format(what, err or ""), vim.log.levels.ERROR)
        return false
    end
    return true
end

-- strip trailing whitespace from a git output line (e.g. rev-parse, show, log)
---@param s string
---@return string
function M.chomp(s)
    return (s:gsub("%s+$", ""))
end

-- a buffer on a file differ just rewrote keeps the old content until something checks,
-- and a window switch doesn't. checktime leaves unsaved edits alone, so fire it always
---@param root string
---@param relpath string
function M.reload_buffer(root, relpath)
    local buf = require("differ.util.buf").find(root .. "/" .. relpath)
    if buf and vim.api.nvim_buf_is_loaded(buf) then
        -- silent!: the file may be gone entirely (a discarded untracked file)
        pcall(vim.api.nvim_buf_call, buf, function()
            vim.cmd("silent! checktime")
        end)
    end
end

return M
