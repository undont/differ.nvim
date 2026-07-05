local stacked = require("differ.render.stacked")
local winbar = require("differ.ui.winbar")

-- two hunks far apart -> stacked (full context) buffer:
--   1 ctx | 2 old"2" h1 | 3 new"X" h1 | 4-8 ctx | 9 old"8" h2 | 10 new"Y" h2 | 11 ctx
local function two_hunk_map()
    return stacked.render({
        path = "x",
        old_rev = "A",
        new_rev = "B",
        old_text = "1\n2\n3\n4\n5\n6\n7\n8\n9\n",
        new_text = "1\nX\n3\n4\n5\n6\n7\nY\n9\n",
        hunks = {
            {
                old_start = 2,
                old_count = 1,
                new_start = 2,
                new_count = 1,
                old_lines = { "2" },
                new_lines = { "X" },
            },
            {
                old_start = 8,
                old_count = 1,
                new_start = 8,
                new_count = 1,
                old_lines = { "8" },
                new_lines = { "Y" },
            },
        },
    }, { context = math.huge }).columns[1].map
end

describe("winbar.hunk_at", function()
    local map = two_hunk_map()

    it("is 0 before the first hunk starts", function()
        assert.are.equal(0, winbar.hunk_at(map, 1))
    end)

    it("counts the first hunk from its start through its own lines", function()
        assert.are.equal(1, winbar.hunk_at(map, 2))
        assert.are.equal(1, winbar.hunk_at(map, 3))
    end)

    it("still reads as the first hunk on trailing context after it", function()
        assert.are.equal(1, winbar.hunk_at(map, 5))
        assert.are.equal(1, winbar.hunk_at(map, 8))
    end)

    it("counts the second hunk from its start onward", function()
        assert.are.equal(2, winbar.hunk_at(map, 9))
        assert.are.equal(2, winbar.hunk_at(map, 10))
    end)

    it("still reads as the second hunk on trailing context past it", function()
        assert.are.equal(2, winbar.hunk_at(map, 11))
    end)

    it("clamps to the map's last line past the end", function()
        assert.are.equal(2, winbar.hunk_at(map, 999))
    end)
end)

describe("winbar.hunk_at with no hunks", function()
    it("is always 0", function()
        local map = stacked.render({
            path = "x",
            old_rev = "A",
            new_rev = "B",
            old_text = "a\nb\n",
            new_text = "a\nb\n",
            hunks = {},
        }, { context = math.huge }).columns[1].map
        assert.are.equal(0, winbar.hunk_at(map, 1))
        assert.are.equal(0, winbar.hunk_at(map, 2))
    end)
end)
