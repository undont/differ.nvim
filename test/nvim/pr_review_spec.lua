-- runs under headless nvim: the pending-review draft lifecycle. stubs pr.client (the
-- one seam review.lua reaches the sidecar through), so a fake session with a fake panel
-- is enough to drive start / reattach without a real PR session
local client = require("differ.pr.client")
local review = require("differ.pr.review")

-- swap the client calls out for the duration of a test. `calls` records which client
-- methods fired; the fake panel records the path reattach landed on
local function stub(pending)
    local calls = {}
    local real = {
        start_review = client.start_review,
        get_pending_review = client.get_pending_review,
    }
    client.start_review = function(_pr, cb)
        calls[#calls + 1] = "start_review"
        cb(nil, { review_id = "fresh" })
    end
    client.get_pending_review = function(_pr, cb)
        calls[#calls + 1] = "get_pending_review"
        cb(nil, pending)
    end
    return calls,
        function()
            client.start_review = real.start_review
            client.get_pending_review = real.get_pending_review
        end
end

-- entries as the panel holds them; `viewed` is what next_unviewed scans
local function fake_session(review_id, entries)
    local landed = {}
    return {
        pr = { owner = "acme", repo = "widget", number = 7 },
        review_id = review_id,
        entries = entries,
        panel = {
            landed = landed,
            goto_path = function(self, path)
                self.landed[#self.landed + 1] = path
            end,
        },
        -- alive() only asks the view whether it's still open
        view = {
            is_open = function()
                return true
            end,
            columns = {},
        },
    }
end

local FILES = {
    { path = "a.lua", viewed = true },
    { path = "b.lua", viewed = true },
    { path = "c.lua", viewed = false },
    { path = "d.lua", viewed = false },
}

describe("review.start", function()
    it("starts a fresh draft when the session has none", function()
        local calls, restore = stub({})
        local s = fake_session(nil, FILES)
        review.start(s)
        assert.are.same({ "start_review" }, calls)
        assert.are.equal("fresh", s.review_id)
        restore()
    end)

    it("reattaches instead of refusing when a draft is already in progress", function()
        local calls, restore = stub({ review_id = "existing" })
        local s = fake_session("existing", FILES)
        review.start(s)
        -- the point: no second start_review, and it doesn't dead-end on a notice
        assert.are.same({ "get_pending_review" }, calls)
        restore()
    end)
end)

describe("review.reattach", function()
    it("lands on the first file still unviewed", function()
        local _, restore = stub({ review_id = "existing" })
        local s = fake_session("existing", FILES)
        review.reattach(s)
        assert.are.same({ "c.lua" }, s.panel.landed)
        restore()
    end)

    it("leaves the cursor alone when the caller already positioned", function()
        local _, restore = stub({ review_id = "existing" })
        local s = fake_session("existing", FILES)
        review.reattach(s, { jump = false })
        assert.are.same({}, s.panel.landed) -- the overview's thread anchor stands
        restore()
    end)

    it("stays put when every file has been viewed", function()
        local _, restore = stub({ review_id = "existing" })
        local s = fake_session("existing", {
            { path = "a.lua", viewed = true },
            { path = "b.lua", viewed = true },
        })
        review.reattach(s)
        assert.are.same({}, s.panel.landed)
        restore()
    end)

    it("notifies and lands nowhere when the PR has no draft", function()
        local _, restore = stub({ review_id = nil })
        local s = fake_session(nil, FILES)
        _G.notifs = {}
        review.reattach(s)
        assert.are.equal(
            "differ: no pending review to resume on this PR",
            _G.notifs[#_G.notifs].msg
        )
        assert.are.same({}, s.panel.landed)
        restore()
    end)
end)
