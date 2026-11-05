-- exec.async / exec.submit: git yields inside a runner, tasks on one root run in
-- order, and a supersede drops results submitted before it
local exec = require("differ.git.exec")
local helpers = require("test.nvim.git.helpers")

---@param pred fun(): boolean
local function wait_for(pred)
    assert.is_true(vim.wait(5000, pred, 5), "timed out waiting")
end

-- a task that yields until `open()` is called, logging its start and finish
local function gate(log, name)
    local open
    local task = function()
        log[#log + 1] = name .. ":start"
        exec.await(function(resume)
            open = resume
        end)
        log[#log + 1] = name .. ":end"
        return name
    end
    return task,
        function()
            wait_for(function()
                return open ~= nil
            end)
            open()
        end
end

describe("exec.async", function()
    it("yields on git and hands on_done its result on a later tick", function()
        local root = helpers.fresh_repo()
        local got, returned
        exec.async(function()
            return exec.git({ "rev-parse", "--show-toplevel" }, root)
        end, function(...)
            got = vim.F.pack_len(...)
        end)
        returned = true
        assert.is_nil(got)
        wait_for(function()
            return got ~= nil
        end)
        assert.is_true(returned)
        assert.is_true(got[1])
        assert.are.equal(vim.uv.fs_realpath(root), vim.trim(got[2]))
    end)

    it("keeps git blocking outside a runner, in a coroutine of its own too", function()
        local root = helpers.fresh_repo()
        local co = coroutine.create(function()
            return exec.git({ "rev-parse", "HEAD" }, root)
        end)
        local ok, out = coroutine.resume(co)
        assert.is_true(ok)
        assert.are.equal("dead", coroutine.status(co))
        assert.is_truthy(out:match("^%x+"))
    end)

    it("returns git's failure as nil + stderr", function()
        local root = helpers.fresh_repo()
        local got
        exec.async(function()
            return exec.git({ "rev-parse", "--verify", "no-such-rev" }, root)
        end, function(...)
            got = vim.F.pack_len(...)
        end)
        wait_for(function()
            return got ~= nil
        end)
        assert.is_true(got[1])
        assert.is_nil(got[2])
        assert.is_truthy(got[3]:match("no%-such%-rev") or got[3]:match("fatal"))
    end)

    it("returns a never-started git as nil + the spawn error", function()
        local got
        exec.async(function()
            return exec.git({ "status" }, "/no/such/dir/for/differ")
        end, function(...)
            got = vim.F.pack_len(...)
        end)
        wait_for(function()
            return got ~= nil
        end)
        assert.is_true(got[1])
        assert.is_nil(got[2])
        assert.is_truthy(got[3]:match("ENOENT"))
    end)

    -- git kills its alias child on TERM; a backgrounded grandchild escapes that and
    -- keeps the pipes open, so only the guard timer ends the wait
    for _, case in ipairs({
        { what = "a git killed at its timeout", alias = "!sleep 2" },
        { what = "a git whose grandchild holds the pipes", alias = "!(sleep 2 &); sleep 2" },
    }) do
        it("times out " .. case.what, function()
            local root = helpers.fresh_repo()
            local got
            local started = vim.uv.hrtime()
            exec.async(function()
                return exec.git(
                    { "-c", "alias.hang=" .. case.alias, "hang" },
                    root,
                    { timeout = 200 }
                )
            end, function(...)
                got = vim.F.pack_len(...)
            end)
            wait_for(function()
                return got ~= nil
            end)
            assert.is_true((vim.uv.hrtime() - started) / 1e9 < 2)
            assert.is_nil(got[2])
            assert.is_truthy(got[3]:match("timed out"))
        end)
    end

    it("hands a raised error to on_done as false + the error", function()
        local got
        exec.async(function()
            error("boom", 0)
        end, function(...)
            got = vim.F.pack_len(...)
        end)
        wait_for(function()
            return got ~= nil
        end)
        assert.is_false(got[1])
        assert.are.equal("boom", got[2])
    end)

    it("refuses await outside a runner", function()
        assert.has_error(function()
            exec.await(function() end)
        end)
    end)
end)

describe("exec.submit", function()
    it("runs one task at a time per root, in submit order", function()
        local log, done = {}, {}
        local a, open_a = gate(log, "a")
        local b, open_b = gate(log, "b")
        exec.submit("/r/order", a, function(_, v)
            done[#done + 1] = v
        end)
        exec.submit("/r/order", b, function(_, v)
            done[#done + 1] = v
        end)
        open_a()
        open_b()
        wait_for(function()
            return #done == 2
        end)
        assert.are.same({ "a:start", "a:end", "b:start", "b:end" }, log)
        assert.are.same({ "a", "b" }, done)
    end)

    it("runs different roots side by side", function()
        local log, done = {}, {}
        local a, open_a = gate(log, "a")
        local b, open_b = gate(log, "b")
        exec.submit("/r/one", a, function(_, v)
            done[#done + 1] = v
        end)
        exec.submit("/r/two", b, function(_, v)
            done[#done + 1] = v
        end)
        open_b()
        wait_for(function()
            return #done == 1
        end)
        open_a()
        wait_for(function()
            return #done == 2
        end)
        assert.are.same({ "b", "a" }, done)
    end)

    it("drops a superseded result and skips a superseded queued task", function()
        local log, done = {}, {}
        local a, open_a = gate(log, "a")
        local b = gate(log, "b")
        local c, open_c = gate(log, "c")
        exec.submit("/r/stale", a, function(_, v)
            done[#done + 1] = v
        end)
        exec.submit("/r/stale", b, function(_, v)
            done[#done + 1] = v
        end)
        exec.supersede("/r/stale")
        exec.submit("/r/stale", c, function(_, v)
            done[#done + 1] = v
        end)
        open_a()
        open_c()
        wait_for(function()
            return #done == 1
        end)
        assert.are.same({ "c" }, done)
        assert.are.same({ "a:start", "a:end", "c:start", "c:end" }, log)
    end)

    it("keeps draining after a task or an on_done raises", function()
        local done = {}
        exec.submit("/r/err", function()
            error("task", 0)
        end, function(ok, err)
            done[#done + 1] = { ok, err }
            error("on_done", 0)
        end)
        exec.submit("/r/err", function()
            return "next"
        end, function(ok, v)
            done[#done + 1] = { ok, v }
        end)
        -- the on_done error surfaces from a scheduled callback; nvim reports it
        wait_for(function()
            return #done == 2
        end)
        assert.are.same({ { false, "task" }, { true, "next" } }, done)
    end)
end)
