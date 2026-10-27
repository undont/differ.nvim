-- s, u and X through the selection core on hunks of identical lines, where the
-- read-back may mark another line of a run than the op moved
local content = require("differ.git.content")
local fuzz = require("test.fuzz.stage")
local selected = require("differ.git.staging.selection")

describe("git.staging.selection", function()
    it("unstages a deletion the read-back marks on another line of its run", function()
        local union, cached, unstaged =
            content.union_pairs("/", "f", "a\na\na\n", "a\nx9\na\n", "x9\na")
        local selection = { old = { [3] = true }, new = { [1] = true, [2] = true } }
        local text, after, refusal =
            selected.stage("/", "f", union, cached, unstaged, selection, false)
        assert.is_nil(refusal)
        assert.is_not_nil(after)
        assert.are.equal("a\na\n", text)
    end)

    it("writes every selection on a hunk of identical lines in order, or refuses", function()
        local t = { head = "c\nc\nc\n", index = "c\nd\nc\nc\n", work = "c\nd\nx4\nx4\n" }
        local rows = fuzz.rows((content.union_pairs("/", "f", t.head, t.index, t.work)))
        local written = 0
        for first = 1, #rows do
            for last = first, #rows do
                local selection = { old = {}, new = {} }
                for i = first, last do
                    selection[rows[i].side][rows[i].line] = true
                end
                for _, op in ipairs(fuzz.OPS) do
                    local outcome = fuzz.run_op(t, op, selection)
                    if outcome.kind == "written" then
                        written = written + 1
                        assert.are_not.equal("c\nc\nd\nx4\n", outcome.index)
                        assert.is_true(fuzz.matches(t, outcome), op)
                    end
                end
            end
        end
        assert.is_true(written > 0)
    end)

    describe("on HEAD c c c, index c d c c, worktree c d x4 x4", function()
        local function c_pairs()
            return content.union_pairs("/", "f", "c\nc\nc\n", "c\nd\nc\nc\n", "c\nd\nx4\nx4\n")
        end
        local selection = { old = { [3] = true }, new = { [2] = true, [3] = true } }

        it("stages new lines after the index's d", function()
            local union, cached, unstaged = c_pairs()
            local text = selected.stage("/", "f", union, cached, unstaged, selection, true)
            assert.are.equal("c\nd\nc\nx4\n", text)
        end)

        it("refuses an index with the d moved below a c", function()
            local union, cached, unstaged = c_pairs()
            local text = "c\nc\nd\nx4\n"
            local after, refusal =
                selected.checked("/", "f", union, cached, unstaged, selection, true, text)
            assert.is_nil(after)
            assert.are.equal("moves_others", refusal)
        end)
    end)
end)
