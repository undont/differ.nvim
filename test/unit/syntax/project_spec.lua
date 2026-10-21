local project = require("differ.syntax.project")

describe("syntax.project", function()
    it("remaps source rows to buffer rows, preserving cols and hl", function()
        -- source lines 1,2,3 land on buffer rows 5,6,7 (1-based map -> 0-based row)
        local from = { [1] = 6, [2] = 7, [3] = 8 }
        local caps = {
            { row = 0, col_start = 0, col_end = 5, hl = "@keyword.lua" },
            { row = 2, col_start = 4, col_end = 7, hl = "@variable.lua" },
        }
        local marks = project.project(caps, from)
        assert.are.same({
            { row = 5, col_start = 0, col_end = 5, hl = "@keyword.lua" },
            { row = 7, col_start = 4, col_end = 7, hl = "@variable.lua" },
        }, marks)
    end)

    it("drops captures whose source line is absent from the column", function()
        -- only old line 2 is present in this column (e.g. lines 1/3 have no partner
        -- or are meta/filler), so captures on rows 0 and 2 fall away
        local from = { [2] = 3 }
        local caps = {
            { row = 0, col_start = 0, col_end = 1, hl = "@a.x" },
            { row = 1, col_start = 2, col_end = 4, hl = "@b.x" },
            { row = 2, col_start = 0, col_end = 1, hl = "@c.x" },
        }
        local marks = project.project(caps, from)
        assert.are.same({ { row = 2, col_start = 2, col_end = 4, hl = "@b.x" } }, marks)
    end)

    it("carries the layer priority through, so injections stay above their host", function()
        local from = { [1] = 1 }
        local marks = project.project({
            {
                row = 0,
                col_start = 0,
                col_end = 4,
                hl = "@markup.raw.block.markdown",
                priority = 90,
            },
            { row = 0, col_start = 0, col_end = 5, hl = "@keyword.lua", priority = 91 },
        }, from)
        assert.are.equal(90, marks[1].priority)
        assert.are.equal(91, marks[2].priority)
    end)

    it("returns nothing for no captures", function()
        assert.are.same({}, project.project({}, { [1] = 1 }))
    end)
end)
