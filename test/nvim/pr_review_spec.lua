-- runs under headless nvim: the pending-review draft lifecycle. stubs pr.client (the
-- one seam review.lua reaches the sidecar through), so a fake session with a fake panel
-- is enough to drive start / reattach without a real PR session
local client = require("differ.pr.client")
local review = require("differ.pr.review")

-- swap the client calls out for the duration of a test, and make `live` the session the
-- guards see. `calls` records which client methods fired; the fake panel records the
-- path reattach landed on
---@param pending table|nil  -- what get_pending_review answers
---@param live table|nil  -- the session pr.current_session() reports, nil for none
local function stub(pending, live)
    local calls = {}
    local pr = require("differ.pr")
    local real = {
        start_review = client.start_review,
        get_pending_review = client.get_pending_review,
        current_session = pr.current_session,
    }
    client.start_review = function(_pr, cb)
        calls[#calls + 1] = "start_review"
        cb(nil, { review_id = "fresh" })
    end
    client.get_pending_review = function(_pr, cb)
        calls[#calls + 1] = "get_pending_review"
        cb(nil, pending)
    end
    pr.current_session = function()
        return live
    end
    return calls,
        function()
            client.start_review = real.start_review
            client.get_pending_review = real.get_pending_review
            pr.current_session = real.current_session
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
        -- no view: the draft lifecycle keys off session identity, so it works before
        -- the diff's async blob fetch has built one
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
        local s = fake_session(nil, FILES)
        local calls, restore = stub({}, s)
        review.start(s)
        assert.are.same({ "start_review" }, calls)
        assert.are.equal("fresh", s.review_id)
        restore()
    end)

    it("reattaches instead of refusing when a draft is already in progress", function()
        local s = fake_session("existing", FILES)
        local calls, restore = stub({ review_id = "existing" }, s)
        review.start(s)
        -- the point: no second start_review, and it doesn't dead-end on a notice
        assert.are.same({ "get_pending_review" }, calls)
        restore()
    end)

    -- the diff's blob fetch and start_review race, and either can land first
    it("adopts the draft when the response beats the diff window", function()
        local s = fake_session(nil, FILES)
        local _, restore = stub({}, s)
        assert.is_nil(s.view) -- show_file hasn't built one yet
        _G.notifs = {}
        review.start(s)
        assert.are.equal("fresh", s.review_id)
        assert.are.equal(
            "differ: review started - comments are drafts until you submit",
            _G.notifs[#_G.notifs].msg
        )
        restore()
    end)

    it("drops the draft when the session was replaced mid-flight", function()
        local s = fake_session(nil, FILES)
        local _, restore = stub({}, fake_session(nil, FILES)) -- a different live session
        review.start(s)
        assert.is_nil(s.review_id) -- the superseded session keeps no draft id
        restore()
    end)
end)

describe("review.reattach", function()
    it("lands on the first file still unviewed", function()
        local s = fake_session("existing", FILES)
        local _, restore = stub({ review_id = "existing" }, s)
        review.reattach(s)
        assert.are.same({ "c.lua" }, s.panel.landed)
        restore()
    end)

    it("leaves the cursor alone when the caller already positioned", function()
        local s = fake_session("existing", FILES)
        local _, restore = stub({ review_id = "existing" }, s)
        review.reattach(s, { jump = false })
        assert.are.same({}, s.panel.landed) -- the overview's thread anchor stands
        restore()
    end)

    it("stays put when every file has been viewed", function()
        local s = fake_session("existing", {
            { path = "a.lua", viewed = true },
            { path = "b.lua", viewed = true },
        })
        local _, restore = stub({ review_id = "existing" }, s)
        review.reattach(s)
        assert.are.same({}, s.panel.landed)
        restore()
    end)

    it("notifies and lands nowhere when the PR has no draft", function()
        local s = fake_session(nil, FILES)
        local _, restore = stub({ review_id = nil }, s)
        _G.notifs = {}
        review.reattach(s)
        assert.are.equal(
            "differ: no pending review to resume on this PR",
            _G.notifs[#_G.notifs].msg
        )
        assert.are.same({}, s.panel.landed)
        restore()
    end)

    -- resume's whole purpose is re-entering draft mode, so it can't wait on the diff
    it("reattaches with no diff window built yet", function()
        local s = fake_session(nil, FILES)
        local _, restore = stub({ review_id = "existing" }, s)
        review.reattach(s)
        assert.are.equal("existing", s.review_id)
        assert.are.same({ "c.lua" }, s.panel.landed)
        restore()
    end)
end)
