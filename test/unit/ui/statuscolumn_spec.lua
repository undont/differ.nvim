local stacked = require("differ.render.stacked")
local split = require("differ.render.split")
local statuscolumn = require("differ.ui.statuscolumn")

local FULL = math.huge

-- a,b,c,d,e with c -> C (single-digit line numbers, so each rail cell is width 1)
local function sub_model()
    return {
        path = "x",
        old_rev = "A",
        new_rev = "B",
        old_text = "a\nb\nc\nd\ne\n",
        new_text = "a\nb\nC\nd\ne\n",
        hunks = {
            {
                old_start = 3,
                old_count = 1,
                new_start = 3,
                new_count = 1,
                old_lines = { "c" },
                new_lines = { "C" },
            },
        },
    }
end

describe("ui.statuscolumn.format unified", function()
    local rail = statuscolumn.format(stacked.render(sub_model(), { context = FULL }).columns[1])

    it("shows both old and new numbers on a context line", function()
        assert.are.equal("1 1 ", rail[1])
    end)

    it("blanks the new side on a deleted (old) line", function()
        assert.are.equal("3   ", rail[3]) -- old 3, new blank
    end)

    it("blanks the old side on an added (new) line", function()
        assert.are.equal("  3 ", rail[4]) -- old blank, new 3
    end)
end)

describe("ui.statuscolumn.format side columns", function()
    local cols = split.render(sub_model(), { context = FULL }).columns

    it("shows only the old number in the old column", function()
        local rail = statuscolumn.format(cols[1])
        assert.are.equal("1 ", rail[1])
        assert.are.equal("3 ", rail[3]) -- changed row carries the old number
    end)

    it("shows only the new number in the new column", function()
        local rail = statuscolumn.format(cols[2])
        assert.are.equal("1 ", rail[1])
        assert.are.equal("3 ", rail[3]) -- changed row carries the new number
    end)
end)

describe("ui.statuscolumn.format width", function()
    it("right-aligns numbers to the widest line number", function()
        -- 10 lines; line 10 forces width 2
        local old = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n"
        local new = "1\n2\n3\n4\n5\n6\n7\n8\n9\nTEN\n"
        local col = stacked.render({
            path = "x",
            old_rev = "A",
            new_rev = "B",
            old_text = old,
            new_text = new,
            hunks = {
                {
                    old_start = 10,
                    old_count = 1,
                    new_start = 10,
                    new_count = 1,
                    old_lines = { "10" },
                    new_lines = { "TEN" },
                },
            },
        }, { context = FULL }).columns[1]
        local rail = statuscolumn.format(col)
        assert.are.equal(" 1  1 ", rail[1]) -- width 2 each side
    end)
end)
