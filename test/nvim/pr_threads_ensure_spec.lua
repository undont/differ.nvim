-- runs under headless nvim: exercises pr.threads.ensure's in-flight coalescing and its
-- freshness clock in isolation. ensure defers to require("differ.pr").current_session() and
-- client.get_threads, so both are stubbed; the get_threads cb is captured (not fired)
-- to hold a fetch "in flight" while a second caller queues behind it

require("differ").setup({})

local threads = require("differ.pr.threads")
local client = require("differ.pr.client")
local pr = require("differ.pr")

local PR = { owner = "acme", repo = "widget", number = 7 }

describe("pr.threads.ensure (coalescing + freshness)", function()
    local restore

    after_each(function()
        if restore then
            restore()
        end
        restore = nil
    end)

    -- point current_session at `session`, capture get_threads' cb without firing it, and
    -- count requests + notify_err calls. returns a handle with a fire(err, list) to run
    -- the captured callback on demand
    local function harness(session)
        local real_cs = pr.current_session
        local real_get = client.get_threads
        local real_notify = pr.notify_err
        local sent, notified = 0, 0
        local captured = {} -- every get_threads cb, in issue order
        pr.current_session = function()
            return session
        end
        client.get_threads = function(_pr, cb)
            sent = sent + 1
            captured[#captured + 1] = cb
        end
        pr.notify_err = function()
            notified = notified + 1
        end
        restore = function()
            pr.current_session = real_cs
            client.get_threads = real_get
            pr.notify_err = real_notify
        end
        return {
            sent = function()
                return sent
            end,
            notified = function()
                return notified
            end,
            -- fire the nth fetch's callback (default the first), so a test can land an
            -- older fetch after a newer one
            fire = function(err, list, nth)
                captured[nth or 1](err, list)
            end,
        }
    end

    it("coalesces two concurrent callers into one request; each cb runs once", function()
        local session = { pr = PR, threads = nil }
        local h = harness(session)

        local n1, n2 = 0, 0
        threads.ensure(session, function()
            n1 = n1 + 1
        end)
        threads.ensure(session, function()
            n2 = n2 + 1
        end)

        assert.are.equal(1, h.sent()) -- the second caller queues behind the first fetch
        assert.are.equal(0, n1) -- nothing runs until the fetch responds
        assert.are.equal(0, n2)

        h.fire(nil, { { thread_id = "th_1", path = "a.txt", line = 2, comments = {} } })

        assert.are.equal(1, n1)
        assert.are.equal(1, n2)
        assert.are.equal(1, h.sent()) -- still one request total
        assert.are.equal(1, #session.threads) -- the list is stored on the session
        assert.is_nil(session.threads_waiters) -- the queue is drained
    end)

    -- posting a comment while the first fetch is still running: the mutation invalidates,
    -- and the refresh behind it must not join a fetch that predates the comment
    it("refuses to piggyback a fetch issued before an invalidation", function()
        local session = { pr = PR, threads = nil }
        local h = harness(session)

        local before, after = 0, 0
        threads.ensure(session, function()
            before = before + 1
        end)
        assert.are.equal(1, h.sent())

        threads.invalidate(session) -- a comment posted mid-fetch
        threads.ensure(session, function()
            after = after + 1
        end)
        assert.are.equal(2, h.sent()) -- a fresh fetch, not a queue-up

        -- the stale fetch lands first, carrying the pre-comment list
        h.fire(nil, { { thread_id = "old", path = "a.txt", line = 2, comments = {} } }, 1)
        assert.is_nil(session.threads) -- its snapshot is dropped, not stored
        assert.are.equal(0, before)
        assert.are.equal(0, after)

        h.fire(nil, {
            { thread_id = "old", path = "a.txt", line = 2, comments = {} },
            { thread_id = "new", path = "a.txt", line = 4, comments = {} },
        }, 2)
        assert.are.equal(2, #session.threads) -- the post-comment list wins
        assert.are.equal("new", session.threads[2].thread_id)
        assert.are.equal(1, before) -- the superseded fetch's waiter is still answered
        assert.are.equal(1, after)
        assert.is_nil(session.threads_waiters)
    end)

    -- without the clock a colleague's comment never appears: only the user's own
    -- mutations invalidate
    it("serves a fresh list without a fetch, and refetches a stale one", function()
        local list = { { thread_id = "th_1", path = "a.txt", line = 2, comments = {} } }
        local session = { pr = PR, threads = list, threads_at = vim.uv.now() }
        local h = harness(session)

        local ran = 0
        threads.ensure(session, function()
            ran = ran + 1
        end)
        assert.are.equal(0, h.sent()) -- inside the TTL: no network
        assert.are.equal(1, ran) -- and the cb runs straight away

        session.threads_at = vim.uv.now() - (10 * 60 * 1000) -- ten minutes old
        threads.ensure(session, function()
            ran = ran + 1
        end)
        assert.are.equal(1, h.sent()) -- past the TTL: refetched
        assert.are.equal(1, ran) -- the caller waits for the fresh list

        h.fire(nil, { { thread_id = "th_2", path = "a.txt", line = 4, comments = {} } })
        assert.are.equal(2, ran)
        assert.are.equal("th_2", session.threads[1].thread_id)
        assert.is_true(session.threads_at > vim.uv.now() - 1000) -- restamped on delivery
    end)

    -- an unstamped list must not read as fresh forever
    it("treats an unstamped list as stale", function()
        local session = { pr = PR, threads = {}, threads_at = nil }
        local h = harness(session)
        threads.ensure(session, function() end)
        assert.are.equal(1, h.sent())
    end)

    -- refresh runs on every show_file, so an unbacked-off failure means a request and a
    -- notification per ]f for as long as github is unreachable
    it("backs off after a failure: no refetch, no second notification", function()
        local session = { pr = PR, threads = nil }
        local h = harness(session)

        threads.ensure(session, function() end)
        h.fire({ message = "boom" })
        assert.are.equal(1, h.sent())
        assert.are.equal(1, h.notified())

        local seen
        threads.ensure(session, function(e)
            seen = e
        end)
        assert.are.equal(1, h.sent()) -- inside the window: no new request
        assert.are.equal(1, h.notified()) -- and no second notification
        assert.are.equal("boom", seen.message) -- the caller is still answered
    end)

    -- the run has to end on a success, or one failure silences every later one
    it("retries once the window closes, and an unrelated failure notifies again", function()
        local session = { pr = PR, threads = nil }
        local h = harness(session)

        threads.ensure(session, function() end)
        h.fire({ message = "boom" })

        session.threads_retry_at = vim.uv.now() - 1 -- the window has closed
        threads.ensure(session, function() end)
        assert.are.equal(2, h.sent())
        h.fire(nil, {}, 2) -- run ends here
        assert.is_nil(session.threads_fail)
        assert.is_nil(session.threads_retry_at)

        session.threads_at = nil -- force the next ensure to fetch
        threads.ensure(session, function() end)
        h.fire({ message = "later" }, nil, 3)
        assert.are.equal(2, h.notified()) -- a new run notifies again
    end)

    -- a comment posted while backing off is an explicit "try now"
    it("invalidate clears the backoff", function()
        local session = { pr = PR, threads = nil }
        local h = harness(session)

        threads.ensure(session, function() end)
        h.fire({ message = "boom" })

        threads.invalidate(session)
        assert.is_nil(session.threads_retry_at)
        threads.ensure(session, function() end)
        assert.are.equal(2, h.sent())
    end)

    it("on error notifies once but still runs both queued callbacks with the err", function()
        local session = { pr = PR, threads = nil }
        local h = harness(session)

        local errs = {}
        threads.ensure(session, function(e)
            errs[#errs + 1] = e
        end)
        threads.ensure(session, function(e)
            errs[#errs + 1] = e
        end)

        local err = { message = "boom" }
        h.fire(err)

        assert.are.equal(1, h.notified()) -- one notification for both waiters
        assert.are.equal(2, #errs)
        assert.are.equal(err, errs[1])
        assert.are.equal(err, errs[2])
        assert.is_nil(session.threads) -- stays nil so a later ensure retries
    end)
end)
