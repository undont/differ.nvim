-- s, u and X through the selection core: hunks of identical lines, where the
-- read-back may mark another line of a run than the op moved, and selections the
-- drawn marks still need moved
local content = require("differ.git.content")
local fuzz = require("test.fuzz.stage")
local selected = require("differ.git.staging.selection")

describe("git.staging.selection", function()
    it("refuses to bring back an unterminated line with a staged line after it", function()
        -- HEAD's unterminated b and the worktree's terminated b are one token
        local union, cached, unstaged = content.union_pairs("/", "f", "b", "b\ne\n", "b\ne\n")
        local selection = { old = { [1] = true }, new = { [1] = true } }
        local text, after, refusal =
            selected.stage("/", "f", union, cached, unstaged, selection, false)
        assert.is_nil(text)
        assert.is_nil(after)
        assert.are.equal("ending_after", refusal)
    end)

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

    -- the index holds HEAD's b where the union shows it deleted
    describe("on HEAD a b, index b a, worktree a", function()
        local t = { head = "a\nb\n", index = "b\na\n", work = "a\n" }
        local selection = { old = { [2] = true }, new = {} }

        for _, op in ipairs({ "u", "X" }) do
            it(op .. " on - b refuses rather than guess where b went", function()
                local outcome = fuzz.run_op(t, op, selection)
                assert.are.equal("refused", outcome.kind)
                assert.are.equal("unshown", outcome.reason)
            end)
        end

        it("hunk u refuses rather than guess where b went", function()
            local union, cached, unstaged = content.union_pairs("/", "f", t.head, t.index, t.work)
            local text = require("differ.model.stage").next_index(
                union,
                cached,
                unstaged,
                union.hunks[1],
                false
            )
            local after, refusal =
                selected.checked("/", "f", union, cached, unstaged, selection, false, text)
            assert.is_nil(after)
            assert.are.equal("unshown", refusal)
        end)
    end)

    describe("on HEAD blank and unterminated b, index b, worktree a and blank", function()
        local t = { head = "\nb", index = "b\n", work = "a\n\n" }
        for _, op in ipairs({ "u", "X" }) do
            it(op .. " on - b refuses rather than guess where b went", function()
                local outcome = fuzz.run_op(t, op, { old = { [2] = true }, new = {} })
                assert.are.equal("refused", outcome.kind)
                assert.are.equal("unshown", outcome.reason)
            end)
        end
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

        -- the worktree's c reads back staged in one hunk, HEAD's third c as a staged
        -- deletion in the next
        it("X on - c - c brings both back with the index as it was", function()
            local t = { head = "c\nc\nc\n", index = "c\nd\nc\nc\n", work = "c\nd\nx4\nx4\n" }
            local outcome = fuzz.run_op(t, "X", { old = { [2] = true, [3] = true }, new = {} })
            assert.are.equal("written", outcome.kind, outcome.reason)
            assert.are.equal("c\nd\nc\nc\n", outcome.index)
            assert.are.equal("c\nd\nc\nc\nx4\nx4\n", outcome.work)
        end)
    end)

    -- the read-back stages HEAD's second b and the worktree's added b, a hunk apart,
    -- where the drawn marks stage the x36 deletion
    describe("on HEAD x29 b x36 b b, index x29 b x36 b b x6, worktree x29 x6 b b b x6", function()
        it("s on - x36 stages the deletion", function()
            local t = {
                head = "x29\nb\nx36\nb\nb\n",
                index = "x29\nb\nx36\nb\nb\nx6\n",
                work = "x29\nx6\nb\nb\nb\nx6\n",
            }
            local outcome = fuzz.run_op(t, "s", { old = { [3] = true }, new = {} })
            assert.are.equal("written", outcome.kind, outcome.reason)
            assert.are.equal("x29\nb\nb\nb\nx6\n", outcome.index)
        end)
    end)
end)
