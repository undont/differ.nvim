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
            assert.are.same({ 1 }, marks.hidden_in({ "foo" }, union, cached, m))
        end)

        -- HEAD 1..5, line 3 staged as 3x, then 4 edited on top in the worktree
        it("names nothing when the view holds what the index does", function()
            local union = { hl(3, { "3", "4" }, 3, { "3x", "4y" }) }
            local cached = { hl(3, { "3" }, 3, { "3x" }) }
            local unstaged = { hl(4, { "4" }, 4, { "4y" }) }
            local m = marks.classify(union, cached, unstaged)
            assert.are.same({}, marks.hidden_in(head, union, cached, m))
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

    describe("meets", function()
        it("meets on shared lines and not on lines apart", function()
            assert.is_true(marks.meets(h(3, 2, 3, 2), "old", h(4, 1, 4, 1), "old"))
            assert.is_false(marks.meets(h(3, 1, 3, 1), "old", h(4, 1, 4, 1), "old"))
        end)

        it("meets an insertion at either edge of its lines", function()
            local lines = h(3, 1, 3, 2) -- HEAD line 3
            assert.is_true(marks.meets(h(2, 0, 3, 1), "old", lines, "old")) -- after line 2
            assert.is_true(marks.meets(lines, "old", h(3, 0, 4, 1), "old")) -- after line 3
            assert.is_false(marks.meets(h(1, 0, 2, 1), "old", lines, "old"))
            assert.is_false(marks.meets(h(4, 0, 5, 1), "old", lines, "old"))
        end)

        it("meets two insertions only at the same place", function()
            assert.is_true(marks.meets(h(2, 0, 3, 1), "old", h(2, 0, 3, 2), "old"))
            assert.is_false(marks.meets(h(2, 0, 3, 1), "old", h(3, 0, 4, 1), "old"))
        end)

        -- HEAD 1..7, index 1 A B C D E 7, worktree 1 A2 3 4 D2 E2 7: one pair hunk each
        -- way spans both union hunks, through the B C only the index holds
        it("names the other union hunk a pair hunk reaches", function()
            local union = { h(2, 1, 2, 1), h(5, 2, 5, 2) }
            local pair = { h(2, 5, 2, 5) }
            assert.are.equal(2, marks.shared_with(union, union[1], pair, "new"))
            assert.are.equal(1, marks.shared_with(union, union[2], pair, "old"))
        end)

        it("names no hunk when each pair hunk stays in one", function()
            local union = { h(2, 1, 2, 1), h(5, 2, 5, 2) }
            local pair = { h(2, 1, 2, 1), h(5, 1, 5, 1) }
            assert.is_nil(marks.shared_with(union, union[1], pair, "new"))
            assert.is_nil(marks.shared_with(union, union[2], pair, "new"))
        end)

        it("compares the sides it's given", function()
            -- index↔worktree deletes index line 3; HEAD↔index changes it
            assert.is_true(marks.meets(h(3, 1, 2, 0), "old", h(3, 1, 3, 1), "new"))
        end)
    end)

    describe("blocks", function()
        -- HEAD a b c d, worktree a B c D e: b and d rewritten, e added at the end
        local head = { "a", "b", "c", "d" }
        local union = { hl(2, { "b" }, 2, { "B" }), hl(4, { "d" }, 4, { "D", "e" }) }

        it("reads HEAD's lines at every hunk of an index that is HEAD", function()
            assert.are.same({ { "b" }, { "d" } }, marks.blocks(union, head, head))
        end)

        it("reads whatever the index holds at a hunk", function()
            local index = { "a", "B", "c", "D" }
            assert.are.same({ { "B" }, { "D" } }, marks.blocks(union, head, index))
            index = { "a", "b", "X", "Y", "c", "d" }
            assert.are.same({ { "b", "X", "Y" }, { "d" } }, marks.blocks(union, head, index))
        end)

        it("gives nil when the index changes a line between hunks", function()
            assert.is_nil(marks.blocks(union, head, { "a", "b", "C", "d" }))
        end)

        -- HEAD a x c, worktree a x x c: the inserted x also fits HEAD's own x
        it("settles a block its unchanged lines repeat by the lines after it", function()
            local repeat_head = { "a", "x", "c" }
            local insert = { hl(1, {}, 2, { "x" }) }
            assert.are.same({ {} }, marks.blocks(insert, repeat_head, repeat_head))
            local index = { "a", "x", "x", "c" }
            assert.are.same({ { "x" } }, marks.blocks(insert, repeat_head, index))
        end)

        it("gives the last hunk the rest of the index", function()
            local index = { "a", "b", "c", "D", "e", "f" }
            assert.are.same({ { "b" }, { "D", "e", "f" } }, marks.blocks(union, head, index))
        end)
    end)

    describe("of_blocks", function()
        -- HEAD 1 a b 4, worktree 1 A B C 4: one hunk rewriting two lines as three
        local union = { hl(2, { "a", "b" }, 2, { "A", "B", "C" }) }

        it("reads a block of HEAD's lines as unstaged and the worktree's as staged", function()
            local m = marks.of_blocks(union, { { "a", "b" } })
            assert.are.same({ "unstaged" }, states(m, union))
            m = marks.of_blocks(union, { { "A", "B", "C" } })
            assert.are.same({ "staged" }, states(m, union))
        end)

        it("marks each line of a block that holds part of the hunk", function()
            local m, hidden = marks.of_blocks(union, { { "a", "B" } })
            assert.are.same({ "partial" }, states(m, union))
            assert.are.same({ [2] = false, [3] = true }, m.old)
            assert.are.same({ [2] = false, [3] = true, [4] = false }, m.new)
            assert.are.same({}, hidden)
        end)

        it("names the hunk whose block holds a line neither side has", function()
            local _, hidden = marks.of_blocks(union, { { "a", "Z" } })
            assert.are.same({ 1 }, hidden)
        end)

        -- HEAD x a, worktree a x: a block of HEAD's lines pairs with the old side first
        it("reads a moved line from HEAD before the worktree", function()
            local moved = { hl(1, { "x", "a" }, 1, { "a", "x" }) }
            local m, hidden = marks.of_blocks(moved, { { "x", "a" } })
            assert.are.same({ "unstaged" }, states(m, moved))
            assert.are.same({}, hidden)
        end)
    end)

    describe("shift", function()
        -- three lines inserted at the top, and line 5 replaced by two
        local hunks = { h(0, 0, 1, 3), h(5, 1, 8, 2) }

        it("moves a line by the hunks that end before it", function()
            assert.are.equal(3, marks.shift(hunks, 1, "old"))
            assert.are.equal(4, marks.shift(hunks, 6, "old"))
            assert.are.equal(-3, marks.shift(hunks, 4, "new"))
        end)

        it("leaves out a hunk that starts on the line", function()
            assert.are.equal(3, marks.shift(hunks, 5, "old"))
        end)
    end)
end)
