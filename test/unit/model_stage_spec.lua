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
end)
