-- the stage fuzz at a fixed seed: every op it writes leaves the index and file the
-- drawn marks say it should. `make lua-fuzz` runs it large
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

    it("writes no op that moves lines it shouldn't", function()
        local report = fuzz.run({ seed = 1, count = 30 })
        for _, op in ipairs(fuzz.OPS) do
            assert.is_true(report.ops[op].written > 0, op)
            assert.are.equal(0, report.ops[op].mismatched, fuzz.format(report))
        end
    end)
end)
