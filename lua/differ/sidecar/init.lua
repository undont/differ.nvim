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
-- the wall-clock a crash-looping binary costs before the client gives up
local RESTART_BUDGET_MS = (function()
    local total = 0
    for i = 1, MAX_ATTEMPTS do
        total = total + math.min(MAX_BACKOFF_MS, BASE_BACKOFF_MS * 2 ^ (i - 1))
    end
    return total
end)()
-- ceiling on one request. the Go client's 30s timeout is per HTTP call, so a handler
-- that paginates (or never returns) outlives it; generous enough for a large PR's file
-- walk, since firing early would fail a request that was going to succeed
local REQUEST_TIMEOUT_MS = 60000
-- the binary's structured logs land on stderr, kept per process and capped so a chatty
-- log level can't grow without limit across a session measured in days. without them
-- the only account of a crash is an exit code
local STDERR_MAX = 200
-- how much of that log gets folded onto an error, in bytes rather than lines: slog
-- renders a multi-line value (the panic stack dispatch logs) as one long quoted line,
-- which costs the same screen height once wrapped as the same bytes spread over many
-- lines, so counting lines would bound the wrong thing
local STDERR_BYTES = 2000

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
---@field stderr_buf string    -- unterminated tail of the stderr stream
---@field stderr_log string[]  -- the last STDERR_MAX lines this process wrote
---@field attempts integer     -- consecutive restart attempts (backoff)
---@field binary string|nil    -- version reported by hello

---@type differ.sidecar.Client|nil
local client = nil

-- the last unintentional death, kept at module scope so it outlives the client the
-- crash took with it: after the restart budget runs out there is no client left to
-- ask, and that is exactly when someone goes looking
---@type { code: integer, stderr: string[] }|nil
local last_exit = nil

-- forward declarations (mutual recursion across start/exit/restart)
local start, on_stdout, on_stderr, on_exit, handshake, schedule_restart, flush_queue, do_request

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
        stderr_buf = "",
        stderr_log = {},
        attempts = 0,
        binary = nil,
    }
end

-- append, dropping the oldest once at the cap. a shift per line past the cap, which at
-- a couple of lines per user action does not earn a cleverer structure
local function push_line(lines, line)
    lines[#lines + 1] = line
    if #lines > STDERR_MAX then
        table.remove(lines, 1)
    end
end

-- fold the sidecar's own last words onto an error. the Go logs are the only account of
-- why it died, so an error that omits them leaves an exit code and nothing else.
local function with_tail(msg, lines)
    if not lines or #lines == 0 then
        return msg
    end
    local out, size = {}, 0
    for i = #lines, 1, -1 do
        local line = lines[i]
        if size + #line > STDERR_BYTES then
            if #out == 0 then
                -- one line can outrun the whole budget on its own (a stack is one
                -- line); keep its head, where go puts the innermost frames
                out[1] = line:sub(1, STDERR_BYTES) .. " …"
            end
            break
        end
        size = size + #line + 1
        table.insert(out, 1, line)
    end
    return msg .. "\n" .. table.concat(out, "\n")
end

-- split `buf` on newlines, handing each complete line to `fn`; returns the
-- unterminated remainder for the next chunk. both streams arrive in arbitrary
-- chunks, so neither can assume a chunk boundary is a line boundary
local function consume_lines(buf, fn)
    while true do
        local nl = buf:find("\n", 1, true)
        if not nl then
            return buf
        end
        local line = buf:sub(1, nl - 1)
        buf = buf:sub(nl + 1)
        if line ~= "" then
            fn(line)
        end
    end
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

-- false when there is no process to write to
local function send(obj)
    if not (client and client.proc) then
        return false
    end
    ---@diagnostic disable-next-line: undefined-field
    client.proc:write(vim.json.encode(obj) .. "\n")
    return true
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

local function teardown(err)
    if not client then
        return
    end
    client.stopping = true
    client.ready = false
    client.running = false
    if client.proc then
        pcall(function()
            -- the binary traps SIGTERM only to cancel a context its blocking stdin scan
            -- never observes, so EOF is what ends it and the signal is a backstop
            ---@diagnostic disable-next-line: undefined-field
            client.proc:write(nil)
            ---@diagnostic disable-next-line: undefined-field
            client.proc:kill(15)
        end)
    end
    fail_all(err)
    client = nil -- supersedes the dying process's callbacks; see `owned` in start()
end

function do_request(method, params, cb)
    local id = client.next_id
    client.next_id = id + 1
    -- the write is synchronous and a response arrives on a later loop turn, so awaiting
    -- after it cannot miss one. back on the queue if the process went: a restart is
    -- already scheduled, and the queue is what survives it
    if not send({ id = id, method = method, params = params or vim.empty_dict() }) then
        table.insert(client.queue, { method = method, params = params, cb = cb })
        return
    end
    await(id, cb)
end

function flush_queue()
    local q = client.queue
    client.queue = {}
    for _, item in ipairs(q) do
        do_request(item.method, item.params, item.cb)
    end
end

-- the next request() spins a fresh client, so a rebuilt binary heals a mismatch
local function handshake_failed(why)
    vim.schedule(function()
        vim.notify("differ: sidecar " .. why, vim.log.levels.ERROR)
    end)
    teardown(mkerr("internal", why))
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
            -- a death before hello is the supervisor's: on_exit already scheduled the
            -- restart, and the queue survives to be flushed after it
            if not client.running then
                return
            end
            handshake_failed("handshake failed: " .. (err.message or err.code))
            return
        end
        if type(result) ~= "table" or result.protocol ~= PROTOCOL then
            handshake_failed(
                "protocol mismatch — rebuild your sidecar (run `make go-build` or `go install`)"
            )
            return
        end
        if not client.running then
            return -- it answered and died in the same turn; the restart owns the queue
        end
        client.ready = true
        client.attempts = 0
        client.binary = result.binary
        flush_queue()
    end)
    send({ id = id, method = "hello", params = { client = "differ.nvim", protocol = PROTOCOL } })
end

-- an id-less frame is a v1 no-op (the seam for phase-6 server→client
-- notifications); only a response matching a pending id is dispatched.
local function dispatch_line(line)
    local ok, msg = pcall(vim.json.decode, line)
    if not (ok and type(msg) == "table" and msg.id ~= nil and client.pending[msg.id]) then
        return
    end
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

-- libuv fast context: accumulate stdout and dispatch each complete line. only
-- vim.json.decode / vim.schedule are touched here (both fast-context safe).
function on_stdout(err, data)
    if err or not data or not client then
        return
    end
    client.stdout_buf = consume_lines(client.stdout_buf .. data, dispatch_line)
end

-- libuv fast context, as on_stdout: string and table work only. a nil `data` is
-- EOF, which leaves any unterminated tail for on_exit to flush
function on_stderr(err, data)
    if err or not data or not client then
        return
    end
    local log = client.stderr_log
    client.stderr_buf = consume_lines(client.stderr_buf .. data, function(line)
        push_line(log, line)
    end)
end

function on_exit(obj)
    if not client then
        return
    end
    client.running = false
    client.ready = false
    client.proc = nil
    if client.stderr_buf ~= "" then
        push_line(client.stderr_log, client.stderr_buf) -- a last line with no newline
        client.stderr_buf = ""
    end
    local lines = client.stderr_log
    last_exit = { code = obj.code, stderr = lines }
    fail_pending(
        mkerr("internal", with_tail("sidecar exited (code " .. tostring(obj.code) .. ")", lines))
    )
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
        -- a request made before the handshake sits in the queue, so no per-exit failure
        -- reaches it and this is the only error a caller sees
        local why = "sidecar unavailable"
        if last_exit then
            why = ("sidecar unavailable after %d restarts (last exit code %d)"):format(
                MAX_ATTEMPTS,
                last_exit.code
            )
        end
        fail_all(mkerr("internal", with_tail(why, last_exit and last_exit.stderr)))
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
    client.stderr_buf = ""
    client.stderr_log = {} -- per process: the previous one's lines live on in last_exit
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
        stderr = owned(on_stderr),
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
        -- nvim closing our stdin on teardown would end it too, but only as a side effect
        -- of the pipe going; this is the same clean stop a `:Differ sidecar stop` makes
        vim.api.nvim_create_autocmd("VimLeavePre", {
            group = vim.api.nvim_create_augroup("differ.sidecar", { clear = true }),
            callback = function()
                M.stop()
            end,
        })
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

-- the handshake result. auth and auth_message are absent from a sidecar built before
-- they were added, which reads as unknown rather than as "no token"
---@class differ.sidecar.Hello
---@field protocol integer
---@field binary string
---@field auth string|nil          -- "ok" | "gh_missing" | "auth"
---@field auth_message string|nil  -- what to do about a non-ok auth

-- prove the round trip without touching GitHub: an explicit hello. drives the
-- :Differ sidecar smoke check and the :checkhealth sidecar section.
---@param cb fun(err: table|nil, info: differ.sidecar.Hello|nil)
function M.ping(cb)
    M.request("hello", { client = "differ.nvim", protocol = PROTOCOL }, cb)
end

-- intentional shutdown.
function M.stop()
    teardown(mkerr("internal", "sidecar stopped"))
end

-- a caller waiting on a request has to outlast this, or it reports a timeout on a
-- client that is mid-recovery
---@return integer
function M.restart_budget_ms()
    return RESTART_BUDGET_MS
end

-- whether the handshake has completed and requests flow without queueing.
function M.is_ready()
    return client ~= nil and client.ready
end

-- the binary a request would spawn, by the same resolution order, or nil when not
-- reachable. used by :checkhealth, to report the path
---@return string|nil
function M.binary_path()
    return resolve_bin()
end

-- what the running sidecar has said, oldest first, back to the cap. empty
-- when nothing is running or the binary has been quiet, which at the default log
-- level it is. callers cut it to their own length with `with_tail`
---@return string[]
function M.stderr_lines()
    if not client then
        return {}
    end
    return vim.list_slice(client.stderr_log, 1)
end

-- the last crash: its exit code and the stderr it left behind. nil when nothing has
-- died unexpectedly this session (an intentional stop is not recorded)
---@return { code: integer, stderr: string[] }|nil
function M.last_exit()
    return last_exit
end

-- append a capped tail of `lines` to `msg`, as the client's own errors do. exported so
-- callers surfacing a stored crash cut it to the same length rather than their own
---@param msg string
---@param lines string[]|nil
---@return string
function M.with_tail(msg, lines)
    return with_tail(msg, lines)
end

return M
