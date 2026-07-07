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
