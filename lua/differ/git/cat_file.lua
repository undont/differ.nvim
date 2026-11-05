-- one long-lived `git cat-file --batch` per root a session holds, for object reads by
-- id or `<rev>:path`. replies come back in request order, so the waiting list is the
-- per-root serialisation. a read it can't answer comes back unanswered and the caller
-- spawns git as it would without the process

local exec = require("differ.git.exec")

local M = {}

-- how long a process with reads waiting may send nothing before it is killed
M.TIMEOUT = 2000

---@class differ.git.Object
---@field sha string
---@field kind string -- "blob", "tree", "commit", "tag"
---@field text string

---@class differ.git.CatFileWaiter
---@field name string
---@field need integer|nil -- reply bytes, header to trailing newline, once the header is in
---@field done fun(answered: boolean, object: differ.git.Object|nil)

---@class differ.git.CatFile
---@field obj table -- vim.system's handle
---@field nul boolean -- started with -z
---@field parts string[] -- stdout not yet matched to a waiter
---@field have integer -- bytes in parts
---@field waiting differ.git.CatFileWaiter[]
---@field timer any -- a uv timer
---@field dead boolean

---@type table<string, differ.git.CatFile>
local procs = {}
---@type table<string, integer>
local holds = {}

local nul_supported ---@type boolean|nil

-- `-z` (NUL-terminated names) arrived in git 2.38
---@param root string
---@return boolean
local function supports_nul(root)
    if nul_supported == nil then
        local out = exec.git({ "--version" }, root)
        local major, minor = (out or ""):match("(%d+)%.(%d+)")
        major, minor = tonumber(major), tonumber(minor)
        nul_supported = major ~= nil and (major > 2 or (major == 2 and minor >= 38))
    end
    return nul_supported
end

---@param proc differ.git.CatFile
local function fail(proc)
    proc.dead = true
    if not proc.timer:is_closing() then
        proc.timer:close()
    end
    local waiting = proc.waiting
    proc.waiting = {}
    for _, w in ipairs(waiting) do
        w.done(false)
    end
end

---@param root string
---@param proc differ.git.CatFile
local function kill(root, proc)
    if procs[root] == proc then
        procs[root] = nil
    end
    pcall(proc.obj.kill, proc.obj, 9)
    fail(proc)
end

---@param root string
---@param proc differ.git.CatFile
local function arm(root, proc)
    proc.timer:stop()
    if proc.waiting[1] then
        proc.timer:start(M.TIMEOUT, 0, function()
            kill(root, proc)
        end)
    end
end

---@param proc differ.git.CatFile
---@return string
local function flatten(proc)
    local s = table.concat(proc.parts)
    proc.parts = { s }
    return s
end

---@param proc differ.git.CatFile
---@param rest string
local function keep(proc, rest)
    proc.parts, proc.have = { rest }, #rest
end

-- hand complete replies to their waiters, in order. false on output that fits no reply
---@param proc differ.git.CatFile
---@return boolean
local function settle(proc)
    while proc.waiting[1] do
        local w = proc.waiting[1]
        if not w.need then
            local s = flatten(proc)
            local header = s:match("^%x+ %l+ %d+\n")
            if header then
                local size = tonumber(header:match(" (%d+)\n$")) --[[@as integer]]
                w.need = #header + size + 1
            else
                -- a name can hold a newline, so the missing line is matched whole
                local answered = false
                for _, word in ipairs({ " missing\n", " ambiguous\n" }) do
                    local line = w.name .. word
                    if s:sub(1, #line) == line then
                        table.remove(proc.waiting, 1)
                        keep(proc, s:sub(#line + 1))
                        w.done(true, nil)
                        answered = true
                        break
                    end
                    if line:sub(1, #s) == s then
                        return true -- the rest of the line hasn't arrived
                    end
                end
                if not answered then
                    return not s:find("\n", 1, true)
                end
            end
        end
        if w.need then
            if proc.have < w.need then
                return true
            end
            local s = flatten(proc)
            local sha, kind, size = s:match("^(%x+) (%l+) (%d+)\n")
            local start = #sha + #kind + #size + 4
            table.remove(proc.waiting, 1)
            keep(proc, s:sub(w.need + 1))
            w.done(true, { sha = sha, kind = kind, text = s:sub(start, w.need - 1) })
        end
    end
    return proc.have == 0
end

---@param root string
---@return differ.git.CatFile|nil
local function start(root)
    local nul = supports_nul(root)
    local cmd = vim.list_extend({}, exec.GIT)
    vim.list_extend(cmd, { "cat-file", "--batch" })
    if nul then
        cmd[#cmd + 1] = "-z"
    end
    local proc ---@type differ.git.CatFile
    local ok, obj = pcall(vim.system, cmd, {
        cwd = root,
        stdin = true,
        stderr = false, -- an ambiguous name writes hint lines for the life of the process
        stdout = function(_, data)
            if not data or proc.dead then
                return
            end
            proc.parts[#proc.parts + 1] = data
            proc.have = proc.have + #data
            if not settle(proc) then
                return kill(root, proc)
            end
            arm(root, proc)
        end,
    }, function()
        if procs[root] == proc then
            procs[root] = nil
        end
        fail(proc)
    end)
    if not ok then
        return nil
    end
    proc = {
        obj = obj,
        nul = nul,
        parts = {},
        have = 0,
        waiting = {},
        timer = assert(vim.uv.new_timer()),
        dead = false,
    }
    return proc
end

-- queue a read of `name` on `root`'s process, starting one when there's none.
-- `done` runs from a libuv callback
---@param root string
---@param name string
---@param done fun(answered: boolean, object: differ.git.Object|nil)
---@return boolean queued
local function request(root, name, done)
    local proc = procs[root] or start(root)
    if not proc then
        return false
    end
    procs[root] = proc
    local ok = pcall(proc.obj.write, proc.obj, name .. (proc.nul and "\0" or "\n"))
    if not ok then
        kill(root, proc)
        return false
    end
    proc.waiting[#proc.waiting + 1] = { name = name, done = done }
    if #proc.waiting == 1 then
        arm(root, proc)
    end
    return true
end

-- the object `name` resolves to on `root`. `answered` is false when the process can't
-- say (no session holds the root, an index name, a dead or timed-out process), and the
-- caller reads it another way; answered with a nil object means git found nothing.
-- yields inside exec.async, blocks anywhere else
---@param root string
---@param name string
---@return boolean answered, differ.git.Object|nil object
function M.read(root, name)
    -- the process reads the index once, at startup
    if not holds[root] or name:sub(1, 1) == ":" then
        return false
    end
    -- without -z a name ends at a newline, and git drops a CR before it
    if not supports_nul(root) and (name:find("\n", 1, true) or name:sub(-1) == "\r") then
        return false
    end
    if exec.in_async() then
        return exec.await(function(resume)
            if not request(root, name, resume) then
                resume(false)
            end
        end)
    end
    local result ---@type { answered: boolean, object: differ.git.Object|nil }|nil
    local queued = request(root, name, function(answered, object)
        result = { answered = answered, object = object }
    end)
    if not queued then
        return false
    end
    -- fast-only: nothing scheduled runs while this read blocks. the process timer fails
    -- it, so the wait itself only needs a backstop
    vim.wait(2 * M.TIMEOUT, function()
        return result ~= nil
    end, nil, true)
    if not result then
        return false
    end
    return result.answered, result.object
end

---@param root string
local function release(root)
    local n = (holds[root] or 0) - 1
    if n > 0 then
        holds[root] = n
        return
    end
    holds[root] = nil
    local proc = procs[root]
    if proc then
        procs[root] = nil
        pcall(proc.obj.write, proc.obj, nil) -- EOF: cat-file exits on its own
        fail(proc)
    end
end

-- serve reads on `root` from its process until the returned release runs; the last
-- release stops the process, and a second call to the same one does nothing
---@param root string
---@return fun() release
function M.hold(root)
    holds[root] = (holds[root] or 0) + 1
    local released = false
    return function()
        if released then
            return
        end
        released = true
        release(root)
    end
end

-- the live process on `root`, for specs
---@param root string
---@return table|nil
function M.process(root)
    local proc = procs[root]
    return proc and proc.obj or nil
end

return M
