-- runs under headless nvim: drives the real differ-sidecar binary (bin/) over the
-- live stdio protocol, so it doubles as the client + handshake smoke test. needs
-- the binary built (make go-build); skips with a clear message when it is absent.
local sidecar = require("differ.sidecar")

require("differ").setup({})

-- the binary the client would resolve, so the suite can skip cleanly when unbuilt.
local function has_binary()
    local root = vim.fn.getcwd()
    return vim.fn.executable(root .. "/bin/differ-sidecar") == 1
end

-- live sidecar processes, so the lifecycle tests can assert on what is actually running
-- rather than on client state alone. matched on the path suffix, not an absolute path:
-- .busted sets a relative lpath, so the client resolves the binary to ./bin/differ-sidecar
-- and that relative form is what lands in the process's argv
local function running_sidecars()
    local out = vim.fn.system({ "pgrep", "-f", "bin/differ-sidecar" })
    local n = 0
    for _ in out:gmatch("%d+") do
        n = n + 1
    end
    return n
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
    if not has_binary() then
        -- one-arg pending(name) is valid busted;
        -- the type stub only declares pending(name, block)
        ---@diagnostic disable-next-line: missing-parameter
        pending("bin/differ-sidecar not built (run `make go-build`)")
        return
    end

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
end)
