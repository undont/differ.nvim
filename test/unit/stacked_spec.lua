local stacked = require("differ.render.stacked")

-- hand-built models use the vim.text.diff index convention (verified against the
-- engine): pure insertions report old_count==0 with old_start at the preceding
-- old line; pure deletions mirror it on the new side

local FULL = math.huge

-- stacked renders a single "unified" column; unwrap it for the assertions
local function render(model, opts)
    return stacked.render(model, opts).columns[1]
end

describe("render.stacked substitution", function()
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

    it("interleaves old then new with full context", function()
        local r = render(model, { context = FULL })
        assert.are.same({ "a", "b", "c", "C", "d", "e" }, r.lines)
    end)

    it("classifies every rail line", function()
        local r = render(model, { context = FULL })
        local kinds = {}
        for i, l in ipairs(r.map.lines) do
            kinds[i] = l.kind
        end
        assert.are.same({ "context", "context", "old", "new", "context", "context" }, kinds)
        assert.are.equal(1, r.map.lines[3].hunk)
        assert.are.equal(3, r.map.lines[3].old)
        assert.is_nil(r.map.lines[3].new)
        assert.are.equal(3, r.map.lines[4].new)
        assert.is_nil(r.map.lines[4].old)
    end)

    it("builds reverse indices that point old/new lnums at buffer lnums", function()
        local r = render(model, { context = FULL })
        assert.are.same({ [1] = 1, [2] = 2, [3] = 3, [4] = 5, [5] = 6 }, r.map.from_old)
        assert.are.same({ [1] = 1, [2] = 2, [3] = 4, [4] = 5, [5] = 6 }, r.map.from_new)
    end)
end)

describe("render.stacked context collapsing", function()
    -- two changes far apart so an interior gap exceeds 2*context
    local model = {
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
    }

    it("emits full content and marks the far gap's middle foldable", function()
        local r = render(model, { context = 1 })
        -- every line is rendered (nothing dropped); the buffer holds full content
        assert.are.same({
            "1", -- 1 context (tail of file start / lead of hunk 1)
            "2", -- 2 old
            "X", -- 3 new
            "3", -- 4 trailing context of hunk 1
            "4", -- 5 foldable middle (4,5,6)
            "5", -- 6 foldable
            "6", -- 7 foldable
            "7", -- 8 leading context of hunk 2
            "8", -- 9 old
            "Y", -- 10 new
            "9", -- 11 trailing context
        }, r.lines)
        -- the middle 3 lines (buffer rows 5..7) collapse under a native fold
        assert.are.same({ { first = 5, last = 7, gap = 1 } }, r.folds)
    end)

    it("marks nothing foldable under full context", function()
        local r = render(model, { context = FULL })
        assert.are.same({}, r.folds)
        assert.are.equal(9 + 2, #r.lines) -- still full content: 9 unchanged + 2 added (X,Y)
    end)
end)

describe("render.stacked add-only", function()
    it("renders an inserted line as new with surrounding context", function()
        local model = {
            path = "x",
            old_rev = "A",
            new_rev = "B",
            old_text = "a\nb\n",
            new_text = "a\nX\nb\n",
            hunks = {
                {
                    old_start = 1,
                    old_count = 0,
                    new_start = 2,
                    new_count = 1,
                    old_lines = {},
                    new_lines = { "X" },
                },
            },
        }
        local r = render(model, { context = FULL })
        assert.are.same({ "a", "X", "b" }, r.lines)
        assert.are.same({ "context", "new", "context" }, {
            r.map.lines[1].kind,
            r.map.lines[2].kind,
            r.map.lines[3].kind,
        })
        assert.are.same({ [1] = 1, [2] = 3 }, r.map.from_old)
        assert.are.same({ [1] = 1, [2] = 2, [3] = 3 }, r.map.from_new)
    end)
end)

describe("render.stacked delete-only", function()
    it("renders a removed line as old with surrounding context", function()
        local model = {
            path = "x",
            old_rev = "A",
            new_rev = "B",
            old_text = "a\nb\nc\n",
            new_text = "a\nc\n",
            hunks = {
                {
                    old_start = 2,
                    old_count = 1,
                    new_start = 1,
                    new_count = 0,
                    old_lines = { "b" },
                    new_lines = {},
                },
            },
        }
        local r = render(model, { context = FULL })
        assert.are.same({ "a", "b", "c" }, r.lines)
        assert.are.same({ "context", "old", "context" }, {
            r.map.lines[1].kind,
            r.map.lines[2].kind,
            r.map.lines[3].kind,
        })
        assert.are.same({ [1] = 1, [2] = 2, [3] = 3 }, r.map.from_old)
        assert.are.same({ [1] = 1, [2] = 3 }, r.map.from_new)
    end)
end)

describe("render.stacked word-level spans", function()
    it("attaches spans to paired changed lines", function()
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
        assert.are.same({ { col_start = 6, col_end = 9 } }, r.map.lines[1].spans)
        assert.are.same({ { col_start = 6, col_end = 9 } }, r.map.lines[2].spans)
    end)

    it("omits spans when deep_diff is disabled", function()
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
        local r = render(model, { context = FULL, deep_diff = { enabled = false } })
        assert.is_nil(r.map.lines[1].spans)
        assert.is_nil(r.map.lines[2].spans)
    end)
end)

describe("render.stacked identical content", function()
    it("produces no lines when there are no hunks", function()
        local r = render({
            path = "x",
            old_rev = "A",
            new_rev = "B",
            old_text = "a\nb\n",
            new_text = "a\nb\n",
            hunks = {},
        }, { context = FULL })
        assert.are.same({}, r.lines)
        assert.are.equal(0, r.map:len())
    end)
end)
