-- s, u and X through the selection core: hunks of identical lines, where the
-- read-back may mark another line of a run than the op moved, and selections the
-- drawn marks still need moved
local content = require("differ.git.content")
local fuzz = require("test.fuzz.stage")
local selected = require("differ.git.staging.selection")

describe("git.staging.selection", function()
    it("refuses to bring back an unterminated line with a staged line after it", function()
        -- HEAD's unterminated b and the worktree's terminated b are one token
        local head_work, head_index, index_work =
            content.three_diffs("/", "f", "b", "b\ne\n", "b\ne\n")
        local selection = { old = { [1] = true }, new = { [1] = true } }
        local text, after, refusal =
            selected.stage("/", "f", head_work, head_index, index_work, selection, false)
        assert.is_nil(text)
        assert.is_nil(after)
        assert.are.equal("ending_after", refusal)
    end)

    it("unstages a deletion the read-back marks on another line of its run", function()
        local head_work, head_index, index_work =
            content.three_diffs("/", "f", "a\na\na\n", "a\nx9\na\n", "x9\na")
        local selection = { old = { [3] = true }, new = { [1] = true, [2] = true } }
        local text, after, refusal =
            selected.stage("/", "f", head_work, head_index, index_work, selection, false)
        assert.is_nil(refusal)
        assert.is_not_nil(after)
        assert.are.equal("a\na\n", text)
    end)

    it("writes every selection on a hunk of identical lines in order, or refuses", function()
        local t = { head = "c\nc\nc\n", index = "c\nd\nc\nc\n", work = "c\nd\nx4\nx4\n" }
        local rows = fuzz.rows((content.three_diffs("/", "f", t.head, t.index, t.work)))
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

    -- the index holds HEAD's b where HEAD↔worktree shows it deleted
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
            local head_work, head_index, index_work =
                content.three_diffs("/", "f", t.head, t.index, t.work)
            local text = require("differ.model.stage").next_index(
                head_work,
                head_index,
                index_work,
                head_work.hunks[1],
                false
            )
            local after, refusal = selected.checked(
                "/",
                "f",
                head_work,
                head_index,
                index_work,
                selection,
                false,
                text
            )
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
            return content.three_diffs("/", "f", "c\nc\nc\n", "c\nd\nc\nc\n", "c\nd\nx4\nx4\n")
        end
        local selection = { old = { [3] = true }, new = { [2] = true, [3] = true } }

        it("stages new lines after the index's d", function()
            local head_work, head_index, index_work = c_pairs()
            local text =
                selected.stage("/", "f", head_work, head_index, index_work, selection, true)
            assert.are.equal("c\nd\nc\nx4\n", text)
        end)

        it("refuses an index with the d moved below a c", function()
            local head_work, head_index, index_work = c_pairs()
            local text = "c\nc\nd\nx4\n"
            local after, refusal =
                selected.checked("/", "f", head_work, head_index, index_work, selection, true, text)
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

        it("s on - x36 stages the deletion past a line only the index has", function()
            local t = {
                head = "x29\nb\nx36\nb\nb\n",
                index = "x29\nb\nx36\nb\nh\nb\nx6\n",
                work = "x29\nx6\nb\nb\nb\nx6\n",
            }
            local outcome = fuzz.run_op(t, "s", { old = { [3] = true }, new = {} })
            assert.are.equal("written", outcome.kind, outcome.reason)
            assert.are.equal("x29\nb\nb\nh\nb\nx6\n", outcome.index)
        end)
    end)

    -- the read-back pairs a b across hunks with a changed a, kept in the index, between
    -- the paired b and its hunk's edge
    describe("on HEAD a b x2 a b b a, index a b a b b b, worktree a b b b b", function()
        local t = {
            head = "a\nb\nx2\na\nb\nb\na\n",
            index = "a\nb\na\nb\nb\nb\n",
            work = "a\nb\nb\nb\nb\n",
        }

        it("u on - a - b - a + b unstages in place", function()
            local selection = { old = { [4] = true, [5] = true, [7] = true }, new = { [4] = true } }
            local outcome = fuzz.run_op(t, "u", selection)
            assert.are.equal("written", outcome.kind, outcome.reason)
            assert.are.equal("a\nb\na\nb\nb\na\nb\n", outcome.index)
            assert.is_true(fuzz.matches(t, outcome))
        end)

        it("u on - a + b refuses", function()
            local outcome = fuzz.run_op(t, "u", { old = { [7] = true }, new = { [4] = true } })
            assert.are.equal("refused", outcome.kind)
        end)
    end)

    -- X's written texts hold what reverted() marks, where the read-back marks other lines
    -- of them or hides content
    describe("X past a read-back that marks other lines", function()
        it("drops an added a the read-back marks on another a", function()
            local t =
                { head = "b\nc\nb\na\na\na\n", index = "b\nc\nb\na\na\na\n", work = "a\nb\na\na\n" }
            local outcome = fuzz.run_op(t, "X", { old = {}, new = { [1] = true } })
            assert.are.equal("written", outcome.kind, outcome.reason)
            assert.are.equal(t.index, outcome.index)
            assert.are.equal("b\na\na\n", outcome.work)
            assert.is_true(fuzz.matches(t, outcome))
        end)

        it("brings back a staged deletion the read-back pairs differently", function()
            local t = { head = "c\nb\nc\na\nc\nb\n", index = "b\nb\nc\nb\n", work = "b\nb\nc\nb\n" }
            local outcome = fuzz.run_op(t, "X", { old = { [1] = true }, new = {} })
            assert.are.equal("written", outcome.kind, outcome.reason)
            assert.are.equal("c\nb\nb\nc\nb\n", outcome.index)
            assert.are.equal("c\nb\nb\nc\nb\n", outcome.work)
            assert.is_true(fuzz.matches(t, outcome))
        end)

        it("brings back lines where the read-back hides index content", function()
            local t = {
                head = "b\nx7\na\nb\nb\nc\na\nc\n",
                index = "b\nx7\na\nb\nc\nc\n",
                work = "b\nc\nb\nc\nc\n",
            }
            local outcome = fuzz.run_op(t, "X", { old = { [3] = true, [4] = true }, new = {} })
            assert.are.equal("written", outcome.kind, outcome.reason)
            assert.are.equal(t.index, outcome.index)
            assert.are.equal("b\na\nb\nc\nb\nc\nc\n", outcome.work)
            assert.is_true(fuzz.matches(t, outcome))
        end)

        it("refuses a worktree that leaves out a line it marks unchanged", function()
            local t =
                { head = "b\nc\nb\na\na\na\n", index = "b\nc\nb\na\na\na\n", work = "a\nb\na\na\n" }
            local head_work, head_index, index_work =
                content.three_diffs("/", "f", t.head, t.index, t.work)
            local selection = { old = {}, new = { [1] = true } }
            local stage = require("differ.model.stage")
            local m = stage.marks_of(head_work, head_index, index_work)
            local want =
                stage.reverted(head_work, m, selection, stage.index_origins(head_work, head_index))
            local before = {
                head_work = head_work,
                head_index = head_index,
                hidden = false,
                edits = require("differ.git.staging.write").edits,
                take = false,
            }
            local after = { content.three_diffs("/", "f", t.head, t.index, "b\na\n") }
            assert.is_false((stage.reads_as(want, before, selection, unpack(after))))
        end)
    end)

    -- HEAD's unterminated c and the worktree's c are different lines, so the read-back
    -- can't cancel one against the other
    describe("on HEAD c c c$, index c d c c$, worktree c d x4 x4", function()
        it("X on - c - c refuses", function()
            local t = { head = "c\nc\nc", index = "c\nd\nc\nc", work = "c\nd\nx4\nx4\n" }
            local outcome = fuzz.run_op(t, "X", { old = { [2] = true, [3] = true }, new = {} })
            assert.are.equal("refused", outcome.kind)
        end)
    end)
end)
