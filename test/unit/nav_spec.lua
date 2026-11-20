local stacked = require("differ.render.stacked")
local split = require("differ.render.split")
local nav = require("differ.nav")

-- two hunks far apart -> stacked (full context) buffer:
--   1 ctx | 2 old"2" h1 | 3 new"X" h1 | 4-8 ctx | 9 old"8" h2 | 10 new"Y" h2 | 11 ctx
-- hunk starts at buffer lnums 2 and 9
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

describe("nav.next_hunk", function()
    local map = two_hunk_map()

    it("jumps from before the first hunk to its start", function()
        assert.are.equal(2, nav.next_hunk(map, 1))
    end)

    it("jumps from inside the first hunk to the second", function()
        assert.are.equal(9, nav.next_hunk(map, 2))
        assert.are.equal(9, nav.next_hunk(map, 5)) -- from context between hunks
    end)

    it("returns nil at/after the last hunk (no wrap)", function()
        assert.is_nil(nav.next_hunk(map, 9))
        assert.is_nil(nav.next_hunk(map, 11))
    end)
end)

describe("nav.prev_hunk", function()
    local map = two_hunk_map()

    it("jumps from after the last hunk back to its start", function()
        assert.are.equal(9, nav.prev_hunk(map, 11))
    end)

    it("jumps from inside the second hunk to the first", function()
        assert.are.equal(2, nav.prev_hunk(map, 9))
        assert.are.equal(2, nav.prev_hunk(map, 5))
    end)

    it("returns nil at/before the first hunk (no wrap)", function()
        assert.is_nil(nav.prev_hunk(map, 2))
        assert.is_nil(nav.prev_hunk(map, 1))
    end)
end)

-- three hunks far apart -> stacked (full context) buffer, hunk starts at buffer
-- lnums 2, 6 and 10:
--   1 ctx | 2 old"2" h1 | 3 new"X" h1 | 4-5 ctx | 6 old"5" h2 | 7 new"Y" h2
--   | 8-9 ctx | 10 old"8" h3 | 11 new"Z" h3 | 12 ctx
local function three_hunk_map()
    local function hunk(at, old, new)
        return {
            old_start = at,
            old_count = 1,
            new_start = at,
            new_count = 1,
            old_lines = { old },
            new_lines = { new },
        }
    end
    return stacked.render({
        path = "x",
        old_rev = "A",
        new_rev = "B",
        old_text = "1\n2\n3\n4\n5\n6\n7\n8\n9\n",
        new_text = "1\nX\n3\n4\nY\n6\n7\nZ\n9\n",
        hunks = { hunk(2, "2", "X"), hunk(5, "5", "Y"), hunk(8, "8", "Z") },
    }, { context = math.huge }).columns[1].map
end

-- hunk 2 staged, 1 and 3 not: the shape the staging review flow scans over
local function unstaged(h)
    return h ~= 2
end
local function nothing()
    return false
end

describe("nav.next_hunk with a filter", function()
    local map = three_hunk_map()

    it("skips over a hunk the filter rejects", function()
        assert.are.equal(6, nav.next_hunk(map, 2)) -- unfiltered: the very next one
        assert.are.equal(10, nav.next_hunk(map, 2, unstaged)) -- filtered: past hunk 2
    end)

    it("returns nil when nothing after `lnum` matches", function()
        assert.is_nil(nav.next_hunk(map, 10, unstaged)) -- hunk 3 is the last match
        assert.is_nil(nav.next_hunk(map, 1, nothing))
    end)
end)

describe("nav.prev_hunk with a filter", function()
    local map = three_hunk_map()

    it("skips over a hunk the filter rejects", function()
        assert.are.equal(6, nav.prev_hunk(map, 10)) -- unfiltered: the very previous one
        assert.are.equal(2, nav.prev_hunk(map, 10, unstaged)) -- filtered: back past hunk 2
    end)

    it("returns nil when nothing before `lnum` matches", function()
        assert.is_nil(nav.prev_hunk(map, 2, unstaged)) -- hunk 1 is the first match
        assert.is_nil(nav.prev_hunk(map, 12, nothing))
    end)
end)

describe("nav.first_hunk / nav.last_hunk", function()
    local map = three_hunk_map()

    it("spans the whole map, ends included", function()
        assert.are.equal(2, nav.first_hunk(map)) -- the hunk at lnum 2, not skipped
        assert.are.equal(10, nav.last_hunk(map)) -- and the last one, not skipped
    end)

    it("narrows to the filter, matching a single hunk from either end", function()
        local only_two = function(h)
            return h == 2
        end
        assert.are.equal(6, nav.first_hunk(map, only_two))
        assert.are.equal(6, nav.last_hunk(map, only_two))
    end)

    it("returns nil when the filter matches nothing", function()
        assert.is_nil(nav.first_hunk(map, nothing))
        assert.is_nil(nav.last_hunk(map, nothing))
    end)
end)

describe("nav.file_line", function()
    -- the same two-hunk full-context buffer: buf 2 = removed "2" (no new), buf 3 =
    -- added "X" (new=2), trailing buf 11 = context "9" (new=9)
    local map = two_hunk_map()

    it("returns the cursor line's own new when it has one", function()
        assert.are.equal(1, nav.file_line(map, 1)) -- context line, new=1
        assert.are.equal(2, nav.file_line(map, 3)) -- the added "X", new=2
    end)

    it("maps a deleted (old-only) line forward to the next new line", function()
        -- buffer line 2 is the removed "2" (no new); the next new is the added "X"
        assert.are.equal(2, nav.file_line(map, 2))
    end)

    it("falls back to the nearest preceding new past the last new line", function()
        local last = #map.lines
        assert.are.equal(9, nav.file_line(map, last)) -- trailing context, new=9
    end)

    it("returns nil when the map has no new side at all", function()
        local del = stacked.render({
            path = "x",
            old_rev = "A",
            new_rev = "B",
            old_text = "a\nb\n",
            new_text = "",
            hunks = {
                {
                    old_start = 1,
                    old_count = 2,
                    new_start = 0,
                    new_count = 0,
                    old_lines = { "a", "b" },
                    new_lines = {},
                },
            },
        }, { context = math.huge }).columns[1].map
        assert.is_nil(nav.file_line(del, 1))
    end)
end)

describe("nav with no hunks", function()
    it("returns nil both directions", function()
        local map = stacked.render({
            path = "x",
            old_rev = "A",
            new_rev = "B",
            old_text = "a\nb\n",
            new_text = "a\nb\n",
            hunks = {},
        }, { context = math.huge }).columns[1].map
        assert.is_nil(nav.next_hunk(map, 1))
        assert.is_nil(nav.prev_hunk(map, 1))
        assert.is_nil(nav.first_hunk(map))
        assert.is_nil(nav.last_hunk(map))
    end)
end)

-- a moved pair: histogram diff reports a pure deletion then a pure insertion, so
-- each split column sees only one of them:
--   row  old    new
--   1    a      a
--   2    /10    .      h1
--   3    +11    .      h1
--   4    *2     *2
--   5    .      +11    h2
--   6    .      /10    h2
--   7    z      z
local function moved_pair_columns()
    return split.render({
        path = "x",
        old_rev = "A",
        new_rev = "B",
        old_text = "a\n/10\n+11\n*2\nz\n",
        new_text = "a\n*2\n+11\n/10\nz\n",
        hunks = {
            {
                old_start = 2,
                old_count = 2,
                new_start = 1,
                new_count = 0,
                old_lines = { "/10", "+11" },
                new_lines = {},
            },
            {
                old_start = 4,
                old_count = 0,
                new_start = 3,
                new_count = 2,
                old_lines = {},
                new_lines = { "+11", "/10" },
            },
        },
    }, { context = math.huge }).columns
end

describe("nav.merge", function()
    local columns = moved_pair_columns()
    local old_map, new_map = columns[1].map, columns[2].map

    it("leaves each column seeing one hunk", function()
        assert.are.equal(2, nav.first_hunk(old_map))
        assert.are.equal(2, nav.last_hunk(old_map))
        assert.are.equal(5, nav.first_hunk(new_map))
        assert.are.equal(5, nav.last_hunk(new_map))
    end)

    it("resolves filler rows to the hunk beside them", function()
        local map = nav.merge({ old_map, new_map })
        assert.are.equal(1, map.lines[2].hunk)
        assert.are.equal(2, map.lines[5].hunk)
        assert.are.equal(2, nav.next_hunk(map, 0))
        assert.are.equal(5, nav.next_hunk(map, 2))
        assert.are.equal(2, nav.prev_hunk(map, 5))
        assert.are.equal(5, nav.last_hunk(map))
    end)

    it("keeps both sides' reverse indices", function()
        local map = nav.merge({ old_map, new_map })
        assert.are.equal(2, map.from_old[2])
        assert.are.equal(5, map.from_new[3])
        assert.are.equal(7, map.from_old[5])
        assert.are.equal(7, map.from_new[5])
    end)

    it("still applies the filter", function()
        local map = nav.merge({ old_map, new_map })
        local function second(h)
            return h == 2
        end
        assert.are.equal(5, nav.first_hunk(map, second))
        assert.is_nil(nav.prev_hunk(map, 5, second))
    end)

    it("passes a single map through", function()
        assert.are.equal(old_map, nav.merge({ old_map }))
    end)
end)

describe("nav.carry_line", function()
    -- hunk indices are vim.text.diff(a, b, { result_type = "indices" }) output for
    -- the a/b texts beside each case

    -- returns carry_line's two results as one table for a single assertion
    local function carry(hunks, line, b_lines)
        local lnum, unchanged = nav.carry_line(hunks, line, b_lines)
        return { lnum, unchanged }
    end

    it("keeps the line when there are no hunks", function()
        -- a = b = "a\nb\nc\n"
        assert.are.same({ 2, true }, carry({}, 2, 3))
    end)

    it("shifts down past an insertion above", function()
        -- a = "a\nb\nc\n", b = "a\nX\nY\nb\nc\n"
        local hunks = { { 1, 0, 2, 2 } }
        assert.are.same({ 1, true }, carry(hunks, 1, 5))
        assert.are.same({ 4, true }, carry(hunks, 2, 5))
        assert.are.same({ 5, true }, carry(hunks, 3, 5))
    end)

    it("shifts up past a deletion above", function()
        -- a = "a\nb\nc\nd\n", b = "a\nd\n"
        assert.are.same({ 2, true }, carry({ { 2, 2, 1, 0 } }, 4, 2))
    end)

    it("lands a line inside a replaced block on the block's start", function()
        -- a = "a\nb\nc\nd\ne\n", b = "a\nX\ne\n"
        local hunks = { { 2, 3, 2, 1 } }
        assert.are.same({ 2, false }, carry(hunks, 2, 3))
        assert.are.same({ 2, false }, carry(hunks, 4, 3))
        assert.are.same({ 3, true }, carry(hunks, 5, 3))
    end)

    it("lands a line inside a deleted block on the line after the gap", function()
        -- a = "a\nb\nc\nd\n", b = "a\nd\n"
        assert.are.same({ 2, false }, carry({ { 2, 2, 1, 0 } }, 3, 2))
    end)

    it("clamps a deleted block at the bottom to b's last line", function()
        -- a = "a\nb\nc\n", b = "a\n"
        assert.are.same({ 1, false }, carry({ { 2, 2, 1, 0 } }, 3, 1))
    end)

    it("shifts every line past an insertion at the top", function()
        -- a = "a\nb\n", b = "X\nY\na\nb\n"
        local hunks = { { 0, 0, 1, 2 } }
        assert.are.same({ 3, true }, carry(hunks, 1, 4))
        assert.are.same({ 4, true }, carry(hunks, 2, 4))
    end)

    it("leaves lines above an insertion at the bottom alone", function()
        -- a = "a\nb\n", b = "a\nb\nX\n"
        assert.are.same({ 2, true }, carry({ { 2, 0, 3, 1 } }, 2, 3))
    end)

    it("adds up the shift across several hunks", function()
        -- a = "a\nb\nc\nd\ne\nf\ng\n", b = "X\na\nc\nd\nY\nZ\ne\nf\ng\n"
        local hunks = { { 0, 0, 1, 1 }, { 2, 1, 2, 0 }, { 4, 0, 5, 2 } }
        assert.are.same({ 4, true }, carry(hunks, 4, 9))
        assert.are.same({ 7, true }, carry(hunks, 5, 9))
        assert.are.same({ 9, true }, carry(hunks, 7, 9))
    end)

    it("lands on line 1 when b is empty", function()
        -- a = "a\nb\n", b = ""
        assert.are.same({ 1, false }, carry({ { 1, 2, 0, 0 } }, 2, 0))
    end)
end)
