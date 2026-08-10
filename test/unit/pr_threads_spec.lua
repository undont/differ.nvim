local threads = require("differ.pr.threads")

describe("pr.threads.side_of", function()
    it("maps github LEFT/RIGHT to the line-map column side", function()
        assert.are.equal("old", threads.side_of({ side = "LEFT" }))
        assert.are.equal("new", threads.side_of({ side = "RIGHT" }))
        assert.are.equal("new", threads.side_of({ side = nil })) -- default to the new side
    end)
end)

describe("pr.threads.anchor_row", function()
    -- from_new-style index: source line -> buffer row
    local index = { [10] = 3, [11] = 4, [20] = 9 }

    it("returns the exact derived row when the anchor is in context", function()
        assert.are.equal(4, threads.anchor_row(index, 11))
    end)

    it("degrades an out-of-context anchor to the nearest rendered line", function()
        assert.are.equal(9, threads.anchor_row(index, 19)) -- nearest 20
        assert.are.equal(4, threads.anchor_row(index, 13)) -- nearest 11
    end)

    it("breaks a distance tie toward the lower row", function()
        -- line 15 is equidistant from 11 (row 4) and 20 (row 9 via |20-15|=5 vs |11-15|=4)
        -- so use a true tie: 14 is dist 3 from 11 and 6 from 20 -> 11; check 15.5 not needed
        local idx = { [10] = 2, [20] = 8 }
        assert.are.equal(2, threads.anchor_row(idx, 15)) -- tie -> lower row
    end)

    it("returns nil when nothing is rendered on that side", function()
        assert.is_nil(threads.anchor_row({}, 5))
    end)

    -- github nulls the line once a thread's anchor leaves the diff and the wire carries
    -- 0. degrading is for a near miss, so a non-line must not be dragged to the lowest
    -- rendered row, which would stack every outdated thread on the top of the file
    it("refuses a line that isn't a real line rather than degrading it", function()
        assert.is_nil(threads.anchor_row(index, 0))
        assert.is_nil(threads.anchor_row(index, nil))
        assert.is_nil(threads.anchor_row(index, -3))
    end)
end)

describe("pr.threads.anchor_line", function()
    it("uses the current line when the thread still anchors in the diff", function()
        assert.are.equal(12, threads.anchor_line({ line = 12, original_line = 4 }))
    end)

    it("falls back to where an outdated thread was written", function()
        assert.are.equal(4, threads.anchor_line({ line = 0, original_line = 4, outdated = true }))
    end)

    it("is nil when neither line survives", function()
        assert.is_nil(threads.anchor_line({ line = 0, original_line = 0 }))
        assert.is_nil(threads.anchor_line({}))
    end)
end)

describe("pr.threads.stack_sort", function()
    it("orders same-row threads oldest first by first-comment time", function()
        local newer = { comments = { { created_at = "2026-03-02T00:00:00Z" } } }
        local older = { comments = { { created_at = "2026-01-01T00:00:00Z" } } }
        local mid = { comments = { { created_at = "2026-02-15T00:00:00Z" } } }
        local sorted = threads.stack_sort({ newer, older, mid })
        assert.are.equal(older, sorted[1])
        assert.are.equal(mid, sorted[2])
        assert.are.equal(newer, sorted[3])
    end)

    it("treats a thread with no comments as oldest (empty key)", function()
        local empty = { comments = {} }
        local has = { comments = { { created_at = "2026-01-01T00:00:00Z" } } }
        local sorted = threads.stack_sort({ has, empty })
        assert.are.equal(empty, sorted[1])
    end)
end)

describe("pr.threads.anchor_at", function()
    local session = {
        thread_anchors = {
            { key = "1:3", bufnr = 1, row = 3, threads = { "a" } },
            { key = "1:8", bufnr = 1, row = 8, threads = { "b" } },
            { key = "2:3", bufnr = 2, row = 3, threads = { "c" } },
        },
    }

    it("matches on bufnr and row together", function()
        assert.are.equal("1:3", threads.anchor_at(session, 1, 3).key)
        assert.are.equal("2:3", threads.anchor_at(session, 2, 3).key) -- same row, other column
    end)

    it("returns nil off a thread row", function()
        assert.is_nil(threads.anchor_at(session, 1, 5))
        assert.is_nil(threads.anchor_at({}, 1, 3))
    end)
end)

describe("pr.threads.next_anchor", function()
    -- rows 3, 8 on buffer 1; row 3 on buffer 2 (a split column)
    local anchors = {
        { bufnr = 1, row = 8 },
        { bufnr = 1, row = 3 },
        { bufnr = 2, row = 3 },
    }

    it("finds the nearest anchor past the cursor in the same column", function()
        assert.are.equal(8, threads.next_anchor(anchors, 1, 5, "next"))
        assert.are.equal(3, threads.next_anchor(anchors, 1, 5, "prev"))
    end)

    it("skips anchors on a different column buffer", function()
        assert.is_nil(threads.next_anchor(anchors, 2, 5, "next"))
        assert.are.equal(3, threads.next_anchor(anchors, 2, 5, "prev"))
    end)

    it("does not wrap; nil when none remain that direction", function()
        assert.is_nil(threads.next_anchor(anchors, 1, 8, "next"))
        assert.is_nil(threads.next_anchor(anchors, 1, 3, "prev"))
        assert.is_nil(threads.next_anchor({}, 1, 1, "next"))
    end)
end)
