local split = require("differ.render.split")

local FULL = math.huge

-- split renders two columns ("old" left, "new" right); expose them under the
-- old_*/new_* names the assertions read
local function render(model, opts)
    local r = split.render(model, opts)
    return {
        old_lines = r.columns[1].lines,
        new_lines = r.columns[2].lines,
        old_map = r.columns[1].map,
        new_map = r.columns[2].map,
        old_folds = r.columns[1].folds,
        new_folds = r.columns[2].folds,
    }
end

local function kinds(map)
    local out = {}
    for i, l in ipairs(map.lines) do
        out[i] = l.kind
    end
    return out
end

describe("render.split substitution", function()
    local model = {
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

    it("lays old and new in aligned columns", function()
        local r = render(model, { context = FULL })
        assert.are.same({ "a", "b", "c", "d", "e" }, r.old_lines)
        assert.are.same({ "a", "b", "C", "d", "e" }, r.new_lines)
        assert.are.equal(#r.old_lines, #r.new_lines)
    end)

    it("classifies the changed row as old on the left, new on the right", function()
        local r = render(model, { context = FULL })
        assert.are.same({ "context", "context", "old", "context", "context" }, kinds(r.old_map))
        assert.are.same({ "context", "context", "new", "context", "context" }, kinds(r.new_map))
        assert.are.equal(3, r.old_map.lines[3].old)
        assert.are.equal(1, r.old_map.lines[3].hunk)
        assert.are.equal(3, r.new_map.lines[3].new)
    end)

    it("builds per-side reverse indices", function()
        local r = render(model, { context = FULL })
        assert.are.same({ [1] = 1, [2] = 2, [3] = 3, [4] = 4, [5] = 5 }, r.old_map.from_old)
        assert.are.same({ [1] = 1, [2] = 2, [3] = 3, [4] = 4, [5] = 5 }, r.new_map.from_new)
    end)
end)

describe("render.split unequal hunks pad with filler", function()
    it("pads the left column when the new side is longer", function()
        local model = {
            path = "x",
            old_rev = "A",
            new_rev = "B",
            old_text = "a\nM\nb\n",
            new_text = "a\nX\nY\nb\n",
            hunks = {
                {
                    old_start = 2,
                    old_count = 1,
                    new_start = 2,
                    new_count = 2,
                    old_lines = { "M" },
                    new_lines = { "X", "Y" },
                },
            },
        }
        local r = render(model, { context = FULL })
        assert.are.same({ "a", "M", "", "b" }, r.old_lines)
        assert.are.same({ "a", "X", "Y", "b" }, r.new_lines)
        assert.are.equal(#r.old_lines, #r.new_lines)
        -- the padded left cell is a meta (filler) row carrying no old lnum
        assert.are.equal("meta", r.old_map.lines[3].kind)
        assert.is_nil(r.old_map.lines[3].old)
        assert.are.equal("new", r.new_map.lines[3].kind)
        assert.are.same({ [1] = 1, [2] = 2, [3] = 4 }, r.old_map.from_old)
        assert.are.same({ [1] = 1, [2] = 2, [3] = 3, [4] = 4 }, r.new_map.from_new)
    end)

    it("pads the right column when the old side is longer", function()
        local model = {
            path = "x",
            old_rev = "A",
            new_rev = "B",
            old_text = "a\nM\nN\nb\n",
            new_text = "a\nX\nb\n",
            hunks = {
                {
                    old_start = 2,
                    old_count = 2,
                    new_start = 2,
                    new_count = 1,
                    old_lines = { "M", "N" },
                    new_lines = { "X" },
                },
            },
        }
        local r = render(model, { context = FULL })
        assert.are.same({ "a", "M", "N", "b" }, r.old_lines)
        assert.are.same({ "a", "X", "", "b" }, r.new_lines)
        assert.are.equal("meta", r.new_map.lines[3].kind)
        assert.is_nil(r.new_map.lines[3].new)
    end)
end)

describe("render.split similarity alignment", function()
    -- an inserted line in the middle of a hunk must open filler at its own row, not
    -- shift the rows below it out of register and noise up their word spans
    local model = {
        path = "x",
        old_rev = "A",
        new_rev = "B",
        old_text = "p`,\nID\n, P)\n",
        new_text = "p,\nt`,\nID\n, P, T)\n",
        hunks = {
            {
                old_start = 1,
                old_count = 3,
                new_start = 1,
                new_count = 4,
                old_lines = { "p`,", "ID", ", P)" },
                new_lines = { "p,", "t`,", "ID", ", P, T)" },
            },
        },
    }

    it("opens filler at the inserted line, keeping later rows aligned", function()
        local r = render(model, { context = FULL })
        assert.are.same({ "p`,", "", "ID", ", P)" }, r.old_lines)
        assert.are.same({ "p,", "t`,", "ID", ", P, T)" }, r.new_lines)
        assert.are.equal(#r.old_lines, #r.new_lines)
    end)

    it("makes the inserted row a left filler, not a positional substitution", function()
        local r = render(model, { context = FULL })
        assert.are.same({ "old", "meta", "old", "old" }, kinds(r.old_map))
        assert.are.same({ "new", "new", "new", "new" }, kinds(r.new_map))
        assert.is_nil(r.old_map.lines[2].old)
        assert.are.equal(2, r.new_map.lines[2].new)
    end)

    it("diffs the identical ID rows against each other, not against the insertion", function()
        local r = render(model, { context = FULL, deep_diff = { enabled = true } })
        -- old[2] (ID) pairs with new[3] (ID): identical, so no word spans
        assert.are.same({}, r.old_map.lines[3].spans)
        assert.are.same({}, r.new_map.lines[3].spans)
    end)
end)

describe("render.split word-level spans", function()
    it("attaches spans to both sides of a positionally paired row", function()
        local model = {
            path = "x",
            old_rev = "A",
            new_rev = "B",
            old_text = "local foo = 1\n",
            new_text = "local bar = 1\n",
            hunks = {
                {
                    old_start = 1,
                    old_count = 1,
                    new_start = 1,
                    new_count = 1,
                    old_lines = { "local foo = 1" },
                    new_lines = { "local bar = 1" },
                },
            },
        }
        local r = render(model, { context = FULL, deep_diff = { enabled = true } })
        assert.are.same({ { col_start = 6, col_end = 9 } }, r.old_map.lines[1].spans)
        assert.are.same({ { col_start = 6, col_end = 9 } }, r.new_map.lines[1].spans)
    end)
end)

describe("render.split context collapsing", function()
    it("emits full content on both sides and marks the far gap foldable", function()
        local model = {
            path = "x",
            old_rev = "A",
            new_rev = "B",
            old_text = "1\n2\n3\n4\n5\n6\n7\n",
            new_text = "1\nX\n3\n4\n5\n6\n7\n",
            hunks = {
                {
                    old_start = 2,
                    old_count = 1,
                    new_start = 2,
                    new_count = 1,
                    old_lines = { "2" },
                    new_lines = { "X" },
                },
            },
        }
        local r = render(model, { context = 1 })
        assert.are.equal(#r.old_lines, #r.new_lines)
        assert.are.equal(7, #r.old_lines) -- full content, nothing dropped
        -- lines 4..7 (the gap middle after hunk 1) fold; both columns share the range
        assert.are.same({ { first = 4, last = 7, gap = 1 } }, r.old_folds)
        assert.are.same({ { first = 4, last = 7, gap = 1 } }, r.new_folds)
    end)
end)

describe("render.split identical content", function()
    it("produces empty columns when there are no hunks", function()
        local r = render({
            path = "x",
            old_rev = "A",
            new_rev = "B",
            old_text = "a\nb\n",
            new_text = "a\nb\n",
            hunks = {},
        }, { context = FULL })
        assert.are.same({}, r.old_lines)
        assert.are.same({}, r.new_lines)
        assert.are.equal(0, r.old_map:len())
        assert.are.equal(0, r.new_map:len())
    end)
end)
