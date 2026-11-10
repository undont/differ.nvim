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
        local head_work = (pairs_of(HEAD))
        local blocks = stage.index_blocks(head_work, HEAD)
        assert.are.same({ { "2" }, { "5" } }, blocks)
    end)

    it("gives nil when the index changes a line between the hunks", function()
        local head_work = (pairs_of(HEAD))
        assert.is_nil(stage.index_blocks(head_work, "1\n2\n3x\n4\n5\n"))
    end)
end)

describe("marks_of", function()
    it("draws a file with nothing hidden from its blocks", function()
        local head_work, head_index, index_work = pairs_of("1\n2x\n3\n4\n5\n")
        local m, hidden, hidden_in = stage.marks_of(head_work, head_index, index_work)
        assert.are.same({ [2] = true, [5] = false }, m.old)
        assert.are.same({ [2] = true, [5] = false }, m.new)
        assert.is_false(hidden)
        assert.are.same({}, hidden_in)
    end)

    it("draws a file with hidden lines from the least-cost reading", function()
        -- HEAD b a c x, worktree a c y, and an index with a second a. its blocks put
        -- that a inside the first hunk; the reading matches it as the unchanged line,
        -- and the a after b can as well, so the first hunk may hold it. the drawn
        -- reading hides the second a outside every hunk, so the hunk after it is marked too
        local head_work =
            model("b\na\nc\nx\n", "a\nc\ny\n", { h(1, { "b" }, 0, {}), h(4, { "x" }, 3, { "y" }) })
        local head_index = model(
            "b\na\nc\nx\n",
            "b\na\na\nc\ny\n",
            { h(2, {}, 3, { "a" }), h(4, { "x" }, 5, { "y" }) }
        )
        local index_work =
            model("b\na\na\nc\ny\n", "a\nc\ny\n", { h(1, { "b" }, 0, {}), h(3, { "a" }, 2, {}) })
        local m, hidden, hidden_in, unread = stage.marks_of(head_work, head_index, index_work)
        assert.are.same({ [1] = false, [4] = true }, m.old)
        assert.is_true(hidden)
        assert.are.same({ 1, 2 }, hidden_in)
        assert.is_false(unread)
    end)

    it("marks the hunks either side of an unchanged line the index lacks", function()
        local head_work, head_index, index_work = pairs_of("1\n2\n4\n5\n")
        local _, hidden, hidden_in = stage.marks_of(head_work, head_index, index_work)
        assert.is_true(hidden)
        assert.are.same({ 1, 2 }, hidden_in)
    end)

    it("marks the hunks either side of an index line between unchanged lines", function()
        local head_work, head_index, index_work = pairs_of("1\n2\n3\nq\n4\n5\n")
        local _, hidden, hidden_in = stage.marks_of(head_work, head_index, index_work)
        assert.is_true(hidden)
        assert.are.same({ 1, 2 }, hidden_in)
    end)

    it("marks only the hunk after a missing first line", function()
        local head_work, head_index, index_work = pairs_of("2\n3\n4\n5\n")
        local _, hidden, hidden_in = stage.marks_of(head_work, head_index, index_work)
        assert.is_true(hidden)
        assert.are.same({ 1 }, hidden_in)
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
        local head_work = model(text(head), text(work), { edit })
        local head_index = model(text(head), text(index), { h(0, {}, 1, { "x" }) })
        local index_work = model(
            text(index),
            text(work),
            { h(1, { "x" }, 0, {}), h(1101, { "l" }, 1100, { "z" }) }
        )
        local m, hidden, hidden_in, unread = stage.marks_of(head_work, head_index, index_work)
        assert.are.same({ [1100] = false }, m.old)
        assert.is_true(hidden)
        assert.are.same({}, hidden_in)
        assert.is_true(unread)
    end)
end)

describe("next_index", function()
    it("stages a hunk by giving the index the worktree's lines", function()
        local head_work, head_index, index_work = pairs_of(HEAD)
        local text = stage.next_index(head_work, head_index, index_work, head_work.hunks[1], true)
        assert.are.equal("1\n2x\n3\n4\n5\n", text)
    end)

    it("unstages a hunk by giving the index HEAD's lines", function()
        local index = "1\n2x\n3\n4\n5\n"
        local head_work, head_index, index_work = pairs_of(index)
        head_index.hunks = { h(2, { "2" }, 2, { "2x" }) }
        index_work.hunks = { h(5, { "5" }, 5, { "5y" }) }
        local text = stage.next_index(head_work, head_index, index_work, head_work.hunks[1], false)
        assert.are.equal(HEAD, text)
    end)

    -- HEAD "a\nb", worktree "a\nb\n": the hunk is the ending alone
    it("takes the ending with the hunk that reaches the end of the file", function()
        local hunks = { h(2, { "b" }, 2, { "b" }) }
        local head_work = model("a\nb", "a\nb\n", hunks)
        local head_index = model("a\nb", "a\nb", {})
        local index_work = model("a\nb", "a\nb\n", hunks)
        assert.are.equal(
            "a\nb\n",
            stage.next_index(head_work, head_index, index_work, head_work.hunks[1], true)
        )
    end)

    -- HEAD 1..7, index 1 A B C D E 7, worktree 1 A2 3 4 D2 E2 7: the index's B and C
    -- sit between the two HEAD<->worktree hunks, so one HEAD<->index hunk covers both
    it("names the other hunk a pair hunk would carry the op into", function()
        local head = "1\n2\n3\n4\n5\n6\n7\n"
        local index = "1\nA\nB\nC\nD\nE\n7\n"
        local work = "1\nA2\n3\n4\nD2\nE2\n7\n"
        local head_work = model(head, work, {
            h(2, { "2" }, 2, { "A2" }),
            h(5, { "5", "6" }, 5, { "D2", "E2" }),
        })
        local head_index = model(
            head,
            index,
            { h(2, { "2", "3", "4", "5", "6" }, 2, { "A", "B", "C", "D", "E" }) }
        )
        local index_work = model(
            index,
            work,
            { h(2, { "A", "B", "C", "D", "E" }, 2, { "A2", "3", "4", "D2", "E2" }) }
        )
        local text, reaches =
            stage.next_index(head_work, head_index, index_work, head_work.hunks[1], false)
        assert.is_nil(text)
        assert.are.equal(2, reaches)
    end)

    -- HEAD 1 2 x x 5, index 1 x x 5x, worktree 1 2x x 5x: the pairs give hunk 2 nothing
    -- of its own, and the drawn reading holds hunk 2's x and 5x as the slice to replace
    it("takes a hunk's slice in the drawn reading where the index can't be cut", function()
        local head = "1\n2\nx\nx\n5\n"
        local index = "1\nx\nx\n5x\n"
        local work = "1\n2x\nx\n5x\n"
        local head_work = model(head, work, {
            h(2, { "2" }, 2, { "2x" }),
            h(4, { "x", "5" }, 4, { "5x" }),
        })
        local head_index = model(head, index, { h(2, { "2" }, 2, {}), h(5, { "5" }, 4, { "5x" }) })
        local index_work = model(index, work, { h(2, {}, 2, { "2x" }) })
        local text, reaches =
            stage.next_index(head_work, head_index, index_work, head_work.hunks[2], true)
        assert.are.equal("1\nx\n5x\n", text)
        assert.is_nil(reaches)
    end)

    it("never hands back the text the index already holds", function()
        local head_work, head_index, index_work = pairs_of(HEAD)
        -- both hunks are unstaged, so unstaging one has nothing to write
        assert.is_nil(
            stage.next_index(head_work, head_index, index_work, head_work.hunks[1], false)
        )
    end)

    -- HEAD a b c, index a q b c, worktree a b q b c: HEAD<->worktree inserts q b after b,
    -- and the index's only b is HEAD's, with q hidden before it
    it("keeps HEAD's unchanged line the index holds beside an inserted hunk", function()
        local head_work = model("a\nb\nc\n", "a\nb\nq\nb\nc\n", { h(2, {}, 3, { "q", "b" }) })
        local head_index = model("a\nb\nc\n", "a\nq\nb\nc\n", { h(1, {}, 2, { "q" }) })
        local index_work = model("a\nq\nb\nc\n", "a\nb\nq\nb\nc\n", { h(1, {}, 2, { "b" }) })
        assert.is_nil(
            stage.next_index(head_work, head_index, index_work, head_work.hunks[1], false)
        )
    end)
end)

describe("model.stage.drop_lines", function()
    it("takes back only the lines asked for inside a block of the same length", function()
        local head_index = model("1\n2\n3\n4\n5\n", "1\nB\nC\nD\n5\n", {
            h(2, { "2", "3", "4" }, 2, { "B", "C", "D" }),
        })
        assert.are.equal("1\nB\n3\nD\n5\n", stage.drop_lines(head_index, 1, 3, 3))
    end)

    it("keeps every other staged hunk", function()
        local head_index = model("1\n2\n3\n4\n5\n", "X\n2\nC\nD\n5\n", {
            h(1, { "1" }, 1, { "X" }),
            h(3, { "3", "4" }, 3, { "C", "D" }),
        })
        assert.are.equal("X\n2\n3\nD\n5\n", stage.drop_lines(head_index, 2, 3, 3))
    end)

    it("takes back a block's last line and keeps the file's ending", function()
        local head_index = model("1\n2", "1\nB", { h(2, { "2" }, 2, { "B" }) })
        assert.are.equal("1\n2", stage.drop_lines(head_index, 1, 2, 2))
    end)
end)

describe("model.stage.select_index", function()
    it("stages part of an insertion", function()
        local head_work = model("1\n2\n", "1\nA\nB\nC\n2\n", { h(1, {}, 2, { "A", "B", "C" }) })
        local head_index = model("1\n2\n", "1\n2\n", {})
        assert.are.equal(
            "1\nB\n2\n",
            stage.select_index(head_work, head_index, sel({}, { 3 }), true)
        )
    end)

    it("stages part of a deletion", function()
        local head_work = model("1\na\nb\nc\n2\n", "1\n2\n", { h(2, { "a", "b", "c" }, 1, {}) })
        local head_index = model("1\na\nb\nc\n2\n", "1\na\nb\nc\n2\n", {})
        local text = stage.select_index(head_work, head_index, sel({ 3 }, {}), true)
        assert.are.equal("1\na\nc\n2\n", text)
    end)

    -- HEAD 1 a b 2, worktree 1 x y 2: rows a|x and b|y
    local SPLIT_HEAD, SPLIT_WORK = "1\na\nb\n2\n", "1\nx\ny\n2\n"
    local function split_pair(index)
        local head_work = model(SPLIT_HEAD, SPLIT_WORK, { h(2, { "a", "b" }, 2, { "x", "y" }) })
        return head_work, model(SPLIT_HEAD, index, {})
    end

    it("splits a replacement of equal length row by row", function()
        local head_work, head_index = split_pair(SPLIT_HEAD)
        local text = stage.select_index(head_work, head_index, sel({ 2 }, { 2 }), true)
        assert.are.equal("1\nx\nb\n2\n", text)
    end)

    it("stages the rest of a hunk staged in part", function()
        local head_work, head_index = split_pair("1\nx\nb\n2\n")
        local text = stage.select_index(head_work, head_index, sel({ 3 }, { 3 }), true)
        assert.are.equal(SPLIT_WORK, text)
    end)

    it("unstages part of a staged hunk", function()
        local head_work, head_index = split_pair(SPLIT_WORK)
        local text = stage.select_index(head_work, head_index, sel({ 3 }, { 3 }), false)
        assert.are.equal("1\nx\nb\n2\n", text)
    end)

    it("puts held new lines after the kept old lines when the sides differ in length", function()
        local head = "1\na\nb\nc\n2\n"
        local head_work = model(head, "1\nx\n2\n", { h(2, { "a", "b", "c" }, 2, { "x" }) })
        local text = stage.select_index(head_work, model(head, head, {}), sel({}, { 2 }), true)
        assert.are.equal("1\na\nb\nc\nx\n2\n", text)
    end)

    -- HEAD a d d, index a x3 d, worktree a x3 c x5
    local function reorder_pair()
        local head, index = "a\nd\nd\n", "a\nx3\nd\n"
        local head_work =
            model(head, "a\nx3\nc\nx5\n", { h(2, { "d", "d" }, 2, { "x3", "c", "x5" }) })
        return head_work, model(head, index, {})
    end

    it("stages new lines after the index's own lines, keeping their order", function()
        local head_work, head_index = reorder_pair()
        local text = stage.select_index(head_work, head_index, sel({}, { 3, 4 }), true)
        assert.are.equal("a\nx3\nd\nc\nx5\n", text)
    end)

    it("gives nothing for an unstage of lines the index doesn't hold", function()
        local head_work, head_index = reorder_pair()
        local text, refusal = stage.select_index(head_work, head_index, sel({}, { 3, 4 }), false)
        assert.is_nil(text)
        assert.is_nil(refusal)
    end)

    it("leaves a held new line above a kept old line where the index has it", function()
        local head = "l14\nl12\nl9\nl29\n"
        local head_work =
            model(head, "l14\nl33\nx7\nl9\nl29\n", { h(2, { "l12" }, 2, { "l33", "x7" }) })
        local head_index = model(head, "l14\nl33\nl12\nl9\nl29\n", {})
        local text, refusal = stage.select_index(head_work, head_index, sel({}, { 3 }), false)
        assert.is_nil(text)
        assert.is_nil(refusal)
    end)

    it("keeps a staged line in the middle of a hunk whose sides differ in length", function()
        local head = "1\na\nb\nc\n2\n"
        local head_work = model(head, "1\nx\ny\n2\n", { h(2, { "a", "b", "c" }, 2, { "x", "y" }) })
        local head_index = model(head, "1\na\nx\nb\nc\n2\n", {})
        local text = stage.select_index(head_work, head_index, sel({ 3 }, { 3 }), true)
        assert.are.equal("1\na\nx\nc\ny\n2\n", text)
    end)

    it("ends an unterminated HEAD line once a line follows it", function()
        local head_work = model("1\na", "1\nx\ny\n", { h(2, { "a" }, 2, { "x", "y" }) })
        local head_index = model("1\na", "1\na", {})
        assert.are.equal(
            "1\na\nx\n",
            stage.select_index(head_work, head_index, sel({}, { 2 }), true)
        )
    end)

    it("leaves a worktree's unterminated last line unterminated", function()
        local head_work = model("1\na\n", "1\nx\ny", { h(2, { "a" }, 2, { "x", "y" }) })
        local head_index = model("1\na\n", "1\na\n", {})
        assert.are.equal("1\na\ny", stage.select_index(head_work, head_index, sel({}, { 3 }), true))
    end)

    it("keeps the index's block at every hunk the selection misses", function()
        local head_work, head_index = pairs_of("1\n2\n3\n4\n5y\n")
        local text = stage.select_index(head_work, head_index, sel({ 2 }, { 2 }), true)
        assert.are.equal(WORK, text)
    end)

    it("gives nothing for a selection with nothing to move", function()
        local head_work, head_index = pairs_of(HEAD)
        local text, refusal = stage.select_index(head_work, head_index, sel({ 3 }, { 3 }), true)
        assert.is_nil(text)
        assert.is_nil(refusal)
    end)

    it("refuses where the view reads a staged line next to the hunk into it", function()
        local head_work = (pairs_of(HEAD))
        local index = "1\n2\n3x\n4\n5\n"
        local head_index = model(HEAD, index, { h(3, { "3" }, 3, { "3x" }) })
        for _, take in ipairs({ true, false }) do
            local text, refusal = stage.select_index(head_work, head_index, sel({ 2 }, { 2 }), take)
            assert.is_nil(text)
            assert.are.equal("hidden", refusal)
        end
    end)

    describe("with a staged line away from the selection", function()
        local head = "1\n2\n3\n4\n5\n6\n7\n"
        local head_work = model(head, "1\n2\n3\n4\n5\n6x\n7\n", { h(6, { "6" }, 6, { "6x" }) })

        it("stages the selected hunk", function()
            local head_index = model(head, "1\n1q\n2\n3\n4\n5\n6\n7\n", { h(1, {}, 2, { "1q" }) })
            local text, refusal = stage.select_index(head_work, head_index, sel({ 6 }, { 6 }), true)
            assert.is_nil(refusal)
            assert.are.equal("1\n1q\n2\n3\n4\n5\n6x\n7\n", text)
        end)

        it("unstages the selected hunk", function()
            local head_index = model(head, "1\n1q\n2\n3\n4\n5\n6x\n7\n", {
                h(1, {}, 2, { "1q" }),
                h(6, { "6" }, 7, { "6x" }),
            })
            local text, refusal =
                stage.select_index(head_work, head_index, sel({ 6 }, { 6 }), false)
            assert.is_nil(refusal)
            assert.are.equal("1\n1q\n2\n3\n4\n5\n6\n7\n", text)
        end)
    end)

    it("stages where the view reads the hunk when the lines around it repeat", function()
        local head = "1\nx\n2\n1\nx\n2\n9\n"
        local head_work = model(head, "1\nX\n2\n1\nx\n2\n9\n", { h(2, { "x" }, 2, { "X" }) })
        local head_index = model(head, "1\nx\n2\n1\nx\n2\n9z\n", { h(7, { "9" }, 7, { "9z" }) })
        local text, refusal = stage.select_index(head_work, head_index, sel({ 2 }, { 2 }), true)
        assert.is_nil(refusal)
        assert.are.equal("1\nX\n2\n1\nx\n2\n9z\n", text)
    end)

    it("unstages a staged line the view reads into the selected hunk", function()
        local head_work = model("c\n", "b\nc\nc\nd\n", {
            h(0, {}, 1, { "b" }),
            h(1, {}, 3, { "c", "d" }),
        })
        local head_index = model("c\n", "c\nc\n", { h(1, {}, 2, { "c" }) })
        local text, refusal = stage.select_index(head_work, head_index, sel({}, { 3, 4 }), false)
        assert.is_nil(refusal)
        assert.are.equal("c\n", text)
    end)

    it(
        "refuses rather than gives nothing where the view reads a hidden line into the hunk",
        function()
            local head_work = model("b\nx\n", "e\nb\n", {
                h(0, {}, 1, { "e" }),
                h(2, { "x" }, 2, {}),
            })
            local head_index = model("b\nx\n", "b\nb\n", { h(2, { "x" }, 2, { "b" }) })
            local text, refusal = stage.select_index(head_work, head_index, sel({ 2 }, {}), true)
            assert.is_nil(text)
            assert.are.equal("hidden", refusal)
        end
    )

    it("refuses a selection in an uncut file too big to read", function()
        local olds, news = {}, {}
        for k = 1, 100 do
            olds[k], news[k] = "o" .. k, "n" .. k
        end
        local old, new = table.concat(olds, "\n"), table.concat(news, "\n")
        local head = "1\n2\n3\n" .. old .. "\n4\n5\n6\n"
        local head_work = model(head, "1\n2x\n3\n" .. new .. "\n4\n5\n6\n", {
            h(2, { "2" }, 2, { "2x" }),
            h(4, olds, 4, news),
        })
        local index = "1\n2\n3\n" .. old .. "\n4\n5q\n6\n"
        local head_index = model(head, index, { h(105, { "5" }, 105, { "5q" }) })
        assert.is_nil(stage.reading(head_work, index))
        local text, refusal = stage.select_index(head_work, head_index, sel({ 2 }, { 2 }), true)
        assert.is_nil(text)
        assert.are.equal("between", refusal)
    end)

    it("stages into an uncut index below a change that adds lines", function()
        local head_work = (pairs_of(HEAD))
        local index = "1\n2\n3x\n3y\n4\n5\n"
        local head_index = model(HEAD, index, { h(3, { "3" }, 3, { "3x", "3y" }) })
        local text, refusal = stage.select_index(head_work, head_index, sel({ 5 }, { 5 }), true)
        assert.is_nil(refusal)
        assert.are.equal("1\n2\n3x\n3y\n4\n5y\n", text)
    end)

    it("stages part of a hunk into an uncut index", function()
        local head_work = model(HEAD, "1\n2x\n3\n4\nA\nB\n5\n", {
            h(2, { "2" }, 2, { "2x" }),
            h(4, {}, 5, { "A", "B" }),
        })
        local index = "1\n2\n3x\n4\n5\n"
        local head_index = model(HEAD, index, { h(3, { "3" }, 3, { "3x" }) })
        local text, refusal = stage.select_index(head_work, head_index, sel({}, { 6 }), true)
        assert.is_nil(refusal)
        assert.are.equal("1\n2\n3x\n4\nB\n5\n", text)
    end)

    it("refuses an uncut index that changes a selected hunk to neither side", function()
        local head_work = (pairs_of(HEAD))
        local index = "1\n2z\n3x\n4\n5\n"
        local head_index = model(HEAD, index, { h(2, { "2", "3" }, 2, { "2z", "3x" }) })
        for _, take in ipairs({ true, false }) do
            local text, refusal = stage.select_index(head_work, head_index, sel({ 2 }, { 2 }), take)
            assert.is_nil(text)
            assert.are.equal("hidden", refusal)
        end
    end)

    it("refuses a hunk whose index block holds a line neither side has", function()
        local head_work = model("1\na\n2\n", "1\nx\n2\n", { h(2, { "a" }, 2, { "x" }) })
        local head_index = model("1\na\n2\n", "1\nz\n2\n", {})
        local text, refusal = stage.select_index(head_work, head_index, sel({}, { 2 }), true)
        assert.is_nil(text)
        assert.are.equal("hidden", refusal)
    end)

    -- HEAD 1 b, index and worktree 1 b with a newline: -b / +b differ by the ending alone
    local function newline_pair()
        local head_work = model("1\nb", "1\nb\n", { h(2, { "b" }, 2, { "b" }) })
        return head_work, model("1\nb", "1\nb\n", {})
    end

    it("refuses one row of a line and its newline change", function()
        local head_work, head_index = newline_pair()
        for _, s in ipairs({ sel({ 2 }, {}), sel({}, { 2 }) }) do
            local text, refusal = stage.select_index(head_work, head_index, s, false)
            assert.is_nil(text)
            assert.are.equal("split_ending", refusal)
        end
    end)

    it("unstages a line and its newline change together", function()
        local head_work, head_index = newline_pair()
        assert.are.equal(
            "1\nb",
            stage.select_index(head_work, head_index, sel({ 2 }, { 2 }), false)
        )
    end)

    it("gives nothing for one row of a newline change with nothing to move", function()
        local head_work = model("1\nb", "1\nb\n", { h(2, { "b" }, 2, { "b" }) })
        local head_index = model("1\nb", "1\nb", {})
        local text, refusal = stage.select_index(head_work, head_index, sel({ 2 }, {}), false)
        assert.is_nil(text)
        assert.is_nil(refusal)
    end)

    it("refuses to bring back an unterminated line with a staged line after it", function()
        local head_work = model("b", "b\ne\n", { h(1, { "b" }, 1, { "b", "e" }) })
        local head_index = model("b", "b\ne\n", {})
        local text, refusal = stage.select_index(head_work, head_index, sel({ 1 }, { 1 }), false)
        assert.is_nil(text)
        assert.are.equal("ending_after", refusal)
    end)

    it("stages a new line above the worktree's unterminated line", function()
        local head_work = model("1\na\nb\n", "1\nc\nb", { h(2, { "a", "b" }, 2, { "c", "b" }) })
        local head_index = model("1\na\nb\n", "1\na\nb\n", {})
        assert.are.equal(
            "1\nc\nb",
            stage.select_index(head_work, head_index, sel({ 2, 3 }, { 2, 3 }), true)
        )
    end)

    it("refuses to stage a line after an unterminated line it keeps", function()
        local head_work = model("1\nb", "1\nb\nc\n", { h(2, { "b" }, 2, { "b", "c" }) })
        local head_index = model("1\nb", "1\nb", {})
        local text, refusal = stage.select_index(head_work, head_index, sel({}, { 3 }), true)
        assert.is_nil(text)
        assert.are.equal("ending", refusal)
    end)
end)

describe("model.stage.select_worktree", function()
    it("drops part of an insertion", function()
        local head_work = model("1\n2\n", "1\nA\nB\nC\n2\n", { h(1, {}, 2, { "A", "B", "C" }) })
        local out = stage.select_worktree(head_work, sel({}, { 3 }))
        assert.are.equal("1\nA\nC\n2\n", out.old_text)
        assert.are.equal(head_work.new_text, out.new_text)
        assert.are.same({ h(2, { "A", "C" }, 2, { "A", "B", "C" }) }, out.hunks)
    end)

    it("puts back part of a deletion", function()
        local head_work = model("1\na\nb\nc\n2\n", "1\n2\n", { h(2, { "a", "b", "c" }, 1, {}) })
        local out = stage.select_worktree(head_work, sel({ 3 }, {}))
        assert.are.equal("1\nb\n2\n", out.old_text)
        assert.are.same({ h(2, { "b" }, 1, {}) }, out.hunks)
    end)

    it("reverts a replacement of equal length row by row", function()
        local head_work =
            model("1\na\nb\n2\n", "1\nx\ny\n2\n", { h(2, { "a", "b" }, 2, { "x", "y" }) })
        local out = stage.select_worktree(head_work, sel({ 2 }, { 2 }))
        assert.are.equal("1\na\ny\n2\n", out.old_text)
        out = stage.select_worktree(head_work, sel({ 3 }, {}))
        assert.are.equal("1\nx\nb\ny\n2\n", out.old_text)
    end)

    it("puts old lines before new ones when the sides differ in length", function()
        local head_work =
            model("1\na\nb\nc\n2\n", "1\nx\n2\n", { h(2, { "a", "b", "c" }, 2, { "x" }) })
        local out = stage.select_worktree(head_work, sel({ 2 }, {}))
        assert.are.equal("1\na\nx\n2\n", out.old_text)
        assert.are.same({ h(2, { "a", "x" }, 2, { "x" }) }, out.hunks)
    end)

    it("places a later hunk where the earlier reverts leave it", function()
        local head_work = model("1\n2\n3\n", "1\nA\nB\n2\n3x\n", {
            h(1, {}, 2, { "A", "B" }),
            h(3, { "3" }, 5, { "3x" }),
        })
        local out = stage.select_worktree(head_work, sel({ 3 }, { 2, 5 }))
        assert.are.equal("1\nB\n2\n3\n", out.old_text)
        assert.are.same({ h(2, { "B" }, 2, { "A", "B" }), h(4, { "3" }, 5, { "3x" }) }, out.hunks)
    end)

    it("names the line before a block the revert empties", function()
        local head_work = model("1\n2\n", "1\nA\n2\n", { h(1, {}, 2, { "A" }) })
        local out = stage.select_worktree(head_work, sel({}, { 2 }))
        assert.are.equal("1\n2\n", out.old_text)
        assert.are.same({ h(1, {}, 2, { "A" }) }, out.hunks)
    end)

    it("ends an unterminated HEAD line once a line follows it", function()
        local head_work = model("1\na", "1\nx\n", { h(2, { "a" }, 2, { "x" }) })
        local out = stage.select_worktree(head_work, sel({ 2 }, {}))
        assert.are.equal("1\na\nx\n", out.old_text)
        assert.are.same({ h(2, { "a", "x" }, 2, { "x" }) }, out.hunks)
    end)

    it("keeps a reverted last line unterminated as HEAD has it", function()
        local head_work = model("1\na", "1\nx\n", { h(2, { "a" }, 2, { "x" }) })
        local out = stage.select_worktree(head_work, sel({ 2 }, { 2 }))
        assert.are.equal("1\na", out.old_text)
        assert.are.same({ h(2, { "a" }, 2, { "x" }) }, out.hunks)
    end)

    it("leaves a worktree's unterminated last line as the file's end", function()
        local head_work = model("1\na\n", "1\nx\ny", { h(2, { "a" }, 2, { "x", "y" }) })
        local out = stage.select_worktree(head_work, sel({}, { 2 }))
        assert.are.equal("1\ny", out.old_text)
        assert.are.same({ h(2, { "y" }, 2, { "x", "y" }) }, out.hunks)
    end)

    it("gives nothing for a selection that touches no hunk", function()
        local head_work = model("1\na\n2\n", "1\nx\n2\n", { h(2, { "a" }, 2, { "x" }) })
        assert.is_nil(stage.select_worktree(head_work, sel({ 1 }, { 3 })))
    end)

    -- HEAD 1 b c, worktree 1 b unterminated: -b -c / +b, where -b / +b is b's newline
    local function dropped_newline()
        return model("1\nb\nc\n", "1\nb", { h(2, { "b", "c" }, 2, { "b" }) })
    end

    it("refuses one row of a line and its newline change", function()
        local out, refusal = stage.select_worktree(dropped_newline(), sel({}, { 2 }))
        assert.is_nil(out)
        assert.are.equal("split_ending", refusal)
    end)

    it("refuses to put a line back after the worktree's unterminated line", function()
        local out, refusal = stage.select_worktree(dropped_newline(), sel({ 3 }, {}))
        assert.is_nil(out)
        assert.are.equal("ending", refusal)
    end)

    it("refuses to bring back an unterminated line above a line it keeps", function()
        local head_work = model("b", "b\ne\n", { h(1, { "b" }, 1, { "b", "e" }) })
        local out, refusal = stage.select_worktree(head_work, sel({ 1 }, { 1 }))
        assert.is_nil(out)
        assert.are.equal("ending_after", refusal)
    end)

    it("reverts a line and its newline change together", function()
        local out = stage.select_worktree(dropped_newline(), sel({ 2 }, { 2 }))
        assert.are.equal("1\nb\n", out.old_text)
    end)

    -- HEAD 1 c c 2, index 1 e c 2, worktree 1 e 2: the index's c is HEAD's second
    local function index_order_pair(index)
        local head = "1\nc\nc\n2\n"
        local head_work = model(head, "1\ne\n2\n", { h(2, { "c", "c" }, 2, { "e" }) })
        return head_work, model(head, index, {})
    end

    it("restores lines in the index's order, as the index takes them back", function()
        local head_work, head_index = index_order_pair("1\ne\nc\n2\n")
        local selection = sel({ 2, 3 }, {})
        local out =
            stage.select_worktree(head_work, selection, stage.index_origins(head_work, head_index))
        assert.are.equal("1\nc\ne\nc\n2\n", out.old_text)
        assert.are.equal(
            "1\nc\ne\nc\n2\n",
            stage.select_index(head_work, head_index, selection, false)
        )
    end)

    it("restores old lines first where the index holds none of the hunk", function()
        local head_work, head_index = index_order_pair("1\nc\nc\n2\n")
        local selection = sel({ 2, 3 }, {})
        local origins = stage.index_origins(head_work, head_index)
        local out = stage.select_worktree(head_work, selection, origins)
        assert.are.equal("1\nc\nc\ne\n2\n", out.old_text)
    end)

    it("restores lines in the index's order with a staged line away from them", function()
        local head = "1\nc\nc\n2\n9\n"
        local head_work = model(head, "1\ne\n2\n9\n", { h(2, { "c", "c" }, 2, { "e" }) })
        local head_index = model(head, "1\ne\nc\n2\n9z\n", {
            h(2, { "c" }, 2, { "e" }),
            h(5, { "9" }, 5, { "9z" }),
        })
        local selection = sel({ 2, 3 }, {})
        local origins = stage.index_origins(head_work, head_index)
        local out = stage.select_worktree(head_work, selection, origins)
        assert.are.equal("1\nc\ne\nc\n2\n9\n", out.old_text)
        assert.are.equal(
            "1\nc\ne\nc\n2\n9z\n",
            stage.select_index(head_work, head_index, selection, false)
        )
    end)
end)
