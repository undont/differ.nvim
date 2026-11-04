-- spawning git, and telling the user (or a stale buffer) about it. every git module
-- runs through here, so the argv prefix and the message shape sit in one place.
-- M.async and M.submit run git off the main loop without changing call sites

local M = {}

-- every path differ hands git is a real file name, never a glob
M.GIT = { "git", "--literal-pathspecs" }

---@param msg string
---@param level integer|nil
function M.notify(msg, level)
    vim.notify("differ: " .. msg, level or vim.log.levels.INFO)
end

---@alias differ.GitResult { code: integer, stdout: string|nil, stderr: string|nil }

-- coroutines started by M.async: git yields inside one of these and blocks anywhere else
---@type table<thread, true>
local runners = setmetatable({}, { __mode = "k" })

-- yield the running M.async coroutine until the callback handed to `start` fires (from
-- any context, at most once counts), returning what it was called with
---@param start fun(resume: fun(...))
---@return ...
function M.await(start)
    local co = coroutine.running()
    assert(co and runners[co], "exec.await outside exec.async")
    local settled = false
    start(function(...)
        if settled then
            return
        end
        settled = true
        local args = vim.F.pack_len(...)
        vim.schedule(function()
            local ok, err = coroutine.resume(co, vim.F.unpack_len(args))
            if not ok then
                error(err, 0)
            end
        end)
    end)
    return coroutine.yield()
end

-- on_exit waits for the pipes to close, so a child outliving git would never fire it;
-- the guard gives up when wait() would
---@param cmd string[]
---@param opts table
---@return differ.GitResult|nil res, string|nil err
local function run_yielding(cmd, opts)
    return M.await(function(resume)
        local guard = assert(vim.uv.new_timer())
        local function done(res, err)
            if not guard:is_closing() then
                guard:close()
            end
            resume(res, err)
        end
        local ok, obj = pcall(vim.system, cmd, opts, done)
        if not ok then
            return done(nil, tostring(obj))
        end
        if opts.timeout then
            guard:start(2 * opts.timeout, 0, function()
                pcall(obj.kill, obj, 9)
                done(nil)
            end)
        end
    end)
end

-- spawn git and wait. vim.system raises when the process can't start, so that comes
-- back as `err`; a nil res with no err is wait() answering nothing at all
---@param cmd string[]
---@param opts table
---@return differ.GitResult|nil res, string|nil err
local function run(cmd, opts)
    local co = coroutine.running()
    if co and runners[co] then
        return run_yielding(cmd, opts)
    end
    local ok, obj = pcall(vim.system, cmd, opts)
    if not ok then
        return nil, tostring(obj)
    end
    return obj:wait()
end

-- run `fn` in a coroutine where M.git and M.git_raw yield instead of blocking.
-- `on_done` gets pcall's results, always on a later tick and outside the coroutine
---@param fn fun(): ...
---@param on_done fun(ok: boolean, ...)
function M.async(fn, on_done)
    local co = coroutine.create(function()
        local res = vim.F.pack_len(pcall(fn))
        vim.schedule(function()
            on_done(vim.F.unpack_len(res))
        end)
    end)
    runners[co] = true
    local ok, err = coroutine.resume(co)
    if not ok then
        error(err, 0)
    end
end

---@class differ.GitQueue
---@field generation integer
---@field busy boolean
---@field pending { generation: integer, task: fun(): ..., on_done: fun(ok: boolean, ...) }[]

---@type table<string, differ.GitQueue>
local queues = {}

---@param root string
---@return differ.GitQueue
local function queue_for(root)
    local q = queues[root]
    if not q then
        q = { generation = 0, busy = false, pending = {} }
        queues[root] = q
    end
    return q
end

---@param q differ.GitQueue
local function drain(q)
    local job = table.remove(q.pending, 1)
    while job and job.generation ~= q.generation do
        job = table.remove(q.pending, 1)
    end
    if not job then
        q.busy = false
        return
    end
    q.busy = true
    M.async(job.task, function(...)
        local ok, err = true, nil
        if job.generation == q.generation then
            ok, err = pcall(job.on_done, ...)
        end
        drain(q)
        if not ok then
            error(err, 0)
        end
    end)
end

-- run `task` (see M.async) once every earlier task on `root` has finished. `on_done` is
-- dropped when M.supersede ran on `root` after this submit
---@param root string
---@param task fun(): ...
---@param on_done fun(ok: boolean, ...)
function M.submit(root, task, on_done)
    local q = queue_for(root)
    table.insert(q.pending, { generation = q.generation, task = task, on_done = on_done })
    if not q.busy then
        drain(q)
    end
end

-- drop the result of every task submitted on `root` so far; queued ones never start
---@param root string
function M.supersede(root)
    local q = queue_for(root)
    q.generation = q.generation + 1
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
---@param stdin? string
---@return string|nil stdout, string|nil stderr
function M.git_raw(args, cwd, stdin)
    local cmd = vim.list_extend({}, M.GIT)
    vim.list_extend(cmd, args)
    local res, err = run(cmd, { cwd = cwd, stdin = stdin })
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
        M.notify(M.with_stderr(what .. " failed", err), vim.log.levels.ERROR)
        return false
    end
    return true
end

-- `lead`, followed by what git said when it said anything
---@param lead string
---@param stderr string|nil
---@return string
function M.with_stderr(lead, stderr)
    local said = vim.trim(stderr or "")
    if said == "" then
        return lead
    end
    return lead .. ": " .. said
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
