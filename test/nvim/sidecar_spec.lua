-- runs under headless nvim: drives the real differ-sidecar binary (bin/) over the
-- live stdio protocol, so it doubles as the client + handshake smoke test. `make
-- lua-test-nvim` builds it first; a direct busted run without it fails on the spot
-- rather than as a 5s timeout per test
local sidecar = require("differ.sidecar")

require("differ").setup({})

-- the binary the client would resolve
local function has_binary()
    local root = vim.fn.getcwd()
    return vim.fn.executable(root .. "/bin/differ-sidecar") == 1
end

-- live sidecar processes *this nvim spawned*, so the lifecycle tests can assert on what
-- is actually running rather than on client state alone. matched by executable name
-- (-x), not command line (-f): the client resolves the binary relative or absolute
-- depending on the rtp, and a -f match also counts any unrelated process whose arguments
-- merely mention the path, an editor, a grep, or the very shell that launched the suite.
-- scoped to our own children (-P), since the counts here are absolute: a differ session
-- open in another editor, or a second suite running alongside, is a sidecar by the same
-- name and would otherwise be counted as ours
local function running_sidecars()
    local out = vim.fn.system({
        "pgrep",
        "-P",
        tostring(vim.uv.os_getpid()),
        "-x",
        "differ-sidecar",
    })
    local n = 0
    for _ in out:gmatch("%d+") do
        n = n + 1
    end
    return n
end

-- the pid of the sidecar this nvim spawned, scoped as running_sidecars is
local function sidecar_pid()
    local out = vim.fn.system({
        "pgrep",
        "-P",
        tostring(vim.uv.os_getpid()),
        "-x",
        "differ-sidecar",
    })
    return tonumber(out:match("%d+"))
end

-- a vim.uv.new_timer stand-in whose timers fire after `ms` whatever duration they are
-- started with. a table rather than the handle itself, since a uv handle is userdata and
-- takes no field assignment; it forwards the four methods the client uses
local function clamped_timers(ms, real)
    return function()
        local timer = real()
        return {
            start = function(_, _, repeat_ms, cb)
                return timer:start(ms, repeat_ms, cb)
            end,
            stop = function()
                return timer:stop()
            end,
            close = function()
                return timer:close()
            end,
            is_closing = function()
                return timer:is_closing()
            end,
        }
    end
end

-- run one request synchronously by pumping the event loop until the callback fires.
local function call(method, params)
    local done, gerr, gres = false, nil, nil
    sidecar.request(method, params, function(err, res)
        gerr, gres, done = err, res, true
    end)
    assert.is_true(
        vim.wait(5000, function()
            return done
        end),
        "request timed out: " .. method
    )
    return gerr, gres
end

describe("sidecar client", function()
    assert(has_binary(), "bin/differ-sidecar not built (run `make go-build`)")

    after_each(function()
        sidecar.stop()
        vim.wait(100)
    end)

    it("completes the hello handshake and reports the binary", function()
        local done, gerr, ginfo = false, nil, nil
        sidecar.ping(function(err, info)
            gerr, ginfo, done = err, info, true
        end)
        assert.is_true(vim.wait(5000, function()
            return done
        end))
        assert.is_nil(gerr)
        assert.are.equal(1, ginfo.protocol)
        assert.is_string(ginfo.binary)
        assert.is_true(sidecar.is_ready())
    end)

    it("queues requests issued before the handshake and flushes them in order", function()
        -- a fresh client: stop first so the next request starts cold and queues.
        sidecar.stop()
        vim.wait(100)
        local err, res = call("cache_clear", nil)
        assert.is_nil(err)
        assert.are.same(vim.empty_dict(), res)
    end)

    it("leaves no process behind after stop", function()
        local err = call("cache_clear", nil)
        assert.is_nil(err)
        assert.are.equal(1, running_sidecars())
        sidecar.stop()
        -- EOF on stdin is what ends it; the binary traps SIGTERM only to cancel a
        -- context its blocking stdin scan never observes, so a signal alone would
        -- leave this at 1 forever
        assert.is_true(
            vim.wait(3000, function()
                return running_sidecars() == 0
            end),
            "sidecar still running after stop"
        )
        assert.is_false(sidecar.is_ready())
    end)

    it("does not orphan a process when a request lands in the same tick as stop", function()
        -- stop() used to leave the client in place, so an immediate request started a
        -- second process while the first was still dying; that first process's exit
        -- callback then cleared the live proc handle, orphaning it
        local err = call("cache_clear", nil)
        assert.is_nil(err)
        sidecar.stop()
        local err2 = call("cache_clear", nil) -- same tick as the stop
        assert.is_nil(err2)
        assert.is_true(
            vim.wait(3000, function()
                return running_sidecars() == 1
            end),
            "expected exactly one sidecar, found " .. running_sidecars()
        )
    end)

    it("maps an unknown method to a bad_request error envelope", function()
        local err, res = call("does_not_exist", nil)
        assert.is_nil(res)
        assert.are.equal("bad_request", err.code)
    end)

    it("rejects a malformed request before the handshake clears it", function()
        -- get_pr without a number is validated server-side as bad_request.
        local err = call("get_pr", { owner = "o", repo = "r" })
        assert.are.equal("bad_request", err.code)
    end)

    it("rejects a request the sidecar never answers", function()
        assert.is_nil(call("cache_clear", nil))
        local pid = sidecar_pid()
        assert.is_number(pid)

        -- SIGSTOP leaves the process alive and connected but completing no read, which is
        -- the handler-that-never-returns condition without a stub binary. the write still
        -- lands: the pipe buffers it
        assert.are.equal(0, vim.uv.kill(pid, "sigstop"))

        -- the real ceiling is 60s, so the timer is clamped where it is made. the client is
        -- ready by now, so the request arms its timer inside this call and the global is
        -- put back before anything waits on it
        local done, gerr = false, nil
        local real_new_timer = vim.uv.new_timer
        vim.uv.new_timer = clamped_timers(200, real_new_timer)
        sidecar.request("cache_clear", nil, function(err)
            gerr, done = err, true
        end)
        vim.uv.new_timer = real_new_timer

        local fired = vim.wait(3000, function()
            return done
        end)
        -- let it run again so the teardown can end it the way it always does
        vim.uv.kill(pid, "sigcont")

        assert.is_true(fired, "the pending request was never rejected")
        assert.are.equal("network", gerr.code)
        assert.are.equal("the sidecar did not answer in time", gerr.message)
    end)
end)
