local stage = require("differ.model.stage")

local function model(old_text, new_text, hunks)
    return {
        path = "f",
        old_rev = "A",
        new_rev = "B",
        old_text = old_text,
        new_text = new_text,
        hunks = hunks,
    }
end

local function h(old_start, old_lines, new_start, new_lines)
    return {
        old_start = old_start,
        old_count = #old_lines,
        old_lines = old_lines,
        new_start = new_start,
        new_count = #new_lines,
        new_lines = new_lines,
    }
end

local function sel(old, new)
    local out = { old = {}, new = {} }
    for _, l in ipairs(old) do
        out.old[l] = true
    end
    for _, l in ipairs(new) do
        out.new[l] = true
    end
    return out
end

-- HEAD 1..5, worktree 1 2x 3 4 5y: one hunk on line 2 and one on the last line
local HEAD = "1\n2\n3\n4\n5\n"
local WORK = "1\n2x\n3\n4\n5y\n"
local function pairs_of(index)
    local hunks = { h(2, { "2" }, 2, { "2x" }), h(5, { "5" }, 5, { "5y" }) }
    return model(HEAD, WORK, hunks), model(HEAD, index, {}), model(index, WORK, hunks)
end

describe("index_blocks", function()
    it("reads each hunk's lines from an index that is HEAD", function()
        local union = (pairs_of(HEAD))
        local blocks = stage.index_blocks(union, HEAD)
        assert.are.same({ { "2" }, { "5" } }, blocks)
    end)

    it("gives nil when the index changes a line between the hunks", function()
        local union = (pairs_of(HEAD))
        assert.is_nil(stage.index_blocks(union, "1\n2\n3x\n4\n5\n"))
    end)
end)

describe("marks_of", function()
    it("draws a file with nothing hidden from its blocks", function()
        local union, cached, unstaged = pairs_of("1\n2x\n3\n4\n5\n")
        local m, hidden, hidden_in = stage.marks_of(union, cached, unstaged)
        assert.are.same({ [2] = true, [5] = false }, m.old)
        assert.are.same({ [2] = true, [5] = false }, m.new)
        assert.is_false(hidden)
        assert.are.same({}, hidden_in)
    end)

    it("draws a file with hidden lines from the least-cost reading", function()
        -- HEAD b a c x, worktree a c y, and an index with a second a. its blocks put
        -- that a inside the first hunk; the reading matches it as the unchanged line
        local union =
            model("b\na\nc\nx\n", "a\nc\ny\n", { h(1, { "b" }, 0, {}), h(4, { "x" }, 3, { "y" }) })
        local cached = model(
            "b\na\nc\nx\n",
            "b\na\na\nc\ny\n",
            { h(2, {}, 3, { "a" }), h(4, { "x" }, 5, { "y" }) }
        )
        local unstaged =
            model("b\na\na\nc\ny\n", "a\nc\ny\n", { h(1, { "b" }, 0, {}), h(3, { "a" }, 2, {}) })
        local m, hidden, hidden_in, unread = stage.marks_of(union, cached, unstaged)
        assert.are.same({ [1] = false, [4] = true }, m.old)
        assert.is_true(hidden)
        assert.are.same({}, hidden_in)
        assert.is_false(unread)
    end)

    it("draws a file too big to read from its pairs", function()
        local head, index, work = {}, { "x" }, {}
        for l = 1, 1100 do
            head[l], index[l + 1], work[l] = "l", "l", "l"
        end
        work[1100] = "z"
        local text = function(lines)
            return table.concat(lines, "\n") .. "\n"
        end
        local edit = h(1100, { "l" }, 1100, { "z" })
        local union = model(text(head), text(work), { edit })
        local cached = model(text(head), text(index), { h(0, {}, 1, { "x" }) })
        local unstaged = model(
            text(index),
            text(work),
            { h(1, { "x" }, 0, {}), h(1101, { "l" }, 1100, { "z" }) }
        )
        local m, hidden, hidden_in, unread = stage.marks_of(union, cached, unstaged)
        assert.are.same({ [1100] = false }, m.old)
        assert.is_true(hidden)
        assert.are.same({}, hidden_in)
        assert.is_true(unread)
    end)
end)

describe("next_index", function()
    it("stages a hunk by giving the index the worktree's lines", function()
        local union, cached, unstaged = pairs_of(HEAD)
        local text = stage.next_index(union, cached, unstaged, union.hunks[1], true)
        assert.are.equal("1\n2x\n3\n4\n5\n", text)
    end)

    it("unstages a hunk by giving the index HEAD's lines", function()
        local index = "1\n2x\n3\n4\n5\n"
        local union, cached, unstaged = pairs_of(index)
        cached.hunks = { h(2, { "2" }, 2, { "2x" }) }
        unstaged.hunks = { h(5, { "5" }, 5, { "5y" }) }
        local text = stage.next_index(union, cached, unstaged, union.hunks[1], false)
        assert.are.equal(HEAD, text)
    end)

    -- HEAD "a\nb", worktree "a\nb\n": the hunk is the ending alone
    it("takes the ending with the hunk that reaches the end of the file", function()
        local hunks = { h(2, { "b" }, 2, { "b" }) }
        local union = model("a\nb", "a\nb\n", hunks)
        local cached = model("a\nb", "a\nb", {})
        local unstaged = model("a\nb", "a\nb\n", hunks)
        assert.are.equal("a\nb\n", stage.next_index(union, cached, unstaged, union.hunks[1], true))
    end)

    -- HEAD 1..7, index 1 A B C D E 7, worktree 1 A2 3 4 D2 E2 7: the index's B and C
    -- sit between the two union hunks, so one HEAD↔index hunk covers both
    it("names the other hunk a pair hunk would carry the op into", function()
        local head = "1\n2\n3\n4\n5\n6\n7\n"
        local index = "1\nA\nB\nC\nD\nE\n7\n"
        local work = "1\nA2\n3\n4\nD2\nE2\n7\n"
        local union = model(head, work, {
            h(2, { "2" }, 2, { "A2" }),
            h(5, { "5", "6" }, 5, { "D2", "E2" }),
        })
        local cached = model(
            head,
            index,
            { h(2, { "2", "3", "4", "5", "6" }, 2, { "A", "B", "C", "D", "E" }) }
        )
        local unstaged = model(
            index,
            work,
            { h(2, { "A", "B", "C", "D", "E" }, 2, { "A2", "3", "4", "D2", "E2" }) }
        )
        local text, reaches = stage.next_index(union, cached, unstaged, union.hunks[1], false)
        assert.is_nil(text)
        assert.are.equal(2, reaches)
    end)

    -- HEAD 1 2 x x 5, index 1 x x 5x, worktree 1 2x x 5x: the index drops a line the
    -- union shows under hunk 1, so the pair hunks leave hunk 2 nothing of its own. the
    -- op has to say so rather than hand back the index's own text
    it("gives no text and no reaches for a hunk neither pair sits at", function()
        local head = "1\n2\nx\nx\n5\n"
        local index = "1\nx\nx\n5x\n"
        local work = "1\n2x\nx\n5x\n"
        local union = model(head, work, {
            h(2, { "2" }, 2, { "2x" }),
            h(4, { "x", "5" }, 4, { "5x" }),
        })
        local cached = model(head, index, { h(2, { "2" }, 2, {}), h(5, { "5" }, 4, { "5x" }) })
        local unstaged = model(index, work, { h(2, {}, 2, { "2x" }) })
        local text, reaches = stage.next_index(union, cached, unstaged, union.hunks[2], true)
        assert.is_nil(text)
        assert.is_nil(reaches)
    end)

    it("never hands back the text the index already holds", function()
        local union, cached, unstaged = pairs_of(HEAD)
        -- both hunks are unstaged, so unstaging one has nothing to write
        assert.is_nil(stage.next_index(union, cached, unstaged, union.hunks[1], false))
    end)
end)

describe("model.stage.drop_lines", function()
    it("takes back only the lines asked for inside a block of the same length", function()
        local cached = model("1\n2\n3\n4\n5\n", "1\nB\nC\nD\n5\n", {
            h(2, { "2", "3", "4" }, 2, { "B", "C", "D" }),
        })
        assert.are.equal("1\nB\n3\nD\n5\n", stage.drop_lines(cached, 1, 3, 3))
    end)

    it("keeps every other staged hunk", function()
        local cached = model("1\n2\n3\n4\n5\n", "X\n2\nC\nD\n5\n", {
            h(1, { "1" }, 1, { "X" }),
            h(3, { "3", "4" }, 3, { "C", "D" }),
        })
        assert.are.equal("X\n2\n3\nD\n5\n", stage.drop_lines(cached, 2, 3, 3))
    end)

    it("takes back a block's last line and keeps the file's ending", function()
        local cached = model("1\n2", "1\nB", { h(2, { "2" }, 2, { "B" }) })
        assert.are.equal("1\n2", stage.drop_lines(cached, 1, 2, 2))
    end)
end)

describe("model.stage.select_index", function()
    it("stages part of an insertion", function()
        local union = model("1\n2\n", "1\nA\nB\nC\n2\n", { h(1, {}, 2, { "A", "B", "C" }) })
        local cached = model("1\n2\n", "1\n2\n", {})
        assert.are.equal("1\nB\n2\n", stage.select_index(union, cached, sel({}, { 3 }), true))
    end)

    it("stages part of a deletion", function()
        local union = model("1\na\nb\nc\n2\n", "1\n2\n", { h(2, { "a", "b", "c" }, 1, {}) })
        local cached = model("1\na\nb\nc\n2\n", "1\na\nb\nc\n2\n", {})
        local text = stage.select_index(union, cached, sel({ 3 }, {}), true)
        assert.are.equal("1\na\nc\n2\n", text)
    end)

    -- HEAD 1 a b 2, worktree 1 x y 2: rows a|x and b|y
    local SPLIT_HEAD, SPLIT_WORK = "1\na\nb\n2\n", "1\nx\ny\n2\n"
    local function split_pair(index)
        local union = model(SPLIT_HEAD, SPLIT_WORK, { h(2, { "a", "b" }, 2, { "x", "y" }) })
        return union, model(SPLIT_HEAD, index, {})
    end

    it("splits a replacement of equal length row by row", function()
        local union, cached = split_pair(SPLIT_HEAD)
        local text = stage.select_index(union, cached, sel({ 2 }, { 2 }), true)
        assert.are.equal("1\nx\nb\n2\n", text)
    end)

    it("stages the rest of a hunk staged in part", function()
        local union, cached = split_pair("1\nx\nb\n2\n")
        local text = stage.select_index(union, cached, sel({ 3 }, { 3 }), true)
        assert.are.equal(SPLIT_WORK, text)
    end)

    it("unstages part of a staged hunk", function()
        local union, cached = split_pair(SPLIT_WORK)
        local text = stage.select_index(union, cached, sel({ 3 }, { 3 }), false)
        assert.are.equal("1\nx\nb\n2\n", text)
    end)

    it("puts held new lines after the kept old lines when the sides differ in length", function()
        local head = "1\na\nb\nc\n2\n"
        local union = model(head, "1\nx\n2\n", { h(2, { "a", "b", "c" }, 2, { "x" }) })
        local text = stage.select_index(union, model(head, head, {}), sel({}, { 2 }), true)
        assert.are.equal("1\na\nb\nc\nx\n2\n", text)
    end)

    it("ends an unterminated HEAD line once a line follows it", function()
        local union = model("1\na", "1\nx\ny\n", { h(2, { "a" }, 2, { "x", "y" }) })
        local cached = model("1\na", "1\na", {})
        assert.are.equal("1\na\nx\n", stage.select_index(union, cached, sel({}, { 2 }), true))
    end)

    it("leaves a worktree's unterminated last line unterminated", function()
        local union = model("1\na\n", "1\nx\ny", { h(2, { "a" }, 2, { "x", "y" }) })
        local cached = model("1\na\n", "1\na\n", {})
        assert.are.equal("1\na\ny", stage.select_index(union, cached, sel({}, { 3 }), true))
    end)

    it("keeps the index's block at every hunk the selection misses", function()
        local union, cached = pairs_of("1\n2\n3\n4\n5y\n")
        local text = stage.select_index(union, cached, sel({ 2 }, { 2 }), true)
        assert.are.equal(WORK, text)
    end)

    it("gives nothing for a selection with nothing to move", function()
        local union, cached = pairs_of(HEAD)
        local text, refusal = stage.select_index(union, cached, sel({ 3 }, { 3 }), true)
        assert.is_nil(text)
        assert.is_nil(refusal)
    end)

    it("leaves an uncut index alone when it changes nothing at the hunks unstaged", function()
        local union = (pairs_of(HEAD))
        local index = "1\n2\n3x\n4\n5\n"
        local cached = model(HEAD, index, { h(3, { "3" }, 3, { "3x" }) })
        local text, refusal = stage.select_index(union, cached, sel({ 2 }, { 2 }), false)
        assert.is_nil(text)
        assert.is_nil(refusal)
    end)

    it("stages into an uncut index below a change that adds lines", function()
        local union = (pairs_of(HEAD))
        local index = "1\n2\n3x\n3y\n4\n5\n"
        local cached = model(HEAD, index, { h(3, { "3" }, 3, { "3x", "3y" }) })
        local text, refusal = stage.select_index(union, cached, sel({ 5 }, { 5 }), true)
        assert.is_nil(refusal)
        assert.are.equal("1\n2\n3x\n3y\n4\n5y\n", text)
    end)

    it("stages part of a hunk into an uncut index", function()
        local union = model(HEAD, "1\n2x\n3\n4\nA\nB\n5\n", {
            h(2, { "2" }, 2, { "2x" }),
            h(4, {}, 5, { "A", "B" }),
        })
        local index = "1\n2\n3x\n4\n5\n"
        local cached = model(HEAD, index, { h(3, { "3" }, 3, { "3x" }) })
        local text, refusal = stage.select_index(union, cached, sel({}, { 6 }), true)
        assert.is_nil(refusal)
        assert.are.equal("1\n2\n3x\n4\nB\n5\n", text)
    end)

    it("refuses to unstage from an uncut index that changes a selected hunk", function()
        local union = (pairs_of(HEAD))
        local index = "1\n2z\n3x\n4\n5\n"
        local cached = model(HEAD, index, { h(2, { "2", "3" }, 2, { "2z", "3x" }) })
        local text, refusal = stage.select_index(union, cached, sel({ 2 }, { 2 }), false)
        assert.is_nil(text)
        assert.are.equal("between", refusal)
        text, refusal = stage.select_index(union, cached, sel({ 2 }, { 2 }), true)
        assert.is_nil(text)
        assert.are.equal("between", refusal)
    end)

    it("refuses a hunk whose index block holds a line neither side has", function()
        local union = model("1\na\n2\n", "1\nx\n2\n", { h(2, { "a" }, 2, { "x" }) })
        local cached = model("1\na\n2\n", "1\nz\n2\n", {})
        local text, refusal = stage.select_index(union, cached, sel({}, { 2 }), true)
        assert.is_nil(text)
        assert.are.equal("hidden", refusal)
    end)
end)

describe("model.stage.select_worktree", function()
    it("drops part of an insertion", function()
        local union = model("1\n2\n", "1\nA\nB\nC\n2\n", { h(1, {}, 2, { "A", "B", "C" }) })
        local out = stage.select_worktree(union, sel({}, { 3 }))
        assert.are.equal("1\nA\nC\n2\n", out.old_text)
        assert.are.equal(union.new_text, out.new_text)
        assert.are.same({ h(2, { "A", "C" }, 2, { "A", "B", "C" }) }, out.hunks)
    end)

    it("puts back part of a deletion", function()
        local union = model("1\na\nb\nc\n2\n", "1\n2\n", { h(2, { "a", "b", "c" }, 1, {}) })
        local out = stage.select_worktree(union, sel({ 3 }, {}))
        assert.are.equal("1\nb\n2\n", out.old_text)
        assert.are.same({ h(2, { "b" }, 1, {}) }, out.hunks)
    end)

    it("reverts a replacement of equal length row by row", function()
        local union = model("1\na\nb\n2\n", "1\nx\ny\n2\n", { h(2, { "a", "b" }, 2, { "x", "y" }) })
        local out = stage.select_worktree(union, sel({ 2 }, { 2 }))
        assert.are.equal("1\na\ny\n2\n", out.old_text)
        out = stage.select_worktree(union, sel({ 3 }, {}))
        assert.are.equal("1\nx\nb\ny\n2\n", out.old_text)
    end)

    it("puts old lines before new ones when the sides differ in length", function()
        local union = model("1\na\nb\nc\n2\n", "1\nx\n2\n", { h(2, { "a", "b", "c" }, 2, { "x" }) })
        local out = stage.select_worktree(union, sel({ 2 }, {}))
        assert.are.equal("1\na\nx\n2\n", out.old_text)
        assert.are.same({ h(2, { "a", "x" }, 2, { "x" }) }, out.hunks)
    end)

    it("places a later hunk where the earlier reverts leave it", function()
        local union = model("1\n2\n3\n", "1\nA\nB\n2\n3x\n", {
            h(1, {}, 2, { "A", "B" }),
            h(3, { "3" }, 5, { "3x" }),
        })
        local out = stage.select_worktree(union, sel({ 3 }, { 2, 5 }))
        assert.are.equal("1\nB\n2\n3\n", out.old_text)
        assert.are.same({ h(2, { "B" }, 2, { "A", "B" }), h(4, { "3" }, 5, { "3x" }) }, out.hunks)
    end)

    it("names the line before a block the revert empties", function()
        local union = model("1\n2\n", "1\nA\n2\n", { h(1, {}, 2, { "A" }) })
        local out = stage.select_worktree(union, sel({}, { 2 }))
        assert.are.equal("1\n2\n", out.old_text)
        assert.are.same({ h(1, {}, 2, { "A" }) }, out.hunks)
    end)

    it("ends an unterminated HEAD line once a line follows it", function()
        local union = model("1\na", "1\nx\n", { h(2, { "a" }, 2, { "x" }) })
        local out = stage.select_worktree(union, sel({ 2 }, {}))
        assert.are.equal("1\na\nx\n", out.old_text)
        assert.are.same({ h(2, { "a", "x" }, 2, { "x" }) }, out.hunks)
    end)

    it("keeps a reverted last line unterminated as HEAD has it", function()
        local union = model("1\na", "1\nx\n", { h(2, { "a" }, 2, { "x" }) })
        local out = stage.select_worktree(union, sel({ 2 }, { 2 }))
        assert.are.equal("1\na", out.old_text)
        assert.are.same({ h(2, { "a" }, 2, { "x" }) }, out.hunks)
    end)

    it("leaves a worktree's unterminated last line as the file's end", function()
        local union = model("1\na\n", "1\nx\ny", { h(2, { "a" }, 2, { "x", "y" }) })
        local out = stage.select_worktree(union, sel({}, { 2 }))
        assert.are.equal("1\ny", out.old_text)
        assert.are.same({ h(2, { "y" }, 2, { "x", "y" }) }, out.hunks)
    end)

    it("gives nothing for a selection that touches no hunk", function()
        local union = model("1\na\n2\n", "1\nx\n2\n", { h(2, { "a" }, 2, { "x" }) })
        assert.is_nil(stage.select_worktree(union, sel({ 1 }, { 3 })))
    end)
end)
