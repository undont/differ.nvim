-- the stage fuzz at a fixed seed: every op it writes leaves the index and file the
-- drawn marks say it should, and where a reading places the index, on a shortest path
-- to the side it takes. `make lua-fuzz` runs it large
local fuzz = require("test.fuzz.stage")

local function text(tokens)
    return (tokens:gsub(" ", "\n")) .. "\n"
end

describe("stage fuzz", function()
    it("reads a reordered index as wrong", function()
        local index = text("a x3 d")
        assert.is_true(fuzz.moved(index, text("a x3 d c x5"), {}, { "c", "x5" }))
        assert.is_false(fuzz.moved(index, text("a d x3 c x5"), {}, { "c", "x5" }))
    end)

    it("reads an entering line outside its hunk as wrong", function()
        local content = require("differ.git.content")
        local union =
            content.union_pairs("/", "f", text("a d d"), text("a x3 d"), text("a x3 c x5"))
        -- one of HEAD's d's and every worktree line
        local keep = {
            old = function(l)
                return l == 3
            end,
            new = function()
                return true
            end,
        }
        assert.is_true(fuzz.placed(union, text("a x3 d c x5"), keep))
        assert.is_false(fuzz.placed(union, text("c a x3 d x5"), keep))
    end)

    local report
    before_each(function()
        report = report or fuzz.run({ seed = 1, count = 30 })
    end)

    it("writes no op that moves lines it shouldn't", function()
        for _, op in ipairs(fuzz.OPS) do
            assert.is_true(report.ops[op].written > 0, op)
            assert.are.equal(0, report.ops[op].mismatched, fuzz.format(report))
        end
    end)

    it("keeps a line and its newline change together", function()
        for _, op in ipairs(fuzz.OPS) do
            assert.are.equal(0, report.ops[op].ending_split, fuzz.format(report))
        end
    end)

    it("gives what the hunk op gives for visual s and u over a whole hunk", function()
        for _, op in ipairs(fuzz.HUNK_OPS) do
            assert.is_true(report.hunks[op].agree > 0, op)
            assert.are.equal(0, report.hunks[op].mismatch, fuzz.format(report))
        end
    end)

    it("moves a read index straight towards the side the hunk op takes", function()
        for _, op in ipairs(fuzz.HUNK_OPS) do
            assert.are.equal(0, report.hunks[op].off_path, fuzz.format(report))
        end
    end)
end)
