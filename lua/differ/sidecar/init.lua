-- the sidecar client: one supervised differ-sidecar process per nvim
-- instance, speaking newline-delimited JSON over stdio. request(method, params, cb)
-- calls cb(err, result) where err is { code, message, retry_after? } (mirroring the
-- wire envelope) or nil on success. the hello handshake gates every other request;
-- on a crash, in-flight requests fail with code "internal" and the process restarts
-- with backoff. v1 has no server-initiated frames, so an id-less line is ignored
-- with a seam left for the phase-6 notification path.

local PROTOCOL = 1
local BASE_BACKOFF_MS = 200
local MAX_BACKOFF_MS = 8000
local MAX_ATTEMPTS = 5
-- ceiling on one request. the Go client's 30s timeout is per HTTP call, so a handler
-- that paginates (or never returns) outlives it; generous enough for a large PR's file
-- walk, since firing early would fail a request that was going to succeed
local REQUEST_TIMEOUT_MS = 60000

local M = {}

---@class differ.sidecar.Client
---@diagnostic disable-next-line: undefined-doc-name
---@field proc vim.SystemObj|nil
---@field running boolean
---@field ready boolean        -- hello handshake completed
---@field stopping boolean     -- intentional stop; suppress restart
---@field next_id integer
---@field pending table<integer, { cb: fun(err: table|nil, result: any), timer: any }>
---@field queue { method: string, params: any, cb: fun(err: table|nil, result: any) }[]
---@field stdout_buf string
---@field attempts integer     -- consecutive restart attempts (backoff)
---@field binary string|nil    -- version reported by hello

---@type differ.sidecar.Client|nil
local client = nil

-- forward declarations (mutual recursion across start/exit/restart)
local start, on_stdout, on_exit, handshake, schedule_restart, flush_queue, do_request

local function mkerr(code, message)
    return { code = code, message = message }
end

local function new_client()
    return {
        proc = nil,
        running = false,
        ready = false,
        stopping = false,
        next_id = 1,
        pending = {},
        queue = {},
        stdout_buf = "",
        attempts = 0,
        binary = nil,
    }
end

-- this file is lua/differ/sidecar/init.lua, so the plugin root is three dirs up.
local function plugin_bin()
    local src = debug.getinfo(1, "S").source:sub(2)
    local root = vim.fn.fnamemodify(src, ":h:h:h:h")
    return root .. "/bin/differ-sidecar"
end

-- resolve the binary: config override, then the bundled bin/, then $PATH.
local function resolve_bin()
    local cfg = require("differ").get_config()
    if cfg.sidecar_bin and cfg.sidecar_bin ~= "" then
        return cfg.sidecar_bin
    end
    local bundled = plugin_bin()
    if vim.fn.executable(bundled) == 1 then
        return bundled
    end
    local onpath = vim.fn.exepath("differ-sidecar")
    if onpath ~= "" then
        return onpath
    end
    return nil
end

local function send(obj)
    if client and client.proc then
        ---@diagnostic disable-next-line: undefined-field
        client.proc:write(vim.json.encode(obj) .. "\n")
    end
end

-- take a pending entry off the map and disarm its timer, returning its callback for the
-- caller to run. nil when the id already went (a response racing its own timeout).
local function take(id)
    local entry = client and client.pending[id]
    if not entry then
        return nil
    end
    client.pending[id] = nil
    entry.timer:stop()
    if not entry.timer:is_closing() then
        entry.timer:close()
    end
    return entry.cb
end

-- register `cb` under `id` with a timeout, so a handler that never answers rejects the
-- caller instead of stranding it. the sidecar has no cancel frame, so a late response
-- to a timed-out id finds no pending entry and is dropped.
local function await(id, cb)
    local self = client
    local timer = vim.uv.new_timer()
    client.pending[id] = { cb = cb, timer = timer }
    timer:start(REQUEST_TIMEOUT_MS, 0, function()
        vim.schedule(function()
            if client ~= self then
                return -- this client was replaced; its pending map went with it
            end
            local fn = take(id)
            if fn then
                fn(mkerr("network", "the sidecar did not answer in time"))
            end
        end)
    end)
end

-- fail in-flight (sent, awaiting response) requests; queued-but-unsent ones are left
-- for a restart to flush after re-handshake.
local function fail_pending(err)
    local pend = client.pending
    client.pending = {}
    for _, entry in pairs(pend) do
        entry.timer:stop()
        if not entry.timer:is_closing() then
            entry.timer:close()
        end
        vim.schedule(function()
            entry.cb(err)
        end)
    end
end

-- fail everything, in-flight and queued (a terminal condition: handshake mismatch or
-- an intentional stop).
local function fail_all(err)
    fail_pending(err)
    local q = client.queue
    client.queue = {}
    for _, item in ipairs(q) do
        vim.schedule(function()
            item.cb(err)
        end)
    end
end

function do_request(method, params, cb)
    local id = client.next_id
    client.next_id = id + 1
    await(id, cb)
    send({ id = id, method = method, params = params or vim.empty_dict() })
end

function flush_queue()
    local q = client.queue
    client.queue = {}
    for _, item in ipairs(q) do
        do_request(item.method, item.params, item.cb)
    end
end

function handshake()
    local self = client
    local id = client.next_id
    client.next_id = id + 1
    await(id, function(err, result)
        if client ~= self then
            return -- this client was stopped/replaced; its handshake result is moot
        end
        if err then
            vim.schedule(function()
                vim.notify(
                    "differ: sidecar handshake failed: " .. (err.message or err.code),
                    vim.log.levels.ERROR
                )
            end)
            client.stopping = true
            fail_all(mkerr("internal", "handshake failed"))
            return
        end
        if type(result) ~= "table" or result.protocol ~= PROTOCOL then
            vim.schedule(function()
                vim.notify(
                    "differ: sidecar protocol mismatch — rebuild your sidecar (run `make go-build` or `go install`)",
                    vim.log.levels.ERROR
                )
            end)
            client.stopping = true
            fail_all(mkerr("internal", "protocol mismatch"))
            return
        end
        client.ready = true
        client.attempts = 0
        client.binary = result.binary
        flush_queue()
    end)
    send({ id = id, method = "hello", params = { client = "differ.nvim", protocol = PROTOCOL } })
end

-- libuv fast context: accumulate stdout and dispatch each complete line. only
-- vim.json.decode / vim.schedule are touched here (both fast-context safe).
function on_stdout(err, data)
    if err or not data or not client then
        return
    end
    client.stdout_buf = client.stdout_buf .. data
    while true do
        local nl = client.stdout_buf:find("\n", 1, true)
        if not nl then
            break
        end
        local line = client.stdout_buf:sub(1, nl - 1)
        client.stdout_buf = client.stdout_buf:sub(nl + 1)
        -- an id-less frame is a v1 no-op (the seam for phase-6 server→client
        -- notifications); only a response matching a pending id is dispatched.
        if line ~= "" then
            local ok, msg = pcall(vim.json.decode, line)
            if ok and type(msg) == "table" and msg.id ~= nil and client.pending[msg.id] then
                local cb = take(msg.id)
                local e, result
                if msg.error then
                    e = {
                        code = msg.error.code or "internal",
                        message = msg.error.message,
                        retry_after = msg.error.retry_after,
                    }
                else
                    result = msg.result
                end
                vim.schedule(function()
                    cb(e, result)
                end)
            end
        end
    end
end

function on_exit(obj)
    if not client then
        return
    end
    client.running = false
    client.ready = false
    client.proc = nil
    fail_pending(mkerr("internal", "sidecar exited (code " .. tostring(obj.code) .. ")"))
    if client.stopping then
        client.stopping = false
        return
    end
    schedule_restart()
end

function schedule_restart()
    local self = client
    client.attempts = client.attempts + 1
    if client.attempts > MAX_ATTEMPTS then
        vim.schedule(function()
            vim.notify("differ: sidecar keeps crashing; giving up", vim.log.levels.ERROR)
        end)
        fail_all(mkerr("internal", "sidecar unavailable"))
        return
    end
    local delay = math.min(MAX_BACKOFF_MS, BASE_BACKOFF_MS * 2 ^ (client.attempts - 1))
    vim.defer_fn(function()
        -- a stop (or a replacement client) between scheduling and firing cancels the
        -- retry; without this the timer would spawn a process the current client
        -- doesn't own and can't reach
        if client ~= self or client.stopping or client.running then
            return
        end
        local ok = start()
        if not ok then
            schedule_restart()
        end
    end, delay)
end

-- start (or restart) the process and kick off the handshake. returns false + reason
-- when the binary can't be found / spawned; queued requests are preserved.
function start()
    local bin = resolve_bin()
    if not bin then
        return false, "sidecar binary not found (run `make go-build`, or set sidecar_bin)"
    end
    client.stdout_buf = ""
    client.ready = false
    -- every callback below belongs to the client that spawned this process. a stop (or
    -- a crash-restart) can leave an older process still dying while a newer one runs, and
    -- its late stdout would splice foreign frames into the live stream while its exit
    -- would clear the live proc handle out from under it. `owned` drops both
    local self = client
    local function owned(fn)
        return function(...)
            if client == self then
                return fn(...)
            end
        end
    end
    local ok, proc = pcall(vim.system, { bin }, {
        stdin = true,
        stdout = owned(on_stdout),
        stderr = function() end, -- structured logs on the binary's stderr; the client ignores them
    }, owned(on_exit))
    if not ok then
        return false, tostring(proc)
    end
    client.proc = proc
    client.running = true
    handshake()
    return true
end

-- issue a request. starts/supervises the process on demand; until the handshake
-- completes the request is queued and flushed in order.
---@param method string
---@param params table|nil
---@param cb fun(err: table|nil, result: any)|nil
function M.request(method, params, cb)
    cb = cb or function() end
    if not client then
        client = new_client()
    end
    if not client.running then
        local ok, err = start()
        if not ok then
            vim.schedule(function()
                cb(mkerr("internal", err))
            end)
            return
        end
    end
    if client.ready then
        do_request(method, params, cb)
    else
        table.insert(client.queue, { method = method, params = params, cb = cb })
    end
end

-- prove the round trip without touching GitHub: an explicit hello, returning
-- { protocol, binary }. drives the :Differ sidecar smoke check.
---@param cb fun(err: table|nil, info: table|nil)
function M.ping(cb)
    M.request("hello", { client = "differ.nvim", protocol = PROTOCOL }, cb)
end

-- intentional shutdown: close the sidecar's stdin, fail outstanding requests, and drop
-- the client so the next request() spins a fresh one.
--
-- closing stdin is what actually stops it. the binary traps SIGTERM, but only to cancel
-- a context, and its read loop is parked in a blocking scan of stdin that never observes
-- one, so a signal alone leaves the process running forever. EOF is the loop's own exit
-- condition: it drains inflight work, closes its writer and returns. the signal stays as
-- a backstop for a process wedged somewhere other than the read.
--
-- dropping the client is what suppresses the restart: the dying process's exit callback
-- finds itself superseded and no-ops, where before it would clear `proc`/`running` on
-- whatever client had since taken its place, orphaning that process and leaving the
-- client believing nothing was running
function M.stop()
    if not client then
        return
    end
    client.stopping = true
    client.ready = false
    client.running = false
    if client.proc then
        pcall(function()
            ---@diagnostic disable-next-line: undefined-field
            client.proc:write(nil) -- EOF: the read loop's clean exit
            ---@diagnostic disable-next-line: undefined-field
            client.proc:kill(15)
        end)
    end
    fail_all(mkerr("internal", "sidecar stopped"))
    client = nil
end

-- whether the handshake has completed and requests flow without queueing.
function M.is_ready()
    return client ~= nil and client.ready
end

return M
