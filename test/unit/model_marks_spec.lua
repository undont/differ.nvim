local marks = require("differ.model.marks")

-- classify only reads the four line-range fields, so the hunks here carry just those
local function h(old_start, old_count, new_start, new_count)
    return {
        old_start = old_start,
        old_count = old_count,
        new_start = new_start,
        new_count = new_count,
    }
end

-- each union hunk's rolled-up state
local function states(m, union)
    local out = {}
    for i, u in ipairs(union) do
        out[i] = marks.state(m, u)
    end
    return out
end

describe("union marks", function()
    it("calls every hunk unstaged when the index holds nothing", function()
        local union = { h(2, 1, 2, 1), h(9, 1, 9, 1) }
        local m = marks.classify(union, {}, { h(2, 1, 2, 1), h(9, 1, 9, 1) })
        assert.are.same({ "unstaged", "unstaged" }, states(m, union))
        assert.is_false(m.old[2])
        assert.is_false(m.new[2])
    end)

    it("calls every hunk staged when the worktree matches the index", function()
        local union = { h(2, 1, 2, 1) }
        local m = marks.classify(union, { h(2, 1, 2, 1) }, {})
        assert.are.same({ "staged" }, states(m, union))
        assert.is_true(m.old[2])
        assert.is_true(m.new[2])
    end)

    -- one file, one hunk staged and another not: each rolls up on its own, so a file
    -- half in the index still reads hunk by hunk rather than as one blurred state
    it("rolls each hunk up separately", function()
        local union = { h(1, 1, 1, 1), h(10, 1, 10, 1) }
        local m = marks.classify(union, { h(1, 1, 1, 1) }, { h(10, 1, 10, 1) })
        assert.are.same({ "staged", "unstaged" }, states(m, union))
    end)

    -- the ticket's repro: a hunk staged, then two more edits inside the region it
    -- covers, so HEAD↔worktree collapses all three into one hunk. that hunk is partial,
    -- and the per-line marks still say which line of it the index already has
    it("marks a hunk partial when later edits land inside a staged one", function()
        local union = { h(3, 3, 3, 3) }
        local m = marks.classify(union, { h(3, 1, 3, 1) }, { h(4, 2, 4, 2) })
        assert.are.same({ "partial" }, states(m, union))
        assert.are.same({ [3] = true, [4] = false, [5] = false }, m.old)
        assert.are.same({ [3] = true, [4] = false, [5] = false }, m.new)
    end)

    -- a hunk carrying content, for the checks that compare lines rather than ranges
    local function hl(old_start, old_lines, new_start, new_lines)
        return {
            old_start = old_start,
            old_count = #old_lines,
            old_lines = old_lines,
            new_start = new_start,
            new_count = #new_lines,
            new_lines = new_lines,
        }
    end

    describe("completeness", function()
        it("passes a file whose half-staged content is all on screen", function()
            assert.is_true(marks.complete({ h(3, 3, 3, 3) }, { h(3, 1, 3, 1) }, { h(4, 2, 4, 2) }))
        end)

        -- stage an edit, then put the worktree back: git still calls the file MM, both
        -- pairs hold a change, and HEAD↔worktree is empty
        it("catches an edit staged and then undone in the worktree", function()
            local ok, why = marks.complete({}, { h(2, 1, 2, 1) }, { h(2, 1, 2, 1) })
            assert.is_false(ok)
            assert.are.equal("the index differs from HEAD and the worktree matches it", why)
        end)

        it("catches unstaged content no hunk covers", function()
            local ok, why = marks.complete({ h(3, 1, 3, 1) }, {}, { h(9, 1, 9, 1) })
            assert.is_false(ok)
            assert.are.equal("unstaged content sits outside every hunk", why)
        end)

        it("catches staged content no hunk covers", function()
            local ok, why = marks.complete({ h(3, 1, 3, 1) }, { h(9, 1, 9, 1) }, {})
            assert.is_false(ok)
            assert.are.equal("staged content sits outside every hunk", why)
        end)

        -- HEAD x,y; index x,ghost,y; worktree X,y. the line the index added and the
        -- worktree then dropped reaches neither side of a HEAD↔worktree diff
        it("catches a line only the index holds", function()
            local union = { hl(1, { "x" }, 1, { "X" }) }
            local cached = { hl(1, {}, 2, { "ghost" }) }
            local unstaged = { hl(1, { "x", "ghost" }, 1, { "X" }) }
            local ok, why = marks.complete(union, cached, unstaged)
            assert.is_false(ok)
            assert.are.equal("the index holds a line neither HEAD nor the worktree has", why)
        end)

        -- the pair diffs can align repeated lines differently from the union: here the
        -- worktree drops a HEAD line the union still shows as context
        it("catches a replaced line the union shows as context", function()
            local union = { h(1, 1, 1, 1) }
            local unstaged = { h(5, 1, 4, 0) }
            local ok, why = marks.complete(union, {}, unstaged)
            assert.is_false(ok)
            assert.are.equal("a line the worktree replaced sits outside every hunk", why)
        end)

        -- stage an edit, then edit the same line again: the index's version is replaced
        -- in the worktree, so it reaches neither side of a HEAD↔worktree diff
        it("catches a staged line edited again in the worktree", function()
            local union = { hl(1, { "foo" }, 1, { "FOOD" }) }
            local cached = { hl(1, { "foo" }, 1, { "FOO" }) }
            local unstaged = { hl(1, { "FOO" }, 1, { "FOOD" }) }
            local ok, why = marks.complete(union, cached, unstaged)
            assert.is_false(ok)
            assert.are.equal("the index holds a line neither HEAD nor the worktree has", why)
        end)

        -- HEAD a,a,a,b; index a,a,c,b; worktree b,a,c,b. every range check passes, but
        -- the marks keep two HEAD a's and hold the worktree's a too: five index lines
        -- where there are four
        it("catches marks that count a line twice", function()
            local union = { hl(1, { "a", "a", "a" }, 1, { "b", "a", "c" }) }
            local cached = { hl(3, { "a" }, 3, { "c" }) }
            local unstaged = { hl(1, { "a" }, 1, { "b" }) }
            local ok, why = marks.complete(union, cached, unstaged)
            assert.is_false(ok)
            assert.are.equal("the marked lines don't add up to the index", why)
        end)

        it("allows a deletion of a line HEAD held too", function()
            local union = { hl(7, { "gone" }, 7, {}) }
            local unstaged = { hl(7, { "gone" }, 7, {}) }
            assert.is_true(marks.complete(union, {}, unstaged))
        end)
    end)

    describe("locating hidden content", function()
        local head = { "1", "2", "3", "4", "5" }

        it("names the hunk whose staged line was edited again", function()
            local union = { hl(1, { "foo" }, 1, { "FOOD" }) }
            local cached = { hl(1, { "foo" }, 1, { "FOO" }) }
            local unstaged = { hl(1, { "FOO" }, 1, { "FOOD" }) }
            local m = marks.classify(union, cached, unstaged)
            local where, outside = marks.hidden_in({ "foo" }, union, cached, m)
            assert.are.same({ 1 }, where)
            assert.is_false(outside)
        end)

        -- HEAD 1..5, line 3 staged as 3x, then 4 edited on top in the worktree
        it("names nothing when the view holds what the index does", function()
            local union = { hl(3, { "3", "4" }, 3, { "3x", "4y" }) }
            local cached = { hl(3, { "3" }, 3, { "3x" }) }
            local unstaged = { hl(4, { "4" }, 4, { "4y" }) }
            local m = marks.classify(union, cached, unstaged)
            local where, outside = marks.hidden_in(head, union, cached, m)
            assert.are.same({}, where)
            assert.is_false(outside)
        end)

        -- line 5 staged as 5x and then put back in the worktree, beside an edit at 1
        it("reports a staged change that touches no hunk", function()
            local union = { hl(1, { "1" }, 1, { "1y" }) }
            local cached = { hl(5, { "5" }, 5, { "5x" }) }
            local unstaged = { hl(1, { "1" }, 1, { "1y" }), hl(5, { "5x" }, 5, { "5" }) }
            local m = marks.classify(union, cached, unstaged)
            local where, outside = marks.hidden_in(head, union, cached, m)
            assert.are.same({}, where)
            assert.is_true(outside)
        end)
    end)

    describe("local hunks over staged content", function()
        it("names a local hunk rewriting a line the index added", function()
            local cached = { hl(1, { "foo" }, 1, { "FOO" }) }
            local unstaged = { hl(1, { "FOO" }, 1, { "FOOD" }) }
            assert.are.same({ 1 }, marks.restaged(unstaged, cached))
        end)

        it("names a local hunk putting back a line the index deleted", function()
            local cached = { hl(3, { "3" }, 2, {}) }
            local unstaged = { hl(2, {}, 3, { "3" }) }
            assert.are.same({ 1 }, marks.restaged(unstaged, cached))
        end)

        it("leaves out local hunks on lines the index left alone", function()
            local cached = { hl(3, { "3" }, 3, { "3x" }) }
            local beside = hl(3, {}, 4, { "new" }) -- an insertion after the staged line
            local apart = hl(5, { "5" }, 6, { "5y" })
            assert.are.same({}, marks.restaged({ beside, apart }, cached))
        end)
    end)
end)
