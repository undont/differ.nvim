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

-- each HEAD<->worktree hunk's rolled-up state
local function states(m, head_work)
    local out = {}
    for i, u in ipairs(head_work) do
        out[i] = marks.state(m, u)
    end
    return out
end

describe("HEAD<->worktree marks", function()
    it("calls every hunk unstaged when the index holds nothing", function()
        local head_work = { h(2, 1, 2, 1), h(9, 1, 9, 1) }
        local m = marks.classify(head_work, {}, { h(2, 1, 2, 1), h(9, 1, 9, 1) })
        assert.are.same({ "unstaged", "unstaged" }, states(m, head_work))
        assert.is_false(m.old[2])
        assert.is_false(m.new[2])
    end)

    it("calls every hunk staged when the worktree matches the index", function()
        local head_work = { h(2, 1, 2, 1) }
        local m = marks.classify(head_work, { h(2, 1, 2, 1) }, {})
        assert.are.same({ "staged" }, states(m, head_work))
        assert.is_true(m.old[2])
        assert.is_true(m.new[2])
    end)

    -- one file, one hunk staged and another not: each rolls up on its own, so a file
    -- half in the index still reads hunk by hunk rather than as one blurred state
    it("rolls each hunk up separately", function()
        local head_work = { h(1, 1, 1, 1), h(10, 1, 10, 1) }
        local m = marks.classify(head_work, { h(1, 1, 1, 1) }, { h(10, 1, 10, 1) })
        assert.are.same({ "staged", "unstaged" }, states(m, head_work))
    end)

    -- the ticket's repro: a hunk staged, then two more edits inside the region it
    -- covers, so HEAD<->worktree collapses all three into one hunk. that hunk is partial,
    -- and the per-line marks still say which line of it the index already has
    it("marks a hunk partial when later edits land inside a staged one", function()
        local head_work = { h(3, 3, 3, 3) }
        local m = marks.classify(head_work, { h(3, 1, 3, 1) }, { h(4, 2, 4, 2) })
        assert.are.same({ "partial" }, states(m, head_work))
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
        -- pairs hold a change, and HEAD<->worktree is empty
        it("catches an edit staged and then undone in the worktree", function()
            assert.is_false(marks.complete({}, { h(2, 1, 2, 1) }, { h(2, 1, 2, 1) }))
        end)

        it("catches unstaged content no hunk covers", function()
            assert.is_false(marks.complete({ h(3, 1, 3, 1) }, {}, { h(9, 1, 9, 1) }))
        end)

        it("catches staged content no hunk covers", function()
            assert.is_false(marks.complete({ h(3, 1, 3, 1) }, { h(9, 1, 9, 1) }, {}))
        end)

        -- HEAD x,y; index x,ghost,y; worktree X,y. the line the index added and the
        -- worktree then dropped reaches neither side of a HEAD<->worktree diff
        it("catches a line only the index holds", function()
            local head_work = { hl(1, { "x" }, 1, { "X" }) }
            local head_index = { hl(1, {}, 2, { "ghost" }) }
            local index_work = { hl(1, { "x", "ghost" }, 1, { "X" }) }
            assert.is_false(marks.complete(head_work, head_index, index_work))
        end)

        -- the pair diffs can align repeated lines differently from HEAD<->worktree: here
        -- the worktree drops a HEAD line HEAD<->worktree still shows as context
        it("catches a replaced line HEAD<->worktree shows as context", function()
            local head_work = { h(1, 1, 1, 1) }
            local index_work = { h(5, 1, 4, 0) }
            assert.is_false(marks.complete(head_work, {}, index_work))
        end)

        -- stage an edit, then edit the same line again: the index's version is replaced
        -- in the worktree, so it reaches neither side of a HEAD<->worktree diff
        it("catches a staged line edited again in the worktree", function()
            local head_work = { hl(1, { "foo" }, 1, { "FOOD" }) }
            local head_index = { hl(1, { "foo" }, 1, { "FOO" }) }
            local index_work = { hl(1, { "FOO" }, 1, { "FOOD" }) }
            assert.is_false(marks.complete(head_work, head_index, index_work))
        end)

        -- HEAD a,a,a,b; index a,a,c,b; worktree b,a,c,b. every range check passes, but
        -- the marks keep two HEAD a's and hold the worktree's a too: five index lines
        -- where there are four
        it("catches marks that count a line twice", function()
            local head_work = { hl(1, { "a", "a", "a" }, 1, { "b", "a", "c" }) }
            local head_index = { hl(3, { "a" }, 3, { "c" }) }
            local index_work = { hl(1, { "a" }, 1, { "b" }) }
            assert.is_false(marks.complete(head_work, head_index, index_work))
        end)

        it("allows a deletion of a line HEAD held too", function()
            local head_work = { hl(7, { "gone" }, 7, {}) }
            local index_work = { hl(7, { "gone" }, 7, {}) }
            assert.is_true(marks.complete(head_work, {}, index_work))
        end)
    end)

    describe("locating hidden content", function()
        local head = { "1", "2", "3", "4", "5" }

        it("names the hunk whose staged line was edited again", function()
            local head_work = { hl(1, { "foo" }, 1, { "FOOD" }) }
            local head_index = { hl(1, { "foo" }, 1, { "FOO" }) }
            local index_work = { hl(1, { "FOO" }, 1, { "FOOD" }) }
            local m = marks.classify(head_work, head_index, index_work)
            assert.are.same({ 1 }, marks.hidden_in({ "foo" }, head_work, head_index, m))
        end)

        -- HEAD 1..5, line 3 staged as 3x, then 4 edited on top in the worktree
        it("names nothing when the view holds what the index does", function()
            local head_work = { hl(3, { "3", "4" }, 3, { "3x", "4y" }) }
            local head_index = { hl(3, { "3" }, 3, { "3x" }) }
            local index_work = { hl(4, { "4" }, 4, { "4y" }) }
            local m = marks.classify(head_work, head_index, index_work)
            assert.are.same({}, marks.hidden_in(head, head_work, head_index, m))
        end)
    end)

    describe("local hunks over staged content", function()
        it("names a local hunk rewriting a line the index added", function()
            local head_index = { hl(1, { "foo" }, 1, { "FOO" }) }
            local index_work = { hl(1, { "FOO" }, 1, { "FOOD" }) }
            assert.are.same({ 1 }, marks.restaged(index_work, head_index))
        end)

        it("names a local hunk putting back a line the index deleted", function()
            local head_index = { hl(3, { "3" }, 2, {}) }
            local index_work = { hl(2, {}, 3, { "3" }) }
            assert.are.same({ 1 }, marks.restaged(index_work, head_index))
        end)

        it("leaves out local hunks on lines the index left alone", function()
            local head_index = { hl(3, { "3" }, 3, { "3x" }) }
            local beside = hl(3, {}, 4, { "new" }) -- an insertion after the staged line
            local apart = hl(5, { "5" }, 6, { "5y" })
            assert.are.same({}, marks.restaged({ beside, apart }, head_index))
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
        -- way spans both HEAD<->worktree hunks, through the B C only the index holds
        it("names the other HEAD<->worktree hunk a pair hunk reaches", function()
            local head_work = { h(2, 1, 2, 1), h(5, 2, 5, 2) }
            local pair = { h(2, 5, 2, 5) }
            assert.are.equal(2, marks.shared_with(head_work, head_work[1], pair, "new"))
            assert.are.equal(1, marks.shared_with(head_work, head_work[2], pair, "old"))
        end)

        it("names no hunk when each pair hunk stays in one", function()
            local head_work = { h(2, 1, 2, 1), h(5, 2, 5, 2) }
            local pair = { h(2, 1, 2, 1), h(5, 1, 5, 1) }
            assert.is_nil(marks.shared_with(head_work, head_work[1], pair, "new"))
            assert.is_nil(marks.shared_with(head_work, head_work[2], pair, "new"))
        end)

        it("compares the sides it's given", function()
            -- index<->worktree deletes index line 3; HEAD<->index changes it
            assert.is_true(marks.meets(h(3, 1, 2, 0), "old", h(3, 1, 3, 1), "new"))
        end)
    end)

    describe("blocks", function()
        -- HEAD a b c d, worktree a B c D e: b and d rewritten, e added at the end
        local head = { "a", "b", "c", "d" }
        local head_work = { hl(2, { "b" }, 2, { "B" }), hl(4, { "d" }, 4, { "D", "e" }) }

        it("reads HEAD's lines at every hunk of an index that is HEAD", function()
            assert.are.same({ { "b" }, { "d" } }, marks.blocks(head_work, head, head))
        end)

        it("reads whatever the index holds at a hunk", function()
            local index = { "a", "B", "c", "D" }
            assert.are.same({ { "B" }, { "D" } }, marks.blocks(head_work, head, index))
            index = { "a", "b", "X", "Y", "c", "d" }
            assert.are.same({ { "b", "X", "Y" }, { "d" } }, marks.blocks(head_work, head, index))
        end)

        it("gives nil when the index changes a line between hunks", function()
            assert.is_nil(marks.blocks(head_work, head, { "a", "b", "C", "d" }))
        end)

        -- HEAD a x c, worktree a x x c: the inserted x also fits HEAD's own x
        it("settles a block its unchanged lines repeat by the lines after it", function()
            local repeat_head = { "a", "x", "c" }
            local insert = { hl(1, {}, 2, { "x" }) }
            assert.are.same({ {} }, marks.blocks(insert, repeat_head, repeat_head))
            local index = { "a", "x", "x", "c" }
            assert.are.same({ { "x" } }, marks.blocks(insert, repeat_head, index))
        end)

        -- HEAD a b _ _ c d, worktree a b B _ d: a blank either side of hunk 1's insertion,
        -- so the index's first blank fits hunk 1's block or the context after it
        it("reads a block by the hunk's own lines where a repeated line fits two ways", function()
            local blank = { "a", "b", "", "", "c", "d" }
            local around = { hl(2, {}, 3, { "B" }), hl(4, { "", "c" }, 4, {}) }
            assert.are.same({ {}, { "", "c" } }, marks.blocks(around, blank, blank))
            local index = { "a", "b", "B", "", "", "c", "d" }
            assert.are.same({ { "B" }, { "", "c" } }, marks.blocks(around, blank, index))
            index = { "a", "b", "", "d" }
            assert.are.same({ {}, {} }, marks.blocks(around, blank, index))
        end)

        it("gives the last hunk the rest of the index", function()
            local index = { "a", "b", "c", "D", "e", "f" }
            assert.are.same({ { "b" }, { "D", "e", "f" } }, marks.blocks(head_work, head, index))
        end)

        -- a blank file with a line rewritten as two every 25 lines, and the index holding
        -- one of the two: nearly every blank is a place the block could end
        it("gives nil rather than search a mostly blank file for long", function()
            local blank_head, blank_index, spread = {}, {}, {}
            for l = 1, 2000 do
                local line = ""
                if l % 25 == 0 then
                    line = "old" .. l
                    local n = #spread
                    spread[n + 1] = hl(l, { line }, l + n, { "x" .. l, "y" .. l })
                    blank_index[l] = "x" .. l
                end
                blank_head[l], blank_index[l] = line, blank_index[l] or line
            end
            assert.is_nil(marks.blocks(spread, blank_head, blank_index))
        end)
    end)

    describe("of_blocks", function()
        -- HEAD 1 a b 4, worktree 1 A B C 4: one hunk rewriting two lines as three
        local head_work = { hl(2, { "a", "b" }, 2, { "A", "B", "C" }) }

        it("reads a block of HEAD's lines as unstaged and the worktree's as staged", function()
            local m = marks.of_blocks(head_work, { { "a", "b" } })
            assert.are.same({ "unstaged" }, states(m, head_work))
            m = marks.of_blocks(head_work, { { "A", "B", "C" } })
            assert.are.same({ "staged" }, states(m, head_work))
        end)

        it("marks each line of a block that holds part of the hunk", function()
            local m, hidden = marks.of_blocks(head_work, { { "a", "B" } })
            assert.are.same({ "partial" }, states(m, head_work))
            assert.are.same({ [2] = false, [3] = true }, m.old)
            assert.are.same({ [2] = false, [3] = true, [4] = false }, m.new)
            assert.are.same({}, hidden)
        end)

        it("names the hunk whose block holds a line neither side has", function()
            local _, hidden = marks.of_blocks(head_work, { { "a", "Z" } })
            assert.are.same({ 1 }, hidden)
        end)

        -- HEAD a a, worktree a z: the two sides share an a
        it("reads a block that is one whole side as that side", function()
            local shared = { hl(1, { "a", "a" }, 1, { "a", "z" }) }
            assert.are.same({ "staged" }, states(marks.of_blocks(shared, { { "a", "z" } }), shared))
            assert.are.same(
                { "unstaged" },
                states(marks.of_blocks(shared, { { "a", "a" } }), shared)
            )
        end)

        -- HEAD x a, worktree a x: a block of HEAD's lines pairs with the old side first
        it("reads a moved line from HEAD before the worktree", function()
            local moved = { hl(1, { "x", "a" }, 1, { "a", "x" }) }
            local m, hidden = marks.of_blocks(moved, { { "x", "a" } })
            assert.are.same({ "unstaged" }, states(m, moved))
            assert.are.same({}, hidden)
        end)

        -- HEAD x a, worktree a y: a block of a alone is x dropped from HEAD, or the
        -- worktree's a with y still to come. both describe the same index
        it("reads a partial block's shared line as HEAD's", function()
            local shared = { hl(1, { "x", "a" }, 1, { "a", "y" }) }
            local m, hidden = marks.of_blocks(shared, { { "a" } })
            assert.are.same({ "partial" }, states(m, shared))
            assert.are.same({ [1] = true, [2] = false }, m.old)
            assert.are.same({ [1] = false, [2] = false }, m.new)
            assert.are.same({}, hidden)
        end)
    end)

    -- past MAX_CELLS the block isn't compared line by line, and an uncompared hunk takes
    -- the whole file to the pair diffs rather than marking half of it
    it("gives no marks for a hunk too big to compare", function()
        local old_lines, block = {}, {}
        for i = 1, 1001 do
            old_lines[i] = "line " .. i
            block[i] = "line " .. i
        end
        block[1] = "changed" -- so the block isn't one whole side, which needs no compare
        local head_work = { hl(1, old_lines, 1, { "one" }) }
        local m, hidden = marks.of_blocks(head_work, { block })
        assert.is_nil(m)
        assert.are.same({}, hidden)
    end)

    describe("a last line without its newline", function()
        local text = require("differ.util.text")
        local NO = text.NO_EOL
        local S, U, P = "staged", "unstaged", "partial"

        -- HEAD "a\nb", worktree "a\nb\n": one hunk, b on both sides
        it("tells a line from the same line with its newline", function()
            local head_work = { hl(2, { "b" .. NO }, 2, { "b" }) }
            local head = text.ended_lines("a\nb")
            local unstaged = marks.blocks(head_work, head, text.ended_lines("a\nb"))
            local staged = marks.blocks(head_work, head, text.ended_lines("a\nb\n"))
            assert.are.same({ U }, states(marks.of_blocks(head_work, unstaged), head_work))
            assert.are.same({ S }, states(marks.of_blocks(head_work, staged), head_work))
        end)

        -- HEAD "a\nb", worktree "a\nB\n": the index holds B without the newline
        it("reads a last line the index holds without its newline as neither side's", function()
            local head_work = { hl(2, { "b" .. NO }, 2, { "B" }) }
            local blocks =
                marks.blocks(head_work, text.ended_lines("a\nb"), text.ended_lines("a\nB"))
            local m, hidden = marks.of_blocks(head_work, blocks)
            assert.are.same({ P }, states(m, head_work))
            assert.are.same({ 1 }, hidden)
        end)

        -- HEAD "a\nx\nc\nb\na\na\n", worktree "a\nc\nay\nz4\na\na": the index's last `a`
        -- has no newline, so it's the worktree's added line, not HEAD's last one
        it("cuts an unterminated last line into the hunk that ends the worktree", function()
            local head_work = {
                hl(2, { "x" }, 1, {}),
                hl(4, { "b", "a" }, 3, { "ay", "z4" }),
                hl(6, {}, 6, { "a" .. NO }),
            }
            local head = text.ended_lines("a\nx\nc\nb\na\na\n")
            local blocks = marks.blocks(head_work, head, text.ended_lines("a\nx\nc\nb\na\na"))
            assert.are.same({ { "x" }, { "b" }, { "a" .. NO } }, blocks)
            assert.are.same({ U, P, S }, states(marks.of_blocks(head_work, blocks), head_work))
        end)
    end)

    describe("reading", function()
        ---@param read differ.model.Reading
        local function slices(read)
            local out = {}
            for i, s in ipairs(read.slices) do
                out[i] = s
            end
            return out
        end

        -- HEAD b a, worktree a: one hunk dropping b
        local drop_b = { hl(1, { "b" }, 0, {}) }

        it("reads an index that is HEAD or the worktree at no cost", function()
            local read = marks.reading(drop_b, { "b", "a" }, { "b", "a" }) --[[@as differ.model.Reading]]
            assert.are.equal(0, read.cost)
            assert.are.same({ [1] = false }, read.marks.old)
            assert.are.same({ { 1, 2 } }, slices(read))
            read = marks.reading(drop_b, { "b", "a" }, { "a" }) --[[@as differ.model.Reading]]
            assert.are.equal(0, read.cost)
            assert.are.same({ [1] = true }, read.marks.old)
            assert.are.same({ { 1, 1 } }, slices(read))
        end)

        it("reads part of a hunk in any interleaving of its sides", function()
            local head_work = { hl(2, { "a", "b" }, 2, { "c", "d" }) }
            local read = marks.reading(head_work, { "1", "a", "b", "4" }, { "1", "c", "a", "4" })
            assert.are.equal(0, read and read.cost)
            assert.are.same({ [2] = false, [3] = true }, read and read.marks.old)
            assert.are.same({ [2] = true, [3] = false }, read and read.marks.new)
        end)

        it("keeps an old line before holding an equal new one", function()
            local head_work = { hl(1, { "b", "y" }, 1, { "b", "z" }) }
            local read = marks.reading(head_work, { "b", "y" }, { "b" })
            assert.are.same({ [1] = false, [2] = true }, read and read.marks.old)
            assert.are.same({ [1] = false, [2] = false }, read and read.marks.new)
        end)

        it("names the hunk whose lines hold a hidden line", function()
            local read = marks.reading(drop_b, { "b", "a" }, { "b", "x", "a" }) --[[@as differ.model.Reading]]
            assert.are.equal(1, read.cost)
            assert.are.same({ 1 }, read.hidden_in)
            assert.are.same({ { 1, 3 } }, slices(read))
        end)

        it("matches unchanged lines from the end before reading the rest", function()
            local read = marks.reading(drop_b, { "b", "a" }, { "b", "a", "a" }) --[[@as differ.model.Reading]]
            assert.are.equal(1, read.cost)
            assert.are.same({ [1] = false }, read.marks.old)
            assert.are.same({ 1 }, read.hidden_in)
            assert.are.same({ { 1, 3 } }, slices(read))
        end)

        it("matches an unchanged line before hiding an equal one", function()
            -- HEAD b a c x, worktree a c y, and the index has a second a between hunks
            local head_work = { hl(1, { "b" }, 0, {}), hl(4, { "x" }, 3, { "y" }) }
            local head, index = { "b", "a", "c", "x" }, { "b", "a", "a", "c", "y" }
            local read = marks.reading(head_work, head, index) --[[@as differ.model.Reading]]
            assert.are.equal(1, read.cost)
            assert.are.same({}, read.hidden_in)
            assert.are.same({ { 1, 2 }, { 5, 6 } }, slices(read))
        end)

        it("gives a hidden line between two hunks to the earlier one", function()
            -- HEAD p c q, worktree P c Q, and an index that lacks c
            local head_work = { hl(1, { "p" }, 1, { "P" }), hl(3, { "q" }, 3, { "Q" }) }
            local read = marks.reading(head_work, { "p", "c", "q" }, { "P", "x", "Q" }) --[[@as differ.model.Reading]]
            assert.are.equal(2, read.cost)
            assert.are.same({ 1 }, read.hidden_in)
            assert.are.same({ { 1, 3 }, { 3, 4 } }, slices(read))
        end)

        it("gives a hidden line next to a hunk with no lines in the index to that hunk", function()
            -- HEAD d b c, worktree d c, the index d x c
            local head_work = { hl(2, { "b" }, 1, {}) }
            local read = marks.reading(head_work, { "d", "b", "c" }, { "d", "x", "c" }) --[[@as differ.model.Reading]]
            assert.are.same({ [2] = true }, read.marks.old)
            assert.are.same({ 1 }, read.hidden_in)
            assert.are.same({ { 2, 3 } }, slices(read))
        end)

        it("counts a missing unchanged line without naming a hunk", function()
            local read = marks.reading(drop_b, { "b", "a" }, {}) --[[@as differ.model.Reading]]
            assert.are.equal(1, read.cost)
            assert.are.same({}, read.hidden_in)
        end)

        -- the shapes where a walk on its own reads other lines than the blocks do
        for _, case in ipairs({
            {
                name = "an index that is HEAD next to an inserted repeated line",
                head_work = { hl(2, {}, 3, { "x", "b" }), hl(4, { "b", "b" }, 5, {}) },
                head = { "x", "b", "b", "b", "b", "x" },
                index = { "x", "b", "b", "b", "b", "x" },
            },
            {
                name = "a block that is the new side and shares a line with the old",
                head_work = { hl(1, { "b", "b" }, 1, { "b", "x" }) },
                head = { "b", "b", "b", "b" },
                index = { "b", "x", "b", "b" },
            },
            {
                name = "a block that keeps one of several equal old lines",
                head_work = { hl(1, { "a", "b", "a", "b" }, 1, { "x", "x" }) },
                head = { "a", "b", "a", "b" },
                index = { "x", "b" },
            },
            {
                name = "a block with a new line between equal old ones",
                head_work = { hl(1, { "b", "b", "b" }, 1, { "x", "x" }) },
                head = { "b", "b", "b" },
                index = { "b", "x", "b" },
            },
            {
                name = "a block that is a whole side",
                head_work = { hl(2, { "a", "b" }, 2, { "A", "B", "C" }) },
                head = { "1", "a", "b", "4" },
                index = { "1", "A", "B", "C", "4" },
            },
        }) do
            it("reads as the blocks do: " .. case.name, function()
                local blocks = marks.blocks(case.head_work, case.head, case.index)
                local held, hidden = marks.of_blocks(case.head_work, blocks or {})
                assert.are.same({}, hidden)
                local read = marks.reading(case.head_work, case.head, case.index) --[[@as differ.model.Reading]]
                assert.are.equal(0, read.cost)
                assert.are.same(held, read.marks)
            end)
        end

        -- HEAD l1..l1100, worktree with the first and last lines changed, and an index
        -- that holds the unchanged lines between them
        local function far_apart()
            local head, index = {}, {}
            for l = 1, 1100 do
                head[l] = "l" .. l
            end
            for l = 2, 1099 do
                index[#index + 1] = head[l]
            end
            return { hl(1, { "l1" }, 1, { "n1" }), hl(1100, { "l1100" }, 1100, { "n1100" }) },
                head,
                index
        end

        it("reads hunks far apart with hidden lines at each", function()
            local head_work, head, index = far_apart()
            table.insert(index, 1, "x")
            index[#index + 1] = "y"
            local read = marks.reading(head_work, head, index) --[[@as differ.model.Reading]]
            assert.are.equal(2, read.cost)
            assert.are.same({ 1, 2 }, read.hidden_in)
        end)

        it("reads a hidden line in the gap between hunks", function()
            local head_work, head, index = far_apart()
            table.insert(index, 500, "x")
            local read = marks.reading(head_work, head, index) --[[@as differ.model.Reading]]
            assert.are.equal(1, read.cost)
            assert.are.same({}, read.hidden_in)
            assert.are.same({ [1] = true, [1100] = true }, read.marks.old)
        end)

        it("leaves out a unique line the index holds out of place", function()
            -- l2 sits at the bottom: matching it would leave every line after it unmatched
            local head_work, head, index = far_apart()
            local moved = table.remove(index, 1)
            index[#index + 1] = moved
            local read = marks.reading(head_work, head, index) --[[@as differ.model.Reading]]
            assert.are.equal(2, read.cost) -- l2 missing, and hidden at the bottom
            assert.are.same({ 2 }, read.hidden_in)
            assert.are.same({ { 1, 1 }, { 1098, 1099 } }, slices(read))
        end)

        it("gives nil for a file too big to read", function()
            local head, index = {}, { "x" }
            for l = 1, 1100 do
                head[l], index[l + 1] = "l", "l"
            end
            index[#index] = "z"
            local head_work = { hl(1100, { "l" }, 1100, { "z" }) }
            assert.is_nil(marks.reading(head_work, head, index))
        end)

        describe("doubt", function()
            it("flags a hunk another reading of the same cost stages other lines in", function()
                -- HEAD a b c, worktree a b q b c: the index's q is hidden, or held with b missing
                local head_work = { hl(2, {}, 3, { "q", "b" }) }
                local read = marks.reading(
                    head_work,
                    { "a", "b", "c" },
                    { "a", "q", "b", "c" },
                    true
                )
                assert.are.same({ 1 }, read and read.doubt_in)
            end)

            it("flags the hunk a repeated line could be hidden in", function()
                -- HEAD f( end) g( end), worktree f( x end) g( y end), a second end) in the index
                local head_work = { hl(1, {}, 2, { "x" }), hl(3, {}, 5, { "y" }) }
                local head = { "f(", "end)", "g(", "end)" }
                local read =
                    marks.reading(head_work, head, { "f(", "end)", "end)", "g(", "end)" }, true)
                assert.are.same({}, read and read.hidden_in)
                assert.are.same({ 1 }, read and read.doubt_in)
            end)

            it("flags every hunk between the held lines either side of a hidden line", function()
                -- HEAD 1-7, worktree 1 A2 3 4 D2 E2 7: nothing between 1 and 7 is held
                local head_work =
                    { hl(2, { "2" }, 2, { "A2" }), hl(5, { "5", "6" }, 5, { "D2", "E2" }) }
                local head = { "1", "2", "3", "4", "5", "6", "7" }
                local read =
                    marks.reading(head_work, head, { "1", "A", "B", "C", "D", "E", "7" }, true)
                assert.are.same({ 1 }, read and read.hidden_in)
                assert.are.same({ 1, 2 }, read and read.doubt_in)
            end)

            it("doesn't flag the same lines marked on another copy", function()
                -- HEAD a c, worktree a x y x c, the index holds one x
                local head_work = { hl(1, {}, 2, { "x", "y", "x" }) }
                local read = marks.reading(head_work, { "a", "c" }, { "a", "x", "c" }, true)
                assert.are.same({}, read and read.doubt_in)
            end)

            it("doesn't flag a hidden line only one hunk can hold", function()
                local head_work = { hl(2, { "b" }, 2, { "y" }) }
                local read = marks.reading(head_work, { "a", "b", "c" }, { "a", "x", "c" }, true)
                assert.are.same({ 1 }, read and read.hidden_in)
                assert.are.same({}, read and read.doubt_in)
            end)

            it("doesn't flag a reading only one walk fits", function()
                local head_work = { hl(2, {}, 3, { "q", "b" }) }
                local read = marks.reading(
                    head_work,
                    { "a", "b", "c" },
                    { "a", "b", "q", "c" },
                    true
                )
                assert.are.same({}, read and read.doubt_in)
            end)
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
